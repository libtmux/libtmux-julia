# A tmux client that names no socket follows an inherited TMUX to the server its
# caller is inside, and otherwise goes to the default socket under TMUX_TMPDIR.
# Entering the sandbox removes what selects a server and points TMUX_TMPDIR at a
# directory of this run's own. A child started with a replaced environment sees
# only that environment, so it takes `child_entries` to keep TMUX_TMPDIR. Any
# socket below the directory is a leak: it is stopped with -S, checked gone and
# named. Findings name variables and never values: a TMUX value names a server.
module TestSandbox

using Sockets

const MARKER = "LIBTMUX_TEST_SANDBOX"
const PREFIX = "ltj-sb-"
# sun_path is 104 bytes on macOS. The directory leaves room for /tmux-<uid>/<name>.
const MAX_BYTES = 60
# The separator and the six characters mktempdir appends to PREFIX.
const SUFFIX_BYTES = 7
# Seconds a server may take to give up its socket after kill-server.
const PATIENCE = Ref(5.0)

struct Refused <: Exception
    findings::Vector{String}
end

Base.showerror(io::IO, refusal::Refused) = print(io, join(refusal.findings, "; "))

ambient(name::AbstractString) =
    name == "TMUX" || name == "TMUX_PANE" || startswith(name, "LIBTMUX_SOCKET")

function directory_problem(env)
    directory = get(env, "TMUX_TMPDIR", "")
    isempty(directory) && return "TMUX_TMPDIR is unset"
    isabspath(directory) || return "TMUX_TMPDIR is not an absolute path"
    ncodeunits(directory) <= MAX_BYTES ||
        return "TMUX_TMPDIR is longer than $MAX_BYTES bytes"
    get(env, MARKER, "") == directory && startswith(basename(directory), PREFIX) ||
        return "TMUX_TMPDIR is not the sandbox directory of this run"
    isdir(directory) && stat(directory).uid == Libc.getuid() ||
        return "the sandbox directory is missing or belongs to another user"
    stat(directory).mode & 0o077 == 0 ||
        return "the sandbox directory is open to other users"
    nothing
end

"""
    violations(env=ENV) -> Vector{String}

List what keeps `env` from being a sandbox: a variable that selects a tmux
server, or a `TMUX_TMPDIR` that is not this run's directory. A finding names
the variable and never its value.
"""
function violations(env=ENV)
    found = ["$name is set" for name in sort!(String[k for k in keys(env) if ambient(k)])]
    problem = directory_problem(env)
    problem === nothing || push!(found, problem)
    found
end

default_roots(env) = (get(env, "TMPDIR", "/tmp"), "/tmp")

function create(roots)
    for root in roots
        ncodeunits(root) + ncodeunits(PREFIX) + SUFFIX_BYTES <= MAX_BYTES || continue
        try
            return mktempdir(root; prefix=PREFIX, cleanup=false)
        catch error
            error isa Union{SystemError,Base.IOError} || rethrow()
        end
    end
    throw(
        Refused([
            "no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one",
        ]),
    )
end

"""
    prepare!(env; roots) -> (directory, created)

Turn `env` into a sandbox: remove every variable that selects a server and make
`TMUX_TMPDIR` a directory of this run's own, under the first of `roots` that is
short enough. An `env` that already holds this run's sandbox keeps it, so a child
process joins its parent's directory. Throw `Refused` when `env` still fails
`violations`.
"""
function prepare!(env; roots=default_roots(env))
    joined = directory_problem(env) === nothing
    for name in String[k for k in keys(env) if ambient(k)]
        delete!(env, name)
    end
    directory = joined ? env["TMUX_TMPDIR"] : create(roots)
    env["TMUX_TMPDIR"] = directory
    env[MARKER] = directory
    found = violations(env)
    if !isempty(found)
        joined || rm(directory; recursive=true, force=true)
        throw(Refused(found))
    end
    directory, !joined
end

"""
    child_entries(env=ENV) -> Vector{Pair{String,String}}

The entries every replaced environment for a tmux child carries. A child started
with `setenv(command, dict)` or `env=dict` sees only `dict`, so without
`TMUX_TMPDIR` a client that names no socket would reach the default socket under
`/tmp`, which is the developer's own. Splat the result into the dictionary:
`Dict("PATH" => ..., TestSandbox.child_entries()...)`. Throw `Refused` when `env`
is not this run's sandbox.
"""
function child_entries(env=ENV)
    problem = directory_problem(env)
    problem === nothing || throw(Refused([problem]))
    ["TMUX_TMPDIR" => env["TMUX_TMPDIR"]]
end

default_tmux() = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")

# Every socket in the tree, as a path below `directory`. A symlink is not
# followed: a server it names is not this sandbox's to stop.
function sockets(directory)
    found = String[]
    isdir(directory) || return found
    for (root, _, names) in walkdir(directory; onerror=_ -> nothing), name in names
        path = joinpath(root, name)
        issocket(lstat(path)) && push!(found, relpath(path, directory))
    end
    sort!(found)
end

# Connecting is what a client does, so it is what tells a live server from a
# socket file that nothing listens on. A full backlog is a server too busy to
# accept, not an absent one.
function answers(socket)
    try
        close(Sockets.connect(socket))
        true
    catch error
        error isa Base.IOError || rethrow()
        error.code == Base.UV_EAGAIN
    end
end

function gone(socket)
    deadline = time() + PATIENCE[]
    while answers(socket)
        time() < deadline || return false
        sleep(0.025)
    end
    true
end

function stop(socket; tmux=default_tmux())
    command = ignorestatus(`$tmux -u -N -S $socket kill-server`)
    try
        process = run(pipeline(command; stdout=devnull, stderr=devnull); wait=false)
        if timedwait(() -> process_exited(process), PATIENCE[]; pollint=0.02) !== :ok
            kill(process)
            wait(process)
        end
    catch error
        error isa Base.IOError || rethrow()
    end
    nothing
end

"""
    sweep(directory; tmux) -> (findings, kept)

Look for sockets anywhere in the tree below `directory`. `tmux-<uid>/default`
is where a client that named no socket goes; any other socket belongs to a server
a test started and left, with `-S` or `-L`. Stop each with
`tmux -S <path> kill-server` and connect to it again to see that it is gone. A
stopped or stale socket is removed. `findings` names every socket as a path below
`directory`, and `kept` names those whose server still answers: the caller must
not delete `directory` while any remain.
"""
function sweep(directory; tmux=default_tmux())
    findings, kept = String[], String[]
    uid_directory = "tmux-$(Libc.getuid())"
    for name in sockets(directory)
        path = joinpath(directory, name)
        served = answers(path)
        stop(path; tmux)
        if !gone(path)
            push!(kept, name)
            push!(findings, "a server still answers on $name after kill-server")
            continue
        end
        rm(path; force=true)
        push!(
            findings,
            if name == uid_directory * "/default"
                "a client started without -S or -L and chose $name in the sandbox"
            elseif served
                "a server was left running on $name in the sandbox"
            else
                "a socket was left at $name in the sandbox"
            end,
        )
    end
    findings, kept
end

"""
    verify!(env=ENV; tmux)

Throw `Refused` when `env` has left the sandbox, or when a socket exists
anywhere in it: a client that started without `-S` or `-L`, or a server a test
left on its own socket. Each is stopped and removed, so a later call does not
blame the next file; a server that survives `kill-server` is named.
"""
function verify!(env=ENV; tmux=default_tmux())
    found = violations(env)
    isempty(found) && append!(found, first(sweep(env["TMUX_TMPDIR"]; tmux)))
    isempty(found) || throw(Refused(found))
    nothing
end

"""
    enter!(env=ENV; roots) -> String

Enter the sandbox and return its directory. The process that made the directory
sweeps it at exit and fails the run if it holds a socket. It deletes the
directory only when no server answers there.
"""
function enter!(env=ENV; roots=default_roots(env))
    directory, created = prepare!(env; roots)
    if created
        atexit() do
            findings, kept = sweep(directory)
            isempty(kept) &&
                startswith(basename(directory), PREFIX) &&
                rm(directory; recursive=true, force=true)
            if !isempty(findings)
                println(
                    stderr,
                    "libtmux-julia tests left sockets in the sandbox: ",
                    join(findings, "; "),
                )
                isempty(kept) || println(
                    stderr,
                    "the sandbox directory ",
                    basename(directory),
                    " was kept because a server still answers there",
                )
                exit(1)
            end
        end
    end
    directory
end

"""
    enter_or_refuse!(env=ENV; roots) -> String

Call [`enter!`](@ref). When the sandbox cannot be made, print what failed, never
a value, and exit with status 2 before any test runs.
"""
function enter_or_refuse!(env=ENV; roots=default_roots(env))
    try
        return enter!(env; roots)
    catch error
        error isa Refused || rethrow()
        println(stderr, "libtmux-julia tests refused to run: ", sprint(showerror, error))
        exit(2)
    end
end

end

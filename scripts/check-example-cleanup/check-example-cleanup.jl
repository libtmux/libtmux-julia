# Run unchanged exported examples with an audited tmux executable boundary.
#
# usage:
#   julia scripts/check-example-cleanup/check-example-cleanup.jl \
#       [--pure] --tmux TMUX --cwd DIR -- COMMAND...
#   julia scripts/check-example-cleanup/check-example-cleanup.jl \
#       --negative-control --tmux TMUX --cwd DIR -- JULIA [FLAGS]
#   julia scripts/check-example-cleanup/check-example-cleanup.jl --identity-self-test
#
# The example gets a private tmux wrapper as LIBTMUX_TEST_TMUX. The wrapper records
# each tmux process the example starts, refuses a socket outside the owned
# directory, and can fail one command after the first session exists. Afterwards
# the checker verifies, independently of the example, that every recorded process is
# gone and that no daemon left its socket directory. Pass --pure for an example
# that must start no tmux. The tests are in tests/runtests.jl.

module CheckExampleCleanup

import TOML

const FAULT = "libtmux-example-injected-command-failure"

function ps_process_identity(pid)
    output = IOBuffer()
    process =
        run(pipeline(ignorestatus(`ps -p $pid -o lstart=`); stdout=output, stderr=devnull))
    process.exitcode == 0 ? strip(String(take!(output))) : nothing
end

"A value that changes when the process is replaced, or `nothing` for a process that is gone."
function process_identity(pid::Integer)
    if Sys.islinux()
        text = try
            read("/proc/$pid/stat", String)
        catch error
            error isa SystemError || rethrow()
            return nothing
        end
        return split(text[(last(findlast(')', text))+1):end])[20]
    end
    ps_process_identity(pid)
end

function identity_self_test()
    current = process_identity(getpid())
    current === nothing && error("current process has no identity")
    child = run(`true`; wait=false)
    pid = getpid(child)
    wait(child)
    process_identity(pid) === nothing || error("reaped child remains identifiable")
    current == process_identity(getpid()) || error("current identity changed")
    println("PASS process identity lookup")
end

# The audited stand-in for tmux. It records the process, refuses strays, can fail one
# command after the first session exists, and then becomes tmux. It is a POSIX shell
# script because a Julia wrapper starts too slowly for the library's 900 ms version
# probe; .github/SCRIPTS.md records the measurement.
function wrapper_source(root, tmux, fault)
    template = raw"""
#!/bin/sh
root=@ROOT@
tmux=@TMUX@
fault=@FAULT@
socket=
daemon=false
creates=false
previous=
for argument in "$@"; do
    [ "$previous" = -S ] && [ -z "$socket" ] && socket=$argument
    [ "$argument" = -D ] && daemon=true
    [ "$argument" = new-session ] && creates=true
    previous=$argument
done
if [ -n "$socket" ]; then
    case "$socket" in
        "$root"/*) ;;
        *) echo "example attempted a tmux socket outside its owned directory" >&2; exit 97 ;;
    esac
elif [ "$*" != "-V" ]; then
    echo "example attempted tmux without an explicit owned socket" >&2
    exit 97
fi
if [ -r /proc/$$/stat ]; then
    started=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
else
    started=$(ps -p $$ -o lstart= | sed 's/^ *//')
fi
{
    printf 'pid = %s\nstarted = "%s"\ndaemon = %s\n' "$$" "$started" "$daemon"
    [ -n "$socket" ] && printf 'socket = "%s"\n' "$socket"
    [ "$daemon" = true ] && printf 'owner = "%s"\n' "$(cat "$(dirname "$socket")/owner")"
} > "$root/process-$$.toml"
if [ "$fault" = true ] && [ -n "$socket" ] && [ "$daemon" = false ] && mv "$root/armed" "$root/fired" 2>/dev/null; then
    sessions=$("$tmux" -N -S "$socket" list-sessions -F '#{session_id}') || exit 98
    case "$sessions" in
        '$'*) ;;
        *) echo "failure injection did not follow session creation" >&2; exit 98 ;;
    esac
    printf 'client = %s\nexit = 86\n' "$$" > "$root/fault.toml"
    echo @MARKER@ >&2
    exit 86
fi
if [ "$fault" = true ] && [ "$creates" = true ] && [ ! -e "$root/fault.toml" ]; then
    : > "$root/armed"
fi
exec "$tmux" "$@"
"""
    shell_word(text) = "'" * replace(text, "'" => "'\\''") * "'"
    replace(
        lstrip(template),
        "@ROOT@" => shell_word(root),
        "@TMUX@" => shell_word(tmux),
        "@FAULT@" => string(fault),
        "@MARKER@" => FAULT,
    )
end

# A process that exited but is not reaped yet, as an orphan adopted by a subreaper stays
# until its new parent collects it, is gone for this purpose.
function process_exited(pid, started)
    identity = process_identity(pid)
    identity == started || return true
    Sys.islinux() || return false
    text = try
        read("/proc/$pid/stat", String)
    catch error
        error isa SystemError || rethrow()
        return true
    end
    first(split(text[(last(findlast(')', text))+2):end])) in ("Z", "X")
end

# Stop only the recorded process instance, after a failed audit.
function terminate_record(record)
    pid = record["pid"]
    process_exited(pid, record["started"]) && return nothing
    function wait_exit(seconds)
        deadline = time() + seconds
        while !process_exited(pid, record["started"]) && time() < deadline
            sleep(0.01)
        end
        process_exited(pid, record["started"])
    end
    ccall(:kill, Cint, (Cint, Cint), pid, 15)
    wait_exit(0.9) && return nothing
    ccall(:kill, Cint, (Cint, Cint), pid, 9)
    wait_exit(0.9) || error("owned example process did not exit after rescue")
    nothing
end

function records_in(root)
    [
        TOML.parsefile(joinpath(root, name)) for name in sort(readdir(root)) if
        startswith(name, "process-") && endswith(name, ".toml")
    ]
end

function run_example(command::Cmd; tmux, env, cwd, fault=false, diagnostics=true)
    started = time()
    mktempdir("/tmp"; prefix="ltj-ex-") do directory
        root = realpath(directory)
        wrapper = joinpath(root, "tmux")
        write(wrapper, wrapper_source(root, realpath(Sys.which(tmux)), fault))
        chmod(wrapper, 0o700)
        child = Dict{String,String}(string(k) => string(v) for (k, v) in env)
        # A client that names no socket must reach neither the caller's server nor the
        # default socket: the wrapper refuses it, and TMUX_TMPDIR is ours.
        for name in collect(keys(child))
            (name in ("TMUX", "TMUX_PANE") || startswith(name, "LIBTMUX_SOCKET")) &&
                delete!(child, name)
        end
        merge!(
            child,
            Dict("LIBTMUX_TEST_TMUX" => wrapper, "TMPDIR" => root, "TMUX_TMPDIR" => root),
        )
        out, err = IOBuffer(), IOBuffer()
        try
            process = run(
                pipeline(setenv(Cmd(command; dir=cwd), child); stdout=out, stderr=err);
                wait=false,
            )
            timer = Timer(60) do _
                process_running(process) && kill(process, Base.SIGKILL)
            end
            try
                wait(process)
            finally
                close(timer)
            end
            records = records_in(root)
            daemons = filter(item -> item["daemon"], records)
            injected = isfile(joinpath(root, "fault.toml"))
            problems = String[]
            if fault
                (process.exitcode == 0 || !injected) && push!(
                    problems,
                    "example did not propagate the injected command failure",
                )
            elseif process.exitcode != 0
                push!(problems, "example exited $(process.exitcode)")
            end
            for record in records
                process_identity(record["pid"]) == record["started"] && push!(
                    problems,
                    "example left a daemon or client process alive or unreaped",
                )
            end
            for record in daemons
                isdir(dirname(record["socket"])) &&
                    push!(problems, "example left its owned socket directory")
            end
            if !isempty(problems)
                if diagnostics
                    write(stdout, take!(out))
                    write(stderr, take!(err))
                end
                error(join(unique(problems), "; "))
            end
            (;
                fault,
                daemons=length(daemons),
                clients=length(records) - length(daemons),
                exit=process.exitcode,
                seconds=time() - started,
                injected,
            )
        finally
            foreach(terminate_record, records_in(root))
        end
    end
end

const NEGATIVE_PROGRAM = """
using LibTmux
owned = open_server(; tmux=ENV["LIBTMUX_TEST_TMUX"])
new_session(owned.server; name="missing-close", command=["/bin/cat"])
"""

function negative_control(command::Cmd; tmux, cwd)
    message = try
        run_example(`$command -e $NEGATIVE_PROGRAM`; tmux, env=ENV, cwd, diagnostics=false)
        nothing
    catch error
        error isa ErrorException || rethrow()
        error.msg
    end
    message === nothing && error("cleanup audit accepted a real missing close")
    occursin("process alive or unreaped", message) || error(message)
    occursin("socket directory", message) || error(message)
    println("PASS negative control rejects a real daemon and socket-directory leak")
end

describe(result) = join(("$name=$(getfield(result, name))" for name in keys(result)), " ")

function main(arguments=ARGS)
    "--identity-self-test" in arguments && return (identity_self_test(); 0)
    separator = findfirst(==("--"), arguments)
    options = separator === nothing ? arguments : arguments[1:(separator-1)]
    command = separator === nothing ? String[] : arguments[(separator+1):end]
    value(name) = (i=findfirst(==(name), options); i === nothing ? nothing : options[i+1])
    tmux, cwd = value("--tmux"), value("--cwd")
    if tmux === nothing || cwd === nothing || isempty(command)
        println(
            stderr,
            "usage: check-example-cleanup.jl [--pure|--negative-control] --tmux TMUX --cwd DIR -- COMMAND...",
        )
        return 2
    end
    Sys.which(tmux) === nothing &&
        (println(stderr, "tmux executable is unavailable"); return 2)
    if "--negative-control" in options
        negative_control(Cmd(command); tmux, cwd)
        return 0
    end
    pure = "--pure" in options
    command = Cmd(command)
    success = run_example(command; tmux, env=ENV, cwd)
    (success.daemons > 0) != pure ||
        error("example ownership differs from its declared runtime class")
    println("PASS example success and independent cleanup ", describe(success))
    if success.daemons > 0
        failure = run_example(command; tmux, env=ENV, cwd, fault=true)
        println(
            "PASS example failure after session creation and independent cleanup ",
            describe(failure),
        )
    end
    0
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(CheckExampleCleanup.main(ARGS))

using Test, Sockets

const SANDBOX_DECOYS = Dict(
    "TMUX" => "/decoy-secret/sock,1,0",
    "TMUX_PANE" => "%decoy-secret",
    "LIBTMUX_SOCKET" => "decoy-secret",
    "LIBTMUX_SOCKET_PATH" => "/decoy-secret",
    "LIBTMUX_SOCKET_FUTURE" => "decoy-secret",
    "TMUX_TMPDIR" => "/decoy-secret",
)

# A tmux that records its arguments and, for each selector, only whether it is set.
function sandbox_fake_tmux(directory)
    checks = join(
        [
            "if [ \"\${$name+set}\" ]; then echo '$name set'; else echo '$name unset'; fi"
            for name in keys(SANDBOX_DECOYS)
        ],
        "\n",
    )
    path = joinpath(directory, "tmux")
    write(
        path,
        """
        #!/bin/sh
        {
        printf 'argv:'
        for argument in "\$@"; do printf ' [%s]' "\$argument"; done
        printf '\\n'
        $checks
        if [ -n "\$TMUX_TMPDIR" ] && [ "\$TMUX_TMPDIR" = "\${$(Main.TestSandbox.MARKER)-}" ]; then
            echo 'TMUX_TMPDIR is the sandbox'
        fi
        } >> "\$LIBTMUX_TEST_RECORD"
        exit 0
        """,
    )
    chmod(path, 0o755)
    nothing
end

# A socket nothing listens on. libuv unlinks the name it bound when the listener
# closes, so a second name keeps the inode, as a server killed in the middle of
# its run leaves its socket behind. Child programs include the same source.
const STALE_SOCKET = raw"""
using Sockets
function stale_socket(path)
    mkpath(dirname(path))
    keep = path * ".keep"
    server = listen(keep)
    run(`ln $keep $path`)
    close(server)
    path
end
"""
include_string(@__MODULE__, STALE_SOCKET)

# A listener with a backlog of one, filled until a connect fails with EAGAIN, as
# it does for a server too busy to accept. Returns what to close afterwards.
function full_backlog_listener(path)
    mkpath(dirname(path))
    server = Sockets.PipeServer()
    Sockets.bind(server, path) || error("could not bind a test socket")
    listen(server; backlog=1)
    clients = []
    while true
        try
            push!(clients, connect(path))
        catch failure
            failure isa Base.IOError && failure.code == Base.UV_EAGAIN || rethrow()
            break
        end
        length(clients) < 64 || error("the backlog of a test socket did not fill")
    end
    [clients; server]
end

# A tmux that records its arguments, naming every path only as `[path]`, and
# either removes the socket it is asked to stop, as a server does when it exits,
# or leaves it alone, as a server that survives kill-server does.
function sandbox_stopping_tmux(directory; stops=true)
    path = joinpath(directory, stops ? "stopper" : "bystander")
    removal = stops ? raw"""
        while [ $# -gt 0 ]; do
            if [ "$1" = -S ]; then rm -f "$2"; exit 0; fi
            shift
        done
        """ : ""
    write(
        path,
        """
        #!/bin/sh
        {
        printf 'argv:'
        for argument in "\$@"; do
            case "\$argument" in
                /*) printf ' [path]' ;;
                *) printf ' [%s]' "\$argument" ;;
            esac
        done
        printf '\\n'
        } >> "\$LIBTMUX_TEST_RECORD"
        $removal
        exit 0
        """,
    )
    chmod(path, 0o755)
    path
end

# Runs `program` in a child Julia whose environment holds the decoys and whose
# `tmux` is the recorder. Its sandbox, when it makes one, is inside this one.
function sandbox_child(directory, program, arguments...; record="record", extra=())
    environment = Dict{String,String}(string(k) => string(v) for (k, v) in ENV)
    for name in collect(keys(environment))
        Main.TestSandbox.ambient(name) && delete!(environment, name)
    end
    delete!(environment, Main.TestSandbox.MARKER)
    merge!(environment, SANDBOX_DECOYS)
    environment["PATH"] = directory * ":" * get(ENV, "PATH", "/usr/bin:/bin")
    environment["TMPDIR"] = ENV["TMUX_TMPDIR"]
    environment["LIBTMUX_TEST_RECORD"] = joinpath(directory, record)
    merge!(environment, Dict{String,String}(extra))
    out, err = IOBuffer(), IOBuffer()
    julia = `$(Base.julia_cmd()) --startup-file=no --compile=min -O0 -e $program $arguments`
    process =
        run(pipeline(ignorestatus(setenv(julia, environment)); stdout=out, stderr=err))
    recorded = joinpath(directory, record)
    (;
        status=process.exitcode,
        out=String(take!(out)),
        err=String(take!(err)),
        record=isfile(recorded) ? read(recorded, String) : "",
    )
end

const SANDBOX_HELPER = joinpath(dirname(@__DIR__), "dev", "test-diagnostics.jl")

@testset "the test process runs inside the tmux sandbox" begin
    sandbox = Main.TestSandbox
    @test isempty(sandbox.violations(ENV))
    directory = ENV["TMUX_TMPDIR"]
    @test isdir(directory) && ENV[sandbox.MARKER] == directory
    @test ncodeunits(directory) <= sandbox.MAX_BYTES
    @test !haskey(ENV, "TMUX") && !haskey(ENV, "TMUX_PANE")
    @test !any(startswith("LIBTMUX_SOCKET"), keys(ENV))
end

@testset "sandbox findings name variables and never values" begin
    sandbox = Main.TestSandbox
    env = merge(SANDBOX_DECOYS, Dict("LIBTMUX_TEST_TMUX" => "tmux", "LIBTMUX_OWNER" => "x"))
    found = sandbox.violations(env)
    for name in ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH")
        @test "$name is set" in found
    end
    @test "LIBTMUX_SOCKET_FUTURE is set" in found
    @test "TMUX_TMPDIR is not the sandbox directory of this run" in found
    @test !occursin("decoy-secret", join(found, "\n"))
    @test !any(finding -> occursin("LIBTMUX_TEST_TMUX", finding), found)
    @test !any(finding -> occursin("LIBTMUX_OWNER", finding), found)
    unset = Dict{String,String}()
    @test sandbox.violations(unset) == ["TMUX_TMPDIR is unset"]
    relative = Dict("TMUX_TMPDIR" => "relative")
    @test sandbox.violations(relative) == ["TMUX_TMPDIR is not an absolute path"]
    long = Dict("TMUX_TMPDIR" => "/" * "x"^sandbox.MAX_BYTES)
    @test only(sandbox.violations(long)) == "TMUX_TMPDIR is longer than 60 bytes"
    missing_directory = joinpath(ENV["TMUX_TMPDIR"], sandbox.PREFIX * "missing")
    absent = Dict("TMUX_TMPDIR" => missing_directory, sandbox.MARKER => missing_directory)
    @test only(sandbox.violations(absent)) ==
          "the sandbox directory is missing or belongs to another user"
    mktempdir(ENV["TMUX_TMPDIR"]; prefix=sandbox.PREFIX) do open_directory
        chmod(open_directory, 0o755)
        loose = Dict("TMUX_TMPDIR" => open_directory, sandbox.MARKER => open_directory)
        @test only(sandbox.violations(loose)) ==
              "the sandbox directory is open to other users"
        chmod(open_directory, 0o700)
        @test isempty(sandbox.violations(loose))
    end
end

@testset "a replaced environment takes TMUX_TMPDIR from the sandbox" begin
    sandbox = Main.TestSandbox
    # Booleans, so a failure reports the names and not the directory.
    entries = sandbox.child_entries()
    @test length(entries) == 1 && entries == ["TMUX_TMPDIR" => ENV["TMUX_TMPDIR"]]
    environment = Dict("PATH" => "/usr/bin", sandbox.child_entries()...)
    keeps = get(environment, "TMUX_TMPDIR", "") == ENV["TMUX_TMPDIR"]
    @test keeps
    @test !any(sandbox.ambient, keys(environment))
    for unsandboxed in (Dict("TMUX_TMPDIR" => "/decoy-secret"), Dict{String,String}())
        refusal = try
            sandbox.child_entries(unsandboxed)
        catch error
            error
        end
        @test refusal isa sandbox.Refused
        @test !occursin("decoy-secret", sprint(showerror, refusal))
    end
end

@testset "preparing an environment makes a sandbox and a child joins it" begin
    sandbox = Main.TestSandbox
    roots = (ENV["TMUX_TMPDIR"],)
    env = merge(SANDBOX_DECOYS, Dict("LIBTMUX_TEST_TMUX" => "tmux"))
    directory, created = sandbox.prepare!(env; roots)
    try
        @test created && isdir(directory) && dirname(directory) == only(roots)
        @test isempty(sandbox.violations(env))
        @test env["TMUX_TMPDIR"] == directory && env[sandbox.MARKER] == directory
        @test sort(collect(keys(env))) ==
              ["LIBTMUX_TEST_SANDBOX", "LIBTMUX_TEST_TMUX", "TMUX_TMPDIR"]
        env["TMUX"] = SANDBOX_DECOYS["TMUX"]
        joined, created = sandbox.prepare!(env; roots)
        @test joined == directory && !created && !haskey(env, "TMUX")
        @test_throws sandbox.Refused sandbox.prepare!(
            Dict("TMUX_TMPDIR" => "/decoy-secret");
            roots=("/nonexistent-ltj-root", "/" * "x"^sandbox.MAX_BYTES),
        )
    finally
        rm(directory; recursive=true, force=true)
    end
end

@testset "a socket chosen inside the sandbox fails the run and is removed" begin
    sandbox = Main.TestSandbox
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    try
        @test sandbox.verify!(env) === nothing
        socket_directory = joinpath(directory, "tmux-$(Libc.getuid())")
        mkpath(socket_directory)
        touch(joinpath(socket_directory, "regular-file"))
        @test sandbox.verify!(env) === nothing
        stale_socket(joinpath(socket_directory, "default"))
        refusal = try
            sandbox.verify!(env)
        catch error
            error
        end
        @test refusal isa sandbox.Refused
        @test occursin("tmux-$(Libc.getuid())/default", sprint(showerror, refusal))
        @test !ispath(joinpath(socket_directory, "default"))
        @test sandbox.verify!(env) === nothing
        env["TMUX"] = SANDBOX_DECOYS["TMUX"]
        refusal = try
            sandbox.verify!(env)
        catch error
            error
        end
        @test refusal isa sandbox.Refused && refusal.findings == ["TMUX is set"]
    finally
        rm(directory; recursive=true, force=true)
    end
end

@testset "the sweep looks for sockets in the whole sandbox and stops each by -S" begin
    sandbox = Main.TestSandbox
    uid = Libc.getuid()
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do scratch
        directory = joinpath(scratch, "world")
        record = joinpath(scratch, "record")
        mkpath(directory)
        stale_socket(joinpath(directory, "custom.sock"))
        stale_socket(joinpath(directory, "deep", "er", "nested.sock"))
        stale_socket(joinpath(directory, "tmux-$uid", "default"))
        # A name other than `default` is a server started with -L, or a socket
        # left behind by one; it is not a client that named no socket.
        stale_socket(joinpath(directory, "tmux-$uid", "named"))
        served = listen(joinpath(directory, "tmux-$uid", "served"))
        touch(joinpath(directory, "regular-file"))
        # A symlink to a socket is not followed: the server it names is not this
        # sandbox's to stop.
        outside = stale_socket(joinpath(scratch, "outside.sock"))
        symlink(outside, joinpath(directory, "link.sock"))
        symlink(joinpath(scratch, "deep"), joinpath(directory, "linked-directory"))
        expected = [
            "custom.sock",
            "deep/er/nested.sock",
            "tmux-$uid/default",
            "tmux-$uid/named",
            "tmux-$uid/served",
        ]
        @test sandbox.sockets(directory) == expected
        tmux = sandbox_stopping_tmux(scratch)
        findings, kept = withenv("LIBTMUX_TEST_RECORD" => record) do
            sandbox.sweep(directory; tmux)
        end
        @test isempty(kept)
        @test findings == [
            "a socket was left at custom.sock in the sandbox",
            "a socket was left at deep/er/nested.sock in the sandbox",
            "a client started without -S or -L and chose tmux-$uid/default in the sandbox",
            "a socket was left at tmux-$uid/named in the sandbox",
            "a server was left running on tmux-$uid/served in the sandbox",
        ]
        close(served)
        @test isempty(sandbox.sockets(directory))
        @test issocket(outside) && islink(joinpath(directory, "link.sock"))
        calls = readlines(record)
        @test calls == fill("argv: [-u] [-N] [-S] [path] [kill-server]", 5)
        @test !occursin(scratch, join(findings, "\n"))
        @test sandbox.sweep(directory; tmux) == (String[], String[])
    end
end

@testset "a server that survives kill-server is named and keeps the sandbox" begin
    sandbox = Main.TestSandbox
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    survivor = joinpath(directory, "survivor.sock")
    listener = listen(survivor)
    patience = sandbox.PATIENCE[]
    sandbox.PATIENCE[] = 0.2
    try
        mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do scratch
            tmux = sandbox_stopping_tmux(scratch; stops=false)
            record = joinpath(scratch, "record")
            withenv("LIBTMUX_TEST_RECORD" => record) do
                findings, kept = sandbox.sweep(directory; tmux)
                @test kept == ["survivor.sock"]
                @test findings ==
                      ["a server still answers on survivor.sock after kill-server"]
                @test issocket(survivor)
                refusal = try
                    sandbox.verify!(env; tmux)
                catch error
                    error
                end
                @test refusal isa sandbox.Refused
                @test refusal.findings == findings
            end
            @test readlines(record) == fill("argv: [-u] [-N] [-S] [path] [kill-server]", 2)
        end
    finally
        sandbox.PATIENCE[] = patience
        close(listener)
        rm(directory; recursive=true, force=true)
    end
end

@testset "a server too busy to accept still answers" begin
    sandbox = Main.TestSandbox
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    busy = joinpath(directory, "busy.sock")
    held = full_backlog_listener(busy)
    patience = sandbox.PATIENCE[]
    sandbox.PATIENCE[] = 0.2
    try
        mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do scratch
            tmux = sandbox_stopping_tmux(scratch; stops=false)
            @test sandbox.answers(busy)
            @test !sandbox.answers(joinpath(directory, "missing.sock"))
            withenv("LIBTMUX_TEST_RECORD" => joinpath(scratch, "record")) do
                findings, kept = sandbox.sweep(directory; tmux)
                @test kept == ["busy.sock"]
                @test findings == ["a server still answers on busy.sock after kill-server"]
            end
        end
    finally
        sandbox.PATIENCE[] = patience
        foreach(close, held)
        rm(directory; recursive=true, force=true)
    end
end

@testset "every runner enters the sandbox through the diagnostics helper" begin
    root = dirname(@__DIR__)
    runners = [joinpath(root, "test", "runtests.jl")]
    for package in readdir(joinpath(root, "packages"); join=true)
        runner = joinpath(package, "test", "runtests.jl")
        isfile(runner) && push!(runners, runner)
    end
    @test length(runners) > 1
    for runner in runners
        @test occursin("test-diagnostics.jl", readline(runner))
    end
end

@testset "the diagnostics helper hides every selector from a client" begin
    sandbox = Main.TestSandbox
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        sandbox_fake_tmux(directory)
        before = readdir(ENV["TMUX_TMPDIR"])
        control = sandbox_child(directory, "run(`tmux list-sessions`)"; record="control")
        @test control.status == 0
        for name in ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH")
            @test occursin("$name set\n", control.record)
        end
        @test occursin("LIBTMUX_SOCKET_FUTURE set\n", control.record)
        @test !occursin("TMUX_TMPDIR is the sandbox", control.record)
        entered = sandbox_child(
            directory,
            "include(ARGS[1]); run(`tmux list-sessions`)",
            SANDBOX_HELPER;
            record="entered",
        )
        @test entered.status == 0
        @test startswith(entered.record, "argv: [list-sessions]\n")
        for name in ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH")
            @test occursin("$name unset\n", entered.record)
        end
        @test occursin("LIBTMUX_SOCKET_FUTURE unset\n", entered.record)
        @test occursin("TMUX_TMPDIR set\n", entered.record)
        @test occursin("TMUX_TMPDIR is the sandbox\n", entered.record)
        @test !occursin("decoy-secret", join((entered.out, entered.err, entered.record)))
        @test !any(
            name -> startswith(name, sandbox.PREFIX),
            setdiff(readdir(ENV["TMUX_TMPDIR"]), before),
        )
    end
end

@testset "the diagnostics helper checks each file against the sandbox" begin
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        leak =
            STALE_SOCKET *
            "stale_socket(joinpath(ENV[\"TMUX_TMPDIR\"], \"tmux-\$(Libc.getuid())\", \"default\"))\n"
        custom =
            STALE_SOCKET * "stale_socket(joinpath(ENV[\"TMUX_TMPDIR\"], \"custom.sock\"))\n"
        tamper = "ENV[\"TMUX\"] = \"decoy-secret\"\n"
        files = [
            "clean.jl" => "",
            "leak.jl" => leak,
            "custom.jl" => custom,
            "after.jl" => "",
            "tamper.jl" => tamper,
        ]
        for (name, source) in files
            write(joinpath(directory, name), source)
        end
        paths = [joinpath(directory, name) for (name, _) in files]
        program = """
        include(ARGS[1])
        for file in ARGS[2:end]
            include_test_file(Main, file)
        end
        finish_test_diagnostics()
        """
        tmux = sandbox_stopping_tmux(directory)
        result = sandbox_child(
            directory,
            program,
            SANDBOX_HELPER,
            paths...;
            extra=("LIBTMUX_TEST_TMUX" => tmux,),
        )
        outcomes = Dict(
            match.captures[1] => match.captures[2] for match in
            eachmatch(r"FILE END \"[^\"]*?([\w.]+)\" outcome=(\w+)", result.err)
        )
        @test outcomes == Dict(
            "clean.jl" => "RETURNED",
            "leak.jl" => "ABORTED",
            "custom.jl" => "ABORTED",
            "after.jl" => "RETURNED",
            "tamper.jl" => "ABORTED",
        )
        @test result.status != 0
        @test occursin("chose tmux-$(Libc.getuid())/default", result.err)
        @test occursin("a socket was left at custom.sock", result.err)
        @test occursin("TMUX is set", result.err)
        @test !occursin("decoy-secret", result.err * result.out)
    end
end

@testset "the diagnostics helper fails the run for a socket made after the last file" begin
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        program = STALE_SOCKET * """
                  include(ARGS[1])
                  include_test_file(Main, ARGS[2])
                  stale_socket(joinpath(ENV["TMUX_TMPDIR"], "late.sock"))
                  finish_test_diagnostics()
                  """
        clean = joinpath(directory, "clean.jl")
        write(clean, "")
        report = joinpath(directory, "complete.toml")
        result = sandbox_child(
            directory,
            program,
            SANDBOX_HELPER,
            clean;
            extra=(
                "LIBTMUX_TEST_TMUX" => sandbox_stopping_tmux(directory),
                "LIBTMUX_TEST_COMPLETION" => report,
                "LIBTMUX_TEST_INVOCATION" => "late",
            ),
        )
        @test result.status != 0
        @test occursin("TESTS COMPLETE status=FAIL", result.err)
        @test occursin("a socket was left at late.sock in the sandbox", result.err)
        @test occursin("status = \"FAIL\"", read(report, String))
        @test !occursin("decoy-secret", result.err * result.out)
    end
end

@testset "the process that made the sandbox fails the run for a leaked socket" begin
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        tmux = sandbox_stopping_tmux(directory)
        leak = STALE_SOCKET * """
        include(ARGS[1])
        stale_socket(joinpath(ENV["TMUX_TMPDIR"], "tmux-\$(Libc.getuid())", "default"))
        """
        result = sandbox_child(
            directory,
            leak,
            SANDBOX_HELPER;
            extra=("LIBTMUX_TEST_TMUX" => tmux,),
        )
        @test result.status == 1
        @test occursin("left sockets in the sandbox", result.err)
        @test occursin("tmux-$(Libc.getuid())/default", result.err)
        # A server on any other socket name fails the run the same way.
        custom = STALE_SOCKET * """
        include(ARGS[1])
        stale_socket(joinpath(ENV["TMUX_TMPDIR"], "custom.sock"))
        """
        result = sandbox_child(
            directory,
            custom,
            SANDBOX_HELPER;
            extra=("LIBTMUX_TEST_TMUX" => tmux,),
        )
        @test result.status == 1
        @test occursin("a socket was left at custom.sock in the sandbox", result.err)
        @test !occursin("was kept", result.err)
        clean = sandbox_child(directory, "include(ARGS[1])", SANDBOX_HELPER)
        @test clean.status == 0 && isempty(clean.err)
    end
end

@testset "the process that made the sandbox keeps the directory while a server answers" begin
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        survivor = """
        include(ARGS[1])
        using Sockets
        TestSandbox.PATIENCE[] = 0.2
        global listener = listen(joinpath(ENV["TMUX_TMPDIR"], "survivor.sock"))
        println(basename(ENV["TMUX_TMPDIR"]))
        """
        result = sandbox_child(
            directory,
            survivor,
            SANDBOX_HELPER;
            extra=("LIBTMUX_TEST_TMUX" => sandbox_stopping_tmux(directory; stops=false),),
        )
        kept = strip(result.out)
        @test result.status == 1
        @test occursin(
            "a server still answers on survivor.sock after kill-server",
            result.err,
        )
        @test occursin("the sandbox directory $kept was kept", result.err)
        @test startswith(kept, Main.TestSandbox.PREFIX)
        # The child made its sandbox under this one, and this one removes it.
        remaining = joinpath(ENV["TMUX_TMPDIR"], kept)
        @test isdir(remaining)
        names_the_directory = occursin(ENV["TMUX_TMPDIR"], result.err)
        @test !names_the_directory
        rm(remaining; recursive=true, force=true)
    end
end

@testset "the diagnostics helper refuses to run unsandboxed" begin
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        program = """
        include(ARGS[1])
        TestSandbox.enter_or_refuse!(ENV; roots=("/nonexistent-ltj-root",))
        """
        helper = joinpath(dirname(SANDBOX_HELPER), "test-sandbox.jl")
        result = sandbox_child(directory, program, helper)
        @test result.status == 2
        @test occursin("refused to run: no temporary directory is short enough", result.err)
        @test !occursin("decoy-secret", result.err * result.out)
    end
end

# Marks each character of Julia source as :code, :string or :comment without
# parsing it, so a `Dict(` in a docstring or a note does not count.
function classify(chars)
    kind = fill(:code, length(chars))
    index = 1
    while index <= length(chars)
        char = chars[index]
        if char == '#'
            stop = something(findnext(==('\n'), chars, index), length(chars) + 1)
            kind[index:(stop-1)] .= :comment
            index = stop
        elseif char == '\'' && index + 2 <= length(chars) && chars[index+2] == '\''
            index += 3
        elseif char == '"'
            triple = index + 2 <= length(chars) && chars[index+1] == chars[index+2] == '"'
            width = triple ? 3 : 1
            cursor = index + width
            while cursor <= length(chars)
                if chars[cursor] == '\\'
                    cursor += 2
                elseif all(==('"'), chars[cursor:min(end, cursor+width-1)]) &&
                       cursor + width - 1 <= length(chars)
                    cursor += width
                    break
                else
                    cursor += 1
                end
            end
            kind[index:min(end, cursor-1)] .= :string
            index = cursor
        else
            index += 1
        end
    end
    kind
end

# Each `Dict(...)` or `Dict{...}(...)` call as its line, its text without
# comments, and its text without strings either.
function dict_literals(source)
    chars, found = collect(source), Tuple{Int,String,String}[]
    kind = classify(chars)
    matching(from, open, close) = begin
        depth, index = 1, from
        while index <= length(chars) && depth > 0
            if kind[index] == :code
                depth += chars[index] == open
                depth -= chars[index] == close
            end
            index += 1
        end
        index
    end
    for start = 1:(length(chars)-4)
        all(==(:code), kind[start:(start+3)]) && String(chars[start:(start+3)]) == "Dict" ||
            continue
        start > 1 &&
            (isletter(chars[start-1]) || chars[start-1] in "_.!{}0123456789") &&
            continue
        opening = start + 4
        if chars[opening] == '{'
            opening = matching(opening + 1, '{', '}')
        end
        opening <= length(chars) && chars[opening] == '(' && kind[opening] == :code ||
            continue
        closing = matching(opening + 1, '(', ')') - 1
        inside = (opening+1):(closing-1)
        body = String([chars[index] for index in inside if kind[index] != :comment])
        code = String([chars[index] for index in inside if kind[index] == :code])
        push!(found, (count(==('\n'), chars[1:start]) + 1, body, code))
    end
    found
end

keyed_path(body) = occursin(r"\"PATH\"\s*=>", body)
carries_sandbox(body, code) =
    occursin(r"\"TMUX_TMPDIR\"\s*=>", body) || occursin(r"\bchild_entries\b", code)

# A literal keyed by "PATH" is a child environment: a process started with it
# sees nothing else, so tmux must find TMUX_TMPDIR there.
bare_environments(source) = [
    line for (line, body, code) in dict_literals(source) if
    keyed_path(body) && !carries_sandbox(body, code)
]

# These literals reach a shell script and a Julia process, and start no tmux.
const NO_TMUX_ENVIRONMENTS =
    Dict("packages/LibTmuxWorkspace/test/script.jl" => 1, "dev/check-tag-install.jl" => 1)

function environment_files(root)
    files = String[]
    directories =
        [joinpath(root, name) for name in ("test", "examples", "benchmark", "dev")]
    for package in readdir(joinpath(root, "packages"); join=true), name in ("test", "dev")
        push!(directories, joinpath(package, name))
    end
    for directory in directories
        isdir(directory) || continue
        for (parent, _, names) in walkdir(directory), name in names
            endswith(name, ".jl") || continue
            relpath(joinpath(parent, name), root) == "test/sandbox.jl" && continue
            push!(files, joinpath(parent, name))
        end
    end
    sort!(files)
end

@testset "the guard that finds a replaced environment without TMUX_TMPDIR can fail" begin
    bare = """
    f() = Dict(
        "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
        "NOTE" => ") # not a closer",
        "TERM" => "xterm-256color",
    )
    """
    @test bare_environments(bare) == [1]
    @test bare_environments("x = 1\ny = Dict{String,String}(\"PATH\" => \"a\")\n") == [2]
    keyed = "Dict(\"PATH\" => \"a\", \"TMUX_TMPDIR\" => get(ENV, \"TMUX_TMPDIR\", \"/tmp\"))"
    @test isempty(bare_environments(keyed))
    helper = "Dict(\"PATH\" => \"a\", Main.TestSandbox.child_entries()...)"
    @test isempty(bare_environments(helper))
    # Words in a comment or a string are not entries.
    commented = "Dict(\"PATH\" => \"a\", # TMUX_TMPDIR\n \"TERM\" => \"b\")"
    @test bare_environments(commented) == [1]
    named = "Dict(\"PATH\" => \"a\", \"NOTE\" => \"child_entries\")"
    @test bare_environments(named) == [1]
    # A literal in a docstring or a comment is not code.
    @test isempty(
        bare_environments("\"\"\"\nDict(\"PATH\" => 1)\n\"\"\"\n# Dict(\"PATH\" => 1)\n"),
    )
    # Other dictionaries are not child environments.
    @test isempty(bare_environments("Dict(\"PROJECT\" => \"x\")"))
    @test isempty(bare_environments("merge(Dict(), Dict{String,String}())"))
end

@testset "every replaced environment that can start tmux keeps TMUX_TMPDIR" begin
    root = dirname(@__DIR__)
    files = environment_files(root)
    sites = Dict{String,Int}()
    for file in files
        relative = relpath(file, root)
        source = read(file, String)
        bare = bare_environments(source)
        sites[relative] = count(literal -> keyed_path(literal[2]), dict_literals(source))
        allowed = get(NO_TMUX_ENVIRONMENTS, relative, 0)
        @test length(bare) == allowed
        length(bare) == allowed ||
            @info "a replaced environment names no TMUX_TMPDIR" relative lines = bare
    end
    # The scan sees the sites it exists for.
    for relative in (
        "test/support/owned_tmux.jl",
        "test/lifecycle.jl",
        "test/integration.jl",
        "packages/LibTmuxMCP/test/tools.jl",
        "packages/LibTmuxWorkspace/test/owned_server.jl",
        "examples/output_stream.jl",
        "benchmark/mcp.jl",
        "packages/LibTmuxWorkspace/dev/cli_latency.jl",
    )
        @test get(sites, relative, 0) > 0
    end
    @test all(relative -> get(sites, relative, 0) > 0, keys(NO_TMUX_ENVIRONMENTS))
end

@testset "every dev entry point that starts a server enters the sandbox" begin
    root = dirname(@__DIR__)
    entries = String[]
    directories = [joinpath(root, "dev"), joinpath(root, "benchmark")]
    for package in readdir(joinpath(root, "packages"); join=true)
        push!(directories, joinpath(package, "dev"))
    end
    for directory in directories
        isdir(directory) || continue
        for name in readdir(directory; join=true)
            endswith(name, ".jl") || continue
            source = read(name, String)
            code = String(collect(source)[classify(collect(source)) .== :code])
            occursin(r"\b(with_server|open_server)\(", code) && push!(entries, name)
        end
    end
    relatives = relpath.(entries, root)
    for expected in (
        "dev/check-doc-examples.jl",
        "benchmark/startup.jl",
        "benchmark/observations.jl",
        "benchmark/mcp.jl",
        "benchmark/workflows.jl",
        "packages/LibTmuxWorkspace/dev/cli_latency.jl",
    )
        @test expected in relatives
    end
    for entry in entries
        source = read(entry, String)
        code = String(collect(source)[classify(collect(source)) .== :code])
        @test occursin("test-sandbox.jl", source)
        @test occursin("TestSandbox.enter_or_refuse!()", code)
    end
    # The doc-example checker also looks for a leaked socket before it reports.
    source = read(joinpath(root, "dev", "check-doc-examples.jl"), String)
    code = String(collect(source)[classify(collect(source)) .== :code])
    for name in ("run_contextual_snippets", "doc_examples_main")
        body = match(Regex("(?ms)^function $name\\(.*?^end\$"), code)
        @test body !== nothing && occursin("check_sandbox_clean()", body.match)
    end
end

# The matrix runs some test scripts on their own, so no runner has entered the
# sandbox for them. A script that no other Julia file names has to enter itself.
@testset "a test script that no runner includes enters the sandbox itself" begin
    root = dirname(@__DIR__)
    directories = [joinpath(root, "test")]
    for package in readdir(joinpath(root, "packages"); join=true)
        push!(directories, joinpath(package, "test"))
    end
    files = String[]
    for directory in directories, (parent, _, names) in walkdir(directory)
        for name in names
            endswith(name, ".jl") && push!(files, joinpath(parent, name))
        end
    end
    # This file names the script it checks, so it does not count as a runner.
    filter!(file -> relpath(file, root) != "test/sandbox.jl", files)
    sources = Dict(file => read(file, String) for file in files)
    named(file, other) =
        file != other && occursin(
            Regex("[\"/]" * splitext(basename(file))[1] * "(\\.jl)?\""),
            sources[other],
        )
    standalone = filter(file -> !any(other -> named(file, other), files), files)
    users = filter(file -> occursin("TestSandbox", sources[file]), standalone)
    # The scan sees the script it exists for.
    @test "packages/LibTmuxMCP/test/product.jl" in relpath.(users, root)
    for file in users
        source = sources[file]
        code = String(collect(source)[classify(collect(source)) .== :code])
        @test occursin("test-sandbox.jl", source)
        @test occursin("TestSandbox.enter_or_refuse!()", code)
    end
end

@testset "the doc-example checker enters the sandbox before it starts tmux" begin
    checker = joinpath(dirname(SANDBOX_HELPER), "check-doc-examples.jl")
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
        sandbox_fake_tmux(directory)
        entered = sandbox_child(
            directory,
            "include(ARGS[1]); run(`tmux list-sessions`)",
            checker;
            record="entered",
        )
        @test entered.status == 0
        for name in ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH")
            @test occursin("$name unset\n", entered.record)
        end
        @test occursin("LIBTMUX_SOCKET_FUTURE unset\n", entered.record)
        @test occursin("TMUX_TMPDIR is the sandbox\n", entered.record)
        @test !occursin("decoy-secret", join((entered.out, entered.err, entered.record)))
        leaked = sandbox_child(
            directory,
            STALE_SOCKET * """
            include(ARGS[1])
            stale_socket(joinpath(ENV["TMUX_TMPDIR"], "custom.sock"))
            check_sandbox_clean()
            println("unreachable")
            """,
            checker;
            record="leaked",
            extra=("LIBTMUX_TEST_TMUX" => sandbox_stopping_tmux(directory),),
        )
        @test leaked.status == 1 && !occursin("unreachable", leaked.out)
        @test occursin(
            "doc examples left sockets in the sandbox: a socket was left at custom.sock",
            leaked.err,
        )
        @test !occursin("decoy-secret", leaked.err * leaked.out)
    end
end

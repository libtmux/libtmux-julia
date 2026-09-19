using Test
using LibTmuxWorkspace
import LibTmux
import JSON
isdefined(@__MODULE__, :with_workspace_server) || include("owned_server.jl")

# Outer tier: execute installed launchers as separate Julia consumers.
@testset "installed workspace load and freeze protocol" begin
    with_workspace_server() do fixture
        launcher = install_cli(
            joinpath(fixture.directory, "bin");
            project=get(ENV, "LIBTMUX_TEST_CLI_PROJECT", Base.active_project()),
            julia_flags=vcat(
                ["--threads=$(Threads.nthreads())"],
                get(ENV, "LIBTMUX_TEST_CLI_COMPILE", "minimal") == "normal" ? String[] :
                ["--compile=min", "-O0"],
            ),
        )
        path = joinpath(fixture.directory, "workspace.yaml")
        write(
            path,
            "session_name: installed\noptions:\n  default-shell: /bin/sh\nwindows:\n  - window_name: cli\n",
        )
        args = [
            launcher,
            "load",
            path,
            "--socket",
            fixture.socket,
            "--tmux",
            fixture.tmux,
            "--output",
            "ndjson",
        ]
        stderr_path = joinpath(fixture.directory, "stderr")
        text = open(stderr_path, "w") do errors
            read(pipeline(ignorestatus(Cmd(args)); stderr=errors), String)
        end
        records = JSON.parse.(split(chomp(text), '\n'))
        last(records)["event"] == "error" && println(stderr, read(stderr_path, String))
        @test last(records)["event"] == "result"
        @test last(records)["status"] == "loaded"
        @test [r["sequence"] for r in records] == collect(1:length(records))
        @test isempty(read(stderr_path, String))
        args = [
            launcher,
            "freeze",
            "installed",
            "--socket",
            fixture.socket,
            "--tmux",
            fixture.tmux,
            "--output",
            "json",
        ]
        frozen = JSON.parse(read(Cmd(args), String))
        @test frozen["status"] == "frozen"
        @test validate(frozen["workspace"]).windows[1].name == "cli"
        @test length(
            LibTmux.sessions(
                LibTmux.snapshot(
                    LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux),
                ),
            ),
        ) == 1
    end
end

@testset "installed CLI interrupt reaps script and rolls back" begin
    with_workspace_server() do fixture
        launcher = install_cli(
            joinpath(fixture.directory, "bin");
            project=get(ENV, "LIBTMUX_TEST_CLI_PROJECT", Base.active_project()),
            julia_flags=vcat(
                ["--threads=$(Threads.nthreads())"],
                get(ENV, "LIBTMUX_TEST_CLI_COMPILE", "minimal") == "normal" ? String[] :
                ["--compile=min", "-O0"],
            ),
        )
        fifo, script, pidfile =
            (joinpath(fixture.directory, name) for name in ("blocked", "before", "pid"))
        @test ccall(:mkfifo, Cint, (Cstring, Cuint), fifo, 0o600) == 0
        write(
            script,
            "#!/bin/sh\nprintf '%s' \"\$\$\" > \"\$1\"\nprintf ready\nexec /bin/cat \"\$2\"\n",
        )
        chmod(script, 0o700)
        word = LibTmuxWorkspace._shell_word
        path = joinpath(fixture.directory, "interrupt.json")
        write(
            path,
            JSON.json(
                Dict(
                    "session_name" => "interrupted",
                    "before_script" => join(word.([script, pidfile, fifo]), " "),
                    "windows" => [Dict("window_name" => "unused")],
                ),
            ),
        )
        args = [
            launcher,
            "load",
            path,
            "--socket",
            fixture.socket,
            "--tmux",
            fixture.tmux,
            "--output",
            "ndjson",
            "--rollback-created",
        ]
        output = Pipe()
        stderr_path = joinpath(fixture.directory, "stderr")
        proc = nothing
        timer = nothing
        timer_task = nothing
        forced = Ref(false)
        records = []
        try
            open(stderr_path, "w") do errors
                proc = run(
                    pipeline(ignorestatus(Cmd(args)); stdout=output, stderr=errors);
                    wait=false,
                )
            end
            close(output.in)
            while !eof(output.out)
                record = JSON.parse(readline(output.out))
                push!(records, record)
                if get(get(record, "progress", Dict()), "event", "") == "script_output"
                    timer, timer_task = LibTmuxWorkspace._owned_timer(0.9) do
                        if process_running(proc)
                            forced[] = true
                            kill(proc, Base.SIGKILL)
                        end
                    end
                    kill(proc, Base.SIGINT)
                end
            end
            wait(proc)
            @test !forced[]
            @test proc.exitcode == 5
            @test last(records)["event"] == "error"
            @test last(records)["result"]["status"] == "cancelled"
            @test only(last(records)["result"]["rollback"])["status"] == "removed"
            @test ccall(:kill, Cint, (Cint, Cint), parse(Int, read(pidfile, String)), 0) ==
                  -1
            @test ccall(:kill, Cint, (Cint, Cint), -parse(Int, read(pidfile, String)), 0) ==
                  -1
            server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
            @test isempty(LibTmux.sessions(LibTmux.snapshot(server)))
        finally
            timer === nothing || close(timer)
            timer_task === nothing || wait(timer_task)
            proc === nothing || !process_running(proc) || kill(proc, Base.SIGKILL)
            close(output)
            proc === nothing || wait(proc)
            if isfile(pidfile)
                pid = parse(Int, read(pidfile, String))
                ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 &&
                    ccall(:kill, Cint, (Cint, Cint), -pid, Base.SIGKILL)
            end
        end
    end
end

include("cli_backpressure.jl")

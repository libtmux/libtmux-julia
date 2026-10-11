using Test, LibTmuxWorkspace
import JSON

# Outer tier: a real installed process must retire while its stdout pipe is full.
@testset "installed workspace writer retires against a stalled reader" begin
    mktempdir() do directory
        flags =
            get(ENV, "LIBTMUX_TEST_CLI_COMPILE", "minimal") == "normal" ? String[] :
            ["--compile=min", "-O0"]
        pushfirst!(flags, "--threads=$(Threads.nthreads())")
        launcher = install_cli(
            joinpath(directory, "bin");
            project=get(ENV, "LIBTMUX_TEST_CLI_PROJECT", Base.active_project()),
            julia_flags=flags,
        )
        path = joinpath(directory, "large.json")
        write(
            path,
            JSON.json(
                Dict(
                    "session_name"=>"output",
                    "windows"=>[
                        Dict(
                            "window_name"=>"main",
                            "panes"=>fill(repeat("echo x;", 225), 512),
                        ),
                    ],
                ),
            ),
        )
        output = Pipe()
        read_maximum = output.out.buffer.maxsize
        # Keep Julia read-ahead from relieving the installed writer's pressure.
        output.out.buffer.maxsize = 1
        proc = nothing
        timer = timer_task = nothing
        forced = Ref(false)
        try
            proc = run(
                pipeline(
                    ignorestatus(Cmd([launcher, "plan", path, "--output", "json"]));
                    stdout=output,
                    stderr=devnull,
                );
                wait=false,
            )
            close(output.in)
            @assert output.out.buffer.maxsize == 1
            @test read(output.out, UInt8) == UInt8('{')
            timer, timer_task = LibTmuxWorkspace._owned_timer(0.9) do
                if process_running(proc)
                    forced[] = true
                    kill(proc, Base.SIGKILL)
                end
            end
            wait(proc)
            @assert output.out.buffer.maxsize == 1 && bytesavailable(output.out) <= 1
            @test !forced[]
            @test proc.exitcode == 3
            output.out.buffer.maxsize = read_maximum
            @test length(read(output.out)) < 512 * 1575
        finally
            timer === nothing || close(timer)
            timer_task === nothing || wait(timer_task)
            proc === nothing || !process_running(proc) || kill(proc, Base.SIGKILL)
            output.out.buffer.maxsize = read_maximum
            close(output)
            proc === nothing || wait(proc)
        end
    end
end

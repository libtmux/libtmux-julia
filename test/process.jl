struct CancelDuringCopy <: AbstractVector{UInt8}
    token::CancellationToken
end

Base.size(::CancelDuringCopy) = (0,)
Base.copy(value::CancelDuringCopy) = (cancel!(value.token); UInt8[])

struct FrozenInputBytes <: AbstractVector{UInt8}
    bytes::Tuple{Vararg{UInt8}}
end
Base.size(value::FrozenInputBytes) = (length(value.bytes),)
Base.getindex(value::FrozenInputBytes, i::Int) = value.bytes[i]
Base.copy(value::FrozenInputBytes) = value

@testset "empty process input performs no write" begin
    endpoint = Base.PipeEndpoint()
    close(endpoint)
    errors = Exception[]
    worker = LibTmux._ProcessInput(error -> push!(errors, error), endpoint, UInt8[])
    @test worker() === nothing
    @test isempty(errors)
end

# A child that no system tool can stand in for is a short Julia program.
child(program, arguments...) = Main.StandIns.julia_cmd(program, arguments...)

@testset "bounded owned processes" begin
    @test isdefined(LibTmux, :_run_process)
    if isdefined(LibTmux, :_run_process)
        execute = LibTmux._run_process
        bytes = execute(
            child(
                "write(stdout, UInt8[0x00, 0x61, 0xff, 0x0a]); write(stderr, \"err\"); exit(7)",
            ),
        )
        @test bytes.stdout == UInt8[0x00, 0x61, 0xff, 0x0a]
        @test bytes.stderr == codeunits("err")
        @test bytes.exitcode == 7
        @test bytes.termsignal == 0
        @test occursin(
            "rejected",
            sprint(
                showerror,
                CommandError(
                    CommandResult(UInt8[], collect(codeunits("rejected\n")), 2, 0),
                ),
            ),
        )
        payload = repeat(UInt8[0x00, 0xff, 0x0a, 0x7f], 32768)
        @test execute(`cat`; input=payload).stdout == payload
        @test execute(`cat`; input=FrozenInputBytes((0x00, 0xff))).stdout ==
              UInt8[0x00, 0xff]
        pressure = execute(
            child(
                "block = zeros(UInt8, 131072); " *
                "@sync begin @async write(stdout, block); @async write(stderr, block) end",
            ),
        )
        @test pressure.stdout == zeros(UInt8, 131072)
        @test pressure.stderr == zeros(UInt8, 131072)
        @test_throws OutputLimitExceeded execute(`yes x`; max_output_bytes=128)
        @test_throws OutputLimitExceeded execute(
            child("while true; write(stderr, \"x\\n\"); end");
            max_error_bytes=128,
        )
        @test_throws DeadlineExceeded execute(`sleep 30`; timeout=0.03)
        @test execute(child("ccall(:kill, Cint, (Cint, Cint), getpid(), 15); sleep(30)")).termsignal ==
              15
        @test_throws TmuxNotFound execute(Cmd(["/nonexistent/libtmux-julia-executable"]))
        # A file that is not executable is refused whatever it holds.
        mktemp() do executable, io
            close(io)
            chmod(executable, 0o600)
            denied = try
                execute(setenv(Cmd([executable]), Dict("SECRET" => "private-probe-value")))
            catch error
                error
            end
            @test nameof(typeof(denied)) == :ProcessSpawnError
            @test !occursin("private-probe-value", sprint(showerror, denied))
        end
        token = CancellationToken()
        cancel!(token)
        cancel!(token)
        @test_throws RequestCancelled execute(
            Cmd(["/nonexistent/not-spawned"]);
            cancel=token,
        )
        @test_throws ArgumentError execute(`true`; timeout=-1)
        @test_throws ArgumentError execute(
            Cmd(["/nonexistent/not-spawned"]);
            timeout=big(10)^10000,
        )
        @test_throws ArgumentError execute(Cmd(["/nonexistent/not-spawned"]); timeout=1e100)
        @test_throws ArgumentError execute(`true`; max_output_bytes=-1)
        @test_throws DeadlineExceeded execute(
            Cmd(["/nonexistent/not-spawned"]);
            timeout=nextfloat(0.0),
        )
        mktempdir(; prefix="libtmux-julia-deadline-") do directory
            marker = joinpath(directory, "must-not-exist")
            @test_throws DeadlineExceeded execute(`touch $marker`; timeout=nextfloat(0.0))
            @test !isfile(marker)
        end
        preparation_token = CancellationToken()
        @test_throws RequestCancelled execute(
            Cmd(["/nonexistent/not-spawned"]);
            cancel=preparation_token,
            input=CancelDuringCopy(preparation_token),
        )
        stdin_ready = Ref(false)
        function stdin_timer(callback, delay)
            timer, task = LibTmux._owned_timer(callback, delay)
            if callback isa LibTmux._DeadlineCallback
                try
                    # No drain or input worker starts before this readiness read.
                    stdin_ready[] = readline(callback.stop.error.out) == "stdin closed"
                catch
                    close(timer)
                    wait(task)
                    rethrow()
                end
            end
            timer, task
        end
        # This deadline bounds a broken error path; it is not an asserted latency.
        closed_stdin = try
            execute(
                child(
                    # Julia keeps a second copy of stdin, which exec drops.
                    "ccall(:close, Cint, (Cint,), 0); println(stderr, \"stdin closed\"); " *
                    "StandIns.exec(\"sleep\", \"30\")",
                );
                input=fill(UInt8(1), 131072),
                timeout=30,
                _make_timer=stdin_timer,
            )
        catch error
            error
        end
        @test stdin_ready[]
        @test closed_stdin isa ProcessIOError
        if closed_stdin isa ProcessIOError
            @test closed_stdin.stream === :stdin
            @test closed_stdin.result.termsignal == Base.SIGKILL
        end
        rejected = try
            execute(child("write(stderr, \"rejected\"); exit(2)"); input=fill(UInt8(1), 131072))
        catch error
            error
        end
        @test rejected isa ProcessIOError
        if rejected isa ProcessIOError
            @test hasproperty(rejected, :result)
            if hasproperty(rejected, :result)
                @test rejected.result.stderr == codeunits("rejected")
                @test rejected.result.exitcode == 2 || rejected.result.termsignal != 0
            end
        end
        tasks = [Threads.@spawn execute(`cat`; input=UInt8[i]).stdout for i = 1:8]
        @test fetch.(tasks) == [UInt8[i] for i = 1:8]
    end
end

@testset "tmux client environment boundary" begin
    server = Server(socket_name="never-contacted", tmux="/nonexistent/not-spawned")
    @test_throws ArgumentError run_command(
        server,
        "display-message";
        env=Dict("LIBTMUX_TEST_LARGE" => repeat("x", 15 * 1024)),
    )
    @test_throws ArgumentError run_command(
        server,
        "display-message";
        env=Dict("INVALID=KEY" => "value"),
    )
    @test_throws ArgumentError run_command(
        server,
        "display-message";
        env=Dict("LIBTMUX_TEST_NUL" => "a\0b"),
    )
    @test_throws ArgumentError run_command(
        server,
        "display-message";
        env=Dict("ENTRY_$i" => repeat("x", 8 * 1024) for i = 1:17),
    )
end

# A descendant that inherited the client's pipes can hold them open forever.
@testset "an exited client's silent pipes are closed after a quiet interval" begin
    mktempdir(; prefix="ltj-drain-") do directory
        pidfile = joinpath(directory, "holder.pid")
        # The sleep keeps this child's pipes after the child itself exits.
        holder = child(
            "background = run(`sleep 20`; wait=false); " *
            "write(ARGS[1], string(getpid(background))); println(\"kept\")",
            pidfile,
        )
        try
            started = time_ns()
            result = LibTmux._run_process(holder)
            @test String(result.stdout) == "kept\n" && result.exitcode == 0
            @test (time_ns() - started) / 1e9 < 5
        finally
            for pid in split(isfile(pidfile) ? read(pidfile, String) : "")
                run(ignorestatus(`kill $pid`))
            end
        end

        # Output that arrives slowly, within the quiet interval, is kept whole.
        slow = child("for letter in \"abc\"; print(letter); flush(stdout); sleep(0.1); end")
        result = LibTmux._run_process(slow)
        @test String(result.stdout) == "abc" && result.exitcode == 0
    end
end

if isdefined(Main, :include_test_file)
    Main.include_test_file(@__MODULE__, joinpath(@__DIR__, "process_retirement.jl"))
else
    include("process_retirement.jl")
end

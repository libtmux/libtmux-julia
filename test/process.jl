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

@testset "bounded owned processes" begin
    @test isdefined(LibTmux, :_run_process)
    if isdefined(LibTmux, :_run_process)
        execute = LibTmux._run_process
        bytes = execute(`sh -c "printf '\\000a\\377\\n'; printf err >&2; exit 7"`)
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
        pressure =
            execute(`sh -c "head -c 131072 /dev/zero & head -c 131072 /dev/zero >&2; wait"`)
        @test pressure.stdout == zeros(UInt8, 131072)
        @test pressure.stderr == zeros(UInt8, 131072)
        @test_throws OutputLimitExceeded execute(`yes x`; max_output_bytes=128)
        @test_throws OutputLimitExceeded execute(
            `sh -c "exec yes x >&2"`;
            max_error_bytes=128,
        )
        @test_throws DeadlineExceeded execute(`sh -c "while :; do :; done"`; timeout=0.03)
        @test execute(`sh -c "kill -TERM \$\$"`).termsignal == 15
        @test_throws TmuxNotFound execute(Cmd(["/nonexistent/libtmux-julia-executable"]))
        mktemp() do executable, io
            write(io, "#!/bin/sh\nexit 0\n")
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
        @test_throws ProcessIOError execute(
            `sh -c "exec 0<&-; while :; do :; done"`;
            input=fill(UInt8(1), 131072),
            timeout=0.08,
        )
        rejected = try
            execute(`sh -c "printf rejected >&2; exit 2"`; input=fill(UInt8(1), 131072))
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

include("process_retirement.jl")

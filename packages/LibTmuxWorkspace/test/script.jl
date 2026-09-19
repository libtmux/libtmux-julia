using Test
using LibTmuxWorkspace
import LibTmux

@testset "owned before_script execution" begin
    @test isdefined(LibTmuxWorkspace, :run_before_script)
    if isdefined(LibTmuxWorkspace, :run_before_script)
        mktempdir() do directory
            marker = joinpath(directory, "unintended")
            script = joinpath(directory, "argv")
            write(script, "#!/bin/sh\nprintf '%s\\n' \"\$@\"\nprintf '\\377' >&2\n")
            chmod(script, 0o700)
            result = run_before_script(
                "./argv '' 'a b' '; touch " * marker * "' \"\\\$VALUE\"";
                base_directory=directory,
                env=Dict("PATH" => "/usr/bin:/bin"),
            )
            @test String(result.stdout) == "\na b\n; touch " * marker * "\n\\\$VALUE\n"
            @test result.stderr == UInt8[0xff]
            @test result.exitcode == 0 && result.termsignal == 0
            @test !ispath(marker)
            @test ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1
            @test_throws WorkspaceConfigError run_before_script(
                "./argv 'unterminated";
                base_directory=directory,
            )
            failure = try
                run_before_script(
                    "/bin/echo too-much-output";
                    base_directory=directory,
                    max_output_bytes=3,
                )
            catch error
                error
            end
            @test failure isa BeforeScriptError && failure.code == :output_limit
            @test failure.result.stdout == codeunits("too")
            @test ccall(:kill, Cint, (Cint, Cint), failure.result.pid, 0) == -1
            token = LibTmux.CancellationToken()
            fifo = joinpath(directory, "blocked")
            @test ccall(:mkfifo, Cint, (Cstring, Cuint), fifo, 0o600) == 0
            write(script, "#!/bin/sh\nprintf ready\nexec /bin/cat \"\$1\"\n")
            failure = try
                run_before_script(
                    "./argv '" * fifo * "'";
                    base_directory=directory,
                    cancel=token,
                    on_output=(stream, bytes) -> LibTmux.cancel!(token),
                )
            catch error
                error
            end
            @test failure isa BeforeScriptError && failure.code == :cancelled
            @test failure.result.stdout == codeunits("ready")
            @test ccall(:kill, Cint, (Cint, Cint), failure.result.pid, 0) == -1
            failure = try
                run_before_script(
                    "./argv '" * fifo * "'";
                    base_directory=directory,
                    timeout=0.1,
                )
            catch error
                error
            end
            @test failure isa BeforeScriptError && failure.code == :deadline
            @test ccall(:kill, Cint, (Cint, Cint), failure.result.pid, 0) == -1
        end
    end
end

@testset "expired script deadline refuses admission" begin
    mktempdir() do directory
        marker = joinpath(directory, "must-not-start")
        script = joinpath(directory, "start")
        write(script, "#!/bin/sh\n: > \"\$1\"\n")
        chmod(script, 0o700)
        failure = try
            run_before_script(
                "./start '" * marker * "'";
                base_directory=directory,
                timeout=1e-12,
            )
        catch error
            error
        end
        @test failure isa BeforeScriptError && failure.code == :deadline
        @test failure.result === nothing
        @test !ispath(marker)
    end
end

@testset "worker interrupt remains cancellation" begin
    failure = try
        run_before_script(
            "/bin/echo ready";
            base_directory=tempdir(),
            on_output=(stream, bytes) -> throw(InterruptException()),
        )
    catch error
        error
    end
    @test failure isa BeforeScriptError && failure.code == :cancelled
    @test ccall(:kill, Cint, (Cint, Cint), failure.result.pid, 0) == -1
end

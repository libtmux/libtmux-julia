using Test, LibTmuxWorkspace
import LibTmux

struct _BlockedCLIOutput <: IO
    entered::Base.Event
    release::Base.Event
    closed::Threads.Atomic{Bool}
end
_BlockedCLIOutput() =
    _BlockedCLIOutput(Base.Event(), Base.Event(), Threads.Atomic{Bool}(false))
function Base.unsafe_write(io::_BlockedCLIOutput, data::Ptr{UInt8}, count::UInt)
    notify(io.entered)
    wait(io.release)
    io.closed[] && throw(EOFError())
    count
end
Base.flush(::_BlockedCLIOutput) = nothing
Base.close(io::_BlockedCLIOutput) = (io.closed[]=true; notify(io.release); nothing)

@testset "CLI output ownership and blocked writer retirement" begin
    out, err = IOBuffer(), IOBuffer()
    @test main(["--help"]; out, err) == 0 && isopen(out) && isopen(err)
    close(out)
    close(err)
    mktempdir() do directory
        fifo = joinpath(directory, "blocked")
        @test ccall(:mkfifo, Cint, (Cstring, Cuint), fifo, 0o600) == 0
        output = _BlockedCLIOutput()
        owner = LibTmuxWorkspace._CLIOwnedOutput(output, IOBuffer(); timeout=0.2)
        script_ready = Base.Event()
        command = join(
            LibTmuxWorkspace._shell_word.([
                "/bin/sh",
                "-c",
                "printf ready; exec /bin/cat \"\$1\"",
                "sh",
                fifo,
            ]),
            " ",
        )
        worker = Threads.@spawn try
            run_before_script(
                command;
                base_directory=directory,
                timeout=0.9,
                cancel=owner.cancel,
                on_output=(stream, bytes) -> notify(script_ready),
            )
        catch error
            error
        end
        completion = Threads.@spawn begin
            wait(worker)
            notify(script_ready)
            notify(output.entered)
        end
        try
            wait(script_ready)
            LibTmuxWorkspace._cli_output_enqueue(owner, :out, "progress\n")
            wait(output.entered)
            result = fetch(worker)
            @test result isa BeforeScriptError && result.code === :cancelled
            @test LibTmux.iscancelled(owner.cancel)
            @test_throws LibTmuxWorkspace._CLIOutputError close(owner)
            @test istaskdone(owner.worker) && output.closed[]
        finally
            close(output)
            wait(worker)
            wait(completion)
            try
                close(owner)
            catch
            end
        end
    end
end

@testset "CLI output queue overflow cancels and joins its writer" begin
    output = _BlockedCLIOutput()
    owner = LibTmuxWorkspace._CLIOwnedOutput(output, IOBuffer(); max_items=1, max_bytes=16)
    try
        LibTmuxWorkspace._cli_output_enqueue(owner, :out, "first")
        wait(output.entered)
        LibTmuxWorkspace._cli_output_enqueue(owner, :out, "second")
        @test_throws LibTmuxWorkspace._CLIOutputError LibTmuxWorkspace._cli_output_enqueue(
            owner,
            :out,
            "third",
        )
        @test LibTmux.iscancelled(owner.cancel)
        @test_throws LibTmuxWorkspace._CLIOutputError close(owner)
        @test istaskdone(owner.worker) && output.closed[]
    finally
        close(output)
        try
            close(owner)
        catch
        end
    end
end

@testset "owned full pipe interrupts an active write" begin
    output = Pipe()
    Base.link_pipe!(output; reader_supports_async=true, writer_supports_async=true)
    owner = LibTmuxWorkspace._CLIOwnedOutput(
        IOContext(output, :color=>false),
        IOBuffer();
        timeout=0.2,
    )
    try
        LibTmuxWorkspace._cli_output_enqueue(owner, :out, repeat("x", 1024^2))
        @test read(output.out, UInt8) == UInt8('x')
        @test_throws LibTmuxWorkspace._CLIOutputError close(owner)
        @test istaskdone(owner.worker) && LibTmux.iscancelled(owner.cancel)
        @test !isopen(output.in) && !isopen(output.out)
    finally
        close(output)
        try
            close(owner)
        catch
        end
    end
end

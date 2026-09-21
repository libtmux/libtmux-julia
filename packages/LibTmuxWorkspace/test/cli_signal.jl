using Test, LibTmuxWorkspace
import LibTmux

@testset "CLI signal watcher roots and retires its owned handle" begin
    @test isdefined(LibTmuxWorkspace, :_CLISignalWatcher)
    if isdefined(LibTmuxWorkspace, :_CLISignalWatcher)
        token = LibTmux.CancellationToken()
        watcher = LibTmuxWorkspace._CLISignalWatcher(token; _start=(_ -> 0))
        reference = WeakRef(watcher)
        watcher = nothing
        GC.gc(false)
        retained = reference.value
        @test retained !== nothing
        try
            LibTmuxWorkspace._cli_signal_callback(retained.handle, Cint(Base.SIGINT))
            wait(retained.worker)
            @test LibTmux.iscancelled(token)
        finally
            close(retained)
        end
        @test retained.handle == C_NULL && istaskdone(retained.worker)
        @test !lock(() -> haskey(Base.uvhandles, retained), Base.preserve_handle_lock)
        @test close(retained) === nothing

        rejected = Ref{Any}(nothing)
        function invalid_start(candidate)
            rejected[] = candidate
            LibTmuxWorkspace._cli_signal_start(candidate, Cint(-1))
        end
        @test_throws Base.IOError LibTmuxWorkspace._CLISignalWatcher(
            LibTmux.CancellationToken();
            _start=invalid_start,
        )
        @test rejected[].handle == C_NULL && rejected[].worker === nothing
        @test !lock(() -> haskey(Base.uvhandles, rejected[]), Base.preserve_handle_lock)
    end
end

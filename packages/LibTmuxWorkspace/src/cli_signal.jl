# The installed process owns SIGINT until exit. Julia 1.10 may otherwise deliver
# InterruptException to an already-completed task (JuliaLang/julia#45055).
mutable struct _CLISignalWatcher
    handle::Ptr{Cvoid}
    event::Base.Event
    closed::Base.Event
    fired::Threads.Atomic{Bool}
    stopping::Threads.Atomic{Bool}
    cancel::LibTmux.CancellationToken
    worker::Union{Nothing,Task}
end

# libuv invokes these callbacks on the event loop, not in the OS signal handler.
function _cli_signal_callback(handle::Ptr{Cvoid}, ::Cint)
    watcher = Base.@handle_as handle _CLISignalWatcher
    watcher.fired[] = true
    notify(watcher.event)
    nothing
end

function _cli_signal_closed(handle::Ptr{Cvoid})
    watcher = Base.@handle_as handle _CLISignalWatcher
    Base.disassociate_julia_struct(handle)
    Libc.free(handle)
    watcher.handle = C_NULL
    notify(watcher.closed)
    nothing
end

_cli_signal_start(watcher, number=Cint(Base.SIGINT)) = ccall(
    :uv_signal_start,
    Cint,
    (Ptr{Cvoid}, Ptr{Cvoid}, Cint),
    watcher.handle,
    @cfunction(_cli_signal_callback, Cvoid, (Ptr{Cvoid}, Cint)),
    number,
)

function _cli_signal_wait(watcher)
    wait(watcher.event)
    watcher.fired[] && LibTmux.cancel!(watcher.cancel)
    nothing
end

function _CLISignalWatcher(cancel; _start=_cli_signal_start)
    handle = Libc.malloc(Base._sizeof_uv_signal)
    handle == C_NULL && throw(OutOfMemoryError())
    watcher = _CLISignalWatcher(
        handle,
        Base.Event(),
        Base.Event(),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        cancel,
        nothing,
    )
    Base.preserve_handle(watcher)
    initialized = false
    try
        Base.iolock_begin()
        try
            code = ccall(
                :uv_signal_init,
                Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                Base.eventloop(),
                handle,
            )
            Base.uv_error("workspace SIGINT initialization", code)
            initialized = true
            Base.associate_julia_struct(handle, watcher)
            Base.uv_error("workspace SIGINT admission", _start(watcher))
        finally
            Base.iolock_end()
        end
        watcher.worker = Threads.@spawn _cli_signal_wait(watcher)
        watcher
    catch
        if initialized
            close(watcher)
        else
            Libc.free(handle)
            watcher.handle = C_NULL
            Base.unpreserve_handle(watcher)
        end
        rethrow()
    end
end

function Base.close(watcher::_CLISignalWatcher)
    if Threads.atomic_xchg!(watcher.stopping, true)
        wait(watcher.closed)
        watcher.worker === nothing || wait(watcher.worker)
        return nothing
    end
    try
        Base.iolock_begin()
        try
            # libuv restores the default signal action. This private watcher is
            # used only by the installed entrypoint, whose next action is exit.
            ccall(:uv_signal_stop, Cint, (Ptr{Cvoid},), watcher.handle)
            ccall(
                :uv_close,
                Cvoid,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                watcher.handle,
                @cfunction(_cli_signal_closed, Cvoid, (Ptr{Cvoid},)),
            )
        finally
            Base.iolock_end()
        end
        notify(watcher.event)
        wait(watcher.closed)
        watcher.worker === nothing || wait(watcher.worker)
    finally
        Base.unpreserve_handle(watcher)
    end
    nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    precompile(_cli_signal_callback, (Ptr{Cvoid}, Cint))
    precompile(_cli_signal_closed, (Ptr{Cvoid},))
    precompile(_cli_signal_wait, (_CLISignalWatcher,))
    precompile(Base.close, (_CLISignalWatcher,))
end

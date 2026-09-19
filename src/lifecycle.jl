import FileWatching
import UUIDs

"Startup failed after the owned daemon was spawned; `result` retains its exit evidence."
struct OwnedServerStartError <: LibTmuxError
    reason::Symbol
    result::CommandResult
    stderr_truncated::Bool
    probe::Union{Nothing,CommandResult}
end

"Cleanup finished with forced termination, incomplete diagnostics, or lost directory ownership."
struct OwnedServerCleanupError <: LibTmuxError
    reason::Symbol
    result::CommandResult
    stderr_truncated::Bool
end

Base.showerror(io::IO, error::OwnedServerStartError) = print(
    io,
    "owned tmux startup failed: ",
    error.reason,
    " (exit ",
    error.result.exitcode,
    ", signal ",
    error.result.termsignal,
    ")",
)
Base.showerror(io::IO, error::OwnedServerCleanupError) = print(
    io,
    "owned tmux cleanup failed: ",
    error.reason,
    " (exit ",
    error.result.exitcode,
    ", signal ",
    error.result.termsignal,
    ")",
)

"""
    OwnedServer

Own one foreground tmux daemon and its private socket directory. `.server` is
the explicit endpoint. Call `close` to reap the daemon and remove its directory;
use `with_server` when ownership can follow a callback's lifetime. This handle
does not own unrelated processes launched by application code.
"""
mutable struct OwnedServer
    _server::Server
    _directory::String
    _token::String
    _process::Base.Process
    _monitor::FileWatching.FolderMonitor
    _watcher::Task
    _stderr_pipe::Pipe
    _stderr_task::Task
    _lock::ReentrantLock
    _closed::Bool
end

Base.getproperty(owned::OwnedServer, name::Symbol) =
    name === :server ? getfield(owned, :_server) : getfield(owned, name)
Base.propertynames(::OwnedServer, private::Bool=false) =
    private ? (:server, fieldnames(OwnedServer)...) : (:server,)
Base.isopen(owned::OwnedServer) = lock(getfield(owned, :_lock)) do
    !getfield(owned, :_closed) && process_running(getfield(owned, :_process))
end
Base.show(io::IO, owned::OwnedServer) =
    print(io, "OwnedServer(", owned.server, ", open=", isopen(owned), ")")

Base.@noinline function _run_owned_timer(timer::Timer, callback)
    try
        wait(timer)
    catch error
        error isa EOFError || rethrow()
        return
    end
    callback()
end

function _owned_timer(callback, delay)
    timer = Timer(delay)
    task = Threads.@spawn _run_owned_timer(timer, callback)
    timer, task
end

function _owned_stderr(pipe::Pipe)
    captured = UInt8[]
    scratch = Vector{UInt8}(undef, 4096)
    truncated = false
    failure = nothing
    try
        while true
            count = readbytes!(pipe.out, scratch, length(scratch))
            count == 0 && break
            retained = min(count, 64 * 1024 - length(captured))
            offset = length(captured)
            resize!(captured, offset + retained)
            copyto!(captured, offset + 1, scratch, 1, retained)
            truncated |= count > retained
        end
    catch error
        failure = error
    end
    (; bytes=captured, truncated, failure)
end

function _owned_evidence(owned::OwnedServer)
    captured = fetch(getfield(owned, :_stderr_task))
    process = getfield(owned, :_process)
    CommandResult(UInt8[], copy(captured.bytes), process.exitcode, process.termsignal),
    captured
end

function _owned_remove(directory, token)
    marker = joinpath(directory, "owner")
    !islink(directory) &&
    isdir(directory) &&
    !islink(marker) &&
    isfile(marker) &&
    filesize(marker) == ncodeunits(token) &&
    read(marker, String) == token || return false
    rm(directory; recursive=true)
    true
end

"""
    close(owned::OwnedServer)

Stop only the spawned daemon, reap it, join its watchers, and remove its owned
directory. Concurrent calls serialize; later calls return `nothing`. Shutdown
sends SIGTERM and permits 900 ms for exit and diagnostic drainage. If SIGKILL
or forced pipe closure is needed, cleanup completes before throwing
`OwnedServerCleanupError`. A replaced ownership marker prevents directory
removal. Cleanup never sends `kill-server` to an endpoint.
"""
function Base.close(owned::OwnedServer)
    lock(getfield(owned, :_lock)) do
        getfield(owned, :_closed) && return nothing
        setfield!(owned, :_closed, true)
        process = getfield(owned, :_process)
        pipe = getfield(owned, :_stderr_pipe)
        state_lock = ReentrantLock()
        completed = Ref(false)
        forced = Ref(false)
        drain_closed = Ref(false)
        errors = Exception[]
        timer, timer_task = _owned_timer(0.9) do
            lock(state_lock) do
                completed[] && return
                if process_running(process)
                    forced[] = true
                    kill(process, Base.SIGKILL)
                end
                if !istaskdone(getfield(owned, :_stderr_task))
                    drain_closed[] = true
                    _close_owned(pipe.out)
                end
            end
        end
        try
            process_running(process) && kill(process, Base.SIGTERM)
            wait(process)
            wait(getfield(owned, :_stderr_task))
        catch error
            push!(errors, error)
            process_running(process) && kill(process, Base.SIGKILL)
            wait(process)
            _close_owned(pipe.out)
            wait(getfield(owned, :_stderr_task))
        finally
            lock(state_lock) do
                completed[] = true
            end
            close(timer)
            wait(timer_task)
            close(getfield(owned, :_monitor))
            wait(getfield(owned, :_watcher))
            _close_owned(pipe)
        end
        result, captured = _owned_evidence(owned)
        reason =
            forced[] ? :forced_termination :
            drain_closed[] ? :stderr_drain :
            captured.failure !== nothing ? :stderr_io : nothing
        reason === nothing || push!(
            errors,
            OwnedServerCleanupError(reason, result, captured.truncated || drain_closed[]),
        )
        try
            _owned_remove(getfield(owned, :_directory), getfield(owned, :_token)) || push!(
                errors,
                OwnedServerCleanupError(:directory_ownership, result, captured.truncated),
            )
        catch error
            push!(errors, error)
        end
        isempty(errors) ||
            throw(length(errors) == 1 ? only(errors) : CompositeException(errors))
        nothing
    end
end

struct _OwnedStartupFailure <: Exception
    reason::Symbol
    probe::Union{Nothing,CommandResult}
end
_OwnedStartupFailure(reason::Symbol) = _OwnedStartupFailure(reason, nothing)

struct _OwnedReadyStop
    monitor::FileWatching.FolderMonitor
    completed::Base.RefValue{Bool}
    reason::Base.RefValue{Union{Nothing,Exception}}
    lock::ReentrantLock
end
function (stop::_OwnedReadyStop)(error)
    lock(stop.lock) do
        (stop.completed[] || stop.reason[] !== nothing) && return
        stop.reason[] = error
        close(stop.monitor)
    end
end

function _owned_ready(owned, env, cancel, started, budget; _cancel_subscribe=on_cancel)
    state_lock = ReentrantLock()
    reason = Ref{Union{Nothing,Exception}}(nothing)
    completed = Ref(false)
    monitor = getfield(owned, :_monitor)
    process = getfield(owned, :_process)
    remaining() = budget - (time_ns() - started) / 1e9
    stop = _OwnedReadyStop(monitor, completed, reason, state_lock)
    check_reason() = lock(state_lock) do
        reason[] === nothing || throw(reason[])
    end
    timer, timer_task = _owned_timer(_DeadlineCallback(stop, budget), max(remaining(), 0.0))
    registration =
        cancel === nothing ? nothing :
        _cancel_subscribe(() -> stop(RequestCancelled(true)), cancel)
    primary = nothing
    try
        while true
            check_reason()
            process_running(process) || throw(_OwnedStartupFailure(:daemon_exit))
            socket = owned.server.socket_path
            ispath(socket) && !ispath(socket * ".lock") && break
            try
                wait(monitor)
            catch error
                error isa EOFError || rethrow()
                check_reason()
                throw(_OwnedStartupFailure(:daemon_exit))
            end
        end
        delay = remaining()
        delay > 0 || throw(DeadlineExceeded(budget, true, nothing))
        argv = [
            owned.server.tmux,
            "-u",
            "-N",
            "-S",
            owned.server.socket_path,
            "-f",
            "/dev/null",
            "--",
            "display-message",
            "-p",
            "#{pid}",
        ]
        result = _run_process(
            setenv(Cmd(argv), env);
            cancel,
            timeout=delay,
            max_output_bytes=128,
            max_error_bytes=64 * 1024,
        )
        result.exitcode == 0 && result.termsignal == 0 ||
            throw(_OwnedStartupFailure(:ownership_probe, result))
        result.stdout == codeunits(string(getpid(process), '\n')) ||
            throw(_OwnedStartupFailure(:pid_mismatch, result))
        finish =
            () -> lock(state_lock) do
                reason[] === nothing || throw(reason[])
                cancel === nothing || !cancel.cancelled || throw(RequestCancelled(true))
                remaining() > 0 || throw(DeadlineExceeded(budget, true, nothing))
                process_running(process) || throw(_OwnedStartupFailure(:daemon_exit))
                completed[] = true
            end
        cancel === nothing ? finish() : lock(finish, cancel.lock)
    catch error
        primary = error
        rethrow()
    finally
        lock(state_lock) do
            completed[] = true
        end
        cleanup_errors = Exception[]
        for cleanup in (
            () -> close(timer),
            () -> wait(timer_task),
            () -> close(monitor),
            () -> registration === nothing || close(registration),
        )
            try
                cleanup()
            catch error
                push!(cleanup_errors, error)
            end
        end
        if !isempty(cleanup_errors)
            primary === nothing || pushfirst!(cleanup_errors, primary)
            throw(
                length(cleanup_errors) == 1 ? only(cleanup_errors) :
                CompositeException(cleanup_errors),
            )
        end
    end
    nothing
end

"""
    open_server(; tmux="tmux", env=ENV, timeout=0.9, cancel=nothing)

Start an isolated foreground tmux daemon with an empty configuration and a
unique private socket directory. Validate its reported PID against the spawned
child before returning an `OwnedServer`. Environment entries are copied and
validated; inherited `TMUX` and `TMUX_PANE` are removed. No ambient server is
contacted. The temporary directory must permit a socket path under 104 bytes.

`timeout` bounds startup using a monotonic clock; `cancel` applies only until
startup finishes. Both failure paths reap the daemon. Daemon stderr retains at
most 64 KiB; startup and cleanup errors indicate truncated diagnostics. Close
the returned handle explicitly, or use `with_server` for scoped ownership.
"""
function open_server(;
    tmux="tmux",
    env::AbstractDict=ENV,
    timeout::Real=0.9,
    cancel::Union{Nothing,CancellationToken}=nothing,
)
    started = time_ns()
    executable = _argument(tmux)
    isempty(executable) && throw(ArgumentError("tmux executable cannot be empty"))
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1.0e15 || throw(
        ArgumentError("timeout must be positive and representable by the process timer"),
    )
    environment = _client_environment(env)
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    token = string(UUIDs.uuid4())
    directory = mktempdir(; prefix="libtmux-julia-", cleanup=false)
    marker = joinpath(directory, "owner")
    marker_written = false
    monitor = nothing
    pipe = Pipe()
    owned = nothing
    process = nothing
    stderr_task = nothing
    watcher = nothing
    try
        write(marker, token)
        marker_written = true
        socket = joinpath(directory, "s")
        ncodeunits(socket) < 104 ||
            throw(ArgumentError("temporary directory makes the tmux socket path too long"))
        server = Server(; socket_path=socket, tmux=executable)
        monitor = FileWatching.FolderMonitor(directory)
        command =
            setenv(Cmd([executable, "-D", "-S", socket, "-f", "/dev/null"]), environment)
        spawn =
            () -> begin
                cancel === nothing || !cancel.cancelled || throw(RequestCancelled(false))
                (time_ns() - started) / 1e9 < budget ||
                    throw(DeadlineExceeded(budget, false, nothing))
                run(
                    pipeline(
                        ignorestatus(command);
                        stdin=devnull,
                        stdout=devnull,
                        stderr=pipe,
                    );
                    wait=false,
                )
            end
        spawned = try
            cancel === nothing ? spawn() : lock(spawn, cancel.lock)
        catch error
            error
        end
        # A spawn exception embeds Cmd's environment; leave its catch before
        # throwing the sanitized public error so exception chains stay clean.
        if spawned isa Base.IOError
            cause = Base.IOError("owned daemon spawn failed", spawned.code)
            spawned.code == Base.UV_ENOENT && throw(TmuxNotFound(executable, cause))
            throw(ProcessSpawnError(executable, cause))
        end
        spawned isa Exception && throw(spawned)
        process = spawned
        close(pipe.in)
        stderr_task = Threads.@spawn _owned_stderr(pipe)
        watcher = Threads.@spawn begin
            wait(process)
            close(monitor)
        end
        owned = OwnedServer(
            server,
            directory,
            token,
            process,
            monitor,
            watcher,
            pipe,
            stderr_task,
            ReentrantLock(),
            false,
        )
        _owned_ready(owned, environment, cancel, started, budget)
        owned
    catch primary
        cleanup = nothing
        if owned === nothing
            # Keep the spawn-to-handle interval owned if setup itself fails.
            if process !== nothing
                process_running(process) && kill(process, Base.SIGKILL)
                wait(process)
            end
            monitor === nothing || close(monitor)
            _close_owned(pipe)
            stderr_task === nothing || wait(stderr_task)
            watcher === nothing || wait(watcher)
            try
                if marker_written
                    _owned_remove(directory, token) ||
                        error("owned startup directory marker changed")
                else
                    rm(directory; recursive=true)
                end
            catch error
                cleanup = error
            end
        else
            try
                close(owned)
            catch error
                cleanup = error
            end
            if primary isa _OwnedStartupFailure
                result, captured = _owned_evidence(owned)
                primary = OwnedServerStartError(
                    primary.reason,
                    result,
                    captured.truncated,
                    primary.probe,
                )
            elseif primary isa Union{RequestCancelled,DeadlineExceeded}
                result, _ = _owned_evidence(owned)
                evidence = primary.result === nothing ? result : primary.result
                primary =
                    primary isa RequestCancelled ? RequestCancelled(true, evidence) :
                    DeadlineExceeded(budget, true, evidence)
            end
        end
        cleanup === nothing ? throw(primary) : throw(CompositeException([primary, cleanup]))
    end
end

"""
    with_server(f; kwargs...)

Call `f(server)` with an owned daemon, return its result, and close the daemon
before returning or rethrowing. Keywords match `open_server`. If both the body
and cleanup fail, throw `CompositeException` retaining both errors in that order.
"""
function with_server(f; kwargs...)
    owned = open_server(; kwargs...)
    primary = nothing
    try
        f(owned.server)
    catch error
        primary = error
        rethrow()
    finally
        try
            close(owned)
        catch cleanup
            primary === nothing ? throw(cleanup) :
            throw(CompositeException([primary, cleanup]))
        end
    end
end

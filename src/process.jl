abstract type LibTmuxError <: Exception end

"""Owned output bytes and exit evidence from one completed tmux client."""
struct CommandResult
    stdout::Vector{UInt8}
    stderr::Vector{UInt8}
    exitcode::Int
    termsignal::Int
end

struct TmuxNotFound <: LibTmuxError
    executable::String
    cause::Exception
end

struct ProcessSpawnError <: LibTmuxError
    executable::String
    cause::Exception
end

struct RequestCancelled <: LibTmuxError
    sent::Bool
    result::Union{Nothing,CommandResult}
end
RequestCancelled(sent::Bool) = RequestCancelled(sent, nothing)

struct DeadlineExceeded <: LibTmuxError
    timeout::Float64
    sent::Bool
    result::Union{Nothing,CommandResult}
end
DeadlineExceeded(timeout::Float64) = DeadlineExceeded(timeout, true, nothing)

struct OutputLimitExceeded <: LibTmuxError
    stream::Symbol
    limit::Int
    result::Union{Nothing,CommandResult}
end
OutputLimitExceeded(stream::Symbol, limit::Int) =
    OutputLimitExceeded(stream, limit, nothing)

struct ProcessIOError <: LibTmuxError
    stream::Symbol
    cause::Exception
    result::Union{Nothing,CommandResult}
end
ProcessIOError(stream::Symbol, cause::Exception) = ProcessIOError(stream, cause, nothing)

_with_result(e::RequestCancelled, r) = RequestCancelled(e.sent, r)
_with_result(e::DeadlineExceeded, r) = DeadlineExceeded(e.timeout, e.sent, r)
_with_result(e::OutputLimitExceeded, r) = OutputLimitExceeded(e.stream, e.limit, r)
_with_result(e::ProcessIOError, r) = ProcessIOError(e.stream, e.cause, r)

struct CommandError <: LibTmuxError
    result::CommandResult
    command::String
end
CommandError(result::CommandResult) = CommandError(result, "command")

Base.showerror(io::IO, e::TmuxNotFound) =
    print(io, "could not start tmux executable ", repr(e.executable))
Base.showerror(io::IO, e::ProcessSpawnError) =
    print(io, "could not spawn ", repr(e.executable), ": ", sprint(showerror, e.cause))
Base.showerror(io::IO, e::RequestCancelled) = print(
    io,
    e.sent ? "request cancelled after submission; remote effects may have occurred" :
    "request cancelled before submission",
)
Base.showerror(io::IO, e::DeadlineExceeded) = print(
    io,
    "request exceeded ",
    e.timeout,
    e.sent ? " seconds; remote effects may have occurred" : " seconds before submission",
)
Base.showerror(io::IO, e::OutputLimitExceeded) =
    print(io, e.stream, " exceeded ", e.limit, " bytes")
Base.showerror(io::IO, e::ProcessIOError) =
    print(io, "process ", e.stream, " I/O failed: ", sprint(showerror, e.cause))
function Base.showerror(io::IO, e::CommandError)
    print(
        io,
        "tmux ",
        e.command,
        " failed (exit ",
        e.result.exitcode,
        ", signal ",
        e.result.termsignal,
        ")",
    )
    if !isempty(e.result.stderr)
        bytes = e.result.stderr
        preview = decode_text(@view(bytes[1:min(length(bytes), 256)]); invalid=:replace)
        print(io, ": ", repr(rstrip(preview)))
        length(bytes) > 256 && print(io, " (diagnostic truncated)")
    end
end

"""
    CancellationToken()

An explicit, task-safe cancellation signal. `cancel!` is idempotent. Cancelling
an operation retires its local resources; it does not roll back tmux effects.
"""
mutable struct CancellationToken
    lock::ReentrantLock
    cancelled::Bool
    next_id::UInt64
    hooks::Dict{UInt64,Function}
end
CancellationToken() = CancellationToken(ReentrantLock(), false, 0, Dict{UInt64,Function}())

function cancel!(token::CancellationToken)
    callbacks = lock(token.lock) do
        token.cancelled && return Function[]
        token.cancelled = true
        pending = collect(values(token.hooks))
        empty!(token.hooks)
        pending
    end
    errors = Exception[]
    for callback in callbacks
        try
            callback()
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    nothing
end

_iscancelled(token::CancellationToken) = lock(() -> token.cancelled, token.lock)

"Return whether cancellation was requested, without performing I/O."
iscancelled(token::CancellationToken) = _iscancelled(token)

"An owned cancellation callback registration; `close` unregisters and joins its callback."
mutable struct CancellationSubscription
    token::CancellationToken
    key::UInt64
    lock::ReentrantLock
    closed::Bool
end

"""
    on_cancel(f, token::CancellationToken)

Register a callable and return a `CancellationSubscription`. `cancel!` invokes
each registered callback once, outside the token lock, on its calling task.
If already cancelled, invoke `f()` before returning. Keep callbacks prompt:
signal an event or stop an owned process; do not wait for operation completion.
Callback failures are collected after all callbacks run and raised together.

Closing a subscription prevents later invocation and joins a callback already
running on another task. Close subscriptions when their operation retires.
"""
function on_cancel(f, token::CancellationToken)
    subscription = CancellationSubscription(token, 0, ReentrantLock(), false)
    subscription.key = _register_cancel(token) do
        lock(subscription.lock) do
            subscription.closed || f()
        end
    end
    subscription
end

function Base.close(subscription::CancellationSubscription)
    lock(subscription.lock) do
        subscription.closed && return nothing
        subscription.closed = true
        _unregister_cancel(subscription.token, subscription.key)
    end
    nothing
end

function _register_cancel(callback, token::CancellationToken)
    key = lock(token.lock) do
        token.cancelled && return UInt64(0)
        token.next_id += 1
        token.hooks[token.next_id] = callback
        token.next_id
    end
    key == 0 && callback()
    key
end

function _unregister_cancel(token::CancellationToken, key)
    lock(token.lock) do
        delete!(token.hooks, key)
    end
    nothing
end

function _close_owned(io)
    try
        close(io)
    catch error
        error isa Base.IOError || rethrow()
    end
end

# Stable worker types admit native precompilation of process I/O callbacks.
struct _ProcessDrainClose
    output::Base.PipeEndpoint
    error::Base.PipeEndpoint
end
(callback::_ProcessDrainClose)() = foreach(_close_owned, (callback.output, callback.error))

struct _ProcessStop{F}
    make_timer::F
    process::Base.Process
    drain_timer::Base.RefValue{Union{Nothing,Timer}}
    drain_task::Base.RefValue{Union{Nothing,Task}}
    retired::Base.RefValue{Bool}
    reason::Base.RefValue{Union{Nothing,Exception}}
    lock::ReentrantLock
    input::Pipe
    output::Pipe
    error::Pipe
end

function (stop::_ProcessStop)(error)
    should_stop = lock(stop.lock) do
        (stop.retired[] || stop.reason[] !== nothing) && return false
        stop.reason[] = error
        stop.drain_timer[], stop.drain_task[] =
            stop.make_timer(_ProcessDrainClose(stop.output.out, stop.error.out), 0.9)
        true
    end
    should_stop || return
    try
        kill(stop.process, Base.SIGKILL)
    catch cause
        cause isa Base.IOError || rethrow()
    finally
        _close_owned(stop.input.in)
    end
    nothing
end

struct _DeadlineCallback{F}
    stop::F
    timeout::Float64
end
(callback::_DeadlineCallback)() = callback.stop(DeadlineExceeded(callback.timeout))

struct _ProcessDrain{F}
    stop::F
    io::Base.PipeEndpoint
    stream::Symbol
    limit::Int
    activity::Threads.Atomic{UInt64}
    abandoned::Threads.Atomic{Bool}
end

# How long the pipes of an exited client may stay silent before a descendant
# that inherited them is presumed to be holding them open.
const _PIPE_QUIET_NS = UInt64(250_000_000)

Base.@noinline function (worker::_ProcessDrain)()
    captured = UInt8[]
    try
        while !eof(worker.io)
            chunk = readavailable(worker.io)
            worker.activity[] = time_ns()
            available = worker.limit - length(captured)
            count = min(length(chunk), available)
            offset = length(captured)
            resize!(captured, offset + count)
            copyto!(captured, offset + 1, chunk, 1, count)
            if length(chunk) > available
                worker.stop(OutputLimitExceeded(worker.stream, worker.limit))
                break
            end
        end
    catch cause
        worker.abandoned[] || worker.stop(ProcessIOError(worker.stream, cause))
    end
    captured
end

# Wait for both drains once the client has exited. A descendant, such as the
# server of a tmux that cannot close its descriptors, may keep a pipe open
# forever: when no output arrived for `_PIPE_QUIET_NS`, close our read ends so
# the drains finish with what was written.
function _await_drains(tasks, activity, abandoned, close_pipes)
    done = Base.Event()
    joiner = Threads.@spawn begin
        foreach(wait, tasks)
        notify(done)
    end
    # The client's exit counts as activity, so the interval starts there.
    activity[] = max(activity[], time_ns())
    while !istaskdone(joiner)
        deadline = activity[] + _PIPE_QUIET_NS
        remaining = (Int64(deadline) - Int64(time_ns())) / 1e9
        remaining > 0 || begin
            abandoned[] = true
            close_pipes()
            break
        end
        tick = Timer(_ -> notify(done), remaining)
        try
            wait(done)
        finally
            close(tick)
        end
    end
    wait(joiner)
    nothing
end

struct _ProcessInput{F}
    stop::F
    io::Base.PipeEndpoint
    payload::Vector{UInt8}
end

Base.@noinline function (worker::_ProcessInput)()
    try
        isempty(worker.payload) || write(worker.io, worker.payload)
        nothing
    catch cause
        worker.stop(ProcessIOError(:stdin, cause))
        cause
    finally
        _close_owned(worker.io)
    end
end

function _run_process(
    cmd::Cmd;
    input::AbstractVector{UInt8}=UInt8[],
    cancel::Union{Nothing,CancellationToken}=nothing,
    timeout::Union{Nothing,Real}=nothing,
    _started::UInt64=time_ns(),
    _cancel_subscribe=on_cancel,
    _make_timer=_owned_timer,
    max_output_bytes::Int=8 * 1024^2,
    max_error_bytes::Int=1024^2,
)
    max_output_bytes >= 0 && max_error_bytes >= 0 ||
        throw(ArgumentError("output limits must be nonnegative"))
    delay = timeout === nothing ? nothing : Float64(timeout)
    delay === nothing ||
        (isfinite(delay) && 0 < delay < 1.0e15) ||
        throw(
            ArgumentError(
                "timeout must be positive and representable by the process timer",
            ),
        )
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    started = _started
    payload = convert(Vector{UInt8}, copy(input))
    input_pipe, output_pipe, error_pipe = Pipe(), Pipe(), Pipe()
    state_lock = ReentrantLock()
    reason = Ref{Union{Nothing,Exception}}(nothing)
    retired = Ref(false)
    registration = nothing
    timer = nothing
    timer_task = nothing
    drain_timer = Ref{Union{Nothing,Timer}}(nothing)
    drain_timer_task = Ref{Union{Nothing,Task}}(nothing)
    workers = Task[]
    spawned = try
        spawn =
            () -> begin
                cancel === nothing || !cancel.cancelled || throw(RequestCancelled(false))
                delay === nothing ||
                    (time_ns() - started) / 1e9 < delay ||
                    throw(DeadlineExceeded(delay, false, nothing))
                run(
                    pipeline(
                        ignorestatus(cmd);
                        stdin=input_pipe,
                        stdout=output_pipe,
                        stderr=error_pipe,
                    );
                    wait=false,
                )
            end
        # Serialize only process admission with cancellation, never result waiting.
        cancel === nothing ? spawn() : lock(spawn, cancel.lock)
    catch cause
        foreach(_close_owned, (input_pipe, output_pipe, error_pipe))
        cause
    end
    # Julia's spawn error embeds Cmd's environment. Keep diagnostic codes,
    # not the process environment, in public errors or exception chains.
    if spawned isa Base.IOError
        cause = Base.IOError("client spawn failed", spawned.code)
        spawned.code == Base.UV_ENOENT && throw(TmuxNotFound(first(cmd.exec), cause))
        throw(ProcessSpawnError(first(cmd.exec), cause))
    end
    spawned isa Exception && throw(spawned)
    proc = spawned
    primary = nothing
    try
        close(input_pipe.out)
        close(output_pipe.in)
        close(error_pipe.in)
        stop = _ProcessStop(
            _make_timer,
            proc,
            drain_timer,
            drain_timer_task,
            retired,
            reason,
            state_lock,
            input_pipe,
            output_pipe,
            error_pipe,
        )

        registration =
            cancel === nothing ? nothing :
            _cancel_subscribe(() -> stop(RequestCancelled(true)), cancel)
        timer, timer_task =
            delay === nothing ? (nothing, nothing) :
            _make_timer(
                _DeadlineCallback(stop, delay),
                max(0.0, delay - (time_ns() - started) / 1e9),
            )
        activity = Threads.Atomic{UInt64}(time_ns())
        abandoned = Threads.Atomic{Bool}(false)
        output_worker = _ProcessDrain(
            stop,
            output_pipe.out,
            :stdout,
            max_output_bytes,
            activity,
            abandoned,
        )
        output_task = Threads.@spawn output_worker()
        push!(workers, output_task)
        error_worker = _ProcessDrain(
            stop,
            error_pipe.out,
            :stderr,
            max_error_bytes,
            activity,
            abandoned,
        )
        error_task = Threads.@spawn error_worker()
        push!(workers, error_task)
        input_worker = _ProcessInput(stop, input_pipe.in, payload)
        writer_task = Threads.@spawn input_worker()
        push!(workers, writer_task)
        wait(proc)
        _await_drains(
            (output_task, error_task),
            activity,
            abandoned,
            _ProcessDrainClose(output_pipe.out, error_pipe.out),
        )
        stdout_bytes, stderr_bytes = fetch(output_task), fetch(error_task)
        write_error = fetch(writer_task)
        failure = lock(state_lock) do
            retired[] = true
            reason[]
        end
        result = CommandResult(
            stdout_bytes,
            stderr_bytes,
            Int(proc.exitcode),
            Int(proc.termsignal),
        )
        failure === nothing || throw(_with_result(failure, result))
        if write_error !== nothing && result.exitcode == 0 && result.termsignal == 0
            throw(ProcessIOError(:stdin, write_error, result))
        end
        result
    catch error
        primary = error
        rethrow()
    finally
        lock(state_lock) do
            retired[] = true
        end
        cleanup_errors = Exception[]
        cleanup = function (operation)
            try
                operation()
            catch error
                push!(cleanup_errors, error)
            end
        end
        timer === nothing || cleanup(() -> close(timer))
        drain_timer[] === nothing || cleanup(() -> close(drain_timer[]))
        cleanup(() -> process_running(proc) && kill(proc, Base.SIGKILL))
        for pipe in (input_pipe, output_pipe, error_pipe)
            cleanup(() -> _close_owned(pipe))
        end
        cleanup(() -> wait(proc))
        for worker in workers
            cleanup(() -> wait(worker))
        end
        # Callbacks may already be running despite timer closure or cancellation
        # unregistration. Join after releasing their state lock and owned pipes.
        registration === nothing || cleanup(() -> close(registration))
        timer_task === nothing || cleanup(() -> wait(timer_task))
        drain_timer_task[] === nothing || cleanup(() -> wait(drain_timer_task[]))
        if !isempty(cleanup_errors)
            primary === nothing || pushfirst!(cleanup_errors, primary)
            throw(
                length(cleanup_errors) == 1 ? only(cleanup_errors) :
                CompositeException(cleanup_errors),
            )
        end
    end
end

"""
    run_command(server, args...; check=true, env=ENV, input=UInt8[], cancel=nothing,
                timeout=nothing, max_output_bytes=8388608, max_error_bytes=1048576)

Run one tmux client with literal arguments and return owned output bytes.
The client uses UTF-8 mode independently of the caller's locale.
Nonzero exits raise `CommandError` unless `check=false`. I/O yields to other
Julia tasks. Cancellation kills and reaps the client, not any remote pane job.
The call checks the release of the selected daemon, or of the executable that
would create it, against tmux 3.3a. The first command to an endpoint probes the
release; later commands to the same executable and endpoint skip the probe.
Every command runs behind a fence on the checked release, so a replaced daemon
raises `UnsupportedTmuxVersion` before any effect. A fence mismatch, a vanished
endpoint or a tmux 3.1 or older answer drops the remembered release and probes
once more. The probe runs no user hook. It does not pin a server generation;
use strict references only through transports that explicitly advertise that
capability.

The first cancellation, deadline, output overflow or pipe error wins. Its
`result` retains bounded output and observed exit/signal evidence after client
retirement; it is `nothing` before submission. Failed input delivery is an
I/O error even with `check=false`. Cleanup allows at most 900 ms for inherited
output pipes after stopping the owned client, then closes them. After a client
exits by itself, a pipe that stays open and silent for 250 ms is closed and the
output read so far is returned. Return or failure joins I/O tasks, timer tasks
and any running cancellation callback.
If cleanup also fails, `CompositeException` preserves the primary error first.

Arguments and individual environment entries are limited to a conservative
14 KiB; the combined client environment is limited to 128 KiB. Oversized
entries fail before submission instead of being silently omitted by tmux.
Inherited `TMUX` and `TMUX_PANE` are always removed.
"""
function run_command(
    server::Server,
    args::AbstractString...;
    check::Bool=true,
    env::AbstractDict=ENV,
    _checked::Union{Nothing,Base.RefValue{Any}}=nothing,
    _version_guard=nothing,
    kwargs...,
)
    started = time_ns()
    isempty(args) &&
        throw(ArgumentError("supply a tmux command; implicit attach is not supported"))
    arguments = collect(args)
    sum(ncodeunits(arg) + 1 for arg in _argv(server, arguments)) <= 14 * 1024 || throw(
        ArgumentError(
            "command exceeds the conservative 14 KiB limit; use a buffer/input operation for large data",
        ),
    )
    environment = _client_environment(env)
    cleanup = first(args) == "kill-server"
    result = checked = nothing
    for attempt = 1:2
        # A known live endpoint skips the probe. The fence below still checks
        # every command and drops a stale entry, so a replaced or vanished
        # daemon costs one retry before any effect.
        known =
            _checked !== nothing && _checked[] !== nothing ? _checked[].version :
            _cached_release(server)
        reused = attempt == 1 && known !== nothing
        checked =
            reused ? (; version=known, live=true) :
            _check_version(
                server,
                environment;
                cleanup,
                cancel=get(kwargs, :cancel, nothing),
                timeout=get(kwargs, :timeout, nothing),
                started,
            )
        # An absent endpoint has nothing to stop, so cleanup is complete.
        checked.version === nothing && return CommandResult(UInt8[], UInt8[], 0, 0)
        _version_guard === nothing || _version_guard(checked.version)
        marker = _version_marker()
        argv = _fenced_argv(server, arguments, checked, marker)
        result = _run_process(setenv(Cmd(argv), environment); _started=started, kwargs...)
        mismatch = _fence_failed(result, marker)
        vanished =
            reused &&
            result.exitcode != 0 &&
            _endpoint_absent(decode_text(result.stderr; invalid=:replace))
        # An old daemon that replaced the cached one answers the fenced command
        # with a protocol diagnostic instead of the marker.
        stale =
            reused &&
            result.exitcode != 0 &&
            any(_pre_probe_diagnostic, _stderr_lines(result))
        if (mismatch || vanished || stale) && reused
            _forget_release!(server)
            _checked === nothing || (_checked[] = nothing)
            continue
        end
        mismatch && _throw_fence()
        break
    end
    if result.exitcode == 0 && result.termsignal == 0
        if cleanup
            _forget_release!(server)
            _checked === nothing || (_checked[] = nothing)
        else
            _remember_release!(server, checked.version)
            _checked === nothing || (_checked[] = (; checked.version, live=true))
        end
    end
    if check && (result.exitcode != 0 || result.termsignal != 0)
        throw(CommandError(result, String(first(args))))
    end
    result
end

function _client_environment(env)
    environment = Dict{String,String}()
    bytes = 0
    for (key, value) in env
        key in ("TMUX", "TMUX_PANE") && continue
        name, text = _argument(key), _argument(value)
        (isempty(name) || occursin('=', name)) &&
            throw(ArgumentError("environment names must be nonempty and contain no '='"))
        size = ncodeunits(name) + ncodeunits(text) + 2
        size <= 14 * 1024 || throw(
            ArgumentError(
                "environment entry $(repr(name)) exceeds the conservative 14 KiB limit",
            ),
        )
        bytes += size
        bytes <= 128 * 1024 || throw(ArgumentError("client environment exceeds 128 KiB"))
        environment[name] = text
    end
    environment
end

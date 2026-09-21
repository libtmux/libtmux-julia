using UUIDs: uuid4

abstract type _ControlObservationState end
_control_publish!(::Nothing, connection, event) = false
_control_end_observation!(::Nothing, connection, reason) = nothing
_control_join_observation(::Nothing) = nothing

"""
Owned reply bytes and guard for an admitted control command. `run_command`
returns after its completion fence; grouped outcomes expose completion
separately when cancellation leaves only a partial response.
"""
struct ControlResult
    stdout::Vector{UInt8}
    failed::Bool
    timestamp::UInt64
    number::UInt64
    flags::UInt64
end
ControlResult(frame::_ControlFrame) = ControlResult(
    frame.payload,
    frame.failed,
    frame.guard.timestamp,
    frame.guard.number,
    frame.guard.flags,
)

"An admitted control command failed; `result` retains its owned reply bytes and guard."
struct ControlCommandError <: LibTmuxError
    result::ControlResult
    command::String
end
Base.showerror(io::IO, error::ControlCommandError) =
    print(io, "tmux control command failed: ", error.command)

"A terminal control-lane failure; `sent` distinguishes possible remote effects from non-submission."
struct ControlConnectionError <: LibTmuxError
    reason::Symbol
    sent::Bool
end
"""Local resources closed, but retirement of submitted backend work was not proved."""
struct ControlCleanupError <: LibTmuxError
    reason::Symbol
end
Base.showerror(io::IO, error::ControlCleanupError) =
    print(io, "tmux control cleanup could not confirm remote retirement: ", error.reason)
"An exact control target did not resolve; no fallback observation is returned."
struct ControlTargetError <: LibTmuxError
    target::String
end
Base.showerror(io::IO, error::ControlTargetError) =
    print(io, "tmux control target no longer resolves exactly: ", error.target)
Base.showerror(io::IO, error::ControlConnectionError) = print(
    io,
    "tmux control connection ",
    error.reason,
    error.sent ? "; remote effects may have occurred" : "; request was not submitted",
)

abstract type _ControlReplyCollector end

mutable struct _ControlRequest
    command::String
    input::String
    fence::Vector{UInt8}
    policy::_ControlReplyPolicy
    state::Symbol
    sent::Bool
    frame::Union{Nothing,_ControlFrame}
    result::Union{Nothing,ControlResult}
    error::Union{Nothing,Exception}
    caller_done::Bool
    cancel::Union{Nothing,CancellationToken}
    collector::Union{Nothing,_ControlReplyCollector}
end

function _control_collect!(::Nothing, request, frame)
    request.frame === nothing ||
        throw(_ControlProtocolError(:admission, :multiple_command_replies))
    request.frame = frame
end
_control_finish!(::Nothing, request) = ControlResult(something(request.frame))

"""A bounded, one-use wait signal whose tmux channel belongs to its connection."""
mutable struct ControlSignal{C}
    const connection::C
    const name::String
    state::Symbol
    notified::Bool
    request::Union{Nothing,_ControlRequest}
    cleanup_queued::Bool
    cleanup_done::Bool
    error::Union{Nothing,Exception}
end

"""
Own a control client attached to a borrowed session. Closing the connection
owns client processes, pipes and Julia tasks, never the session or daemon.
Attach/detach still invokes configured hooks and can trigger tmux's
destroy-unattached/exit-unattached settings. Aliases and hooks are trusted
server configuration; they must not replace admitted command semantics.
"""
mutable struct ControlConnection
    server::Server
    session::SessionRef
    identity::ServerIdentity
    lock::ReentrantLock
    changed::Threads.Condition
    process::Base.Process
    input::Pipe
    output::Pipe
    errors::Pipe
    workers::Vector{Task}
    supervisor::Union{Nothing,Task}
    pending::Vector{_ControlRequest}
    events::Vector{_ControlEvent}
    stderr::Vector{UInt8}
    capacity::Int
    state::Symbol
    reason::Symbol
    startup::Bool
    startup_failed::Bool
    submitted::Int
    stop_timer::Union{Nothing,Timer}
    stop_timer_task::Union{Nothing,Task}
    cleanup::Union{Nothing,ControlConnection}
    parent::Union{Nothing,ControlConnection}
    signals::Vector{ControlSignal}
    cleanup_queue::Vector{ControlSignal}
    cleanup_worker::Union{Nothing,Task}
    closing_requested::Bool
    cleanup_error::Union{Nothing,ControlCleanupError}
    observation::Union{Nothing,_ControlObservationState}
end

Base.isopen(connection::ControlConnection) =
    lock(() -> connection.state === :open && !connection.closing_requested, connection.lock)
Base.show(io::IO, connection::ControlConnection) = lock(connection.lock) do
    print(
        io,
        "ControlConnection(session=",
        repr(string(connection.session.id)),
        ", state=",
        connection.state,
        ")",
    )
end
Base.show(io::IO, signal::ControlSignal) = lock(signal.connection.lock) do
    print(io, "ControlSignal(state=", signal.state, ", cleanup_done=", signal.cleanup_done, ")")
end

_control_occupancy(connection) =
    length(connection.pending) + count(
        signal -> signal.request === nothing || signal.request.state === :retired,
        connection.signals,
    )

function _control_queue_cleanup!(connection, signal)
    signal.cleanup_queued && return
    signal.cleanup_queued = true
    push!(connection.cleanup_queue, signal)
    notify(connection.changed; all=true)
end

function _control_stop!(connection::ControlConnection, reason::Symbol)
    stop = lock(connection.lock) do
        connection.state in (:closing, :closed) && return false
        connection.state = :closing
        connection.reason = reason
        _control_end_observation!(connection.observation, connection, reason)
        for request in connection.pending
            if !request.caller_done
                request.error = ControlConnectionError(reason, request.sent)
                request.caller_done = true
            end
            request.state = request.sent ? :abandoned : :retired
        end
        empty!(connection.pending)
        for signal in copy(connection.signals)
            request = signal.request
            if request === nothing || !request.sent
                _control_retire_signal!(connection, signal)
            else
                connection.cleanup_error =
                    ControlCleanupError(:remote_retirement_unconfirmed)
                signal.notified = true
                _control_queue_cleanup!(connection, signal)
            end
        end
        connection.stop_timer, connection.stop_timer_task = _owned_timer(0.9) do
            lock(connection.lock) do
                connection.cleanup_error = ControlCleanupError(:forced_client_termination)
            end
            try
                process_running(connection.process) &&
                    kill(connection.process, Base.SIGKILL)
            catch error
                error isa Base.IOError || rethrow()
            end
            foreach(_close_owned, (connection.output, connection.errors))
        end
        notify(connection.changed; all=true)
        true
    end
    stop || return
    auxiliary = lock(connection.lock) do
        connection.closing_requested || !isempty(connection.signals) ? nothing :
        connection.cleanup
    end
    auxiliary === nothing || _control_stop!(auxiliary, reason)
    try
        process_running(connection.process) && kill(connection.process, Base.SIGTERM)
    catch error
        error isa Base.IOError || rethrow()
    end
    _close_owned(connection.input)
    nothing
end

function _control_policy(connection::ControlConnection, guard::_ControlGuard)
    lock(connection.lock) do
        connection.startup && return _ControlReplyPolicy(; diagnostics=true)
        guard.flags == 0 && return _ControlReplyPolicy(; diagnostics=true)
        guard.flags == 1 || throw(_ControlProtocolError(:admission, :unknown_flags))
        index = findfirst(request -> request.sent, connection.pending)
        index === nothing && throw(_ControlProtocolError(:admission, :unsolicited_reply))
        connection.pending[index].policy
    end
end

function _control_event(connection::ControlConnection, event::_ControlEvent)
    lock(connection.lock) do
        connection.state === :closing && return
        if event isa _ControlFrame
            if connection.startup
                connection.startup = false
                connection.startup_failed = event.failed
            elseif event.guard.flags == 1
                isempty(connection.pending) &&
                    throw(_ControlProtocolError(:admission, :unsolicited_reply))
                request = first(connection.pending)
                request.sent ||
                    throw(_ControlProtocolError(:admission, :reply_before_submission))
                if event.failed && event.payload == request.fence
                    request.frame === nothing &&
                        throw(_ControlProtocolError(:admission, :missing_command_reply))
                    request.result = _control_finish!(request.collector, request)
                    request.state = :retired
                    request.caller_done = true
                    popfirst!(connection.pending)
                else
                    _control_collect!(request.collector, request, event)
                end
            else
                _control_publish!(connection.observation, connection, event)
            end
        else
            # Validation already happened in the parser. Unobserved events
            # are future-only and must not accumulate on either client lane.
            _control_publish!(connection.observation, connection, event)
        end
        notify(connection.changed; all=true)
    end
end

function _control_reader(connection::ControlConnection)
    parser = _ControlParser(; frame_policy=guard -> _control_policy(connection, guard))
    try
        while !eof(connection.output.out)
            chunk = readavailable(connection.output.out)
            # A 1 KiB slice cannot overflow the parser's 256-event feed budget.
            first_byte = 1
            while first_byte <= length(chunk)
                newline = findnext(==(0x0a), chunk, first_byte)
                last_byte =
                    min(first_byte + 1023, newline === nothing ? length(chunk) : newline)
                events = _control_feed!(parser, @view(chunk[first_byte:last_byte]))
                foreach(event -> _control_event(connection, event), events)
                first_byte = last_byte + 1
            end
        end
        foreach(
            event -> _control_event(connection, event),
            _control_feed!(parser, UInt8[]; final=true),
        )
        _control_stop!(connection, :eof)
    catch error
        _control_stop!(
            connection,
            error isa _ControlProtocolError ? :protocol_failure : :read_failure,
        )
    end
    nothing
end

function _control_cancel!(connection, request, error)
    lock(connection.lock) do
        request.caller_done && return
        request.error = error(request.sent)
        request.caller_done = true
        if request.sent
            request.state = :tombstone
        else
            request.state = :retired
            filter!(pending -> pending !== request, connection.pending)
        end
        notify(connection.changed; all=true)
    end
    nothing
end

function _control_writer(connection::ControlConnection)
    try
        while true
            request = lock(connection.lock) do
                while true
                    connection.state in (:closing, :closed) && return nothing
                    index = findfirst(
                        request -> request.state === :queued,
                        connection.pending,
                    )
                    if index !== nothing
                        request = connection.pending[index]
                        admit =
                            () -> begin
                                if request.cancel !== nothing && request.cancel.cancelled
                                    request.error = RequestCancelled(false)
                                    request.caller_done = true
                                    request.state = :retired
                                    deleteat!(connection.pending, index)
                                    notify(connection.changed; all=true)
                                    return nothing
                                end
                                request.state = :writing
                                request.sent = true
                                connection.submitted += 1
                                for signal in connection.signals
                                    signal.request === request &&
                                        signal.notified &&
                                        _control_queue_cleanup!(connection, signal)
                                end
                                request
                            end
                        accepted =
                            request.cancel === nothing ? admit() :
                            lock(admit, request.cancel.lock)
                        accepted === nothing || return accepted
                    else
                        wait(connection.changed)
                    end
                end
            end
            request === nothing && break
            write(connection.input.in, request.input)
            flush(connection.input.in)
            lock(connection.lock) do
                request.state === :writing && (request.state = :awaiting_fence)
                notify(connection.changed; all=true)
            end
        end
    catch
        _control_stop!(connection, :write_failure)
    end
    nothing
end

function _control_stderr(connection::ControlConnection)
    try
        while !eof(connection.errors.out)
            chunk = readavailable(connection.errors.out)
            length(chunk) <= 65_536 - length(connection.stderr) || begin
                _control_stop!(connection, :stderr_limit)
                return
            end
            append!(connection.stderr, chunk)
        end
    catch
        _control_stop!(connection, :stderr_failure)
    end
    nothing
end

function _control_supervise(connection::ControlConnection)
    try
        wait(connection.process)
        _control_stop!(connection, :client_exit)
        foreach(wait, connection.workers)
    finally
        connection.stop_timer === nothing || close(connection.stop_timer)
        connection.stop_timer_task === nothing || wait(connection.stop_timer_task)
        foreach(_close_owned, (connection.input, connection.output, connection.errors))
        lock(connection.lock) do
            connection.state = :closed
            notify(connection.changed; all=true)
        end
        parent = lock(() -> connection.parent, connection.lock)
        parent === nothing ||
            lock(() -> parent.closing_requested, parent.lock) ||
            _control_stop!(parent, :cleanup_lane_lost)
    end
    nothing
end

function _close_control_lane(connection::ControlConnection)
    _control_stop!(connection, :closed_by_caller)
    connection.supervisor === nothing || wait(connection.supervisor)
    _control_join_observation(connection.observation)
    nothing
end

function _control_request(
    connection,
    argv,
    policy;
    timeout::Real=5.0,
    cancel=nothing,
    opening::Bool=false,
    reservation=nothing,
    cleanup::Bool=false,
    collector=nothing,
    encoded_group=nothing,
)
    started = time_ns()
    delay = Float64(timeout)
    isfinite(delay) && 0 < delay < 1e15 ||
        throw(ArgumentError("control timeout must be positive and finite"))
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    nonce = "__libtmux_fence_" * replace(string(uuid4()), "-" => "")
    encoded = if encoded_group === nothing
        _encode_control_command(argv)
    else
        collector isa _ControlReplyCollector ||
            throw(ArgumentError("group encoding requires an audited reply collector"))
        bytes = codeunits(encoded_group)
        0 < length(bytes) <= 1024*1024 &&
        last(bytes) == 0x0a &&
        count(==(0x0a), bytes) == 1 ||
            throw(ArgumentError("control group must be one bounded encoded line"))
        String(encoded_group)
    end
    fence = collect(codeunits("parse error: unknown command: " * nonce * "\n"))
    request = _ControlRequest(
        String(first(argv)),
        encoded * _encode_control_command([nonce]),
        fence,
        policy,
        :unadmitted,
        false,
        nothing,
        nothing,
        nothing,
        false,
        cancel,
        collector,
    )
    registration =
        cancel === nothing ? nothing :
        on_cancel(
            () -> _control_cancel!(connection, request, sent -> RequestCancelled(sent)),
            cancel,
        )
    timer, timer_task = _owned_timer(max(0.0, delay - (time_ns() - started) / 1e9)) do
        _control_cancel!(connection, request, sent -> DeadlineExceeded(delay, sent, nothing))
    end
    try
        outcome = lock(connection.lock) do
            allowed() =
                (
                    connection.state === :open &&
                    (!connection.closing_requested || cleanup)
                ) || (opening && connection.state === :opening)
            while allowed() &&
                  !request.caller_done &&
                  reservation === nothing &&
                  _control_occupancy(connection) >= connection.capacity
                wait(connection.changed)
            end
            if !request.caller_done
                allowed() || throw(ControlConnectionError(connection.reason, false))
                request.state = :queued
                push!(connection.pending, request)
                reservation === nothing || (reservation.request = request)
                notify(connection.changed; all=true)
            end
            while !request.caller_done
                wait(connection.changed)
            end
            request.error === nothing ? something(request.result) : request.error
        end
        outcome isa Exception && throw(outcome)
        outcome
    finally
        close(timer)
        wait(timer_task)
        registration === nothing || close(registration)
    end
end

const _CONTROL_FIELDS =
    Set([_SERVER_FIELDS; _SESSION_FIELDS; _WINDOW_FIELDS; _PANE_FIELDS; _CLIENT_FIELDS])

function _control_rows(
    connection::ControlConnection,
    command::AbstractString,
    fields::AbstractVector{<:AbstractString};
    target=nothing,
    timeout::Real=5.0,
    cancel=nothing,
    _opening::Bool=false,
)
    command in
    ("display-message", "list-sessions", "list-windows", "list-panes", "list-clients") ||
        throw(ArgumentError("control row command is not admitted"))
    !isempty(fields) && all(field -> field in _CONTROL_FIELDS, fields) ||
        throw(ArgumentError("control row fields must come from the admitted field catalog"))
    argv = [String(command)]
    command == "display-message" && push!(argv, "-p")
    observed_fields = String.(fields)
    target_field = nothing
    if target !== nothing
        allowed =
            command == "display-message" ? target isa Union{SessionRef,WindowRef,PaneRef} :
            command in ("list-windows", "list-clients") ? target isa SessionRef :
            command == "list-panes" ? target isa WindowRef : false
        allowed ||
            throw(ArgumentError("control row target kind is not admitted for this command"))
        target.server.socket_path == connection.identity.socket_path ||
            throw(CrossServerReference(string(target.id)))
        target.server == connection.identity || throw(StaleReference(string(target.id)))
        append!(argv, ["-t", string(target.id)])
        if command == "display-message"
            target_field =
                target isa SessionRef ? "session_id" :
                target isa WindowRef ? "window_id" : "pane_id"
            pushfirst!(observed_fields, target_field)
        end
    elseif command in ("list-windows", "list-panes")
        push!(argv, "-a")
    end
    prefix = "LIBTMUX\t"
    append!(argv, ["-F", prefix * _format_template(observed_fields)])
    result = _control_request(
        connection,
        argv,
        _ControlReplyPolicy(; prefix, diagnostics=true);
        timeout,
        cancel,
        opening=_opening,
    )
    result.failed && throw(ControlCommandError(result, String(command)))
    rows = _decode_format_rows(result.stdout, length(observed_fields) + 1)
    all(row -> first(row) == "LIBTMUX", rows) ||
        throw(_ControlProtocolError(:rows, :invalid_prefix))
    if target_field !== nothing
        length(rows) == 1 && rows[1][2] == string(target.id) ||
            throw(ControlTargetError(string(target.id)))
        return [row[3:end] for row in rows]
    end
    [row[2:end] for row in rows]
end

"""
    run_command(connection::ControlConnection, argv...; timeout=5.0, cancel=nothing, check=true)

Run an admitted command on the existing control connection. The initial
allowlist covers exact-ID destruction and restricted-name buffer deletion;
raw output producers, formats and borrowed wait channels are rejected.
Cancellation before write admission sends nothing. After admission it reports
uncertain effects; its ledger slot remains until the completion fence retires.
No command is replayed and no other transport is selected.
"""
function run_command(
    connection::ControlConnection,
    argv::AbstractString...;
    timeout::Real=5.0,
    cancel=nothing,
    check::Bool=true,
)
    arguments = collect(argv)
    policy = _admit_control_command(arguments)
    result = _control_request(connection, arguments, policy; timeout, cancel)
    result.failed && check && throw(ControlCommandError(result, String(first(arguments))))
    result
end

"""
    open_control(server, session::SessionRef; timeout=5.0, cancel=nothing, capacity=64)

Attach an owned control client to an existing borrowed session. The client
uses UTF-8, ignores size, suppresses pane output, avoids environment updates,
and does not start a missing server. A same-connection metadata handshake
must match the captured endpoint/generation and exact session before return.
The connection then pins that daemon; captured PID/start-time identity itself
remains a best-effort observation and can theoretically be reused.

Random unknown-command fences establish queue completion under the trusted
alias/hook contract; they are not alias-proof or a solution to raw capture
framing. Each fence's expected error is checked before accepting its result.
"""
function _open_control_lane(
    server::Server,
    session::SessionRef;
    timeout::Real=5.0,
    cancel=nothing,
    capacity::Integer=64,
)
    !(capacity isa Bool) && 0 < capacity <= typemax(Int) || throw(
        ArgumentError("control capacity must be a positive representable Int, not Bool"),
    )
    admitted_capacity = Int(capacity)
    started = time_ns()
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 || throw(ArgumentError("invalid control timeout"))
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    server.socket_path === nothing ||
        server.socket_path == session.server.socket_path ||
        throw(CrossServerReference(string(session.id)))
    selector =
        server.socket_path === nothing ? ["-L", something(server.socket_name)] :
        ["-S", server.socket_path]
    argv = [
        server.tmux;
        "-u";
        "-C";
        "-N";
        selector;
        "--";
        "attach-session";
        "-E";
        "-t";
        string(session.id);
        "-f";
        "ignore-size,no-output"
    ]
    input, output, errors = Pipe(), Pipe(), Pipe()
    spawned = try
        command = setenv(Cmd(argv), _client_environment(ENV))
        spawn =
            () -> begin
                cancel === nothing || !cancel.cancelled || throw(RequestCancelled(false))
                _snapshot_remaining(started, budget)
                run(
                    pipeline(
                        ignorestatus(command);
                        stdin=input,
                        stdout=output,
                        stderr=errors,
                    );
                    wait=false,
                )
            end
        cancel === nothing ? spawn() : lock(spawn, cancel.lock)
    catch error
        foreach(_close_owned, (input, output, errors))
        error
    end
    if spawned isa Base.IOError
        error = Base.IOError("control client spawn failed", spawned.code)
        spawned.code == Base.UV_ENOENT && throw(TmuxNotFound(server.tmux, error))
        throw(ProcessSpawnError(server.tmux, error))
    end
    spawned isa Exception && throw(spawned)
    connection = nothing
    try
        close(input.out)
        close(output.in)
        close(errors.in)
        mutex = ReentrantLock()
        connection = ControlConnection(
            server,
            session,
            session.server,
            mutex,
            Threads.Condition(mutex),
            spawned,
            input,
            output,
            errors,
            Task[],
            nothing,
            _ControlRequest[],
            _ControlEvent[],
            UInt8[],
            admitted_capacity,
            :opening,
            :opening,
            true,
            false,
            0,
            nothing,
            nothing,
            nothing,
            nothing,
            ControlSignal[],
            ControlSignal[],
            nothing,
            false,
            nothing,
            nothing,
        )
        push!(connection.workers, Threads.@spawn _control_reader(connection))
        push!(connection.workers, Threads.@spawn _control_writer(connection))
        push!(connection.workers, Threads.@spawn _control_stderr(connection))
        connection.supervisor = Threads.@spawn _control_supervise(connection)
    catch primary
        cleanup = try
            if connection === nothing
                try
                    process_running(spawned) && kill(spawned, Base.SIGKILL)
                finally
                    foreach(_close_owned, (input, output, errors))
                    wait(spawned)
                end
            else
                _control_stop!(connection, :setup_failure)
                _control_supervise(connection)
            end
            nothing
        catch error
            error
        end
        cleanup === nothing ? throw(primary) : throw(CompositeException([primary, cleanup]))
    end
    timer, timer_task = _owned_timer(max(0.0, budget - (time_ns() - started) / 1e9)) do
        _control_stop!(connection, :open_timeout)
    end
    registration =
        cancel === nothing ? nothing :
        on_cancel(() -> _control_stop!(connection, :open_cancelled), cancel)
    try
        lock(connection.lock) do
            while connection.startup && connection.state === :opening
                wait(connection.changed)
            end
            connection.state === :opening ||
                throw(ControlConnectionError(connection.reason, false))
            connection.startup_failed &&
                throw(ControlConnectionError(:attach_failed, false))
        end
        fields = ["pid", "start_time", "socket_path", "session_id"]
        row = only(
            _control_rows(
                connection,
                "display-message",
                fields;
                timeout=_snapshot_remaining(started, budget),
                cancel,
                _opening=true,
            ),
        )
        _observed_int(row[1], "pid")
        _observed_int(row[2], "start_time")
        identity = ServerIdentity(socket_path=row[3], generation=row[1] * ":" * row[2])
        identity.socket_path == session.server.socket_path ||
            throw(CrossServerReference(string(session.id)))
        identity == session.server && row[4] == string(session.id) ||
            throw(StaleReference(string(session.id)))
        lock(connection.lock) do
            connection.state === :opening ||
                throw(ControlConnectionError(connection.reason, false))
            connection.identity = identity
            connection.state = :open
            connection.reason = :open
            notify(connection.changed; all=true)
        end
        connection
    catch
        _close_control_lane(connection)
        rethrow()
    finally
        close(timer)
        wait(timer_task)
        registration === nothing || close(registration)
    end
end

"""
    control_signal(connection)

Reserve one connection capacity slot for a one-use `ControlSignal`. `wait`
and `notify` operate only on its generated channel. Minted but unused signals
retire locally on close. No caller-provided or borrowed channels are accepted.
"""
function control_signal(connection::ControlConnection)
    lock(connection.lock) do
        connection.state === :open && !connection.closing_requested ||
            throw(ControlConnectionError(connection.reason, false))
        _control_occupancy(connection) < connection.capacity || throw(
            ArgumentError(
                "connection capacity is reserved; retire a request or signal first",
            ),
        )
        signal = ControlSignal(
            connection,
            "libtmux_owned_" * replace(string(uuid4()), "-" => ""),
            :minted,
            false,
            nothing,
            false,
            false,
            nothing,
        )
        push!(connection.signals, signal)
        signal
    end
end

function _control_retire_signal!(connection, signal; error=nothing, confirmed::Bool=true)
    signal.state = :retired
    signal.cleanup_done = confirmed
    signal.error = error
    filter!(owned -> owned !== signal, connection.signals)
    notify(connection.changed; all=true)
end

"""
    notify(signal::ControlSignal)

Signal this owned, one-use wait. Before waiting this is a local latch; after
submission a bounded cleanup worker signals the auxiliary control connection.
The call never waits for network/process I/O and is idempotent.
"""
function Base.notify(signal::ControlSignal)
    connection = signal.connection
    lock(connection.lock) do
        signal.state === :retired && return
        any(owned -> owned === signal, connection.signals) ||
            throw(ArgumentError("control signal was not minted by this connection"))
        signal.notified = true
        request = signal.request
        request === nothing || !request.sent || _control_queue_cleanup!(connection, signal)
    end
    nothing
end

"""
    wait(signal::ControlSignal; timeout=5.0, cancel=nothing)

Wait once for an owned signal. The tmux command's `%end` is not completion:
the request retires only when its following fence executes. After submission,
cancellation wakes the caller with uncertain-effect evidence while an owned
worker signals and retires the backend wait on a second control connection.
"""
function Base.wait(signal::ControlSignal; timeout::Real=5.0, cancel=nothing)
    started = time_ns()
    delay = Float64(timeout)
    isfinite(delay) && 0 < delay < 1e15 || throw(ArgumentError("invalid signal timeout"))
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    connection = signal.connection
    local_only = lock(connection.lock) do
        signal.state === :minted ||
            throw(ArgumentError("control signal can only be waited once"))
        any(owned -> owned === signal, connection.signals) ||
            throw(ArgumentError("control signal was not minted by this connection"))
        connection.state === :open && !connection.closing_requested ||
            throw(ControlConnectionError(connection.reason, false))
        signal.state = :waiting
        if signal.notified
            _control_retire_signal!(connection, signal)
            true
        else
            false
        end
    end
    local_only && return nothing
    try
        result = _control_request(
            connection,
            ["wait-for", signal.name],
            _ControlReplyPolicy(; diagnostics=true);
            timeout=max(eps(Float64), delay - (time_ns() - started) / 1e9),
            cancel,
            reservation=signal,
        )
        result.failed && throw(ControlCommandError(result, "wait-for"))
        lock(connection.lock) do
            _control_queue_cleanup!(connection, signal)
        end
        _control_wait_signal_cleanup(signal, started, delay, cancel)
    catch
        lock(connection.lock) do
            request = signal.request
            if signal.state === :retired
                nothing
            elseif request === nothing || !request.sent
                _control_retire_signal!(connection, signal)
            else
                signal.notified = true
                _control_queue_cleanup!(connection, signal)
            end
        end
        rethrow()
    end
    nothing
end

function _control_wait_signal_cleanup(signal, started, timeout, cancel)
    connection = signal.connection
    reason = Ref{Union{Nothing,Exception}}(nothing)
    function interrupt(error)
        lock(connection.lock) do
            if !signal.cleanup_done && reason[] === nothing
                reason[] = error
                notify(connection.changed; all=true)
            end
        end
    end
    timer, timer_task = _owned_timer(max(0.0, timeout - (time_ns() - started) / 1e9)) do
        interrupt(DeadlineExceeded(timeout, true, nothing))
    end
    registration =
        cancel === nothing ? nothing :
        on_cancel(() -> interrupt(RequestCancelled(true)), cancel)
    try
        lock(connection.lock) do
            while signal.state !== :retired && reason[] === nothing
                wait(connection.changed)
            end
            reason[] === nothing || throw(reason[])
            signal.error === nothing || throw(signal.error)
        end
    finally
        close(timer)
        wait(timer_task)
        registration === nothing || close(registration)
    end
    nothing
end

function _control_signal_worker(connection)
    function command(auxiliary, argv)
        result = _control_request(
            auxiliary,
            argv,
            _ControlReplyPolicy(; diagnostics=true);
            timeout=0.9,
            cleanup=true,
        )
        result.failed && throw(ControlCommandError(result, "wait-for"))
        nothing
    end
    released = ControlSignal[]
    try
        while true
            work = lock(connection.lock) do
                while true
                    if !isempty(connection.cleanup_queue)
                        return (:release, popfirst!(connection.cleanup_queue))
                    end
                    index = findfirst(released) do signal
                        connection.state in (:closing, :closed) || (
                            signal.request !== nothing && signal.request.state === :retired
                        )
                    end
                    index === nothing || return (:retire, splice!(released, index))
                    (connection.closing_requested && isempty(connection.signals)) &&
                        return nothing
                    connection.state in (:closing, :closed) && return nothing
                    wait(connection.changed)
                end
            end
            work === nothing && break
            phase, signal = work
            auxiliary = something(connection.cleanup)
            if phase === :release
                command(auxiliary, ["wait-for", "-S", signal.name])
                # A later wait's fence can be blocked behind an earlier wait.
                # Release other channels before waiting for either retirement.
                push!(released, signal)
                continue
            end
            confirmed = lock(connection.lock) do
                signal.request !== nothing && signal.request.state === :retired
            end
            # Locking prevents S from removing an already-latched channel.
            # Under this owned lock, S establishes woken=1 in either state;
            # U then removes the empty channel. No cleanup command waits.
            command(auxiliary, ["wait-for", "-L", signal.name])
            command(auxiliary, ["wait-for", "-S", signal.name])
            command(auxiliary, ["wait-for", "-U", signal.name])
            lock(connection.lock) do
                error =
                    confirmed ? nothing :
                    ControlCleanupError(:remote_retirement_unconfirmed)
                error === nothing || (connection.cleanup_error = error)
                _control_retire_signal!(connection, signal; error, confirmed)
            end
        end
    catch error
        lock(connection.lock) do
            connection.cleanup_error = ControlCleanupError(:signal_cleanup_failed)
            for signal in copy(connection.signals)
                _control_retire_signal!(connection, signal; error, confirmed=false)
            end
            empty!(connection.cleanup_queue)
        end
        _control_stop!(connection, :signal_cleanup_failed)
    finally
        terminal = lock(() -> connection.state in (:closing, :closed), connection.lock)
        terminal && _control_stop!(something(connection.cleanup), :primary_lane_lost)
    end
    nothing
end

function Base.close(connection::ControlConnection)
    if connection.cleanup === nothing
        return _close_control_lane(connection)
    end
    owner = lock(connection.lock) do
        connection.closing_requested && return false
        connection.closing_requested = true
        connection.state === :open && (connection.reason = :closed_by_caller)
        for request in copy(connection.pending)
            _control_cancel!(
                connection,
                request,
                sent -> ControlConnectionError(:closed_by_caller, sent),
            )
        end
        for signal in copy(connection.signals)
            request = signal.request
            if request === nothing || !request.sent
                _control_retire_signal!(connection, signal)
            else
                signal.notified = true
                _control_queue_cleanup!(connection, signal)
            end
        end
        notify(connection.changed; all=true)
        true
    end
    if owner
        timer, timer_task = _owned_timer(0.9) do
            lock(connection.lock) do
                connection.cleanup_error = ControlCleanupError(:close_timeout)
            end
            _control_stop!(connection, :close_timeout)
            _control_stop!(something(connection.cleanup), :close_timeout)
        end
        try
            lock(connection.lock) do
                while !(connection.state in (:closing, :closed)) &&
                      (!isempty(connection.pending) || !isempty(connection.signals))
                    wait(connection.changed)
                end
            end
            _close_control_lane(connection)
            connection.cleanup_worker === nothing || wait(connection.cleanup_worker)
            _close_control_lane(something(connection.cleanup))
        finally
            close(timer)
            wait(timer_task)
        end
    else
        connection.supervisor === nothing || wait(connection.supervisor)
        connection.cleanup.supervisor === nothing || wait(connection.cleanup.supervisor)
        connection.cleanup_worker === nothing || wait(connection.cleanup_worker)
    end
    _control_join_observation(connection.observation)
    cleanup_error = lock(() -> connection.cleanup_error, connection.lock)
    cleanup_error === nothing && (
        cleanup_error =
            lock(() -> connection.cleanup.cleanup_error, connection.cleanup.lock)
    )
    cleanup_error === nothing || throw(cleanup_error)
    nothing
end

"""
    open_control(server, session::SessionRef; timeout=5.0, cancel=nothing, capacity=64)

Open two owned control clients on the borrowed session: a request lane and a
cleanup lane for library-owned waits. Both independently verify the captured
generation over their own connection. The two attachments are observable;
configured attach/detach hooks and unattached-session/server policies apply.

Capacity includes minted signals until cleanup. `close` stops admission,
signals submitted owned waits, waits for their fences, then joins both client
processes and all I/O/cleanup tasks. A dead/unresponsive backend can prevent
proving remote retirement; local cleanup remains bounded and effects are
reported by `ControlCleanupError`; `ControlSignal.cleanup_done` remains false
without its primary completion fence. No borrowed wait channel is signalled.
The do-block form preserves body and cleanup failures in `CompositeException`.
`capacity` must be positive, fit `Int`, and cannot be `Bool`; invalid capacity
fails before attaching a client.
"""
function open_control(
    server::Server,
    session::SessionRef;
    timeout::Real=5.0,
    cancel=nothing,
    capacity::Integer=64,
)
    started = time_ns()
    primary = _open_control_lane(server, session; timeout, cancel, capacity)
    auxiliary = nothing
    try
        auxiliary = _open_control_lane(
            server,
            session;
            timeout=_snapshot_remaining(started, Float64(timeout)),
            cancel,
            capacity=1,
        )
        lock(primary.lock) do
            primary.state === :open || throw(ControlConnectionError(primary.reason, false))
            primary.cleanup = auxiliary
        end
        lock(auxiliary.lock) do
            auxiliary.parent = primary
        end
        isopen(auxiliary) || throw(ControlConnectionError(:cleanup_lane_lost, false))
        primary.cleanup_worker = Threads.@spawn _control_signal_worker(primary)
        primary
    catch
        auxiliary === nothing || _close_control_lane(auxiliary)
        close(primary)
        rethrow()
    end
end

function open_control(f, server::Server, session::SessionRef; kwargs...)
    connection = open_control(server, session; kwargs...)
    primary = nothing
    try
        f(connection)
    catch error
        primary = error
        rethrow()
    finally
        try
            close(connection)
        catch cleanup
            primary === nothing ? throw(cleanup) :
            throw(CompositeException([primary, cleanup]))
        end
    end
end

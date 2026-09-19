"""
A position bound to a server generation, optional pane, connection epoch,
event kind and sequence. Obtain it with [`observation_cursor`](@ref). Replay
validates its scope and retained history; it is not a screen offset or a
persistent cursor across connections.
"""
struct ObservationCursor
    server::ServerIdentity
    pane::Union{Nothing,PaneID}
    epoch::String
    kind::Symbol
    sequence::UInt64
end

"An observation gap or invalid replay position; `cursor` is the last accepted position."
struct ObservationLost <: LibTmuxError
    reason::Symbol
    cursor::ObservationCursor
end
Base.showerror(io::IO, error::ObservationLost) =
    print(io, "tmux observation lost: ", error.reason, "; acquire a new baseline")

"A notification, raw pane-output chunk or sampled format value with an observation cursor."
abstract type ObservationEvent end
"""
A known tmux notification. `name` is its protocol name as a symbol; `bytes`
owns the complete record without its final LF. No UTF-8 conversion is implied.
"""
struct NotificationEvent <: ObservationEvent
    name::Symbol
    bytes::Vector{UInt8}
    cursor::ObservationCursor
end
"""
Owned, octal-decoded bytes from one exact pane. `age_ms` retains tmux's optional
extended-output age. Chunks are raw output, not screen images, text lines or
command-completion evidence.
"""
struct PaneOutput <: ObservationEvent
    pane::PaneRef
    bytes::Vector{UInt8}
    age_ms::Union{Nothing,UInt64}
    cursor::ObservationCursor
end
"""
One sampled format field, with session and window-link context. `bytes` retains
the field codec's escaped value; `window_index` is tmux's contextual index.
Optional window/pane references distinguish session-level updates. Pane values
may repeat for multiple links; their context is preserved rather than deduplicated.
"""
struct FormatUpdate <: ObservationEvent
    field::String
    bytes::Vector{UInt8}
    session::SessionRef
    window::Union{Nothing,WindowRef}
    window_index::Union{Nothing,Int}
    pane::Union{Nothing,PaneRef}
    cursor::ObservationCursor
end

"""
    format_value(update::FormatUpdate) -> String

Decode one captured format update, preserving literal tabs, newlines,
backslashes and Unicode. This accessor performs no I/O. Empty text does not
establish field availability; malformed escaped bytes raise `ArgumentError`.
The original `update.bytes` remain unchanged.
"""
function format_value(update::FormatUpdate)
    only(only(_decode_format_rows([update.bytes; UInt8('\n')], 1)))
end

"""
A single-consumer, bounded event iterator. Use `take!(stream; timeout, cancel)`
for an explicit deadline or `for event in stream` for connection-lifetime
iteration. Close explicitly or use the producer's do-block form. Each fan-out
subscriber owns its byte copies; overflow ends only that subscription.
"""
mutable struct ObservationStream
    connection::ControlConnection
    kind::Symbol
    pane::Union{Nothing,PaneRef}
    names::Tuple
    subscription::Union{Nothing,String}
    field::Union{Nothing,String}
    queue::Vector{ObservationEvent}
    bytes::Int
    capacity::Int
    max_bytes::Int
    cursor::ObservationCursor
    consumer::Union{Nothing,Task}
    open::Bool
    error::Union{Nothing,Exception}
    cleanup_done::Bool
end

mutable struct _ObservationHub <: _ControlObservationState
    epoch::String
    sequence::UInt64
    history::Vector{Tuple{UInt64,_ControlEvent,Int}}
    bytes::Int
    oldest::UInt64
    streams::Vector{ObservationStream}
    cleanup::Vector{ObservationStream}
    worker::Union{Nothing,Task}
    output_lock::ReentrantLock
    output_enabled::Bool
    terminal::Bool
    cleaning::Bool
end

const _OBSERVATION_HISTORY_ITEMS = 256
const _OBSERVATION_HISTORY_BYTES = 4 * 1024 * 1024
const _OBSERVATION_SUBSCRIBERS = 64

function _observation_hub(connection)
    connection.state === :open && !connection.closing_requested ||
        throw(ControlConnectionError(connection.reason, false))
    if connection.observation === nothing
        hub = _ObservationHub(
            string(uuid4()),
            0,
            Tuple{UInt64,_ControlEvent,Int}[],
            0,
            1,
            ObservationStream[],
            ObservationStream[],
            nothing,
            ReentrantLock(),
            false,
            false,
            false,
        )
        connection.observation = hub
        empty!(connection.events)
        hub.worker = Threads.@spawn _observation_cleanup(connection, hub)
    end
    connection.observation::_ObservationHub
end

_observation_cursor(connection, hub, pane, sequence, kind) = ObservationCursor(
    connection.identity,
    pane === nothing ? nothing : pane.id,
    hub.epoch,
    kind,
    sequence,
)

"Return the last delivered position; this accessor performs no I/O."
observation_cursor(stream::ObservationStream) =
    lock(() -> stream.cursor, stream.connection.lock)

"Private capture boundary: it is a reset position, not proof of atomic screen/output ordering."
function _observation_boundary(connection::ControlConnection, pane::PaneRef)
    pane.server == connection.identity || throw(StaleReference(string(pane.id)))
    lock(connection.lock) do
        hub = _observation_hub(connection)
        _observation_cursor(connection, hub, pane, hub.sequence, :output)
    end
end

function _observation_end!(hub, stream; error=nothing)
    stream.open || return
    stream.open = false
    stream.error = error
    empty!(stream.queue)
    stream.bytes = 0
    filter!(candidate -> candidate !== stream, hub.streams)
    if stream.subscription !== nothing && !hub.terminal
        push!(hub.cleanup, stream)
    else
        stream.cleanup_done = true
    end
    notify(stream.connection.changed; all=true)
end

function _observation_match(stream, event)
    if stream.kind === :output
        event isa _ControlOutput && string(stream.pane.id) == "%" * string(event.pane)
    elseif stream.kind === :notification
        event isa _ControlNotification &&
            (isempty(stream.names) || event.name in stream.names)
    else
        event isa _ControlNotification && event.name === Symbol("subscription-changed") ||
            return false
        prefix = codeunits("%subscription-changed " * stream.subscription * " ")
        length(event.bytes) >= length(prefix) &&
            @view(event.bytes[1:length(prefix)]) == prefix
    end
end

function _observation_event(stream, event, sequence)
    hub = stream.connection.observation::_ObservationHub
    cursor = _observation_cursor(stream.connection, hub, stream.pane, sequence, stream.kind)
    if event isa _ControlOutput
        PaneOutput(something(stream.pane), copy(event.bytes), event.age_ms, cursor)
    elseif stream.kind === :format
        fields = split(String(copy(event.bytes)), ' '; limit=8)
        length(fields) == 8 && fields[7] == ":" ||
            throw(_ControlProtocolError(:observation, :subscription_shape))
        identity = stream.connection.identity
        session = SessionRef(identity, fields[3])
        window = fields[4] == "-" ? nothing : WindowRef(identity, fields[4])
        index = fields[5] == "-" ? nothing : parse(Int, fields[5])
        pane = fields[6] == "-" ? stream.pane : PaneRef(identity, fields[6])
        value = fields[8]
        if stream.pane !== nothing
            prefix = string(stream.pane.id) * "|"
            startswith(value, prefix) ||
                throw(ObservationLost(:target_changed, stream.cursor))
            value = SubString(value, ncodeunits(prefix) + 1)
        end
        FormatUpdate(
            something(stream.field),
            collect(codeunits(value)),
            session,
            window,
            index,
            pane,
            cursor,
        )
    else
        NotificationEvent(event.name, copy(event.bytes), cursor)
    end
end

function _observation_enqueue!(hub, stream, event, sequence, size)
    if event isa _ControlNotification && (
        (
            stream.kind === :output &&
            (event.name in _OBSERVATION_TOPOLOGY_RESET || event.name === :pause)
        ) || (stream.kind === :format && event.name in _OBSERVATION_FORMAT_RESET)
    )
        _observation_end!(
            hub,
            stream;
            error=ObservationLost(:topology_reset, stream.cursor),
        )
        return
    end
    _observation_match(stream, event) || return
    owned = try
        _observation_event(stream, event, sequence)
    catch error
        error isa ObservationLost || rethrow()
        _observation_end!(hub, stream; error)
        return
    end
    if length(stream.queue) >= stream.capacity ||
       length(owned.bytes) > stream.max_bytes - stream.bytes
        _observation_end!(hub, stream; error=ObservationLost(:overflow, stream.cursor))
        return
    end
    push!(stream.queue, owned)
    stream.bytes += length(owned.bytes)
end

const _OBSERVATION_TOPOLOGY_RESET = (
    Symbol("layout-change"),
    Symbol("window-close"),
    Symbol("unlinked-window-close"),
    Symbol("session-changed"),
    Symbol("client-session-changed"),
)
const _OBSERVATION_FORMAT_RESET = (
    Symbol("window-close"),
    Symbol("unlinked-window-close"),
    Symbol("session-changed"),
    Symbol("client-session-changed"),
)

function _control_publish!(hub::_ObservationHub, connection, event)
    hub.terminal && return true
    event isa _ControlFrame && return true
    hub.sequence == typemax(UInt64) &&
        throw(_ControlProtocolError(:observation, :sequence_exhausted))
    hub.sequence += 1
    size = length(event.bytes)
    while !isempty(hub.history) && (
        length(hub.history) >= _OBSERVATION_HISTORY_ITEMS ||
        size > _OBSERVATION_HISTORY_BYTES - hub.bytes
    )
        old_sequence, _, old_size = popfirst!(hub.history)
        hub.bytes -= old_size
        hub.oldest = old_sequence + 1
    end
    if size <= _OBSERVATION_HISTORY_BYTES
        push!(hub.history, (hub.sequence, event, size))
        hub.bytes += size
    else
        hub.oldest = hub.sequence + 1
    end
    for stream in copy(hub.streams)
        _observation_enqueue!(hub, stream, event, hub.sequence, size)
    end
    notify(connection.changed; all=true)
    true
end

function _control_end_observation!(hub::_ObservationHub, connection, reason)
    hub.terminal = true
    for stream in copy(hub.streams)
        error =
            reason === :closed_by_caller ? nothing :
            ObservationLost(:connection_lost, stream.cursor)
        _observation_end!(hub, stream; error)
    end
    for stream in hub.cleanup
        stream.cleanup_done = true
    end
    empty!(hub.cleanup)
    notify(connection.changed; all=true)
end

_control_join_observation(hub::_ObservationHub) =
    hub.worker === nothing ? nothing : wait(hub.worker)

function _observation_cleanup(connection, hub)
    while true
        stream = lock(connection.lock) do
            while isempty(hub.cleanup)
                hub.terminal && return nothing
                wait(connection.changed)
            end
            hub.cleaning = true
            popfirst!(hub.cleanup)
        end
        stream === nothing && return
        failure = nothing
        try
            result = _control_request(
                connection,
                ["refresh-client", "-B", something(stream.subscription)],
                _ControlReplyPolicy(; diagnostics=true);
                timeout=0.9,
                cleanup=true,
            )
            result.failed && throw(ControlCommandError(result, "refresh-client"))
        catch error
            failure = error
        finally
            lock(connection.lock) do
                stream.cleanup_done = true
                hub.cleaning = false
                if failure !== nothing && !hub.terminal
                    stream.error = failure
                    connection.cleanup_error =
                        ControlCleanupError(:subscription_cleanup_failed)
                end
                notify(connection.changed; all=true)
            end
        end
    end
end

function _new_observation(
    connection,
    kind;
    pane=nothing,
    names=(),
    subscription=nothing,
    field=nothing,
    capacity::Integer=64,
    max_bytes::Integer=1024*1024,
    after=nothing,
)
    0 < capacity <= 65536 || throw(ArgumentError("observation capacity must be in 1:65536"))
    0 < max_bytes <= 64*1024*1024 ||
        throw(ArgumentError("observation byte limit must be in 1:67108864"))
    lock(connection.lock) do
        hub = _observation_hub(connection)
        length(hub.streams) + length(hub.cleanup) + hub.cleaning <
        _OBSERVATION_SUBSCRIBERS ||
            throw(ArgumentError("connection observation capacity is reserved"))
        cursor = _observation_cursor(connection, hub, pane, hub.sequence, kind)
        if after !== nothing
            after isa ObservationCursor ||
                throw(ArgumentError("after must be an ObservationCursor"))
            after.server == cursor.server &&
            after.pane == cursor.pane &&
            after.epoch == cursor.epoch &&
            after.kind == kind &&
            after.sequence <= hub.sequence || throw(ObservationLost(:invalid_cursor, after))
            after.sequence >= hub.oldest - 1 ||
                throw(ObservationLost(:cursor_expired, after))
            cursor = after
        end
        stream = ObservationStream(
            connection,
            kind,
            pane,
            names,
            subscription,
            field,
            ObservationEvent[],
            0,
            Int(capacity),
            Int(max_bytes),
            cursor,
            nothing,
            true,
            nothing,
            false,
        )
        push!(hub.streams, stream)
        if after !== nothing
            for (sequence, event, size) in hub.history
                sequence > after.sequence &&
                    _observation_enqueue!(hub, stream, event, sequence, size)
                stream.open || throw(stream.error)
            end
        end
        stream
    end
end

"""
    notifications(connection; kinds=(), capacity=64, max_bytes=1048576, after=nothing)

Observe known tmux notifications from registration onward. `kinds` is an
optional tuple of notification-name symbols. A cursor may replay this
connection's retained events: at most 256 records and 4 MiB, shared with pane
output. Missing, expired or foreign history raises `ObservationLost`.
"""
function notifications(connection::ControlConnection; kinds=(), kwargs...)
    names = Tuple(Symbol.(kinds))
    all(name -> String(name) in _CONTROL_NOTIFICATION_NAMES, names) ||
        throw(ArgumentError("unknown tmux notification kind"))
    _new_observation(connection, :notification; names, kwargs...)
end

function _observation_target(connection, target, started, timeout, cancel)
    window = only(
        only(
            _control_rows(
                connection,
                "display-message",
                ["window_id"];
                target,
                timeout=_snapshot_remaining(started, Float64(timeout)),
                cancel,
            ),
        ),
    )
    if target isa SessionRef
        target.id == connection.session.id ||
            throw(ArgumentError("session subscription must target the attached session"))
    else
        links = _control_rows(
            connection,
            "list-windows",
            ["window_id"];
            target=connection.session,
            timeout=_snapshot_remaining(started, Float64(timeout)),
            cancel,
        )
        any(link -> only(link) == window, links) ||
            throw(ControlTargetError(string(target.id)))
    end
    window
end

"""
    observe_output(connection, pane; capacity=64, max_bytes=1048576, after=nothing,
                   timeout=5.0, cancel=nothing)

Observe raw future pane bytes, not screen images or command completion. The
pane must belong to the attached session. Registration precedes enabling
output on the request lane; its readiness fence does not reconstruct earlier
bytes. Output stays enabled until connection close. Topology changes and
tmux pauses require a new baseline; no contiguous-history claim survives them.
"""
function observe_output(
    connection::ControlConnection,
    pane::PaneRef;
    timeout::Real=5.0,
    cancel=nothing,
    kwargs...,
)
    started = time_ns()
    window = _observation_target(connection, pane, started, timeout, cancel)
    stream = _new_observation(connection, :output; pane, kwargs...)
    hub = connection.observation::_ObservationHub
    try
        lock(hub.output_lock) do
            if !hub.output_enabled
                result = _control_request(
                    connection,
                    ["refresh-client", "-f", "!no-output"],
                    _ControlReplyPolicy(; diagnostics=true);
                    timeout=_snapshot_remaining(started, Float64(timeout)),
                    cancel,
                )
                result.failed && throw(ControlCommandError(result, "refresh-client"))
                hub.output_enabled = true
            end
        end
        _observation_target(connection, pane, started, timeout, cancel) == window ||
            throw(ObservationLost(:target_changed, stream.cursor))
        isopen(stream) || throw(
            something(stream.error, ObservationLost(:registration_lost, stream.cursor)),
        )
        stream
    catch
        close(stream)
        rethrow()
    end
end

"""
    subscribe_format(connection, target, field; timeout=5.0, cancel=nothing, kwargs...)

Subscribe to one admitted format field for the attached session, a window,
or a pane. Updates retain escaped bytes from the field codec. tmux checks
subscriptions at most once per second; these updates cannot establish prompt
readiness or output quiescence. Closing removes only this generated name.
Pane subscriptions use a window pane-loop with an exact pane ID so retained
dead panes still update on tmux versions that skip direct dead-pane watches.
Updates retain their session/window-link context. Removal or movement requires
a new baseline; subscriptions do not silently follow another window.
"""
function subscribe_format(
    connection::ControlConnection,
    target::Union{SessionRef,WindowRef,PaneRef},
    field::AbstractString;
    timeout::Real=5.0,
    cancel=nothing,
    after=nothing,
    kwargs...,
)
    after === nothing ||
        throw(ArgumentError("format subscriptions start a new sampled-value baseline"))
    field in _CONTROL_FIELDS ||
        throw(ArgumentError("format field must come from the admitted catalog"))
    started = time_ns()
    window = _observation_target(connection, target, started, timeout, cancel)
    name = "libtmux_sub_" * replace(string(uuid4()), "-" => "")
    selector =
        target isa SessionRef ? "session" : target isa PaneRef ? window : string(target.id)
    template = _format_template([String(field)])
    if target isa PaneRef
        id = string(target.id)
        template = "#{P:#{?#{==:#{pane_id}," * id * "}," * id * "|" * template * ",}}"
    end
    stream = _new_observation(
        connection,
        :format;
        pane=target isa PaneRef ? target : nothing,
        subscription=name,
        field=String(field),
        kwargs...,
    )
    try
        result = _control_request(
            connection,
            ["refresh-client", "-B", name * ":" * selector * ":" * template],
            _ControlReplyPolicy(; diagnostics=true);
            timeout=_snapshot_remaining(started, Float64(timeout)),
            cancel,
        )
        result.failed && throw(ControlCommandError(result, "refresh-client"))
        _observation_target(connection, target, started, timeout, cancel) == window ||
            throw(ObservationLost(:target_changed, stream.cursor))
        isopen(stream) || throw(
            something(stream.error, ObservationLost(:registration_lost, stream.cursor)),
        )
        stream
    catch
        close(stream)
        rethrow()
    end
end

Base.isopen(stream::ObservationStream) = lock(() -> stream.open, stream.connection.lock)
Base.show(io::IO, stream::ObservationStream) = lock(stream.connection.lock) do
    print(
        io,
        "ObservationStream(kind=",
        stream.kind,
        ", open=",
        stream.open,
        ", queued=",
        length(stream.queue),
        ")",
    )
end

function Base.close(stream::ObservationStream)
    connection = stream.connection
    lock(connection.lock) do
        hub = connection.observation::_ObservationHub
        _observation_end!(hub, stream)
        while !stream.cleanup_done
            wait(connection.changed)
        end
        stream.error === nothing || stream.error isa ObservationLost || throw(stream.error)
    end
    nothing
end

function _take_observation(stream; timeout=nothing, cancel=nothing)
    connection = stream.connection
    timeout === nothing ||
        (isfinite(timeout) && timeout > 0) ||
        throw(ArgumentError("observation timeout must be positive and finite"))
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    interruption = Ref{Union{Nothing,Exception}}(nothing)
    interrupt(error) = lock(connection.lock) do
        interruption[] = error
        notify(connection.changed; all=true)
    end
    timer, timer_task =
        timeout === nothing ? (nothing, nothing) :
        _owned_timer(
            () -> interrupt(DeadlineExceeded(Float64(timeout), false, nothing)),
            Float64(timeout),
        )
    registration =
        cancel === nothing ? nothing :
        on_cancel(() -> interrupt(RequestCancelled(false)), cancel)
    try
        lock(connection.lock) do
            if stream.consumer === nothing
                stream.consumer = current_task()
                notify(connection.changed; all=true)
            end
            stream.consumer === current_task() ||
                throw(ArgumentError("observation has a different consumer task"))
            while isempty(stream.queue) && stream.open && interruption[] === nothing
                wait(connection.changed)
            end
            interruption[] === nothing || throw(interruption[])
            stream.error === nothing || throw(stream.error)
            isempty(stream.queue) && return nothing
            event = popfirst!(stream.queue)
            stream.bytes -= length(event.bytes)
            stream.cursor = event.cursor
            event
        end
    finally
        timer === nothing || close(timer)
        timer_task === nothing || wait(timer_task)
        registration === nothing || close(registration)
    end
end

"Take one event with an optional deadline/cancellation; EOF throws `EOFError`."
function Base.take!(stream::ObservationStream; timeout=nothing, cancel=nothing)
    event = _take_observation(stream; timeout, cancel)
    event === nothing && throw(EOFError())
    event
end
Base.IteratorSize(::Type{ObservationStream}) = Base.SizeUnknown()
Base.eltype(::Type{ObservationStream}) = ObservationEvent
function Base.iterate(stream::ObservationStream, state=nothing)
    event = _take_observation(stream)
    event === nothing ? nothing : (event, nothing)
end

for producer in (:notifications, :observe_output, :subscribe_format)
    @eval function $producer(f, connection::ControlConnection, args...; kwargs...)
        stream = $producer(connection, args...; kwargs...)
        primary = nothing
        try
            f(stream)
        catch error
            primary = error
            rethrow()
        finally
            try
                close(stream)
            catch cleanup
                primary === nothing ? throw(cleanup) :
                throw(CompositeException([primary, cleanup]))
            end
        end
    end
end

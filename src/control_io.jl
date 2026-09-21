"An owned control buffer could not be retired; `buffer` identifies the possible remote resource."
struct ControlBufferCleanupError <: LibTmuxError
    buffer::BufferRef
    cause::Exception
end
Base.showerror(io::IO, error::ControlBufferCleanupError) = print(
    io,
    "could not retire owned control buffer ",
    repr(string(error.buffer.id)),
    ": ",
    sprint(showerror, error.cause),
)

function _control_exact_target(connection, target::EntityRef)
    target.server.socket_path == connection.identity.socket_path ||
        throw(CrossServerReference(string(target.id)))
    target.server == connection.identity || throw(StaleReference(string(target.id)))
    isopen(connection) || throw(ControlConnectionError(connection.reason, false))
    nothing
end

function _control_effect(connection, argv; kwargs...)
    result = _control_request(
        connection,
        argv,
        _ControlReplyPolicy(; diagnostics=true);
        kwargs...,
    )
    result.failed && throw(ControlCommandError(result, first(argv)))
    result
end

function _control_buffer_size(connection, name; kwargs...)
    prefix = "LIBTMUX\t"
    argv = ["list-buffers", "-F", prefix * _format_template(["buffer_name", "buffer_size"])]
    result = _control_request(
        connection,
        argv,
        _ControlReplyPolicy(; prefix, diagnostics=true);
        kwargs...,
    )
    result.failed && throw(ControlCommandError(result, "list-buffers"))
    rows = _decode_format_rows(result.stdout, 3)
    all(row -> row[1] == "LIBTMUX", rows) ||
        throw(_ControlProtocolError(:rows, :invalid_prefix))
    matches = filter(row -> row[2] == name, rows)
    isempty(matches) && return nothing
    row = only(matches)
    size = tryparse(Int, row[3])
    size !== nothing && size >= 0 || throw(_ControlProtocolError(:rows, :invalid_size))
    size
end

function _control_remove_buffer(connection, buffer)
    started = time_ns()
    remaining() = _snapshot_remaining(started, 0.9)
    name = string(buffer.id)
    try
        _control_buffer_size(connection, name; timeout=remaining()) === nothing && return
        _control_effect(connection, ["delete-buffer", "-b", name]; timeout=remaining())
    catch error
        throw(ControlBufferCleanupError(buffer, error))
    end
    nothing
end

"""
    capture_bytes(connection::ControlConnection, pane::PaneRef; kwargs...)

Capture through the existing control connection using a uniquely owned tmux
buffer and private local spool. Pane text never enters the control reply
parser. The buffer size is checked before disk output, and the same-queue
fence proves `save-buffer` completion before reading. This transport requires
the tmux daemon and Julia to share the local filesystem. tmux's file write may
block its event loop; yielding Julia I/O does not make that write asynchronous.

Screen options match `capture_bytes(server, pane)`. `timeout` is one operation
deadline. Cancellation is followed by a separate uncancelled 900 ms buffer
cleanup budget. If remote cleanup cannot be proved, `ControlBufferCleanupError`
retains its buffer reference; a primary failure is preserved in a
`CompositeException`. The owned local spool is always removed. There is no
subprocess fallback or retry.
"""
function capture_bytes(
    connection::ControlConnection,
    pane::PaneRef;
    start_line=nothing,
    end_line=nothing,
    join_wrapped::Bool=false,
    preserve_trailing::Bool=false,
    escapes::Bool=false,
    alternate::Bool=false,
    max_bytes::Int=8 * 1024^2,
    timeout::Real=5.0,
    cancel::Union{Nothing,CancellationToken}=nothing,
)
    started = time_ns()
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 || throw(ArgumentError("invalid capture timeout"))
    0 <= max_bytes < typemax(Int) || throw(ArgumentError("invalid capture byte bound"))
    args = ["capture-pane", "-t", string(pane.id)]
    start_line === nothing || append!(args, ["-S", _capture_line(start_line, :history)])
    end_line === nothing || append!(args, ["-E", _capture_line(end_line, :bottom)])
    join_wrapped && push!(args, "-J")
    preserve_trailing && push!(args, "-N")
    escapes && push!(args, "-e")
    alternate && push!(args, "-a")
    cancel === nothing || !iscancelled(cancel) || throw(RequestCancelled(false))
    _control_exact_target(connection, pane)
    remaining() = _snapshot_remaining(started, budget)
    name = "libtmux_capture_" * replace(string(uuid4()), "-" => "")
    _control_buffer_size(connection, name; timeout=remaining(), cancel) === nothing ||
        throw(ArgumentError("generated capture buffer name already exists"))
    buffer = BufferRef(connection.identity, name)
    directory = mktempdir(; prefix="libtmux-julia-capture-", cleanup=false)
    path = joinpath(directory, "capture")
    primary = nothing
    submitted = false
    try
        all(byte -> byte >= 0x20 && byte != 0x7f, codeunits(path)) ||
            throw(ArgumentError("capture temporary path contains control bytes"))
        append!(args, ["-b", name])
        submitted = true
        _control_effect(connection, args; timeout=remaining(), cancel)
        size = _control_buffer_size(connection, name; timeout=remaining(), cancel)
        # tmux may discard an empty capture instead of creating a buffer.
        size === nothing && return UInt8[]
        size <= max_bytes || throw(OutputLimitExceeded(:stdout, max_bytes))
        _control_effect(
            connection,
            ["save-buffer", "-b", name, replace(path, "#"=>"##")];
            timeout=remaining(),
            cancel,
        )
        isfile(path) && !islink(path) && filesize(path) == size || throw(
            ArgumentError("control capture spool did not match its observed buffer size"),
        )
        bytes = open(io -> read(io, size + 1), path)
        length(bytes) == size ||
            throw(ArgumentError("control capture spool changed during read"))
        remaining()
        cancel === nothing || !iscancelled(cancel) || throw(RequestCancelled(true))
        bytes
    catch error
        primary = error
        rethrow()
    finally
        cleanup = Exception[]
        try
            submitted && _control_remove_buffer(connection, buffer)
        catch error
            push!(cleanup, error)
        end
        try
            rm(directory; recursive=true, force=true)
        catch error
            push!(cleanup, error)
        end
        if !isempty(cleanup)
            primary === nothing || pushfirst!(cleanup, primary)
            throw(length(cleanup) == 1 ? only(cleanup) : CompositeException(cleanup))
        end
    end
end

function capture_pane(
    connection::ControlConnection,
    pane::PaneRef;
    invalid=:error,
    kwargs...,
)
    TextDecoder(; invalid)
    _decode_capture(capture_bytes(connection, pane; kwargs...); invalid)
end

"""
A screen capture bracketed by reader cursors, with `continuity == :reset`.
`bytes` owns the capture. `before` and `after` bracket acquisition; neither
cursor proves an atomic boundary between this screen and raw pane output.
Replaying from either cursor must not be used to reconstruct an exact screen.
"""
struct ObservationBaseline
    bytes::Vector{UInt8}
    before::ObservationCursor
    after::ObservationCursor
    continuity::Symbol
end

"""
    capture_baseline(stream::ObservationStream; kwargs...)

Capture the output stream's pane through its existing control connection.
Returns an `ObservationBaseline` with an explicit reset boundary. Buffered
events remain untouched, and `observation_cursor(stream)` still denotes the
last consumed event. Capture options and cancellation match `capture_bytes`.
A closed, overflowed or topology-invalidated stream requires a new stream.
"""
function capture_baseline(stream::ObservationStream; kwargs...)
    function boundary()
        lock(stream.connection.lock) do
            stream.kind === :output ||
                throw(ArgumentError("a baseline requires a pane output stream"))
            stream.error === nothing || throw(stream.error)
            stream.open || throw(EOFError())
            _observation_boundary(stream.connection, something(stream.pane))
        end
    end
    before = boundary()
    bytes = capture_bytes(stream.connection, something(stream.pane); kwargs...)
    after = boundary()
    ObservationBaseline(bytes, before, after, :reset)
end

function _capture_graph_rows(connection::ControlConnection, started, timeout, cancel)
    rows(command, fields) = _control_rows(
        connection,
        command,
        fields;
        timeout=_snapshot_remaining(started, timeout),
        cancel,
    )
    ss = rows("list-sessions", _SESSION_FIELDS)
    ws = isempty(ss) ? Vector{String}[] : rows("list-windows", _WINDOW_FIELDS)
    ps = isempty(ss) ? Vector{String}[] : rows("list-panes", _PANE_FIELDS)
    cs = isempty(ss) ? Vector{String}[] : rows("list-clients", _CLIENT_FIELDS)
    (; ss, ws, ps, cs)
end

"""
    snapshot(connection::ControlConnection; timeout=5.0, cancel=nothing)

Acquire the captured graph over the existing terminal control connection.
Two observations must agree on topology, with at most one retry within the
deadline. Field values are captured observations, not an atomic transaction.
The connection's two attached clients are included in client/attachment counts.
Local collection and coverage semantics match `snapshot(server)`.
"""
function snapshot(
    connection::ControlConnection;
    timeout::Real=5.0,
    cancel::Union{Nothing,CancellationToken}=nothing,
)
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("invalid snapshot timeout"))
    started = time_ns()
    for attempt = 1:2
        try
            captured = _capture_graph_rows(connection, started, budget, cancel)
            confirmed = _capture_graph_rows(connection, started, budget, cancel)
            _graph_signature(captured) == _graph_signature(confirmed) ||
                throw(InconsistentSnapshot("topology changed during control acquisition"))
            result = _snapshot_from_rows(
                connection.identity,
                captured,
                (started / 1e9, time_ns() / 1e9),
            )
            _snapshot_remaining(started, budget)
            return result
        catch error
            error isa InconsistentSnapshot && attempt == 1 && continue
            rethrow()
        end
    end
    error("unreachable snapshot retry state")
end

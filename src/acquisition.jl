const _SESSION_FIELDS = ["session_id", "session_name", "session_attached"]
const _WINDOW_FIELDS = [
    "window_id",
    "window_name",
    "window_width",
    "window_height",
    "session_id",
    "window_index",
    "window_active",
]
const _PANE_FIELDS = [
    "pane_id",
    "window_id",
    "pane_index",
    "pane_active",
    "pane_dead",
    "pane_width",
    "pane_height",
    "pane_current_command",
    "pane_current_path",
    "pane_title",
]
const _CLIENT_FIELDS = ["client_name", "client_pid", "client_created", "session_id"]
const _SERVER_FIELDS = ["pid", "start_time", "version", "socket_path"]

struct UnsupportedCapability <: LibTmuxError
    operation::Symbol
    detail::String
end
Base.showerror(io::IO, e::UnsupportedCapability) =
    print(io, e.operation, " is unsupported: ", e.detail)

function _observed_int(value, field)
    isempty(value) && throw(SnapshotCoverageError(:format, nothing, Symbol(field)))
    parsed = tryparse(Int, value)
    parsed !== nothing && parsed >= 0 ||
        throw(ArgumentError("invalid integer format field $field"))
    parsed
end

function _observed_bool(value, field)
    value == "1" && return true
    value == "0" && return false
    isempty(value) && throw(SnapshotCoverageError(:format, nothing, Symbol(field)))
    throw(ArgumentError("invalid Boolean format field $field"))
end

function _verify_row_codec(server, started, timeout, cancel)
    probe = raw"#{s|^.*$|A\\B" * "\tC\nD|;" * _format_template(["version"])[3:end]
    result = run_command(
        server,
        "display-message",
        "-p",
        probe;
        timeout=_snapshot_remaining(started, timeout),
        cancel,
    )
    result.stdout == codeunits("A\\\\B\\tC\\nD\n") || throw(
        UnsupportedCapability(
            :snapshot,
            "tmux cannot encode format row separators losslessly",
        ),
    )
    nothing
end

function _snapshot_remaining(started, timeout)
    remaining = timeout - (time_ns() - started) / 1e9
    remaining > 0 || throw(DeadlineExceeded(timeout, false, nothing))
    remaining
end

function _snapshot_rows(server, command, fields, started, timeout, cancel; args=())
    result = run_command(
        server,
        command,
        args...,
        "-F",
        _format_template(fields);
        timeout=_snapshot_remaining(started, timeout),
        cancel,
    )
    _decode_format_rows(result.stdout, length(fields))
end

function _snapshot_metadata(server, started, timeout, cancel)
    rows = _snapshot_rows(
        server,
        "display-message",
        _SERVER_FIELDS,
        started,
        timeout,
        cancel;
        args=("-p",),
    )
    length(rows) == 1 || throw(InconsistentSnapshot("expected one server observation"))
    row = only(rows)
    _observed_int(row[1], "pid")
    _observed_int(row[2], "start_time")
    ServerIdentity(socket_path=row[4], generation=row[1] * ":" * row[2])
end

function _capture_graph_rows(server, started, timeout, cancel)
    ss = _snapshot_rows(server, "list-sessions", _SESSION_FIELDS, started, timeout, cancel)
    ws =
        isempty(ss) ? Vector{String}[] :
        _snapshot_rows(
            server,
            "list-windows",
            _WINDOW_FIELDS,
            started,
            timeout,
            cancel;
            args=("-a",),
        )
    ps =
        isempty(ss) ? Vector{String}[] :
        _snapshot_rows(
            server,
            "list-panes",
            _PANE_FIELDS,
            started,
            timeout,
            cancel;
            args=("-a",),
        )
    cs =
        isempty(ss) ? Vector{String}[] :
        _snapshot_rows(server, "list-clients", _CLIENT_FIELDS, started, timeout, cancel)
    (; ss, ws, ps, cs)
end

function _graph_signature(rows)
    # Contextual links, rather than window IDs alone, determine membership.
    (
        sessions=Set(row[1] for row in rows.ss),
        links=Set((row[5], row[6], row[1]) for row in rows.ws),
        panes=Set((row[1], row[2], row[3]) for row in rows.ps),
        clients=Set(Tuple(row) for row in rows.cs),
    )
end

function _snapshot_from_rows(identity, rows, acquired)
    ss = [
        (id=r[1], name=r[2], attached_clients=_observed_int(r[3], "session_attached"))
        for r in rows.ss
    ]
    ws = [
        (
            id=r[1],
            name=r[2],
            width=_observed_int(r[3], "window_width"),
            height=_observed_int(r[4], "window_height"),
        ) for r in rows.ws
    ]
    ls = [
        (
            session_id=r[5],
            window_id=r[1],
            index=_observed_int(r[6], "window_index"),
            active=_observed_bool(r[7], "window_active"),
        ) for r in rows.ws
    ]
    ps = [
        merge(
            (
                id=r[1],
                window_id=r[2],
                index=_observed_int(r[3], "pane_index"),
                active=_observed_bool(r[4], "pane_active"),
                dead=_observed_bool(r[5], "pane_dead"),
                width=_observed_int(r[6], "pane_width"),
                height=_observed_int(r[7], "pane_height"),
                title=r[10],
            ),
            isempty(r[8]) ? (;) : (current_command=r[8],),
            isempty(r[9]) ? (;) : (current_path=r[9],),
        ) for r in rows.ps
    ]
    cs = [
        (
            id=ClientID(r[1], r[2] * ":" * r[3]),
            name=r[1],
            pid=_observed_int(r[2], "client_pid"),
            created=_observed_int(r[3], "client_created"),
            session_id=isempty(r[4]) ? nothing : r[4],
        ) for r in rows.cs
    ]
    _build_snapshot(
        identity;
        sessions=ss,
        windows=ws,
        panes=ps,
        clients=cs,
        windowlinks=ls,
        acquired,
        complete=true,
    )
end

"""
    snapshot(server; timeout=5.0, cancel=nothing)

Capture sessions, physical windows/panes, contextual links and attached clients.
Transient unattached command clients are outside tmux's `list-clients` source.
Accessors and filtering use only this captured graph. New acquisitions never
refresh earlier values. Retaining a selection may retain its whole snapshot.

Two observations must agree on topology and observed daemon identity. A
topology race retries once within one monotonic deadline. This is a stable
local observation after acquisition, not a transaction or reservation.
The `acquired` interval contains process-relative monotonic seconds.

Subprocess generation (PID and start time) and client incarnation (PID and
creation time) are best-effort observations. They do not provide strict
protection against identity reuse or the check/use race during later actions.
"""
function snapshot(
    server::Server;
    timeout::Real=5.0,
    cancel::Union{Nothing,CancellationToken}=nothing,
)
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("snapshot timeout must be positive and finite"))
    started = time_ns()
    _verify_row_codec(server, started, budget, cancel)
    for attempt = 1:2
        try
            before = _snapshot_metadata(server, started, budget, cancel)
            captured = _capture_graph_rows(server, started, budget, cancel)
            confirmed = _capture_graph_rows(server, started, budget, cancel)
            after = _snapshot_metadata(server, started, budget, cancel)
            before == after ||
                throw(InconsistentSnapshot("daemon identity changed during acquisition"))
            _graph_signature(captured) == _graph_signature(confirmed) ||
                throw(InconsistentSnapshot("topology changed during acquisition"))
            result = _snapshot_from_rows(before, captured, (started / 1e9, time_ns() / 1e9))
            _snapshot_remaining(started, budget)
            return result
        catch error
            error isa InconsistentSnapshot && attempt == 1 && continue
            rethrow()
        end
    end
    error("unreachable snapshot retry state")
end

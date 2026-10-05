const _SESSION_FIELDS = [
    "session_id",
    "session_name",
    "session_attached",
    "session_created",
    "session_activity",
    "session_last_attached",
]
const _WINDOW_FIELDS = [
    "window_id",
    "window_name",
    "window_width",
    "window_height",
    "session_id",
    "window_index",
    "window_active",
    "window_layout",
    "window_visible_layout",
    "window_zoomed_flag",
    "window_activity",
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
    "pane_pid",
    "pane_tty",
    "pane_dead_status",
    "history_size",
    "history_limit",
    "cursor_x",
    "cursor_y",
]
const _CLIENT_FIELDS =
    ["client_name", "client_pid", "client_created", "session_id", "client_activity"]
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

_observed_optional_int(value, field) =
    isempty(value) ? nothing : _observed_int(value, field)

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
        clients=Set((row[1], row[2], row[3], row[4]) for row in rows.cs),
    )
end

function _snapshot_from_rows(identity, rows, acquired; complete=true)
    ss = [
        (
            id=r[1],
            name=r[2],
            attached_clients=_observed_int(r[3], "session_attached"),
            created=_observed_int(r[4], "session_created"),
            activity=_observed_int(r[5], "session_activity"),
            last_attached=_observed_optional_int(r[6], "session_last_attached"),
        ) for r in rows.ss
    ]
    ws = [
        (
            id=r[1],
            name=r[2],
            width=_observed_int(r[3], "window_width"),
            height=_observed_int(r[4], "window_height"),
            layout=r[8],
            visible_layout=r[9],
            zoomed=_observed_bool(r[10], "window_zoomed_flag"),
            activity=_observed_int(r[11], "window_activity"),
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
                pid=_observed_int(r[11], "pane_pid"),
                tty=isempty(r[12]) ? nothing : r[12],
                exit_status=_observed_optional_int(r[13], "pane_dead_status"),
                history_size=_observed_int(r[14], "history_size"),
                history_limit=_observed_int(r[15], "history_limit"),
                cursor_x=_observed_int(r[16], "cursor_x"),
                cursor_y=_observed_int(r[17], "cursor_y"),
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
            activity=_observed_int(r[5], "client_activity"),
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
        complete,
    )
end

function _snapshot_scope_rows(
    server::Server,
    command,
    fields,
    context;
    target=nothing,
    filter=nothing,
)
    args = String[]
    if target !== nothing
        command == "list-panes" && target isa SessionRef && push!(args, "-s")
        append!(args, ["-t", string(target.id)])
    elseif command in ("list-windows", "list-panes")
        push!(args, "-a")
    end
    filter === nothing || append!(args, ["-f", filter])
    _snapshot_rows(
        server,
        command,
        fields,
        context.started,
        context.budget,
        context.cancel;
        args,
    )
end

function _snapshot_scope_sessions(rows)
    ids = unique(SessionID(row[5]) for row in rows)
    numbers = join((string(id)[2:end] for id in ids), '|')
    raw"#{m/r:^[$](" * numbers * raw")$,#{session_id}}"
end

function _capture_scoped_rows(transport, scope, context)
    rows(command, fields; kwargs...) =
        _snapshot_scope_rows(transport, command, fields, context; kwargs...)
    if scope isa SessionRef
        # Filter before expanding time fields: tmux 3.2a cannot safely expand
        # them when display-message permits an unresolved target.
        ss = rows(
            "list-sessions",
            _SESSION_FIELDS;
            filter="#{==:#{session_id}," * string(scope.id) * "}",
        )
        length(ss) == 1 && ss[1][1] == string(scope.id) ||
            throw(InconsistentSnapshot("scoped session target changed"))
        ws = rows("list-windows", _WINDOW_FIELDS; target=scope)
        all(row -> row[5] == string(scope.id), ws) ||
            throw(InconsistentSnapshot("scoped session membership changed"))
        ps = rows("list-panes", _PANE_FIELDS; target=scope)
    else
        ws = rows(
            "list-windows",
            _WINDOW_FIELDS;
            filter="#{==:#{window_id}," * string(scope.id) * "}",
        )
        !isempty(ws) && all(row -> row[1] == string(scope.id), ws) ||
            throw(InconsistentSnapshot("scoped window membership changed"))
        ss = rows("list-sessions", _SESSION_FIELDS; filter=_snapshot_scope_sessions(ws))
        ps = rows("list-panes", _PANE_FIELDS; target=scope)
    end
    (; ss, ws, ps, cs=Vector{String}[])
end

function _snapshot_scope_coverage(scope, rows)
    if scope isa SessionRef
        coverage = Any[(:session, scope.id, :windowlinks)]
        for id in unique(WindowID(row[1]) for row in rows.ws)
            push!(coverage, (:window, id, :panes))
        end
        coverage
    else
        Any[(:window, scope.id, :panes), (:window, scope.id, :windowlinks)]
    end
end

function _snapshot_scope_identity(server::Server, scope, context)
    observed = _snapshot_metadata(server, context.started, context.budget, context.cancel)
    observed == scope.server || throw(StaleReference(string(scope.id)))
    nothing
end

function _scoped_snapshot(transport, scope, context)
    for attempt = 1:2
        try
            captured = _capture_scoped_rows(transport, scope, context)
            confirmed = _capture_scoped_rows(transport, scope, context)
            _snapshot_scope_identity(transport, scope, context)
            _graph_signature(captured) == _graph_signature(confirmed) ||
                throw(InconsistentSnapshot("topology changed during scoped acquisition"))
            result = _snapshot_from_rows(
                scope.server,
                captured,
                (context.started / 1e9, time_ns() / 1e9);
                complete=_snapshot_scope_coverage(scope, captured),
            )
            _snapshot_remaining(context.started, context.budget)
            return scope isa SessionRef ?
                   _lookup(result, :session, scope.id, SessionSnapshot) :
                   _lookup(result, :window, scope.id, WindowSnapshot)
        catch error
            error isa InconsistentSnapshot && attempt == 1 && continue
            rethrow()
        end
    end
end

"""
    snapshot(server, scope::Union{SessionRef,WindowRef}; timeout=5.0, cancel=nothing)

Capture one exact session or physical window and return its captured view.
A session includes all its window links and physical panes; each window's
links to other sessions remain uncaptured. A window includes all its panes,
all links to sessions and those sessions' scalar fields; those sessions' other
window memberships remain uncaptured. Attached client records are not acquired.

`snapshotof(view)` owns a partial graph. Its server-wide root collections raise
`SnapshotCoverageError`; navigate from the returned view instead. Two topology
observations and daemon identity checks share one deadline with at most one
topology retry. Exact references reject cross-server and stale generations;
subprocess generation checks remain best effort.
"""
function snapshot(server::Server, scope::Union{SessionRef,WindowRef}; kwargs...)
    context = _target_context(server, scope; kwargs...)
    _scoped_snapshot(server, scope, context)
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

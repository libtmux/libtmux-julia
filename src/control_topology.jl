function _control_topology_context(connection, targets::EntityRef...; kwargs...)
    context = _control_operation_context(connection; kwargs...)
    foreach(target -> _control_exact_target(connection, target), targets)
    context
end

function _control_topology_effect(context, args)
    _control_effect(
        context.connection,
        args;
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end

"""
    new_session(connection::ControlConnection; name, kwargs...)

Create a detached session on the connected daemon and return its `SessionRef`.
Command, directory and environment options follow the subprocess method. Names
must be valid UTF-8 without control bytes; tmux's name normalization still applies.
The connection pins daemon identity and the prefixed reply verifies that identity.
Cancellation after submission may leave a created session; no retry or automatic
destruction occurs. The returned session is caller-owned.
"""
function new_session(
    connection::ControlConnection;
    name::AbstractString,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    environment=(),
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    isempty(name) && throw(ArgumentError("session name cannot be empty"))
    args = [
        "new-session",
        "-d",
        "-P",
        "-F",
        "LIBTMUX\t"*_format_template(["pid", "start_time", "socket_path", "session_id"]),
        "-s",
        _control_creation_name(name, :new_session),
    ]
    append!(
        args,
        _creation_args(
            command,
            shell_command,
            start_directory,
            environment;
            encoder=_argument,
        ),
    )
    _control_create(context, SessionRef, args)
end

for (operation, command, Ref) in (
    (:kill_session, "kill-session", SessionRef),
    (:kill_window, "kill-window", WindowRef),
    (:kill_pane, "kill-pane", PaneRef),
)
    @eval function $operation(connection::ControlConnection, target::$Ref; kwargs...)
        context = _control_topology_context(connection, target; kwargs...)
        _control_topology_effect(context, [$command, "-t", string(target.id)])
    end
    @eval @doc $("""
        $operation(connection::ControlConnection, target; kwargs...)

    Execute `$command` against an exact ID on the pinned daemon. Return
    `ControlResult` after the completion fence. Removing the session carrying
    this connection, its last window, or its last pane may close the
    connection before the fence; that outcome raises an uncertain-effect error.
    No retry, reconnect or subprocess fallback occurs.
    """) $operation(::ControlConnection, ::$Ref)
end

"""
    select_pane(connection::ControlConnection, pane::PaneRef; kwargs...)

Focus the exact pane within its physical window on the pinned daemon. This
does not select that window in a session; use `select_window` with an explicit
link for that. Return `ControlResult` after the completion fence.
"""
function select_pane(connection::ControlConnection, target::PaneRef; kwargs...)
    context = _control_topology_context(connection, target; kwargs...)
    _control_topology_effect(context, ["select-pane", "-t", string(target.id)])
end

for (operation, command, Ref) in
    ((:resize_pane, "resize-pane", PaneRef), (:resize_window, "resize-window", WindowRef))
    @eval function $operation(
        connection::ControlConnection,
        target::$Ref;
        width=nothing,
        height=nothing,
        kwargs...,
    )
        args = _resize_args($command, target, width, height)
        context = _control_topology_context(connection, target; kwargs...)
        _control_topology_effect(context, args)
    end
    @eval @doc $(
        """
    $operation(connection::ControlConnection, target; width=nothing, height=nothing, kwargs...)

Request absolute cell dimensions over the pinned connection. Dimension
validation and tmux sizing constraints match the subprocess method. Return
`ControlResult` after the completion fence; no fallback or replay occurs.
"""
    ) $operation(::ControlConnection, ::$Ref)
end

"""
    select_layout(connection::ControlConnection, window::WindowRef, layout; kwargs...)

Apply a named layout symbol, unambiguous alias or serialized tmux layout.
Malformed headers are rejected before I/O; tmux validates checksums and layout
structure. Mirrored layouts require an observed tmux version of 3.5 or later.
Return `ControlResult` after the completion fence on the pinned daemon.
"""
function select_layout(
    connection::ControlConnection,
    target::WindowRef,
    layout::Union{Symbol,AbstractString};
    kwargs...,
)
    text = _layout_argument(layout)
    context = _control_topology_context(connection, target; kwargs...)
    if endswith(text, "-mirrored")
        rows = _control_rows(
            connection,
            "display-message",
            ["version"];
            timeout=_snapshot_remaining(context.started, context.budget),
            cancel=context.cancel,
        )
        _check_layout_version(text, only(only(rows)))
    end
    _control_topology_effect(
        context,
        ["select-layout", "-t", string(target.id), "--", text],
    )
end

for (operation, command, Ref) in (
    (:rename_session, "rename-session", SessionRef),
    (:rename_window, "rename-window", WindowRef),
)
    @eval function $operation(
        connection::ControlConnection,
        target::$Ref,
        name::AbstractString;
        kwargs...,
    )
        isempty(name) && throw(ArgumentError("name cannot be empty"))
        text = _control_creation_name(name, $(QuoteNode(operation)))
        context = _control_topology_context(connection, target; kwargs...)
        _control_topology_effect(context, [$command, "-t", string(target.id), "--", text])
    end
    @eval @doc $("""
        $operation(connection::ControlConnection, target, name; kwargs...)

    Rename an exact object without expanding format text. Names must be valid
    UTF-8 without control bytes; tmux's name normalization still applies.
    Return `ControlResult` after the pinned connection's completion fence.
    """) $operation(::ControlConnection, ::$Ref, ::AbstractString)
end

"""
    move_pane(connection::ControlConnection, source::PaneRef, destination::PaneRef; kwargs...)

Move a physical pane without restarting its process. Direction, cell size and
selection options match the subprocess method. Both references must belong to
the connection's daemon generation. Return the fenced `ControlResult`.
"""
function move_pane(
    connection::ControlConnection,
    source::PaneRef,
    destination::PaneRef;
    direction::Symbol=:below,
    size=nothing,
    select::Bool=false,
    kwargs...,
)
    direction in (:left, :right, :above, :below) ||
        throw(ArgumentError("invalid move direction"))
    args = ["move-pane", "-s", string(source.id), "-t", string(destination.id)]
    push!(args, direction in (:left, :right) ? "-h" : "-v")
    direction in (:left, :above) && push!(args, "-b")
    select || push!(args, "-d")
    if size !== nothing
        size isa Integer && !(size isa Bool) && 1 <= size <= typemax(Int32) ||
            throw(ArgumentError("pane size must be a positive tmux integer"))
        append!(args, ["-l", string(size)])
    end
    context = _control_topology_context(connection, source, destination; kwargs...)
    _control_topology_effect(context, args)
end

"""Swap exact panes over the pinned connection, preserving IDs and running processes."""
function swap_pane(
    connection::ControlConnection,
    first::PaneRef,
    second::PaneRef;
    select::Bool=false,
    kwargs...,
)
    context = _control_topology_context(connection, first, second; kwargs...)
    args = ["swap-pane", "-s", string(first.id), "-t", string(second.id)]
    select || push!(args, "-d")
    _control_topology_effect(context, args)
end

for (operation, command, Ref) in (
    (:respawn_pane, "respawn-pane", PaneRef),
    (:respawn_window, "respawn-window", WindowRef),
)
    @eval function $operation(
        connection::ControlConnection,
        target::$Ref;
        kill_running::Bool=false,
        command=nothing,
        shell_command=nothing,
        start_directory=nothing,
        kwargs...,
    )
        args = [$command, "-t", string(target.id)]
        kill_running && push!(args, "-k")
        append!(
            args,
            _creation_args(command, shell_command, start_directory; encoder=_argument),
        )
        context = _control_topology_context(connection, target; kwargs...)
        _control_topology_effect(context, args)
    end
    @eval @doc $("""
        $operation(connection::ControlConnection, target; kwargs...)

    Restart the original or supplied argv/shell command on the pinned daemon.
    Running processes require `kill_running=true`. Window respawn removes all
    but one pane. Options match the subprocess method; the fenced `ControlResult`
    proves tmux command completion, not completion of the new pane application.
    """) $operation(::ControlConnection, ::$Ref)
end

function _control_check_link(context, link::WindowLinkRef)
    rows = _control_rows(
        context.connection,
        "list-windows",
        ["window_index", "window_id"];
        target=link.session,
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    matches = filter(row -> _observed_int(row[1], "window_index") == link.index, rows)
    length(matches) == 1 && only(matches)[2] == string(link.window.id) ||
        throw(StaleReference(_window_slot(link)))
    nothing
end

for (operation, command) in ((:link_window, "link-window"), (:move_window, "move-window"))
    @eval function $operation(
        connection::ControlConnection,
        source::WindowLinkRef,
        destination::SessionRef;
        index::Integer,
        replace::Bool=false,
        select::Bool=false,
        kwargs...,
    )
        slot = _window_index(index)
        context = _control_topology_context(
            connection,
            source.session,
            source.window,
            destination;
            kwargs...,
        )
        _control_check_link(context, source)
        args = [$command, "-s", _window_slot(source), "-t", _window_slot(destination, slot)]
        replace && push!(args, "-k")
        select || push!(args, "-d")
        _control_topology_effect(context, args)
    end
    @eval @doc $(
        """
    $operation(connection::ControlConnection, source::WindowLinkRef, destination::SessionRef; index, kwargs...)

Execute `$command` with explicit source and destination session/index slots.
Replacement and selection follow the subprocess method. The daemon generation
is pinned, but a link's index/window membership is checked before submission
and can change concurrently. This does not reserve a topology transaction.
Repeated links to one physical window retain their separate slot semantics.
Return `ControlResult`; no fallback or replay occurs.
"""
    ) $operation(::ControlConnection, ::WindowLinkRef, ::SessionRef)
end

"""
    unlink_window(connection::ControlConnection, link::WindowLinkRef; allow_destroy=false, kwargs...)

Remove the checked session/index link. Its last physical-window link is protected
unless `allow_destroy=true`. Membership checks are observational and may race
other clients; the daemon generation remains pinned. Return `ControlResult`.
"""
function unlink_window(
    connection::ControlConnection,
    target::WindowLinkRef;
    allow_destroy::Bool=false,
    kwargs...,
)
    context =
        _control_topology_context(connection, target.session, target.window; kwargs...)
    _control_check_link(context, target)
    args = ["unlink-window", "-t", _window_slot(target)]
    allow_destroy && push!(args, "-k")
    _control_topology_effect(context, args)
end

"""
    swap_window(connection::ControlConnection, first::WindowLinkRef, second::WindowLinkRef; kwargs...)

Swap two checked session/index links on the pinned daemon. Other links remain.
Membership checks may race concurrent changes; they do not reserve either slot.
`select=false` preserves selection where tmux permits. Return `ControlResult`.
"""
function swap_window(
    connection::ControlConnection,
    first::WindowLinkRef,
    second::WindowLinkRef;
    select::Bool=false,
    kwargs...,
)
    context = _control_topology_context(
        connection,
        first.session,
        first.window,
        second.session,
        second.window;
        kwargs...,
    )
    _control_check_link(context, first)
    _control_check_link(context, second)
    args = ["swap-window", "-s", _window_slot(first), "-t", _window_slot(second)]
    select || push!(args, "-d")
    _control_topology_effect(context, args)
end

"""
    select_window(connection::ControlConnection, link::WindowLinkRef; kwargs...)

Focus a checked session/index link on the pinned daemon. This selects the
requested occurrence even when its physical window has multiple links in the
same session. Membership may race concurrent changes after the check.
"""
function select_window(connection::ControlConnection, target::WindowLinkRef; kwargs...)
    context =
        _control_topology_context(connection, target.session, target.window; kwargs...)
    _control_check_link(context, target)
    _control_topology_effect(context, ["select-window", "-t", _window_slot(target)])
end

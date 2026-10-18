function _same_observed_server(first::EntityRef, second::EntityRef)
    first.server.socket_path == second.server.socket_path ||
        throw(CrossServerReference(string(second.id)))
    first.server == second.server || throw(StaleReference(string(second.id)))
    nothing
end

function _window_index(index)
    index isa Integer && !(index isa Bool) && 0 <= index <= typemax(Int32) || throw(
        ArgumentError("window index must be an integer between 0 and $(typemax(Int32))"),
    )
    Int(index)
end

"""
    WindowLinkRef(session::SessionRef, window::WindowRef, index::Integer)
    WindowLinkRef(link::WindowLink)

Identify one session/index link and its expected physical window. Operations
verify that the slot still contains this window before acting. Generation and
link checks are best effort; subprocess commands cannot reserve the link.
"""
struct WindowLinkRef
    session::SessionRef
    window::WindowRef
    index::Int

    function WindowLinkRef(session::SessionRef, window::WindowRef, index::Integer)
        slot = _window_index(index)
        _same_observed_server(session, window)
        new(session, window, slot)
    end
end
WindowLinkRef(link::WindowLink) =
    WindowLinkRef(session(link).ref, window(link).ref, link.index)
Base.:(==)(a::WindowLinkRef, b::WindowLinkRef) =
    a.session == b.session && a.window == b.window && a.index == b.index
Base.isequal(a::WindowLinkRef, b::WindowLinkRef) = a == b
Base.hash(link::WindowLinkRef, h::UInt) = hash((link.session, link.window, link.index), h)

_window_slot(session::SessionRef, index) = string(session.id) * ":" * string(index)
_window_slot(link::WindowLinkRef) = _window_slot(link.session, link.index)

function _topology_context(server, first::EntityRef, rest::EntityRef...; kwargs...)
    foreach(ref -> _same_observed_server(first, ref), rest)
    _target_context(server, first; kwargs...)
end

function _check_window_link(context, link::WindowLinkRef)
    result = _operation_command(
        context,
        "list-windows",
        "-t",
        string(link.session.id),
        "-F",
        _format_template(["window_index", "window_id"]),
    )
    rows = _decode_format_rows(result.stdout, 2)
    matches = filter(row -> _observed_int(row[1], "window_index") == link.index, rows)
    length(matches) == 1 && only(matches)[2] == string(link.window.id) ||
        throw(StaleReference(_window_slot(link)))
    nothing
end

function _resize_args(command, target, width, height)
    width === nothing &&
        height === nothing &&
        throw(ArgumentError("supply width or height"))
    args = [command, "-t", string(target.id)]
    for (flag, value) in (("-x", width), ("-y", height))
        value === nothing && continue
        value isa Integer && !(value isa Bool) && 1 <= value <= 10000 ||
            throw(ArgumentError("dimensions must be integers between 1 and 10000"))
        append!(args, [flag, string(value)])
    end
    args
end

for (operation, command, Ref) in
    ((:resize_pane, "resize-pane", PaneRef), (:resize_window, "resize-window", WindowRef))
    @eval function $operation(
        server::Server,
        target::$Ref;
        width=nothing,
        height=nothing,
        kwargs...,
    )
        args = _resize_args($command, target, width, height)
        context = _target_context(server, target; kwargs...)
        _operation_command(context, args...)
    end
    @eval @doc $("""
        $operation(server, target; width=nothing, height=nothing, kwargs...)

    Request absolute dimensions in cells; supply at least one dimension.
    tmux may constrain pane dimensions to fit adjacent panes. Window resizing
    selects tmux's manual window-size policy. Return the command result.
    """) $operation
end

"""
    link_window(server, source::WindowLinkRef, destination::SessionRef;
                index, replace=false, select=false, kwargs...)

Link the source window at an explicit destination index. Existing links remain.
An occupied destination errors unless `replace=true`, which removes that link
and may destroy its window. `select=true` selects the new destination link.
Return the command result; generation and link checks are best effort.
"""
function link_window(
    server::Server,
    source::WindowLinkRef,
    destination::SessionRef;
    index::Integer,
    replace::Bool=false,
    select::Bool=false,
    kwargs...,
)
    slot = _window_index(index)
    context = _topology_context(server, source.session, destination; kwargs...)
    _check_window_link(context, source)
    args =
        ["link-window", "-s", _window_slot(source), "-t", _window_slot(destination, slot)]
    replace && push!(args, "-k")
    select || push!(args, "-d")
    _operation_command(context, args...)
end

"""
    unlink_window(server, target::WindowLinkRef; allow_destroy=false, kwargs...)

Remove exactly one captured session/index link. The last link is protected
unless `allow_destroy=true`; removing it destroys the physical window and
may end its session. Return the command result.
"""
function unlink_window(
    server::Server,
    target::WindowLinkRef;
    allow_destroy::Bool=false,
    kwargs...,
)
    context = _target_context(server, target.session; kwargs...)
    _check_window_link(context, target)
    args = ["unlink-window", "-t", _window_slot(target)]
    allow_destroy && push!(args, "-k")
    _operation_command(context, args...)
end

"""
    move_window(server, source::WindowLinkRef, destination::SessionRef;
                index, replace=false, select=false, kwargs...)

Move only the specified source link to an explicit destination index. Other
links to the physical window remain. Replacement and selection follow
`link_window`; moving a session's final link may end that session.
"""
function move_window(
    server::Server,
    source::WindowLinkRef,
    destination::SessionRef;
    index::Integer,
    replace::Bool=false,
    select::Bool=false,
    kwargs...,
)
    slot = _window_index(index)
    context = _topology_context(server, source.session, destination; kwargs...)
    _check_window_link(context, source)
    args =
        ["move-window", "-s", _window_slot(source), "-t", _window_slot(destination, slot)]
    replace && push!(args, "-k")
    select || push!(args, "-d")
    _operation_command(context, args...)
end

"""
    move_pane(server, source::PaneRef, destination::PaneRef;
              direction=:below, size=nothing, select=false, kwargs...)

Move a physical pane beside an exact destination pane, preserving its ID.
Direction is `:left`, `:right`, `:above` or `:below`; size is a cell count.
The old window can disappear when its final pane moves. No process is respawned.
"""
function move_pane(
    server::Server,
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
    context = _topology_context(server, source, destination; kwargs...)
    _operation_command(context, args...)
end

"""Swap two physical panes, preserving their IDs and running processes."""
function swap_pane(
    server::Server,
    first::PaneRef,
    second::PaneRef;
    select::Bool=false,
    kwargs...,
)
    context = _topology_context(server, first, second; kwargs...)
    args = ["swap-pane", "-s", string(first.id), "-t", string(second.id)]
    select || push!(args, "-d")
    _operation_command(context, args...)
end

"""Swap the windows at two explicit links; other links retain their windows."""
function swap_window(
    server::Server,
    first::WindowLinkRef,
    second::WindowLinkRef;
    select::Bool=false,
    kwargs...,
)
    context = _topology_context(server, first.session, second.session; kwargs...)
    _check_window_link(context, first)
    _check_window_link(context, second)
    args = ["swap-window", "-s", _window_slot(first), "-t", _window_slot(second)]
    select || push!(args, "-d")
    _operation_command(context, args...)
end

for (operation, command, Ref) in (
    (:respawn_pane, "respawn-pane", PaneRef),
    (:respawn_window, "respawn-window", WindowRef),
)
    @eval function $operation(
        server::Server,
        target::$Ref;
        kill_running::Bool=false,
        command=nothing,
        shell_command=nothing,
        start_directory=nothing,
        kwargs...,
    )
        args = [$command, "-t", string(target.id)]
        kill_running && push!(args, "-k")
        append!(args, _creation_args(command, shell_command, start_directory))
        context = _target_context(server, target; kwargs...)
        _operation_command(context, args...)
    end
    @eval @doc $("""
        $operation(server, target; kill_running=false, command=nothing,
                   shell_command=nothing, start_directory=nothing, kwargs...)

    Restart the target's original command, or use explicit command argv or
    `shell_command`. Running processes are protected unless `kill_running=true`.
    Respawning a window reduces it to one pane; other pane references become
    stale. For shared windows, tmux chooses the session context used for the
    process environment. Return the command result without retry or rollback.
    """) $operation
end

for (operation, command, Ref) in (
    (:rename_session, "rename-session", SessionRef),
    (:rename_window, "rename-window", WindowRef),
)
    @eval function $operation(server::Server, target::$Ref, name::AbstractString; kwargs...)
        isempty(name) && throw(ArgumentError("name cannot be empty"))
        literal = _literal_format(name)
        context = _target_context(server, target; kwargs...)
        _operation_command(context, $command, "-t", string(target.id), "--", literal)
    end
    @eval @doc $("""
        $operation(server, target, name; kwargs...)

    Rename an exact object without expanding format text. tmux's name
    normalization rules still apply. Return the command result.
    """) $operation
end

function _check_client(context, target::ClientRef)
    result = _operation_command(
        context,
        "list-clients",
        "-F",
        _format_template(["client_name", "client_pid", "client_created"]),
    )
    rows = filter(row -> row[1] == target.id.name, _decode_format_rows(result.stdout, 3))
    length(rows) == 1 || throw(StaleReference(target.id.name))
    row = only(rows)
    _observed_int(row[2], "client_pid")
    _observed_int(row[3], "client_created")
    row[2] * ":" * row[3] == target.id.incarnation || throw(StaleReference(target.id.name))
    # tmux strips one trailing colon from its client selector.
    _literal_tmux_argument(target.id.name * ":")
end

"""
    switch_client(server, client::ClientRef, session::SessionRef;
                  update_environment=false, kwargs...)

Switch exactly the captured client to a session. Recheck its name and observed
PID/creation-time incarnation before submission. `update_environment=true`
also updates the destination session's environment from the client. Incarnation
and generation checks are best effort; strict execution is unsupported.
"""
function switch_client(
    server::Server,
    client::ClientRef,
    session::SessionRef;
    update_environment::Bool=false,
    kwargs...,
)
    context = _topology_context(server, client, session; kwargs...)
    target = _check_client(context, client)
    args = ["switch-client", "-c", target, "-t", string(session.id)]
    update_environment || push!(args, "-E")
    _operation_command(context, args...)
end

"""
    detach_client(server, client::ClientRef; kwargs...)

Detach only the captured client after checking its observed incarnation.
No parent signal or shell command is sent. Return the command result;
generation and incarnation checks are best effort.
"""
function detach_client(server::Server, client::ClientRef; kwargs...)
    context = _target_context(server, client; kwargs...)
    target = _check_client(context, client)
    _operation_command(context, "detach-client", "-t", target)
end

"""
    select_window(server, target::WindowLinkRef; kwargs...)

Focus one session's exact window link after checking its observed generation
and expected physical window. Checks are best effort; a link can change after
preflight. No arbitrary session is selected for a shared window.
"""
function select_window(server::Server, target::WindowLinkRef; kwargs...)
    context = _topology_context(server, target.session, target.window; kwargs...)
    _check_window_link(context, target)
    _operation_command(context, "select-window", "-t", _window_slot(target))
end

_maintenance_context(server::Server, target::EntityRef; kwargs...) =
    _target_context(server, target; kwargs...)
_maintenance_literal(::Server, text, operation) = _literal_format(text)

function _maintenance_command(context, args)
    hasproperty(context, :connection) && return _control_topology_effect(context, args)
    _operation_command(context, args...)
end

function _maintenance_fields(context, target, names)
    if hasproperty(context, :connection)
        fields = FormatField.(names)
        values = read_formats(
            context.connection,
            target,
            fields;
            timeout=_snapshot_remaining(context.started, context.budget),
            cancel=context.cancel,
        )
        return [value.value for value in values]
    end
    reply = _target_format_command(context, target, _format_template(names))
    only(_decode_format_rows(reply.stdout, length(names)))
end

"""
    clear_history(transport, pane::PaneRef; kwargs...)

Delete this pane's saved scrollback, preserving its visible screen and process.
Accept a `Server` or `ControlConnection`; return the command result. Cancellation
after submission does not undo the deletion.
"""
function clear_history(transport, pane::PaneRef; kwargs...)
    context = _maintenance_context(transport, pane; kwargs...)
    _maintenance_command(context, ["clear-history", "-t", string(pane.id)])
end

"""
    set_title(transport, pane::PaneRef, title; kwargs...)

Set a literal pane title without format expansion. The pane application can
subsequently replace it. Control titles must be printable UTF-8 because tmux
may emit title notifications. Return the command result.
"""
function set_title(transport, pane::PaneRef, title::AbstractString; kwargs...)
    literal = _maintenance_literal(transport, title, :set_title)
    context = _maintenance_context(transport, pane; kwargs...)
    _maintenance_command(context, ["select-pane", "-t", string(pane.id), "-T", literal])
end

"""
    set_zoom(transport, pane::PaneRef, zoomed::Bool; kwargs...)

Request a zoomed pane or an unzoomed window. An already satisfied state returns
`nothing`. Switching between zoomed panes unzooms then zooms the requested pane;
these observations and commands are best effort against concurrent changes.
Return the last command result when changed; never retry uncertain effects.
"""
function set_zoom(transport, pane::PaneRef, zoomed::Bool; kwargs...)
    context = _maintenance_context(transport, pane; kwargs...)
    values = _maintenance_fields(context, pane, ["window_zoomed_flag", "pane_active"])
    current = _observed_bool(values[1], "window_zoomed_flag")
    active = _observed_bool(values[2], "pane_active")
    current == zoomed && (!zoomed || active) && return nothing
    args = ["resize-pane", "-Z", "-t", string(pane.id)]
    current && zoomed && _maintenance_command(context, args)
    _maintenance_command(context, args)
end

"""
    rotate_panes(transport, window::WindowRef; direction=:up, kwargs...)

Rotate pane positions in their physical window with `:up` or `:down`. Pane IDs
and processes remain; indices and active position can change. Return the result.
"""
function rotate_panes(transport, target::WindowRef; direction::Symbol=:up, kwargs...)
    direction in (:up, :down) || throw(ArgumentError("direction must be :up or :down"))
    context = _maintenance_context(transport, target; kwargs...)
    _maintenance_command(
        context,
        ["rotate-window", direction === :up ? "-U" : "-D", "-t", string(target.id)],
    )
end

"""
    cycle_layout(transport, window::WindowRef; direction=:next, kwargs...)

Select the next or previous predefined layout. This unzooms the physical window
and can resize panes. Direction is `:next` or `:previous`; return the result.
"""
function cycle_layout(transport, target::WindowRef; direction::Symbol=:next, kwargs...)
    direction in (:next, :previous) ||
        throw(ArgumentError("direction must be :next or :previous"))
    context = _maintenance_context(transport, target; kwargs...)
    _maintenance_command(
        context,
        [direction === :next ? "next-layout" : "previous-layout", "-t", string(target.id)],
    )
end

"""
    pipe_pane(transport, pane::PaneRef, shell_command=nothing;
              input=false, output=true, replace=false, expand_formats=false, kwargs...)

Connect a shell command to future pane output, or use `input=true` to feed its
stdout into the pane. tmux owns the pipe process; command completion does not
prove its exit. The caller closes a pipe by explicitly passing `nothing`.
Existing pipes are protected by a best-effort check unless `replace=true`;
replacement can close the old pipe before a new one fails.

Shell syntax executes on the tmux host. Formats and strftime sequences remain
literal unless `expand_formats=true`. No finalizer closes a borrowed pipe and
no failure rolls back input already delivered.
"""
function pipe_pane(
    transport,
    pane::PaneRef,
    shell_command::Union{Nothing,AbstractString}=nothing;
    input::Bool=false,
    output::Bool=true,
    replace::Bool=false,
    expand_formats::Bool=false,
    kwargs...,
)
    args = ["pipe-pane", "-t", string(pane.id)]
    if shell_command !== nothing
        input || output || throw(ArgumentError("enable pipe input or output"))
        command = _argument(shell_command)
        isempty(command) && throw(ArgumentError("use nothing to close a pipe"))
        expand_formats || (command = Base.replace(command, "#"=>"##", "%"=>"%%"))
        input && push!(args, "-I")
        output && push!(args, "-O")
        append!(args, ["--", command])
    end
    context = _maintenance_context(transport, pane; kwargs...)
    if shell_command !== nothing && !replace
        value = only(_maintenance_fields(context, pane, ["pane_pipe"]))
        _observed_bool(value, "pane_pipe") &&
            throw(ArgumentError("pane already has a pipe; use replace=true to replace it"))
    end
    if !hasproperty(context, :connection) && shell_command !== nothing
        args[end] = _literal_tmux_argument(args[end])
    end
    _maintenance_command(context, args)
end

"""
    break_pane(transport, pane::PaneRef, source::WindowLinkRef,
               destination::SessionRef; index, name=nothing, select=false, kwargs...)

Move the pane into an explicit destination window slot without respawning it.
The checked source link establishes session context for a shared window. Removing
a pane changes every link to its physical window; moving its final pane moves
the source window link instead. Return the resulting `WindowRef`.
Checks are best effort against concurrent topology changes. Invalid replies
raise `CreationResponseError` with uncertain effects; no retry or rollback occurs.
"""
function break_pane(
    transport,
    pane::PaneRef,
    source::WindowLinkRef,
    destination::SessionRef;
    index::Integer,
    name::Union{Nothing,AbstractString}=nothing,
    select::Bool=false,
    kwargs...,
)
    slot = _window_index(index)
    foreach(
        ref -> _same_observed_server(pane, ref),
        (source.session, source.window, destination),
    )
    literal =
        name === nothing ? nothing : _maintenance_literal(transport, name, :break_pane)
    context = _maintenance_context(transport, pane; kwargs...)
    if hasproperty(context, :connection)
        _control_check_link(context, source)
    else
        _check_window_link(context, source)
    end
    only(_maintenance_fields(context, pane, ["window_id"])) == string(source.window.id) ||
        throw(StaleReference(string(pane.id)))
    prefix = hasproperty(context, :connection) ? "LIBTMUX\t" : ""
    args = [
        "break-pane",
        "-s",
        _window_slot(source) * "." * string(pane.id),
        "-t",
        _window_slot(destination, slot),
        "-P",
        "-F",
        prefix * _format_template(["pid", "start_time", "socket_path", "window_id"]),
    ]
    select || push!(args, "-d")
    literal === nothing || append!(args, ["-n", literal])
    hasproperty(context, :connection) && return _control_create(context, WindowRef, args)
    result = _operation_command(context, args...)
    _creation_reference(WindowRef, result; expected=pane.server)
end

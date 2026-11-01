"""
    Server(; socket_path=nothing, socket_name=nothing, tmux="tmux", env=ENV)

Describe a tmux endpoint without contacting it. Name at most one socket. A
description does not own a daemon or any sessions.

`socket_path` selects a socket file with tmux's `-S` and `socket_name` a named
socket with `-L`; naming both raises `ArgumentError`. With neither, `env` is
read: `LIBTMUX_SOCKET_PATH` selects a socket file and `LIBTMUX_SOCKET` a named
socket, the path first when both are set. A variable that is empty or only
whitespace counts as unset, each one alone. A socket named in the call leaves
both variables unread. When neither variable is set the server names no socket
and passes tmux neither `-S` nor `-L`, so tmux picks the server itself: the one
`TMUX` names inside tmux, otherwise its `default` socket. Use [`from_env`](@ref)
to ask for the `TMUX` socket as an explicit path.

`tmux` is the executable; a bare name is resolved through `PATH` when an
operation runs. Construction validates the arguments and does not check that
the executable or the socket exists. A `Server` is an immutable value with
nothing to close, and the daemon it names may not be running yet:
[`new_session`](@ref) can start one at this endpoint.

# What is on here

A tmux server does a great many things, so this package has a great many
functions that take one. In Julia they sit beside the type rather than on it:
each takes a `Server` as its first argument, and most also have a method for a
[`ControlConnection`](@ref). Functions that run tmux accept `timeout` and
`cancel` keywords, where `cancel` takes a [`CancellationToken`](@ref). They fall
into a few groups:

**Connecting.** `Server` itself only describes an endpoint. [`from_env`](@ref)
asks for the one named by `TMUX` when this process is inside tmux, and selects
the `default` socket when it is not. [`open_server`](@ref) starts a private daemon
you own and returns an [`OwnedServer`](@ref); [`with_server`](@ref) runs a
function against one and closes it afterwards. [`open_control`](@ref) attaches a
[`ControlConnection`](@ref) to one session, which [`observe_output`](@ref),
[`notifications`](@ref), and [`subscribe_format`](@ref) need.

**Finding one thing.** Operations act on references, such as
[`SessionRef`](@ref), [`WindowRef`](@ref), [`PaneRef`](@ref), and
[`ClientRef`](@ref), each tied to the daemon it came from.
[`new_session`](@ref), [`new_window`](@ref), and [`split_window`](@ref) return
the reference to what they create, and a captured session, window, pane, or
client carries its own as `.ref`.
A `Server` has no lookup by name: take a [`snapshot`](@ref) and give
[`onlymatch`](@ref) a criterion, such as [`SessionWhere`](@ref), and one of the
snapshot's collections. It raises [`NoMatchError`](@ref) or
[`MultipleMatchesError`](@ref) instead of choosing for you.

**Listing everything.** [`snapshot`](@ref) captures every session, window,
pane, and attached client into a [`Snapshot`](@ref), and raises when tmux does
not answer, so an outage never reads as an empty server. [`sessions`](@ref),
[`windows`](@ref), [`panes`](@ref), [`clients`](@ref), [`windowlinks`](@ref),
and [`paneoccurrences`](@ref) list what a snapshot holds without contacting tmux
again. A snapshot is a point-in-time copy that never refreshes; take another to
see later changes.

**Querying things and getting around.** [`SessionWhere`](@ref),
[`WindowWhere`](@ref), [`PaneWhere`](@ref), [`ClientWhere`](@ref), and
[`WindowLinkWhere`](@ref) are [`Criterion`](@ref) values that match captured
records with no I/O. Pass one to `filter`, and the [`Selection`](@ref) it
returns keeps its snapshot. To move between levels, go down with
[`windows`](@ref) on a session and [`panes`](@ref) on a window, and up with
[`window`](@ref) on a pane or window link and [`session`](@ref) on a client or
window link. [`snapshotof`](@ref) returns the snapshot a record came from.

**Changing things.** [`new_session`](@ref), [`new_window`](@ref), and
[`split_window`](@ref) create one and return its reference;
[`kill_session`](@ref), [`kill_window`](@ref), and [`kill_pane`](@ref) remove
one. [`rename_session`](@ref), [`rename_window`](@ref),
[`resize_window`](@ref), [`resize_pane`](@ref), [`respawn_window`](@ref),
[`respawn_pane`](@ref), [`select_window`](@ref), [`select_pane`](@ref),
[`select_layout`](@ref), [`swap_window`](@ref), [`swap_pane`](@ref),
[`move_window`](@ref), [`move_pane`](@ref), [`link_window`](@ref), and
[`unlink_window`](@ref) rearrange what is there. Each acts on tmux when called
and returns a [`CommandResult`](@ref) unless it creates something.

**Options and hooks.** [`get_option`](@ref), [`set_option`](@ref), and
[`unset_option`](@ref) work at a scope such as `:server`, `:global_session`, or
a session, window, or pane reference. [`get_hook`](@ref), [`set_hook`](@ref),
and [`unset_hook`](@ref) do the same for hooks, which have no `:server` scope.
The environment has [`get_environment`](@ref), [`set_environment`](@ref),
[`unset_environment`](@ref), which deletes an entry, and
[`remove_environment`](@ref), which marks a variable for removal from new
processes.

**Everything else tmux keeps.** For paste buffers, [`load_buffer`](@ref)
returns a reference that [`delete_buffer`](@ref) releases, and
[`save_buffer`](@ref) reads one back. [`paste_text`](@ref) and
[`paste_bytes`](@ref) paste into a pane through a temporary buffer.
[`send_keys`](@ref) sends keys to a pane, [`capture_pane`](@ref) returns its
screen as text, and [`capture_bytes`](@ref) returns it as bytes. For formats,
[`read_formats`](@ref) reads typed fields, [`render_format`](@ref) expands a raw
expression, and [`format_hints`](@ref) lists candidate names.

**Things that need a terminal.** Popups, menus, and prompts, which draw on an
attached client's terminal, have no function here. [`switch_client`](@ref) and
[`detach_client`](@ref) act on a client that is already attached.

Anything tmux can do that is not here is reachable through
[`run_command`](@ref), which runs one tmux command with literal arguments, or
[`run_group`](@ref) and [`run_batch`](@ref), which run several
[`TmuxCommand`](@ref) values as one semicolon group or as independent commands.
"""
struct Server
    socket_path::Union{Nothing,String}
    socket_name::Union{Nothing,String}
    tmux::String

    function Server(; socket_path=nothing, socket_name=nothing, tmux="tmux", env=ENV)
        socket_path === nothing ||
            socket_name === nothing ||
            throw(ArgumentError("supply at most one of socket_path or socket_name"))
        executable = _argument(tmux)
        isempty(executable) && throw(ArgumentError("tmux executable cannot be empty"))
        if socket_path === nothing && socket_name === nothing
            socket_path, socket_name = _environment_socket(env)
        end
        if socket_path !== nothing
            path = _argument(socket_path)
            isempty(path) && throw(ArgumentError("socket_path cannot be empty"))
            return new(abspath(path), nothing, executable)
        end
        socket_name === nothing && return new(nothing, nothing, executable)
        name = _argument(socket_name)
        (isempty(name) || occursin('/', name)) &&
            throw(ArgumentError("socket_name must be nonempty and contain no slash"))
        new(nothing, name, executable)
    end
end

function _argument(value::AbstractString)
    occursin('\0', value) && throw(ArgumentError("tmux arguments cannot contain NUL"))
    String(value)
end

# The socket the environment names when the caller named none: the path from
# LIBTMUX_SOCKET_PATH, else the name from LIBTMUX_SOCKET, else neither. A blank
# value counts as unset, and any other value is used as written. An error names
# the variable and never its value.
function _environment_socket(env)
    path = _environment_value(env, "LIBTMUX_SOCKET_PATH")
    path === nothing || return (path, nothing)
    name = _environment_value(env, "LIBTMUX_SOCKET")
    name !== nothing &&
        occursin('/', name) &&
        throw(
            ArgumentError(
                "LIBTMUX_SOCKET must name a socket without a slash; " *
                "use LIBTMUX_SOCKET_PATH for a path",
            ),
        )
    (nothing, name)
end

function _environment_value(env, variable)
    value = get(env, variable, nothing)
    (value === nothing || isempty(strip(value))) ? nothing : value
end

"""
    from_env(; env=ENV, socket_path=nothing, socket_name=nothing, tmux="tmux")

Read the endpoint from `TMUX`, or select the named `default` socket when it
is absent. Explicit selectors take precedence. Return a [`Server`](@ref)
description without contacting tmux or starting a daemon. This is how a caller
asks for the `TMUX` socket as a path; `Server` itself leaves that choice to
tmux. Neither `LIBTMUX_SOCKET_PATH` nor `LIBTMUX_SOCKET` is read here.

# Arguments

- `env=ENV`: Mapping used to read `TMUX`. The value must contain a socket
  path, process ID, and session index separated by commas. An absent or empty
  value selects the named `default` socket; a malformed value raises
  `ArgumentError`. Explicit socket selectors bypass this lookup.
- `socket_path=nothing`: Path to a tmux socket. When supplied, select this
  endpoint instead of reading `env`; relative paths become absolute against
  the current directory. Supply either `socket_path` or `socket_name`, never
  both. An empty path or a path containing NUL raises `ArgumentError`.
- `socket_name=nothing`: Name of a tmux socket, used as tmux's `-L` selector.
  When supplied, select this endpoint instead of reading `env`. The name must
  be nonempty and contain neither a slash nor NUL. Supply either
  `socket_name` or `socket_path`, never both.
- `tmux="tmux"`: Executable name or path for later operations on the returned
  server. A bare name is resolved through `PATH` when an operation runs.
  This call checks that the value is a nonempty string without NUL; it does
  not check whether the executable or socket exists.

# See also

[`Server`](@ref) and [`snapshot`](@ref).
"""
function from_env(; env=ENV, socket_path=nothing, socket_name=nothing, tmux="tmux")
    if socket_path !== nothing || socket_name !== nothing
        return Server(; socket_path, socket_name, tmux)
    end
    ambient = get(env, "TMUX", "")
    isempty(ambient) && return Server(; socket_name="default", tmux)
    fields = rsplit(ambient, ','; limit=3)
    length(fields) == 3 &&
    !isempty(fields[1]) &&
    tryparse(Int, fields[2]) !== nothing &&
    tryparse(Int, fields[3]) !== nothing || throw(
        ArgumentError("TMUX must contain a socket path, process ID and session index"),
    )
    Server(; socket_path=fields[1], tmux)
end

# What tmux gets to find the server. A server that names no socket passes
# neither flag, so tmux follows `TMUX` and otherwise uses its default socket.
function _selector(server::Server)
    server.socket_path !== nothing && return ["-S", server.socket_path]
    server.socket_name !== nothing && return ["-L", server.socket_name]
    String[]
end

_argv(server::Server, args) = [server.tmux; "-u"; _selector(server); "--"; _argument.(args)]

function Base.show(io::IO, server::Server)
    print(io, "Server(")
    if server.socket_path !== nothing
        print(io, "socket_path=")
        show(io, server.socket_path)
        print(io, ", ")
    elseif server.socket_name !== nothing
        print(io, "socket_name=")
        show(io, server.socket_name)
        print(io, ", ")
    end
    print(io, "tmux=")
    show(io, server.tmux)
    print(io, ')')
end

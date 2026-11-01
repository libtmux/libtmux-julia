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

`LIBTMUX_SOCKET` names a socket, so a value that holds a slash raises
`ArgumentError`; put a path in `LIBTMUX_SOCKET_PATH`. A relative path, from the
variable or from `socket_path`, is made absolute against the working directory
when the `Server` is built.

`env` is only the mapping those two variables are read from. It is not the
environment a tmux command gets, which is the `env` of [`run_command`](@ref), so
`Server(env=Dict("TMUX_TMPDIR" => dir))` changes nothing. The choice is made
when the `Server` is built and kept in the value. A `Server` held in a `const`
keeps the variables of the process that built it, which under precompilation is
the precompiling process.

A server that names no socket also leaves `TMUX` and `TMUX_PANE` in the
environment of its commands. A command with no target then acts on the pane
`TMUX_PANE` names, so a bare `kill-pane` through [`run_command`](@ref) kills the
caller's own pane. A named socket drops both variables.

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

**Connecting.** `Server` itself only describes an endpoint. Ask for the endpoint
named by `TMUX` when this process is inside tmux, or for the `default` socket
when it is not. Start a private daemon you own and get back an
[`OwnedServer`](@ref), or run a function against one and close it afterwards.
Attach a [`ControlConnection`](@ref) to one session; the output, notification,
and format-subscription functions need that connection.

- The endpoint named in the environment: [`from_env`](@ref)
- Start a private daemon: [`open_server`](@ref)
- Run a function, then close it: [`with_server`](@ref)
- Attach to one session: [`open_control`](@ref)
- Need a control connection: [`observe_output`](@ref), [`notifications`](@ref),
  [`subscribe_format`](@ref)

**Finding one thing.** Operations act on references, each tied to the daemon it
came from. Creating a session, window, or pane returns the reference to what it
creates, and a captured session, window, pane, or client carries its own as
`.ref`. A `Server` has no lookup by name: take a snapshot and give the matching
function a criterion, such as [`SessionWhere`](@ref), and one of the snapshot's
collections. The matching function raises [`NoMatchError`](@ref) or
[`MultipleMatchesError`](@ref) instead of choosing for you.

- References: [`SessionRef`](@ref), [`WindowRef`](@ref), [`PaneRef`](@ref),
  [`ClientRef`](@ref)
- Return a reference: [`new_session`](@ref), [`new_window`](@ref),
  [`split_window`](@ref)
- Capture: [`snapshot`](@ref)
- Match exactly one: [`onlymatch`](@ref)

**Listing everything.** Take a snapshot to capture every session, window, pane,
and attached client into a [`Snapshot`](@ref); the call raises when tmux does
not answer, so an outage never reads as an empty server. Listing what a snapshot
holds does not contact tmux again. A snapshot is a point-in-time copy that never
refreshes; take another to see later changes.

- Capture: [`snapshot`](@ref)
- List what it holds: [`sessions`](@ref), [`windows`](@ref), [`panes`](@ref),
  [`clients`](@ref), [`windowlinks`](@ref), [`paneoccurrences`](@ref)

**Querying things and getting around.** Criteria are [`Criterion`](@ref) values
that match captured records with no I/O. Pass one to `filter`, and the
[`Selection`](@ref) it returns keeps its snapshot. To move between levels, go
down from a session or a window and up from a pane, a window link, or a client.
A record can be asked for the snapshot it came from.

- Criteria: [`SessionWhere`](@ref), [`WindowWhere`](@ref), [`PaneWhere`](@ref),
  [`ClientWhere`](@ref), [`WindowLinkWhere`](@ref)
- Windows of a session, down: [`windows`](@ref)
- Panes of a window, down: [`panes`](@ref)
- Window of a pane or window link, up: [`window`](@ref)
- Session of a client or window link, up: [`session`](@ref)
- Snapshot a record came from: [`snapshotof`](@ref)

**Changing things.** Creating a session, window, or pane returns its reference,
and killing one removes it. The rest rearrange what is there: renaming,
resizing, respawning, selecting, swapping, moving, linking, and unlinking. Each
function acts on tmux when called and returns a [`CommandResult`](@ref) unless
it creates something.

- Create: [`new_session`](@ref), [`new_window`](@ref), [`split_window`](@ref)
- Remove: [`kill_session`](@ref), [`kill_window`](@ref), [`kill_pane`](@ref)
- Rename: [`rename_session`](@ref), [`rename_window`](@ref)
- Resize: [`resize_window`](@ref), [`resize_pane`](@ref)
- Respawn: [`respawn_window`](@ref), [`respawn_pane`](@ref)
- Select: [`select_window`](@ref), [`select_pane`](@ref),
  [`select_layout`](@ref)
- Swap: [`swap_window`](@ref), [`swap_pane`](@ref)
- Move: [`move_window`](@ref), [`move_pane`](@ref)
- Link and unlink: [`link_window`](@ref), [`unlink_window`](@ref)

**Options and hooks.** Getting, setting, and unsetting options work at a scope
such as `:server`, `:global_session`, or a session, window, or pane reference.
The hook functions work the same way, but hooks have no `:server` scope. The
environment can be read, set, unset, and removed: unsetting deletes an entry,
and removing marks a variable for removal from new processes.

- Options: [`get_option`](@ref), [`set_option`](@ref), [`unset_option`](@ref)
- Hooks: [`get_hook`](@ref), [`set_hook`](@ref), [`unset_hook`](@ref)
- Read and set the environment: [`get_environment`](@ref),
  [`set_environment`](@ref)
- Delete an entry: [`unset_environment`](@ref)
- Remove from new processes: [`remove_environment`](@ref)

**Everything else tmux keeps.** For paste buffers, the load function returns a
reference that the delete function releases, and the save function reads one
back. Paste text or bytes into a pane; each goes through a temporary buffer.
Send keys to a pane, and read its screen back as text or as bytes. For formats,
one function reads typed fields, one expands a raw expression, and one lists
candidate names.

- Load a buffer: [`load_buffer`](@ref)
- Release it: [`delete_buffer`](@ref)
- Read one back: [`save_buffer`](@ref)
- Paste: [`paste_text`](@ref), [`paste_bytes`](@ref)
- Send keys to a pane: [`send_keys`](@ref)
- Screen as text: [`capture_pane`](@ref)
- Screen as bytes: [`capture_bytes`](@ref)
- Read typed fields: [`read_formats`](@ref)
- Expand a raw expression: [`render_format`](@ref)
- List candidate names: [`format_hints`](@ref)

**Things that need a terminal.** Popups, menus, and prompts, which draw on an
attached client's terminal, have no function here. Switching and detaching act
on a client that is already attached.

- Switch a client: [`switch_client`](@ref)
- Detach a client: [`detach_client`](@ref)

**Running a command.** Anything tmux can do that is not here is reachable by
running a tmux command with literal arguments, or by running several
[`TmuxCommand`](@ref) values as one semicolon group or as independent commands.

- One command with literal arguments: [`run_command`](@ref)
- Several as one semicolon group: [`run_group`](@ref)
- Several as independent commands: [`run_batch`](@ref)
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

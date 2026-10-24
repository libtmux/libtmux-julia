# Per-operation tmux release requirements above the 3.3a floor. A requirement
# never raises the minimum for the rest of the library.

const CONTROL_MINIMUM_TMUX = "3.7"
const BUFFER_DELETE_MINIMUM_TMUX = "3.4"
const CLIPBOARD_QUERY_MINIMUM_TMUX = "3.6a"
const JSON_LAYOUT_MINIMUM_TMUX = "3.8"

function _require_release(version, minimum, operation, what)
    version === nothing && return nothing
    _version_at_least(version, minimum) || throw(
        UnsupportedCapability(
            operation,
            "$what requires tmux $minimum or newer; the daemon reports $(repr(version))",
        ),
    )
    nothing
end

# Reuse the release an operation already checked, or read it hook-free.
_checked_release(context) =
    context.checked[] === nothing ? _context_release(context) : context.checked[].version

# Exact-name buffer deletion can act on an unrelated buffer before 3.4, so the
# operations that depend on it are refused before any buffer exists.
function _require_buffer_release(context, operation)
    _require_release(
        _checked_release(context),
        BUFFER_DELETE_MINIMUM_TMUX,
        operation,
        "named-buffer deletion",
    )
end

# tmux 3.7 rejects ':' and '.' in session and window names.
# 3.7a restored them. Pre-release builds of 3.7 rank below it but carry the
# restriction, so the guard covers every 3.7 build without a patch letter.
function _names_restricted(version)
    key = _release_key(version)
    key !== nothing && key[1:3] == (3, 7, "")
end

# tmux 3.7 also stops on a `break-pane` that gives the new window no name.
_unnamed_break_stops(version) = _names_restricted(version)

function _check_name_release(version, name, operation)
    _names_restricted(version) &&
        occursin(r"[:.]", name) &&
        throw(
            ArgumentError(
                "$operation: tmux 3.7 rejects ':' and '.' in session and window names; use another name or a different release",
            ),
        )
    nothing
end

function _check_name(context, name, operation)
    occursin(r"[:.]", name) || return nothing
    _check_name_release(_checked_release(context), name, operation)
end

function _check_name(connection::ControlConnection, name, operation)
    occursin(r"[:.]", name) || return nothing
    version = _control_release(connection)
    version === nothing || _check_name_release(version, name, operation)
end

# `break-pane` on tmux 3.7 stops the server unless it names the new window, and
# the name follows the same restriction as any other window name. Return the
# release the check used, or `nothing` when it is unknown.
function _check_break_pane_name(context, name)
    version =
        hasproperty(context, :connection) ? _control_release(context.connection) :
        _checked_release(context)
    version === nothing && return nothing
    if name === nothing
        _unnamed_break_stops(version) && throw(
            UnsupportedCapability(
                :break_pane,
                "break-pane without a window name stops tmux 3.7; pass name or use another release",
            ),
        )
    elseif occursin(r"[:.]", name)
        _check_name_release(version, name, :break_pane)
    end
    version
end

# Raw command lines reach tmux unchanged, so the same requirements apply to
# them as to the typed operations. A command is resolved the way tmux resolves
# it: an exact alias, else an exact name, else a unique name prefix. Nested
# command strings (`if-shell`, `run-shell -C`, brace blocks) are not parsed.
const _TMUX_COMMAND_TABLE = (
    ("attach-session", "attach"),
    ("bind-key", "bind"),
    ("break-pane", "breakp"),
    ("capture-pane", "capturep"),
    ("choose-buffer", nothing),
    ("choose-client", nothing),
    ("choose-tree", nothing),
    ("clear-history", "clearhist"),
    ("clear-prompt-history", "clearphist"),
    ("clock-mode", nothing),
    ("command-prompt", nothing),
    ("confirm-before", "confirm"),
    ("copy-mode", nothing),
    ("customize-mode", nothing),
    ("delete-buffer", "deleteb"),
    ("detach-client", "detach"),
    ("display-menu", "menu"),
    ("display-message", "display"),
    ("display-panes", "displayp"),
    ("display-popup", "popup"),
    ("find-window", "findw"),
    ("has-session", "has"),
    ("if-shell", "if"),
    ("join-pane", "joinp"),
    ("kill-pane", "killp"),
    ("kill-server", nothing),
    ("kill-session", nothing),
    ("kill-window", "killw"),
    ("last-pane", "lastp"),
    ("last-window", "last"),
    ("link-window", "linkw"),
    ("list-buffers", "lsb"),
    ("list-clients", "lsc"),
    ("list-commands", "lscm"),
    ("list-keys", "lsk"),
    ("list-panes", "lsp"),
    ("list-sessions", "ls"),
    ("list-windows", "lsw"),
    ("load-buffer", "loadb"),
    ("lock-client", "lockc"),
    ("lock-server", "lock"),
    ("lock-session", "locks"),
    ("move-pane", "movep"),
    ("move-window", "movew"),
    ("new-session", "new"),
    ("new-window", "neww"),
    ("next-layout", "nextl"),
    ("next-window", "next"),
    ("paste-buffer", "pasteb"),
    ("pipe-pane", "pipep"),
    ("previous-layout", "prevl"),
    ("previous-window", "prev"),
    ("refresh-client", "refresh"),
    ("rename-session", "rename"),
    ("rename-window", "renamew"),
    ("resize-pane", "resizep"),
    ("resize-window", "resizew"),
    ("respawn-pane", "respawnp"),
    ("respawn-window", "respawnw"),
    ("rotate-window", "rotatew"),
    ("run-shell", "run"),
    ("save-buffer", "saveb"),
    ("select-layout", "selectl"),
    ("select-pane", "selectp"),
    ("select-window", "selectw"),
    ("send-keys", "send"),
    ("send-prefix", nothing),
    ("server-access", nothing),
    ("set-buffer", "setb"),
    ("set-environment", "setenv"),
    ("set-hook", nothing),
    ("set-option", "set"),
    ("set-window-option", "setw"),
    ("show-buffer", "showb"),
    ("show-environment", "showenv"),
    ("show-hooks", nothing),
    ("show-messages", "showmsgs"),
    ("show-options", "show"),
    ("show-prompt-history", "showphist"),
    ("show-window-options", "showw"),
    ("source-file", "source"),
    ("split-window", "splitw"),
    ("start-server", "start"),
    ("suspend-client", "suspendc"),
    ("swap-pane", "swapp"),
    ("swap-window", "swapw"),
    ("switch-client", "switchc"),
    ("unbind-key", "unbind"),
    ("unlink-window", "unlinkw"),
    ("wait-for", "wait"),
)

function _resolve_tmux_command(word::AbstractString)
    found = nothing
    ambiguous = false
    for (name, alias) in _TMUX_COMMAND_TABLE
        alias == word && return name
        startswith(name, word) || continue
        found === nothing || (ambiguous = true)
        found = name
        name == word && break
    end
    ambiguous ? nothing : found
end

# The flags of one command line as getopt reads them: `spec` lists each flag
# and follows it with ':' when it takes a value.
function _command_flags(arguments, spec::AbstractString)
    flags = Dict{Char,Union{Nothing,String}}()
    index = 1
    while index <= length(arguments)
        word = arguments[index]
        word == "--" && (index += 1; break)
        (length(word) > 1 && word[1] == '-') || break
        position = 2
        while position <= lastindex(word)
            flag = word[position]
            found = findfirst(==(flag), spec)
            found === nothing && return (flags, String[], false)
            takes_value = found < lastindex(spec) && spec[found+1] == ':'
            position = nextind(word, position)
            if takes_value
                if position <= lastindex(word)
                    flags[flag] = word[position:end]
                else
                    index += 1
                    index <= length(arguments) || return (flags, String[], false)
                    flags[flag] = arguments[index]
                end
                break
            end
            flags[flag] = nothing
        end
        index += 1
    end
    (flags, arguments[index:end], true)
end

# Split a `run_command` argument list on its tmux command separators.
function _command_segments(arguments)
    segments = Vector{String}[]
    current = String[]
    for argument in arguments
        if argument == ";"
            push!(segments, current)
            current = String[]
        elseif endswith(argument, ';') && !endswith(argument, "\\;")
            push!(current, chop(argument))
            push!(segments, current)
            current = String[]
        else
            push!(current, argument)
        end
    end
    push!(segments, current)
    filter!(!isempty, segments)
end

const _PRESET_LAYOUTS =
    ("even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled")

# tmux 3.3 and 3.3a free an uninitialised pointer when a layout string does not
# start with a checksum, which stops the server. Only a preset name or a string
# that opens like a dumped layout reaches those releases.
function _layout_operand_safe(operand)
    operand in _PRESET_LAYOUTS && return true
    !isempty(operand) &&
        count(name -> startswith(name, operand), _PRESET_LAYOUTS) == 1 &&
        return true
    occursin(r"\A[0-9A-Fa-f]{4},", operand)
end

function _guard_command_line(words, version)
    command = _resolve_tmux_command(first(words))
    command === nothing && return nothing
    arguments = words[2:end]
    if command == "delete-buffer" || command == "set-buffer"
        flags, _, valid =
            _command_flags(arguments, command == "delete-buffer" ? "b:" : "ab:t:n:w")
        valid || return nothing
        flag = command == "delete-buffer" ? 'b' : 'n'
        haskey(flags, flag) && _require_release(
            version,
            BUFFER_DELETE_MINIMUM_TMUX,
            Symbol(replace(command, '-' => '_')),
            "$command -$flag",
        )
    elseif command == "refresh-client"
        flags, _, valid = _command_flags(arguments, "A:B:cC:Df:F:lLr:RSt:U")
        valid || return nothing
        haskey(flags, 'l') && _require_release(
            version,
            CLIPBOARD_QUERY_MINIMUM_TMUX,
            :refresh_client,
            "refresh-client -l (the clipboard query)",
        )
    elseif command == "break-pane"
        flags, _, valid = _command_flags(arguments, "abdPF:n:s:t:")
        valid || return nothing
        _unnamed_break_stops(version) &&
            !haskey(flags, 'n') &&
            throw(
                UnsupportedCapability(
                    :break_pane,
                    "break-pane without a window name stops tmux 3.7; pass -n or use another release",
                ),
            )
    elseif command == "select-layout"
        _, operands, valid = _command_flags(arguments, "Enopt:")
        valid || return nothing
        if version !== nothing && !_version_at_least(version, "3.4") && !isempty(operands)
            _layout_operand_safe(first(operands)) || throw(
                UnsupportedCapability(
                    :select_layout,
                    "tmux below 3.4 stops on a layout string that does not open like a dumped layout; observed $(repr(version))",
                ),
            )
        end
    end
    nothing
end

function _guard_raw_command(arguments, version)
    version === nothing && return nothing
    for words in _command_segments(arguments)
        _guard_command_line(words, version)
    end
    nothing
end

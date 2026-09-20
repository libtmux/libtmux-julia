"""A configured environment entry; `value=nothing` marks removal from new processes."""
struct EnvironmentValue
    value::Union{Nothing,String}
    hidden::Bool
    inherited::Bool
end

"""One sparse hook entry with tmux's canonical command body and inheritance marker."""
struct HookCommand
    index::Int
    command::String
    inherited::Bool
end

struct _ConfigurationRow
    name::String
    index::Union{Nothing,String}
    inherited::Bool
    body::Union{Nothing,String}
end

function _option_scope_flags(scope)
    scope === :server && return ["-s"]
    scope === :global_session && return ["-g"]
    scope === :global_window && return ["-g", "-w"]
    scope isa SessionRef && return ["-t", string(scope.id)]
    scope isa WindowRef && return ["-w", "-t", string(scope.id)]
    scope isa PaneRef && return ["-p", "-t", string(scope.id)]
    throw(
        ArgumentError(
            "option scope must be :server, :global_session, :global_window, or a session/window/pane reference",
        ),
    )
end

function _environment_scope_flags(scope)
    scope === :global && return ["-g"]
    scope isa SessionRef && return ["-t", string(scope.id)]
    throw(ArgumentError("environment scope must be :global or a SessionRef"))
end

function _configuration_name(name::AbstractString; environment=false, hook=false)
    name = _argument(name)
    pattern =
        environment ? r"\A[A-Za-z_][A-Za-z0-9_]*\z" :
        hook ? r"\A[a-z][a-z0-9-]*\z" : r"\A(?:[a-z][a-z0-9-]*|@[A-Za-z0-9_.-]+)\z"
    occursin(pattern, name) ||
        throw(ArgumentError("invalid configuration name: $(repr(name))"))
    name
end

function _configuration_index(index)
    index === nothing && return nothing
    index isa Integer && !(index isa Bool) && 0 <= index <= typemax(Int32) || throw(
        ArgumentError("array index must be an integer from 0 through $(typemax(Int32))"),
    )
    Int(index)
end

function _option_arguments(scope, name, index)
    flags = _option_scope_flags(scope)
    name = _configuration_name(name)
    index = _configuration_index(index)
    startswith(name, '@') &&
        index !== nothing &&
        throw(ArgumentError("user options do not have array indices"))
    (; flags, name, index, key=index === nothing ? name : "$name[$index]")
end

_configuration_context(server, scope; kwargs...) =
    scope isa EntityRef ? _target_context(server, scope; kwargs...) :
    _operation_context(server; kwargs...)

function _configuration_text(result)
    text = decode_text(result.stdout)
    isempty(text) && return nothing
    endswith(text, '\n') || throw(ArgumentError("truncated configuration reply"))
    String(chop(text; tail=1))
end

const _CONFIGURATION_PRINT_PROBE = raw"LIBTMUX:$value"
const _CONFIGURATION_DOLLAR_ESCAPE = r"\\\$(?=[A-Za-z_{])"

function _configuration_printed_text(probe, text)
    text === nothing && return nothing
    occursin(_CONFIGURATION_DOLLAR_ESCAPE, text) || return text
    observed = probe().stdout
    # tmux 3.4 adds this escape in server_client_print, after args_escape.
    observed == codeunits(raw"LIBTMUX:\$value" * "\n") &&
        return replace(text, _CONFIGURATION_DOLLAR_ESCAPE => raw"$")
    observed == codeunits(_CONFIGURATION_PRINT_PROBE * "\n") ||
        throw(ArgumentError("unexpected tmux configuration print encoding"))
    text
end

function _configuration_text(context, result::CommandResult)
    _configuration_printed_text(_configuration_text(result)) do
        _operation_command(context, "display-message", "-p", _CONFIGURATION_PRINT_PROBE)
    end
end

function _configuration_rows(context, scope, requested_name; hooks=true)
    flags = _option_scope_flags(scope)
    args = hooks ? ["show-options", "-A", "-H", flags...] : ["show-options", "-A", flags...]
    result = _operation_command(context, args...)
    rows = _ConfigurationRow[]
    text = _configuration_text(context, result)
    text === nothing && return rows
    for line in split(text, '\n')
        startswith(line, requested_name) || continue
        parsed = match(r"\A([^\s\[\]*]+)(?:\[([^\]]*)\])?(\*)?(?: (.*))?\z", line)
        parsed === nothing && throw(ArgumentError("invalid configuration listing row"))
        name, index, inherited, body = parsed.captures
        name == requested_name || continue
        push!(rows, _ConfigurationRow(name, index, inherited !== nothing, body))
    end
    rows
end

function _configuration_option_rows(context, scope, name)
    rows = _configuration_rows(context, scope, name)
    isempty(rows) &&
        !startswith(name, '@') &&
        throw(ArgumentError("option $name is not defined in the requested scope"))
    rows
end

function _configuration_parent(context, scope)
    scope isa SessionRef && return :global_session
    scope isa WindowRef && return :global_window
    if scope isa PaneRef
        result = _target_format_command(context, scope, _format_template(["window_id"]))
        id = only(only(_decode_format_rows(result.stdout, 1)))
        return WindowRef(scope.server, id)
    end
    nothing
end

function _get_option(context, scope, name, index, inherit)
    rows = _configuration_option_rows(context, scope, name)
    if isempty(rows) && inherit && startswith(name, '@')
        parent = _configuration_parent(context, scope)
        parent === nothing && return nothing
        return _get_option(context, parent, name, index, true)
    end
    inherit || filter!(r -> !r.inherited, rows)
    isempty(rows) && return nothing
    array = any(r -> r.index !== nothing || r.body === nothing, rows)
    array &&
        index === nothing &&
        throw(ArgumentError("array option $name requires an explicit index"))
    !array && index !== nothing && throw(ArgumentError("option $name is not an array"))
    key_index = index === nothing ? nothing : string(index)
    any(r -> r.index == key_index, rows) || return nothing
    flags = _option_scope_flags(scope)
    inherit && push!(flags, "-A")
    key = index === nothing ? name : "$name[$index]"
    result = _operation_command(context, "show-options", flags..., "-v", "--", key)
    _configuration_text(context, result)
end

"""
    get_option(server, scope, name; index=nothing, inherit=false, kwargs...)

Read one scalar or indexed value as a string. `nothing` means no value in the
requested scope; `""` is an explicit empty value. `inherit=true` follows tmux's
parent options. Arrays require a numeric `index`; missing sparse entries return
`nothing`. Use `get_hook` to read an entire command array.

Scopes are `:server`, `:global_session`, `:global_window`, `SessionRef`,
`WindowRef` and `PaneRef`. Names are exact built-in names or user names matching
`@[A-Za-z0-9_.-]+`; abbreviations are rejected. Reads use explicit subprocess
I/O and may span several observations, not a transaction. Deadline, cancellation
and best-effort identity checks follow `new_session`.
"""
function get_option(
    server::Server,
    scope,
    name::AbstractString;
    index=nothing,
    inherit::Bool=false,
    kwargs...,
)
    args = _option_arguments(scope, name, index)
    context = _configuration_context(server, scope; kwargs...)
    _get_option(context, scope, args.name, args.index, inherit)
end

"""
    set_option(server, scope, name, value; index=nothing, kwargs...)

Pass a value to tmux without format expansion and return `CommandResult`.
Scope and names follow `get_option`. tmux applies each option's value rules,
including flag and numeric parsing. Without an index, its whole-array assignment
rules apply. For executable command bodies use `set_hook`.
"""
function set_option(
    server::Server,
    scope,
    name::AbstractString,
    value::AbstractString;
    index=nothing,
    kwargs...,
)
    args = _option_arguments(scope, name, index)
    value = _literal_tmux_argument(value)
    context = _configuration_context(server, scope; kwargs...)
    _configuration_option_rows(context, scope, args.name)
    _operation_command(context, "set-option", args.flags..., "--", args.key, value)
end

"""
    unset_option(server, scope, name; index=nothing, kwargs...)

Remove a local option or sparse entry, restoring inheritance. Unsetting a
built-in global option restores its tmux default. Return `CommandResult`.
"""
function unset_option(server::Server, scope, name::AbstractString; index=nothing, kwargs...)
    args = _option_arguments(scope, name, index)
    context = _configuration_context(server, scope; kwargs...)
    _configuration_option_rows(context, scope, args.name)
    _operation_command(context, "set-option", args.flags..., "-u", "--", args.key)
end

function _get_environment(context, scope, name; inherited=false)
    flags = _environment_scope_flags(scope)
    result = try
        _operation_command(context, "show-environment", flags..., "--", name)
    catch error
        if error isa CommandError &&
           error.result.exitcode == 1 &&
           isempty(error.result.stdout) &&
           error.result.stderr == codeunits("unknown variable: $name\n")
            return nothing
        end
        rethrow()
    end
    hidden = isempty(result.stdout)
    if hidden
        result = _operation_command(context, "show-environment", flags..., "-h", "--", name)
    end
    text = _configuration_text(context, result)
    text == "-$name" && return EnvironmentValue(nothing, hidden, inherited)
    text !== nothing && startswith(text, "$name=") ||
        throw(ArgumentError("invalid environment reply for $name"))
    EnvironmentValue(text[(length(name)+2):end], hidden, inherited)
end

"""
    get_environment(server, scope, name; inherit=false, kwargs...)

Read a global (`:global`) or session (`SessionRef`) environment entry. Return
`nothing` when absent, or `EnvironmentValue(value, hidden, inherited)`.
`value=nothing` is a removal marker for new processes; `value=""` is empty.
Hidden entries are returned with `hidden=true`. `inherit=true` falls back to
global only for an absent session entry, never for a removal marker. This
explicit multi-command observation is not an atomic child-process environment.
Variable names use `[A-Za-z_][A-Za-z0-9_]*`.
"""
function get_environment(
    server::Server,
    scope,
    name::AbstractString;
    inherit::Bool=false,
    kwargs...,
)
    _environment_scope_flags(scope)
    name = _configuration_name(name; environment=true)
    context = _configuration_context(server, scope; kwargs...)
    entry = _get_environment(context, scope, name)
    entry === nothing &&
        inherit &&
        scope isa SessionRef &&
        return _get_environment(context, :global, name; inherited=true)
    entry
end

"""Set a literal environment value at `:global` or `SessionRef`; return `CommandResult`."""
function set_environment(
    server::Server,
    scope,
    name::AbstractString,
    value::AbstractString;
    hidden::Bool=false,
    kwargs...,
)
    flags = _environment_scope_flags(scope)
    name = _configuration_name(name; environment=true)
    value = _literal_tmux_argument(value)
    hidden && push!(flags, "-h")
    context = _configuration_context(server, scope; kwargs...)
    _operation_command(context, "set-environment", flags..., "--", name, value)
end

for (operation, flag, description) in (
    (:unset_environment, "-u", "Delete the configured entry, allowing global inheritance."),
    (
        :remove_environment,
        "-r",
        "Mark the variable for removal from new process environments.",
    ),
)
    @eval function $operation(server::Server, scope, name::AbstractString; kwargs...)
        flags = _environment_scope_flags(scope)
        name = _configuration_name(name; environment=true)
        context = _configuration_context(server, scope; kwargs...)
        _operation_command(context, "set-environment", flags..., $flag, "--", name)
    end
    @eval @doc $description $operation
end

function _hook_arguments(scope, name, index)
    scope === :server &&
        throw(ArgumentError("hooks have session, window or pane scopes, not server scope"))
    _configuration_name(name; hook=true)
    _option_arguments(scope, name, index)
end

function _configuration_hook_rows(context, scope, name)
    rows = _configuration_option_rows(context, scope, name)
    !isempty(_configuration_rows(context, scope, name; hooks=false)) &&
        throw(ArgumentError("option $name is not a hook"))
    rows
end

function _hook_index(value)
    index = tryparse(Int, value)
    index !== nothing && 0 <= index <= typemax(Int32) && string(index) == value || throw(
        UnsupportedCapability(
            :get_hook,
            "hook key $(repr(value)) is outside the portable numeric index range 0..$(typemax(Int32))",
        ),
    )
    index
end

"""
    get_hook(server, scope, name; inherit=false, kwargs...)

Return sparse `HookCommand` entries in tmux order. `nothing` means no local
override; an empty vector means an explicitly empty command array. With
`inherit=true`, include inherited hooks. Scopes follow `get_option`, excluding
`:server`; only built-in hooks supported by the connected tmux are accepted.
Command bodies use tmux's canonical executable grammar, not the original
quoting or whitespace. This read does not execute the returned commands.
"""
function get_hook(
    server::Server,
    scope,
    name::AbstractString;
    inherit::Bool=false,
    kwargs...,
)
    args = _hook_arguments(scope, name, nothing)
    context = _configuration_context(server, scope; kwargs...)
    rows = _configuration_hook_rows(context, scope, args.name)
    inherit || filter!(r -> !r.inherited, rows)
    isempty(rows) && return nothing
    [
        HookCommand(_hook_index(r.index), r.body, r.inherited) for
        r in rows if r.index !== nothing
    ]
end

"""
    set_hook(server, scope, name, command; index=nothing, kwargs...)

Store executable tmux command grammar; this is not a shell command or literal
option value. tmux parses the body when stored and executes it when the hook
fires. Without `index`, replace the whole command array; an empty body clears
it and masks inherited hooks. A numeric index changes only that sparse entry.
Return `CommandResult`; parsing failures retain tmux's command error evidence.
tmux may clear an existing whole array before reporting a parse failure.
The library does not roll back or retry this mutation.
"""
function set_hook(
    server::Server,
    scope,
    name::AbstractString,
    command::AbstractString;
    index=nothing,
    kwargs...,
)
    args = _hook_arguments(scope, name, index)
    command = _literal_tmux_argument(command)
    isempty(command) &&
        args.index !== nothing &&
        throw(
            ArgumentError(
                "an empty hook body requires whole-array assignment; use unset_hook for an index",
            ),
        )
    context = _configuration_context(server, scope; kwargs...)
    _configuration_hook_rows(context, scope, args.name)
    _operation_command(context, "set-hook", args.flags..., "--", args.key, command)
end

"""Unset a hook override or sparse entry at the explicit scope; return `CommandResult`."""
function unset_hook(server::Server, scope, name::AbstractString; index=nothing, kwargs...)
    args = _hook_arguments(scope, name, index)
    context = _configuration_context(server, scope; kwargs...)
    _configuration_hook_rows(context, scope, args.name)
    _operation_command(context, "set-hook", args.flags..., "-u", "--", args.key)
end

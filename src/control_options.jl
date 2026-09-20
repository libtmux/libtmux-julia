include("options_generated.jl")

function _control_option_metadata(context, scope, name, operation)
    startswith(name, '@') && return (
        scope=UInt8(15),
        kind=:string,
        array=false,
        hook=false,
        checked_string=false,
    )
    metadata = _tmux_option_metadata(name)
    version = nothing
    if metadata === nothing && _tmux_option_versioned(name)
        version = only(
            only(
                _control_rows(
                    context.connection,
                    "display-message",
                    ["version"];
                    timeout=_snapshot_remaining(context.started, context.budget),
                    cancel=context.cancel,
                ),
            ),
        )
        metadata = _tmux_option_metadata(name, version)
    end
    if metadata === nothing
        scope_label =
            scope isa Symbol ? string(scope) :
            scope isa SessionRef ? "session $(string(scope.id))" :
            scope isa WindowRef ? "window $(string(scope.id))" : "pane $(string(scope.id))"
        detail =
            version === nothing ? "option $name is not catalogued for $scope_label" :
            "option $name has no unambiguous pinned metadata for tmux $(repr(version)) at $scope_label"
        throw(UnsupportedCapability(operation, detail))
    end
    metadata
end

function _control_option_arguments(
    operation,
    connection,
    scope,
    name,
    index;
    hook=false,
    kwargs...,
)
    args =
        hook ? _hook_arguments(scope, name, index) : _option_arguments(scope, name, index)
    context = _control_configuration_context(connection, scope; kwargs...)
    metadata = _control_option_metadata(context, scope, args.name, operation)
    bit =
        scope === :server ? 1 :
        scope === :global_session || scope isa SessionRef ? 2 :
        scope === :global_window || scope isa WindowRef ? 4 : 8
    metadata.scope & bit != 0 ||
        throw(ArgumentError("option $(args.name) is not defined in the requested scope"))
    hook && !metadata.hook && throw(ArgumentError("option $(args.name) is not a hook"))
    args.index === nothing ||
        metadata.array ||
        throw(ArgumentError("option $(args.name) is not an array"))
    (; args..., context, metadata)
end

function _configuration_text(context, result::ControlResult)
    _configuration_printed_text(_configuration_text(result)) do
        probe = _control_request(
            context.connection,
            ["display-message", "-p", _CONFIGURATION_PRINT_PROBE],
            _ControlReplyPolicy(; prefix="LIBTMUX:", diagnostics=true);
            timeout=_snapshot_remaining(context.started, context.budget),
            cancel=context.cancel,
        )
        probe.failed && throw(ControlCommandError(probe, "display-message"))
        probe
    end
end

function _control_named_configuration(context, scope, name, metadata)
    result = _control_request(
        context.connection,
        ["show-options", _option_scope_flags(scope)..., "--", name],
        _ControlReplyPolicy(; prefix=name, diagnostics=true);
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    if result.failed
        startswith(name, '@') &&
            result.stdout == codeunits("invalid option: $name\n") &&
            return _ConfigurationRow[]
        throw(ControlCommandError(result, "show-options"))
    end
    text = _configuration_text(context, result)
    text === nothing && return _ConfigurationRow[]
    rows = _ConfigurationRow[]
    for line in split(text, '\n')
        startswith(line, name) ||
            throw(ArgumentError("configuration reply has an unexpected name"))
        suffix = SubString(line, ncodeunits(name) + 1)
        parsed = match(r"\A(?:\[([0-9]+)\])?(?: (.*))?\z", suffix)
        parsed === nothing && throw(ArgumentError("invalid named configuration reply"))
        index, body = parsed.captures
        if metadata.array
            index === nothing &&
                body !== nothing &&
                throw(ArgumentError("array reply lacks an index"))
            index === nothing || _hook_index(index)
        else
            index === nothing && body !== nothing ||
                throw(ArgumentError("invalid scalar configuration reply"))
        end
        push!(rows, _ConfigurationRow(name, index, false, body))
    end
    rows
end

# Invert args_escape's VIS representation as data, without tmux expansion or eval.
function _control_option_literal(value::AbstractString)
    bytes = codeunits(value)
    isempty(bytes) && throw(ArgumentError("missing quoted option value"))
    first_index, last_index = 1, length(bytes)
    if bytes[1] in (0x22, 0x27)
        length(bytes) >= 2 && bytes[end] == bytes[1] ||
            throw(ArgumentError("invalid quoted option value"))
        first_index += 1
        last_index -= 1
    end
    output = UInt8[]
    index = first_index
    escapes = Dict{UInt8,UInt8}(
        0x61=>0x07,
        0x62=>0x08,
        0x74=>0x09,
        0x6e=>0x0a,
        0x76=>0x0b,
        0x66=>0x0c,
        0x72=>0x0d,
        0x73=>0x20,
        0x65=>0x1b,
    )
    while index <= last_index
        byte = bytes[index]
        index += 1
        if byte != 0x5c
            push!(output, byte)
            continue
        end
        index <= last_index || throw(ArgumentError("truncated option escape"))
        byte = bytes[index]
        index += 1
        if 0x30 <= byte <= 0x37
            index + 1 <= last_index &&
            all(b -> 0x30 <= b <= 0x37, bytes[index:(index+1)]) ||
                throw(ArgumentError("invalid option octal escape"))
            number = Int(byte-0x30)*64 + Int(bytes[index]-0x30)*8 + Int(bytes[index+1]-0x30)
            number <= 255 || throw(ArgumentError("option octal escape exceeds one byte"))
            push!(output, UInt8(number))
            index += 2
        elseif haskey(escapes, byte)
            push!(output, escapes[byte])
        elseif 0x20 <= byte <= 0x7e && !isletter(Char(byte)) && !isdigit(Char(byte))
            push!(output, byte)
        else
            throw(ArgumentError("unsupported option escape"))
        end
    end
    decode_text(output)
end

function _control_configuration_parent(context, scope)
    scope isa SessionRef && return :global_session
    scope isa WindowRef && return :global_window
    if scope isa PaneRef
        row = only(
            _control_rows(
                context.connection,
                "display-message",
                ["window_id"];
                target=scope,
                timeout=_snapshot_remaining(context.started, context.budget),
                cancel=context.cancel,
            ),
        )
        return WindowRef(scope.server, only(row))
    end
    nothing
end

function _control_configuration_rows(context, scope, name, metadata, inherit)
    rows = _control_named_configuration(context, scope, name, metadata)
    if isempty(rows) && inherit
        parent = _control_configuration_parent(context, scope)
        if parent !== nothing
            rows = _control_configuration_rows(context, parent, name, metadata, true)
            return [_ConfigurationRow(r.name, r.index, true, r.body) for r in rows]
        end
    end
    rows
end

"""
    get_option(connection::ControlConnection, scope, name; index=nothing, inherit=false, kwargs...)

Read an exact option through named, escaped replies on the pinned daemon.
Scope and returned strings follow `get_option(server, ...)`. Missing values
return `nothing`; empty strings and explicitly empty arrays mask inheritance.
Array reads require `index` and inspect complete local membership before any
parent lookup, so a missing sparse entry is never mistaken for an empty value.

Built-in names and scopes use pinned release metadata; the named command still
checks runtime availability. Seven names whose metadata changed require an
encoded version observation. Ambiguous unknown version profiles are refused.
Unrestricted string values are decoded as literal VIS data, never evaluated.
These observations are not atomic, and no subprocess fallback occurs.
"""
function get_option(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    index=nothing,
    inherit::Bool=false,
    kwargs...,
)
    args = _control_option_arguments(:get_option, connection, scope, name, index; kwargs...)
    args.metadata.array &&
        args.index === nothing &&
        throw(ArgumentError("array option $(args.name) requires an explicit index"))
    rows =
        _control_configuration_rows(args.context, scope, args.name, args.metadata, inherit)
    requested = args.index === nothing ? nothing : string(args.index)
    matches = filter(row -> row.index == requested && row.body !== nothing, rows)
    isempty(matches) && return nothing
    body = something(only(matches).body)
    args.metadata.kind === :string ? _control_option_literal(body) : body
end

"""
    get_hook(connection::ControlConnection, scope, name; inherit=false, kwargs...)

Read the complete sparse hook array in tmux order without executing it.
Return `nothing` for no local override, or an empty vector for a local empty
array. Inherited entries carry `inherited=true`. Canonical command bodies and
scope semantics follow the subprocess method; named replies and explicit parent
lookups avoid raw broad listings and preserve empty-array masking.
"""
function get_hook(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    inherit::Bool=false,
    kwargs...,
)
    args = _control_option_arguments(
        :get_hook,
        connection,
        scope,
        name,
        nothing;
        hook=true,
        kwargs...,
    )
    rows =
        _control_configuration_rows(args.context, scope, args.name, args.metadata, inherit)
    isempty(rows) && return nothing
    [
        HookCommand(_hook_index(row.index), something(row.body), row.inherited) for
        row in rows if row.index !== nothing
    ]
end

function _control_configuration_effect(args, command, value=nothing; unset=false)
    argv = [command, args.flags...]
    unset && push!(argv, "-u")
    append!(argv, ["--", args.key])
    value === nothing || push!(argv, value)
    _control_effect(
        args.context.connection,
        argv;
        timeout=_snapshot_remaining(args.context.started, args.context.budget),
        cancel=args.context.cancel,
    )
end

"""
    set_option(connection::ControlConnection, scope, name, value; index=nothing, kwargs...)

Set an exact option without format expansion. Unrestricted string options and
string arrays preserve literal tabs/newlines. Numeric, flag, choice, colour,
key, style and other validated options require printable UTF-8 values because
tmux may reflect an invalid value in control diagnostics. tmux validates the
remaining value rules. Scalar command options use `set_hook`'s literal grammar;
an empty value stores an empty command list. Hook arrays require `set_hook`.
Return `ControlResult`; cancellation does not roll back an admitted mutation.
"""
function set_option(
    connection::ControlConnection,
    scope,
    name::AbstractString,
    value::AbstractString;
    index=nothing,
    kwargs...,
)
    value = _argument(value)
    args = _control_option_arguments(:set_option, connection, scope, name, index; kwargs...)
    if args.metadata.kind === :command
        args.metadata.hook && throw(ArgumentError("hook arrays require set_hook"))
        value = _control_hook_body(value)
    elseif args.metadata.kind !== :string || args.metadata.checked_string
        value = _control_singleline(value, :set_option)
    end
    _control_configuration_effect(args, "set-option", value)
end

"""Unset an exact option or sparse entry on the pinned daemon, restoring inheritance/defaults."""
function unset_option(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    index=nothing,
    kwargs...,
)
    args =
        _control_option_arguments(:unset_option, connection, scope, name, index; kwargs...)
    _control_configuration_effect(args, "set-option"; unset=true)
end

function _control_hook_body(command::AbstractString)
    text = _control_singleline(command, :set_hook)
    isempty(text) && return text
    bytes = codeunits(text)
    index = 1
    command_start = true
    token_start = true
    quote_byte = UInt8(0)
    while index <= length(bytes)
        byte = bytes[index]
        if command_start
            byte == 0x20 && (index += 1; continue)
            start = index
            while index <= length(bytes) && bytes[index] != 0x20 && bytes[index] != 0x3b
                index += 1
            end
            name = String(bytes[start:(index-1)])
            occursin(r"\A[a-z][a-z0-9-]*\z", name) || throw(
                UnsupportedCapability(
                    :set_hook,
                    "hook command names must be literal unquoted identifiers",
                ),
            )
            command_start = false
            token_start = false
            continue
        end
        if quote_byte == 0x27
            byte == 0x27 && (quote_byte = 0)
        elseif byte == 0x5c
            index < length(bytes) || throw(ArgumentError("truncated hook escape"))
            next = bytes[index+1]
            0x20 <= next <= 0x7e && !isletter(Char(next)) && !isdigit(Char(next)) || throw(
                UnsupportedCapability(
                    :set_hook,
                    "hook escapes must quote literal punctuation; use single quotes for backslash text",
                ),
            )
            index += 1
            token_start = false
        elseif quote_byte == 0x22
            byte in (0x24, 0x7e) && throw(
                UnsupportedCapability(
                    :set_hook,
                    "hook environment and tilde expansion require the subprocess API",
                ),
            )
            byte == 0x22 && (quote_byte = 0)
        elseif byte in (0x22, 0x27)
            quote_byte = byte
            token_start = false
        elseif byte == 0x3b
            command_start = true
            token_start = true
        elseif byte == 0x20
            token_start = true
        elseif byte in (0x24, 0x7e, 0x7b, 0x7d) || (byte == 0x23 && token_start)
            throw(
                UnsupportedCapability(
                    :set_hook,
                    "hook expansion, comments and command blocks require the subprocess API",
                ),
            )
        else
            token_start = false
        end
        index += 1
    end
    quote_byte == 0 || throw(ArgumentError("unterminated hook quote"))
    text
end

"""
    set_hook(connection::ControlConnection, scope, name, command; index=nothing, kwargs...)

Store tmux command grammar using literal unquoted command names and printable
arguments, single/double quotes, literal punctuation escapes and semicolon
sequences. Environment/tilde expansion, comments, command blocks and decoded
control escapes are refused before writing. Single quotes preserve literal
backslash and dollar text. This is a deliberately bounded storage grammar;
commands must also obey the connection's trusted hook contract when executed.

Without `index`, replace the whole array; an empty body masks inherited hooks.
An indexed empty body is invalid. tmux may clear a whole array before reporting
a command parse error. Return `ControlResult` without rollback or replay.
"""
function set_hook(
    connection::ControlConnection,
    scope,
    name::AbstractString,
    command::AbstractString;
    index=nothing,
    kwargs...,
)
    body = _control_hook_body(command)
    args = _control_option_arguments(
        :set_hook,
        connection,
        scope,
        name,
        index;
        hook=true,
        kwargs...,
    )
    isempty(body) &&
        args.index !== nothing &&
        throw(ArgumentError("an empty hook body requires whole-array assignment"))
    _control_configuration_effect(args, "set-hook", body)
end

"""Unset an exact hook override or sparse entry through the pinned connection."""
function unset_hook(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    index=nothing,
    kwargs...,
)
    args = _control_option_arguments(
        :unset_hook,
        connection,
        scope,
        name,
        index;
        hook=true,
        kwargs...,
    )
    _control_configuration_effect(args, "set-hook"; unset=true)
end

"""
    get_environment(connection::ControlConnection, scope, name; inherit=false, kwargs...)

Refuse an environment read that cannot preserve `EnvironmentValue` metadata
under the admitted control grammar. tmux 3.2a through the researched 3.7 dialect
print literal environment newlines; format lookup cannot distinguish absent,
hidden and removal entries or their local/global origin. Use an explicit
`Server` read when that best-effort transport is acceptable. This method never
falls back or returns an empty value as invented metadata.
"""
function get_environment(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    inherit::Bool=false,
    kwargs...,
)
    _environment_scope_flags(scope)
    _configuration_name(name; environment=true)
    _control_configuration_context(connection, scope; kwargs...)
    throw(
        UnsupportedCapability(
            :get_environment,
            "this control grammar has no encoded environment reader preserving presence, hidden/removal and inheritance metadata",
        ),
    )
end

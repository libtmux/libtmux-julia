include("options_generated.jl")

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

"""A captured option row; an empty array has `array=true`, `index=value=nothing`."""
struct OptionEntry
    name::String
    index::Union{Nothing,Int}
    value::Union{Nothing,String}
    array::Bool
    inherited::Bool
    encoding::Symbol
end

"""A sparse hook row; `index=command=nothing` records an explicitly empty array."""
struct HookEntry
    name::String
    index::Union{Nothing,Int}
    command::Union{Nothing,String}
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

# Invert args_escape's VIS representation as data, without tmux expansion or eval.
function _configuration_literal(value::AbstractString)
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

function _configuration_rows(
    context,
    scope,
    requested_name=nothing;
    hooks=true,
    max_bytes=1024^2,
)
    flags = _option_scope_flags(scope)
    if requested_name !== nothing && !startswith(requested_name, '@')
        metadata = _configuration_metadata(context, requested_name)
        if metadata === nothing
            options, hook_rows = _configuration_inventory_legacy(context, scope, max_bytes)
            ordinary = any(row -> row.name == requested_name, options)
            hook = any(row -> row.name == requested_name, hook_rows)
            ordinary ||
                hook ||
                throw(
                    ArgumentError(
                        "option $requested_name is not defined in the requested scope",
                    ),
                )
            !hooks && hook && return _ConfigurationRow[]
        else
            metadata.scope & _configuration_scope_bit(scope) != 0 || throw(
                ArgumentError(
                    "option $requested_name is not defined in the requested scope",
                ),
            )
            !hooks && metadata.hook && return _ConfigurationRow[]
        end
    end
    args = hooks ? ["show-options", "-A", "-H", flags...] : ["show-options", "-A", flags...]
    requested_name === nothing || append!(args, ["-q", "--", requested_name])
    result = _operation_command(context, args...; max_output_bytes=max_bytes)
    text = _configuration_text(context, result)
    rows = _parse_configuration_rows(text, requested_name)
    if requested_name !== nothing && any(row -> row.body === nothing, rows)
        local_args = hooks ? ["show-options", "-H", flags...] : ["show-options", flags...]
        append!(local_args, ["-q", "--", requested_name])
        local_reply = _operation_command(context, local_args...; max_output_bytes=max_bytes)
        local_rows = _parse_configuration_rows(
            _configuration_text(context, local_reply),
            requested_name,
        )
        if isempty(local_rows)
            rows = [_ConfigurationRow(row.name, row.index, true, row.body) for row in rows]
        end
    end
    rows
end

function _parse_configuration_rows(text, requested_name=nothing)
    rows = _ConfigurationRow[]
    text === nothing && return rows
    for line in split(text, '\n')
        requested_name === nothing || startswith(line, requested_name) || continue
        parsed = match(r"\A([^\s\[\]*]+)(?:\[([^\]]*)\])?(\*)?(?: (.*))?\z", line)
        parsed === nothing && throw(ArgumentError("invalid configuration listing row"))
        name, index, inherited, body = parsed.captures
        requested_name === nothing || name == requested_name || continue
        push!(rows, _ConfigurationRow(name, index, inherited !== nothing, body))
    end
    rows
end

"""
    list_options(server, scope; inherit=false, max_bytes=1048576, kwargs...)

Capture option rows in tmux order, excluding hooks. Scopes follow `get_option`.
Values are strings; arrays retain sparse indices and explicit empty overrides.
`inherit=true` includes rows marked inherited by tmux. User options follow
the same parent scopes as `get_option`.
Encoded option metadata preserves arbitrary names when tmux advertises it.
Older versions admit portable names only, verifying the listing against exact
named reads; ambiguous names or changing values refuse acquisition. `encoding`
is `:literal` for admitted strings and `:tmux` for canonical tmux representations,
including command values and unpinned types. Each reply is bounded by `max_bytes`;
one deadline covers the call.
"""
function list_options(
    server::Server,
    scope;
    inherit::Bool=false,
    max_bytes::Int=1024^2,
    kwargs...,
)
    max_bytes >= 0 || throw(ArgumentError("max_bytes cannot be negative"))
    _option_scope_flags(scope)
    context = _configuration_context(server, scope; kwargs...)
    context = merge(
        context,
        (inventory_encoded=_configuration_inventory_admit(context, max_bytes),),
    )
    rows = _configuration_inventory_options(context, scope, inherit, max_bytes)
    inherit || filter!(row -> !row.inherited, rows)
    rows
end

function _configuration_inventory_admit(context, max_bytes)
    reply = _operation_command(
        context,
        "list-commands",
        "-F",
        "#{command_list_name}\t#{command_list_usage}";
        max_output_bytes=max_bytes,
    )
    usage = only(
        filter(
            line -> startswith(line, "show-options\t"),
            split(decode_text(reply.stdout), '\n'),
        ),
    )
    _verify_row_codec(context.server, context.started, context.budget, context.cancel)
    occursin("[-F format]", usage)
end

function _configuration_inventory(context, scope, max_bytes)
    context.inventory_encoded ||
        return _configuration_inventory_legacy(context, scope, max_bytes)
    fields = [
        "option_name",
        "option_array_key",
        "option_has_array_key",
        "option_is_parent",
        "option_is_array",
        "option_has_value",
        "option_value",
        "option_is_string",
    ]
    function capture(hooks)
        args = ["show-options", "-A"]
        hooks && push!(args, "-H")
        append!(args, _option_scope_flags(scope))
        append!(args, ["-F", _format_template(fields)])
        reply = _operation_command(context, args...; max_output_bytes=max_bytes)
        _decode_format_rows(reply.stdout, length(fields))
    end
    rows = capture(true)
    ordinary = capture(false)
    rows == capture(true) ||
        throw(InconsistentSnapshot("encoded configuration changed during acquisition"))
    key(row) = (row[1], row[2], row[3])
    captured = Dict(key(row) => row for row in rows)
    ordinary_keys = Set(key(row) for row in ordinary)
    length(captured) == length(rows) && length(ordinary_keys) == length(ordinary) ||
        throw(InconsistentSnapshot("encoded configuration has ambiguous keys"))
    for row in ordinary
        get(captured, key(row), nothing) == row ||
            throw(InconsistentSnapshot("encoded option and hook inventories changed"))
    end
    options, hooks = OptionEntry[], HookEntry[]
    for row in rows
        name = row[1]
        index =
            _observed_bool(row[3], "option_has_array_key") ? _hook_index(row[2]) : nothing
        inherited = _observed_bool(row[4], "option_is_parent")
        array = _observed_bool(row[5], "option_is_array")
        value = _observed_bool(row[6], "option_has_value") ? row[7] : nothing
        # User hooks may report option_is_hook=0; ordinary listing membership
        # is authoritative for both catalog hooks and user hooks.
        if !(key(row) in ordinary_keys)
            push!(hooks, HookEntry(name, index, value, inherited))
        else
            push!(
                options,
                OptionEntry(
                    name,
                    index,
                    value,
                    array,
                    inherited,
                    _observed_bool(row[8], "option_is_string") ? :literal : :tmux,
                ),
            )
        end
    end
    (options, hooks)
end

function _configuration_inventory_legacy(context, scope, max_bytes)
    rows = _configuration_rows(context, scope; max_bytes)
    keys = [(row.name, row.index) for row in rows]
    length(unique(keys)) == length(keys) || throw(
        UnsupportedCapability(
            :configuration_inventory,
            "ambiguous duplicate option names or indices",
        ),
    )
    for row in rows
        try
            _configuration_name(row.name)
            row.index === nothing || _hook_index(row.index)
        catch error
            error isa InterruptException && rethrow()
            throw(
                UnsupportedCapability(
                    :configuration_inventory,
                    "legacy inventory requires portable option names and numeric indices",
                ),
            )
        end
    end
    names = unique(row.name for row in rows)
    requests = Vector{String}[]
    flags = _option_scope_flags(scope)
    for name in names
        push!(requests, ["show-options", "-A", "-H", flags..., "--", name])
    end
    # Named empty arrays omit the parent marker. A local probe must remain empty
    # for each inherited header, distinguishing absence from an empty override.
    for row in rows
        row.body === nothing && row.inherited || continue
        push!(requests, ["show-options", "-H", flags..., "--", row.name])
    end
    named = _configuration_named_inventory_rows(context, requests, max_bytes)
    canonical(row) =
        (row.name, row.index, row.body, row.body === nothing ? nothing : row.inherited)
    sortkey(row) = (row.name, something(row.index, ""))
    canonical.(sort(rows; by=sortkey)) == canonical.(sort(named; by=sortkey)) ||
        throw(InconsistentSnapshot("configuration changed or listing names are ambiguous"))
    ordinary = _configuration_rows(context, scope; hooks=false, max_bytes)
    ordinary_keys = [(row.name, row.index) for row in ordinary]
    length(unique(ordinary_keys)) == length(ordinary_keys) ||
        throw(InconsistentSnapshot("ordinary option listing has ambiguous names"))
    captured = Dict((row.name, row.index) => row for row in rows)
    for row in ordinary
        prior = get(captured, (row.name, row.index), nothing)
        prior !== nothing && prior.body == row.body && prior.inherited == row.inherited ||
            throw(
                InconsistentSnapshot(
                    "option and hook inventories changed during acquisition",
                ),
            )
    end
    ordinary_names = Set(row.name for row in ordinary)
    options, hooks = OptionEntry[], HookEntry[]
    for row in rows
        index = row.index === nothing ? nothing : _hook_index(row.index)
        if row.name in ordinary_names
            literal = _configuration_string_option(context, row.name)
            value =
                row.body === nothing ? nothing :
                literal ? _configuration_literal(row.body) : row.body
            push!(
                options,
                OptionEntry(
                    row.name,
                    index,
                    value,
                    row.index !== nothing || row.body === nothing,
                    row.inherited,
                    literal ? :literal : :tmux,
                ),
            )
        else
            push!(hooks, HookEntry(row.name, index, row.body, row.inherited))
        end
    end
    (options, hooks)
end

function _configuration_named_inventory_rows(context, requests, max_bytes)
    rows = _ConfigurationRow[]
    args = String[]
    bytes = 0
    function flush!()
        isempty(args) && return
        reply = try
            _operation_command(context, args...; max_output_bytes=max_bytes)
        catch error
            error isa CommandError || rethrow()
            throw(
                InconsistentSnapshot("inventory names did not resolve during verification"),
            )
        end
        append!(rows, _parse_configuration_rows(_configuration_text(context, reply)))
        empty!(args)
    end
    for request in requests
        needed = sum(ncodeunits(arg) + 8 for arg in request)
        needed <= 8000 || throw(
            UnsupportedCapability(
                :configuration_inventory,
                "an option name exceeds the portable command framing limit",
            ),
        )
        if bytes + needed + 10 > 8000
            flush!()
            bytes = 0
        end
        isempty(args) || push!(args, ";")
        append!(args, request)
        bytes += needed + 10
    end
    flush!()
    rows
end

function _configuration_inventory_options(context, scope, inherit, max_bytes)
    rows = first(_configuration_inventory(context, scope, max_bytes))
    if inherit
        parent = _configuration_parent(context, scope)
        if parent !== nothing
            names = Set(row.name for row in rows)
            for row in _configuration_inventory_options(context, parent, true, max_bytes)
                startswith(row.name, '@') && !(row.name in names) || continue
                push!(
                    rows,
                    OptionEntry(
                        row.name,
                        row.index,
                        row.value,
                        row.array,
                        true,
                        row.encoding,
                    ),
                )
            end
        end
    end
    rows
end

function _configuration_inventory_hooks(context, scope, inherit, max_bytes)
    rows = last(_configuration_inventory(context, scope, max_bytes))
    if inherit
        parent = _configuration_parent(context, scope)
        if parent !== nothing
            names = Set(row.name for row in rows)
            for row in _configuration_inventory_hooks(context, parent, true, max_bytes)
                startswith(row.name, '@') && !(row.name in names) || continue
                push!(rows, HookEntry(row.name, row.index, row.command, true))
            end
        end
    end
    rows
end

"""
    list_hooks(server, scope; inherit=false, max_bytes=1048576, kwargs...)

Capture `HookEntry` rows without executing their command bodies.
Scopes follow `get_hook`. Empty arrays remain distinguishable from missing
overrides. `inherit=true` includes parent user hooks unless a local value,
including an empty string, overrides that name. Older tmux versions verify
portable names against exact reads and refuse ambiguous framing or changing
values. Rows are observations, not a transaction.
"""
function list_hooks(
    server::Server,
    scope;
    inherit::Bool=false,
    max_bytes::Int=1024^2,
    kwargs...,
)
    scope === :server && throw(ArgumentError("hooks do not have server scope"))
    max_bytes >= 0 || throw(ArgumentError("max_bytes cannot be negative"))
    _option_scope_flags(scope)
    context = _configuration_context(server, scope; kwargs...)
    context = merge(
        context,
        (inventory_encoded=_configuration_inventory_admit(context, max_bytes),),
    )
    rows = _configuration_inventory_hooks(context, scope, inherit, max_bytes)
    inherit || filter!(row -> !row.inherited, rows)
    rows
end

# Shell-style output is a data grammar. Newlines inside quotes are value bytes.
function _environment_rows(text, hidden, inherited)
    result = Pair{String,EnvironmentValue}[]
    text === nothing && return result
    bytes = codeunits(text)
    start, quoted, escaped = 1, false, false
    for index = 1:(length(bytes)+1)
        terminal = index > length(bytes)
        byte = terminal ? 0x0a : bytes[index]
        if !terminal && quoted
            if escaped
                escaped = false
            elseif byte == 0x5c
                escaped = true
            elseif byte == 0x22
                quoted = false
            end
            continue
        elseif !terminal && byte == 0x22
            quoted = true
            continue
        end
        byte == 0x0a || continue
        quoted && throw(ArgumentError("truncated environment value"))
        line = String(bytes[start:(index-1)])
        start = index+1
        removed = match(r"\Aunset ([A-Za-z_][A-Za-z0-9_]*);\z", line)
        if removed !== nothing
            push!(
                result,
                removed.captures[1] => EnvironmentValue(nothing, hidden, inherited),
            )
            continue
        end
        assigned = match(r"\A([A-Za-z_][A-Za-z0-9_]*)=", line)
        assigned === nothing && throw(
            UnsupportedCapability(
                :list_environment,
                "environment names outside the portable identifier grammar are not admitted",
            ),
        )
        name = assigned.captures[1]
        suffix = "\"; export $name;"
        startswith(line, "$name=\"") && endswith(line, suffix) ||
            throw(ArgumentError("invalid environment listing row"))
        quoted_value = chop(line; head=length(name)+1, tail=length(suffix)-1)
        push!(
            result,
            name =>
                EnvironmentValue(_configuration_literal(quoted_value), hidden, inherited),
        )
    end
    length(unique(first.(result))) == length(result) ||
        throw(ArgumentError("duplicate environment listing name"))
    result
end

function _list_environment(context, scope, max_bytes; inherited=false)
    flags = _environment_scope_flags(scope)
    result = Pair{String,EnvironmentValue}[]
    for hidden in (false, true)
        args = ["show-environment", flags..., "-s"]
        hidden && push!(args, "-h")
        reply = _operation_command(context, args...; max_output_bytes=max_bytes)
        append!(
            result,
            _environment_rows(_configuration_text(context, reply), hidden, inherited),
        )
    end
    length(unique(first.(result))) == length(result) || throw(
        InconsistentSnapshot("environment changed between visible and hidden inventories"),
    )
    result
end

"""
    list_environment(server, scope; inherit=false, max_bytes=1048576, kwargs...)

Return captured `name => EnvironmentValue` pairs, including hidden entries and
removal markers. Scopes are `:global` or `SessionRef`. Session entries override
global entries, including explicit removals. Values retain literal newlines,
quotes and backslashes; shell-style replies are never evaluated. Names outside
`[A-Za-z_][A-Za-z0-9_]*` raise `UnsupportedCapability` rather than disappear.
Hidden, visible and inherited rows span separate bounded observations.
"""
function list_environment(
    server::Server,
    scope;
    inherit::Bool=false,
    max_bytes::Int=1024^2,
    kwargs...,
)
    max_bytes >= 0 || throw(ArgumentError("max_bytes cannot be negative"))
    _environment_scope_flags(scope)
    context = _configuration_context(server, scope; kwargs...)
    rows = _list_environment(context, scope, max_bytes)
    if inherit && scope isa SessionRef
        names = Set(first.(rows))
        append!(
            rows,
            filter(
                row -> !(first(row) in names),
                _list_environment(context, :global, max_bytes; inherited=true),
            ),
        )
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

_configuration_scope_bit(scope) =
    scope === :server ? 1 :
    scope === :global_session || scope isa SessionRef ? 2 :
    scope === :global_window || scope isa WindowRef ? 4 : 8

function _configuration_metadata(context, name)
    metadata = _tmux_option_metadata(name)
    if metadata === nothing && _tmux_option_versioned(name)
        result = _operation_command(context, "display-message", "-p", "#{version}")
        version = _configuration_text(result)
        version === nothing || (metadata = _tmux_option_metadata(name, version))
    end
    metadata
end

function _configuration_string_option(context, name)
    startswith(name, '@') && return true
    metadata = _configuration_metadata(context, name)
    metadata !== nothing && metadata.kind === :string
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
    matches = filter(r -> r.index == key_index, rows)
    isempty(matches) && return nothing
    if _configuration_string_option(context, name)
        return _configuration_literal(something(only(matches).body))
    end
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
`nothing`. String options preserve literal control bytes and backslashes.
Use `get_hook` to read an entire command array.

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
        _operation_command(context, "show-environment", flags..., "-s", "--", name)
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
        result = _operation_command(
            context,
            "show-environment",
            flags...,
            "-s",
            "-h",
            "--",
            name,
        )
    end
    text = _configuration_text(context, result)
    text == "unset $name;" && return EnvironmentValue(nothing, hidden, inherited)
    suffix = "; export $name;"
    text !== nothing && startswith(text, "$name=\"") && endswith(text, "\"" * suffix) ||
        throw(ArgumentError("invalid environment reply for $name"))
    quoted = chop(text; head=length(name)+1, tail=length(suffix))
    EnvironmentValue(_configuration_literal(quoted), hidden, inherited)
end

"""
    get_environment(server, scope, name; inherit=false, kwargs...)

Read a global (`:global`) or session (`SessionRef`) environment entry. Return
`nothing` when absent, or `EnvironmentValue(value, hidden, inherited)`.
`value=nothing` is a removal marker for new processes; `value=""` is empty.
Hidden entries are returned with `hidden=true`. `inherit=true` falls back to
global only for an absent session entry, never for a removal marker. This
explicit multi-command observation is not an atomic child-process environment.
Values retain literal control bytes, quotes and backslashes; tmux's shell-style
reply is decoded as data, never executed. Variable names use
`[A-Za-z_][A-Za-z0-9_]*`.
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

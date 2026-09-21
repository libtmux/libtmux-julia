"""A criteria document error with a stable code and structural location."""
struct WireCriteriaError <: LibTmuxError
    code::Symbol
    path::String
    message::String
end
Base.showerror(io::IO, e::WireCriteriaError) =
    print(io, "criteria ", e.code, " at ", e.path, ": ", e.message)
_wire_error(code, path, message) = throw(WireCriteriaError(code, path, message))

"""
    WhereLimits(; max_depth=32, max_nodes=4096, max_string_bytes=65536,
                max_items=1024, max_bytes=1048576)

Bound the complete inert document before constructing predicates. Nodes count
objects, arrays, keys and scalars; bytes count UTF-8 strings and keys together.
Limits also apply when encoding local criteria. They do not limit later graph
traversal, which depends on the supplied snapshot.
"""
struct WhereLimits
    max_depth::Int
    max_nodes::Int
    max_string_bytes::Int
    max_items::Int
    max_bytes::Int
    function WhereLimits(;
        max_depth::Int=32,
        max_nodes::Int=4096,
        max_string_bytes::Int=65536,
        max_items::Int=1024,
        max_bytes::Int=1048576,
    )
        all(>(0), (max_depth, max_nodes, max_string_bytes, max_items, max_bytes)) ||
            throw(ArgumentError("criteria limits must be positive"))
        max_depth <= 128 || throw(ArgumentError("maximum criteria depth is 128"))
        new(max_depth, max_nodes, max_string_bytes, max_items, max_bytes)
    end
end

"""
An inert object retaining key pairs, including duplicates, until validation.
External codecs must preserve duplicate keys or reject them during parsing.
An ordinary `Dict` cannot reveal keys discarded before `decode_where` runs.
"""
struct WireObject
    pairs::Vector{Pair{String,Any}}
    WireObject(pairs) = new(Pair{String,Any}[String(k) => v for (k, v) in pairs])
end
_wire_pairs(value::AbstractDict) = pairs(value)
_wire_pairs(value::WireObject) = value.pairs
_wire_isobject(value) = value isa Union{AbstractDict,WireObject}
const _WIRE_SCHEMA = "libtmux.julia.where"
const _WIRE_ENTITIES = Dict(
    "pane"=>:pane,
    "window"=>:window,
    "session"=>:session,
    "client"=>:client,
    "windowlink"=>:windowlink,
)
const _WIRE_CONSTRUCTORS = Dict(
    :pane=>PaneWhere,
    :window=>WindowWhere,
    :session=>SessionWhere,
    :client=>ClientWhere,
    :windowlink=>WindowLinkWhere,
)
const _WIRE_SAFE_INTEGER = Int64(9007199254740991)

"""
    read_where_json(text; limits=WhereLimits(), max_input_bytes=8388608)

Read criteria JSON after `using JSON` loads the optional codec extension.
Input byte, nesting and token bounds are checked before JSON materialization;
duplicate keys and invalid JSON raise `WireCriteriaError`.
"""
function read_where_json end

"""Write criteria JSON after `using JSON` loads the optional codec extension."""
function write_where_json end

function _wire_preflight(value, limits, counts, depth=1, path="\$")
    depth <= limits.max_depth || _wire_error(:limit, path, "nesting depth exceeded")
    counts[1] += 1
    counts[1] <= limits.max_nodes || _wire_error(:limit, path, "node count exceeded")
    if _wire_isobject(value)
        entries = _wire_pairs(value)
        length(entries) <= limits.max_items ||
            _wire_error(:limit, path, "object size exceeded")
        seen = Set{String}()
        for (key, item) in entries
            key isa AbstractString ||
                _wire_error(:type, path, "object keys must be strings")
            _wire_preflight(key, limits, counts, depth+1, path)
            key in seen && _wire_error(:duplicate, path, "duplicate object key")
            push!(seen, key)
            _wire_preflight(item, limits, counts, depth+1, path)
        end
    elseif value isa AbstractVector
        length(value) <= limits.max_items ||
            _wire_error(:limit, path, "array size exceeded")
        for item in value
            _wire_preflight(item, limits, counts, depth+1, path)
        end
    elseif value isa AbstractString
        ncodeunits(value) <= limits.max_string_bytes ||
            _wire_error(:limit, path, "string size exceeded")
        isvalid(value) || _wire_error(:value, path, "strings must contain valid UTF-8")
        counts[2] += ncodeunits(value)
        counts[2] <= limits.max_bytes ||
            _wire_error(:limit, path, "total string bytes exceeded")
    elseif value isa Union{Nothing,Bool}
        nothing
    elseif value isa Integer && isbitstype(typeof(value))
        -_WIRE_SAFE_INTEGER <= value <= _WIRE_SAFE_INTEGER ||
            _wire_error(:value, path, "integer exceeds the exact JSON numeric range")
    elseif value isa Union{Float16,Float32,Float64}
        isfinite(value) || _wire_error(:value, path, "numbers must be finite")
    else
        _wire_error(:type, path, "expected inert objects, arrays or JSON scalars")
    end
    nothing
end

function _wire_object(value, names, path)
    _wire_isobject(value) || _wire_error(:type, path, "expected object")
    object = Dict{String,Any}(_wire_pairs(value))
    Set(keys(object)) == Set(names) ||
        _wire_error(:shape, path, "unexpected or missing object keys")
    object
end
function _wire_array(value, path)
    value isa AbstractVector || _wire_error(:type, path, "expected array")
    value
end
function _wire_getop(value, path)
    _wire_isobject(value) || _wire_error(:type, path, "expected predicate object")
    object = Dict{String,Any}(_wire_pairs(value))
    op = get(object, "op", nothing)
    op isa AbstractString || _wire_error(:shape, path, "expected string operator")
    op
end

function _wire_scalar(value)
    value isa TmuxID && return string(value)
    value isa ClientID && return Dict("name"=>value.name, "incarnation"=>value.incarnation)
    value isa Union{Nothing,Bool,AbstractString,Integer,AbstractFloat} && return value
    _wire_error(:unsupported, "\$", "operand has no lossless scalar encoding")
end

function _wire_operator(op)
    for (Type, name) in (
        (Filters.EqualTo, "eq"),
        (Filters.NotEqualTo, "ne"),
        (Filters.AtLeast, "ge"),
        (Filters.AtMost, "le"),
        (Filters.GreaterThan, "gt"),
        (Filters.LessThan, "lt"),
    )
        op isa Type && return Dict("op"=>name, "value"=>_wire_scalar(op.value))
    end
    op isa Filters.OneOf &&
        return Dict("op"=>"in", "values"=>[_wire_scalar(v) for v in op.values])
    for (Type, name) in (
        (Filters.Contains, "contains"),
        (Filters.StartsWith, "startsWith"),
        (Filters.EndsWith, "endsWith"),
    )
        op isa Type && return Dict("op"=>name, "value"=>op.value, "case"=>string(op.case))
    end
    for (Type, name) in (
        (Filters.AnyRelated, "anyRelated"),
        (Filters.AllRelated, "allRelated"),
        (Filters.NoRelated, "noRelated"),
    )
        op isa Type && return Dict("op"=>name, "where"=>_wire_node(op.criterion))
    end
    op isa Criterion && return Dict("op"=>"is", "where"=>_wire_node(op))
    _wire_error(:unsupported, "\$", "criterion operator is not portable")
end
function _wire_node(q::Criterion)
    q isa Filters.AllOf &&
        return Dict("op"=>"all", "args"=>[_wire_node(c) for c in q.criteria])
    q isa Filters.AnyOf &&
        return Dict("op"=>"any", "args"=>[_wire_node(c) for c in q.criteria])
    q isa Filters.Not && return Dict("op"=>"not", "arg"=>_wire_node(q.criterion))
    entity = _criterion_entity(q)
    haskey(_WIRE_CONSTRUCTORS, entity) && q isa _WIRE_CONSTRUCTORS[entity] ||
        _wire_error(:unsupported, "\$", "only built-in criteria are portable")
    Dict(
        "op"=>"fields",
        "fields"=>[
            Dict(
                "field"=>_FIELD_WIRE[(entity, clause.field)],
                "match"=>_wire_operator(clause.constraint),
            ) for clause in getfield(q, :_clauses)
        ],
    )
end

"""
    encode_where(q::Criterion; entity=nothing, limits=WhereLimits())

Return owned inert data in the `libtmux.julia.where` version 1 profile.
Field identities come from the explicit field catalog. This is not a
TypeScript or Rust envelope. Callbacks and native regex are not portable.
Empty Boolean criteria require an explicit entity, such as `entity=:pane`.
Integer operands must fit JSON's exact +/-9007199254740991 numeric range.
"""
function encode_where(q::Criterion; entity=nothing, limits::WhereLimits=WhereLimits())
    inferred = _criterion_entity(q)
    kind = entity === nothing ? inferred : entity
    haskey(_WIRE_CONSTRUCTORS, kind) ||
        throw(ArgumentError("specify a supported criteria entity"))
    inferred in (:any, kind) ||
        throw(ArgumentError("criteria entity does not match requested envelope"))
    # Check structure before recursively allocating an external document.
    _wire_check_criterion(q, limits, Ref(0), 1)
    result = Dict(
        "schema"=>_WIRE_SCHEMA,
        "version"=>1,
        "entity"=>string(kind),
        "where"=>_wire_node(q),
    )
    _wire_preflight(result, limits, [0, 0])
    result
end
function _wire_check_criterion(q, limits, count, depth)
    depth <= limits.max_depth ||
        _wire_error(:limit, "\$", "criteria nesting depth exceeded")
    count[] += 1
    count[] <= limits.max_nodes || _wire_error(:limit, "\$", "criteria node count exceeded")
    if q isa Union{Filters.AllOf,Filters.AnyOf}
        length(q.criteria) <= limits.max_items ||
            _wire_error(:limit, "\$", "criteria child count exceeded")
        for child in q.criteria
            _wire_check_criterion(child, limits, count, depth+1)
        end
    elseif q isa Filters.Not
        _wire_check_criterion(q.criterion, limits, count, depth+1)
    else
        entity = _criterion_entity(q)
        haskey(_WIRE_CONSTRUCTORS, entity) && q isa _WIRE_CONSTRUCTORS[entity] ||
            _wire_error(:unsupported, "\$", "only built-in criteria are portable")
        for clause in getfield(q, :_clauses)
            op = clause.constraint
            if op isa Criterion
                _wire_check_criterion(op, limits, count, depth+1)
            elseif op isa Filters.Related
                _wire_check_criterion(op.criterion, limits, count, depth+1)
            elseif op isa Filters.OneOf
                length(op.values) <= limits.max_items ||
                    _wire_error(:limit, "\$", "membership size exceeded")
            end
        end
    end
end

function _decode_wire_scalar(value, spec, path)
    if spec.type in (:PaneID, :WindowID, :SessionID) && value !== nothing
        value isa AbstractString || _wire_error(:type, path, "entity IDs must be strings")
        Type =
            spec.type === :PaneID ? PaneID : spec.type === :WindowID ? WindowID : SessionID
        try
            return Type(value)
        catch error
            error isa ArgumentError || rethrow()
            _wire_error(:value, path, "invalid entity ID")
        end
    elseif spec.type === :ClientID && value !== nothing
        object = _wire_object(value, ("name", "incarnation"), path)
        all(x -> x isa AbstractString, values(object)) ||
            _wire_error(:type, path, "client ID parts must be strings")
        try
            return ClientID(object["name"], object["incarnation"])
        catch error
            error isa ArgumentError || rethrow()
            _wire_error(:value, path, "invalid client identity")
        end
    end
    value isa AbstractString ? String(value) : value
end
function _decode_wire_operator(value, spec, path)
    op = _wire_getop(value, path)
    if op in ("is", "anyRelated", "allRelated", "noRelated")
        spec.relation !== :scalar ||
            _wire_error(:type, path, "relation operator on scalar field")
        object = _wire_object(value, ("op", "where"), path)
        child = _decode_wire_node(object["where"], spec.target, path * ".where")
        op == "is" && return child
        return op == "anyRelated" ? Filters.AnyRelated(child) :
               op == "allRelated" ? Filters.AllRelated(child) : Filters.NoRelated(child)
    elseif op == "in"
        object = _wire_object(value, ("op", "values"), path)
        return Filters.OneOf(
            _decode_wire_scalar(v, spec, path * ".values") for
            v in _wire_array(object["values"], path * ".values")
        )
    elseif op in ("contains", "startsWith", "endsWith")
        object = _wire_object(value, ("op", "value", "case"), path)
        object["value"] isa AbstractString ||
            _wire_error(:type, path, "text operand must be a string")
        mode = object["case"]
        mode in ("sensitive", "ascii_insensitive") ||
            _wire_error(:unsupported, path, "unsupported case policy")
        Type =
            op == "contains" ? Filters.Contains :
            op == "startsWith" ? Filters.StartsWith : Filters.EndsWith
        return Type(
            object["value"];
            case=mode == "sensitive" ? :sensitive : :ascii_insensitive,
        )
    elseif op in ("eq", "ne", "ge", "le", "gt", "lt")
        object = _wire_object(value, ("op", "value"), path)
        operand = _decode_wire_scalar(object["value"], spec, path * ".value")
        Type =
            op == "eq" ? Filters.EqualTo :
            op == "ne" ? Filters.NotEqualTo :
            op == "ge" ? Filters.AtLeast :
            op == "le" ? Filters.AtMost :
            op == "gt" ? Filters.GreaterThan : Filters.LessThan
        return Type(operand)
    end
    _wire_error(:unsupported, path, "unknown operator")
end
function _decode_wire_node(value, entity, path)
    op = _wire_getop(value, path)
    if op in ("all", "any")
        object = _wire_object(value, ("op", "args"), path)
        args = _wire_array(object["args"], path * ".args")
        children = Criterion[
            _decode_wire_node(arg, entity, path * ".args[$i]") for
            (i, arg) in enumerate(args)
        ]
        return op == "all" ? Filters.AllOf(children...) : Filters.AnyOf(children...)
    elseif op == "not"
        object = _wire_object(value, ("op", "arg"), path)
        return Filters.Not(_decode_wire_node(object["arg"], entity, path * ".arg"))
    elseif op == "fields"
        object = _wire_object(value, ("op", "fields"), path)
        clauses = _FieldClause[]
        seen = Set{Symbol}()
        for (i, entry) in enumerate(_wire_array(object["fields"], path * ".fields"))
            location = path * ".fields[$i]"
            field = _wire_object(entry, ("field", "match"), location)
            key = field["field"]
            key isa AbstractString ||
                _wire_error(:type, location, "field identity must be a string")
            identity = get(_WIRE_FIELDS, key, nothing)
            identity !== nothing && identity[1] === entity ||
                _wire_error(:field, location, "unknown field for this entity")
            name = identity[2]
            name in seen && _wire_error(
                :duplicate,
                location,
                "field constrained twice in one fields node",
            )
            push!(seen, name)
            spec = _CRITERIA_FIELDS[identity]
            constraint = _decode_wire_operator(field["match"], spec, location * ".match")
            _validate_constraint(entity, name, spec, constraint)
            push!(clauses, _FieldClause(name, constraint))
        end
        # Fixed generated types; arbitrary wire shapes never create Julia types.
        return _WIRE_CONSTRUCTORS[entity](Tuple(clauses), Val(:validated))
    end
    _wire_error(:unsupported, path, "unknown predicate node")
end

"""
    decode_where(data; limits=WhereLimits()) -> Criterion

Validate a versioned inert document and return a captured-data predicate.
This performs no tmux I/O or code evaluation. Unknown keys/operators, duplicate
keys/fields, wrong types, unsupported versions and exceeded limits error.
Use a duplicate-preserving codec or `WireObject` at external boundaries.
The returned criterion owns its operand values independently of `data`.
"""
function decode_where(data; limits::WhereLimits=WhereLimits())
    _wire_preflight(data, limits, [0, 0])
    envelope = _wire_object(data, ("schema", "version", "entity", "where"), "\$")
    envelope["schema"] == _WIRE_SCHEMA ||
        _wire_error(:schema, "\$.schema", "unsupported schema")
    version = envelope["version"]
    version isa Integer && !(version isa Bool) && version == 1 ||
        _wire_error(:version, "\$.version", "unsupported schema version")
    entity = get(_WIRE_ENTITIES, envelope["entity"], nothing)
    entity === nothing && _wire_error(:entity, "\$.entity", "unknown criteria entity")
    try
        _decode_wire_node(envelope["where"], entity, "\$.where")
    catch error
        error isa ArgumentError || rethrow()
        _wire_error(:value, "\$.where", sprint(showerror, error))
    end
end

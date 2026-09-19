"""A criterion outside a named sibling profile's verified portable subset."""
struct UnsupportedCriterion <: LibTmuxError
    profile::Symbol
    path::String
    reason::String
end
Base.showerror(io::IO, error::UnsupportedCriterion) =
    print(io, error.profile, " criterion at ", error.path, ": ", error.reason)
_sibling_error(profile, path, reason) = throw(UnsupportedCriterion(profile, path, reason))

# Explicit intersection of the pinned sibling pane schemas, not every format.
const _SIBLING_PANE_FIELDS = Dict(
    "pane_" * string(name) => name for name in (
        :id,
        :index,
        :active,
        :dead,
        :width,
        :height,
        :current_command,
        :current_path,
        :title,
    )
)
const _SIBLING_FIELD_TOKENS =
    Dict(_FIELD_WIRE[(:pane, name)] => token for (token, name) in _SIBLING_PANE_FIELDS)

function _sibling_field(token, profile, path)
    token isa AbstractString && haskey(_SIBLING_PANE_FIELDS, token) ||
        _sibling_error(profile, path, "field is outside the pane scalar subset")
    name = _SIBLING_PANE_FIELDS[token]
    name, _CRITERIA_FIELDS[(:pane, name)]
end

function _sibling_scalar(value, token, profile, path; decoding=false)
    _, spec = _sibling_field(token, profile, path)
    value === nothing && _sibling_error(profile, path, "null semantics are not shared")
    if spec.type === :Bool
        if decoding && profile === :typescript_v1
            value isa AbstractString && value in ("0", "1") ||
                _sibling_error(profile, path, "Boolean wire values must be \"0\" or \"1\"")
            return value == "1"
        end
        value isa Bool || _sibling_error(profile, path, "expected Boolean")
        return profile === :typescript_v1 ? (value ? "1" : "0") : value
    elseif spec.type === :Integer
        parsed = if decoding
            value isa AbstractString ||
                _sibling_error(profile, path, "expected canonical decimal text")
            tryparse(UInt32, value)
        else
            value isa Integer && !(value isa Bool) && 0 <= value <= typemax(UInt32) ||
                _sibling_error(
                    profile,
                    path,
                    "integer must fit the shared unsigned 32-bit domain",
                )
            UInt32(value)
        end
        parsed === nothing &&
            _sibling_error(profile, path, "invalid unsigned 32-bit integer")
        decoding &&
            string(parsed) != value &&
            _sibling_error(profile, path, "integer text must be canonical")
        return decoding ? Int64(parsed) : string(parsed)
    end
    value isa AbstractString || _sibling_error(profile, path, "expected text")
    if spec.type === :PaneID
        id = try
            PaneID(value)
        catch error
            error isa ArgumentError || rethrow()
            _sibling_error(profile, path, "invalid pane identity")
        end
        return decoding ? id : string(id)
    end
    String(value)
end

function _sibling_join(kind, children, profile, path)
    isempty(children) &&
        _sibling_error(profile, path, "empty criteria have no shared constant encoding")
    length(children) == 1 && return only(children)
    kind === :all ? Filters.AllOf(children...) : Filters.AnyOf(children...)
end

function _sibling_leaf(token, op, value, profile, path)
    name, spec = _sibling_field(token, profile, path)
    constraint = if op == "eq"
        Filters.EqualTo(_sibling_scalar(value, token, profile, path; decoding=true))
    elseif op == "in"
        values = _wire_array(value, path)
        Filters.OneOf(
            _sibling_scalar(v, token, profile, path; decoding=true) for v in values
        )
    elseif op in ("contains", "startsWith", "endsWith")
        spec.type === :String && value isa AbstractString || _sibling_error(
            profile,
            path,
            "text matching requires a text field and operand",
        )
        Type =
            op == "contains" ? Filters.Contains :
            op == "startsWith" ? Filters.StartsWith : Filters.EndsWith
        Type(value)
    else
        _sibling_error(profile, path, "operator is outside the verified shared subset")
    end
    PaneWhere(; name => constraint)
end

function _decode_typescript_node(value, path)
    profile = :typescript_v1
    _wire_isobject(value) || _sibling_error(profile, path, "expected criteria object")
    children = Criterion[]
    for (key, entry) in _wire_pairs(value)
        location = path * "." * key
        if key in ("AND", "OR", "NOT")
            nested = Criterion[
                _decode_typescript_node(item, location * "[$i]") for
                (i, item) in enumerate(_wire_array(entry, location))
            ]
            key == "NOT" && (nested = Criterion[Filters.Not(child) for child in nested])
            push!(
                children,
                _sibling_join(key == "OR" ? :any : :all, nested, profile, location),
            )
        elseif _wire_isobject(entry)
            _sibling_field(key, profile, location)
            isempty(_wire_pairs(entry)) &&
                _sibling_error(profile, location, "empty operator object")
            for (operator, operand) in _wire_pairs(entry)
                op = operator == "equals" ? "eq" : operator
                push!(children, _sibling_leaf(key, op, operand, profile, location))
            end
        else
            push!(children, _sibling_leaf(key, "eq", entry, profile, location))
        end
    end
    _sibling_join(:all, children, profile, path)
end

function _decode_rust_node(value, path)
    profile = :rust_v1
    op = _wire_getop(value, path)
    if op in ("and", "or")
        object = _wire_object(value, ("op", "args"), path)
        args = _wire_array(object["args"], path * ".args")
        length(args) >= 2 || _sibling_error(
            profile,
            path,
            "Rust Boolean nodes require at least two children",
        )
        children = Criterion[
            _decode_rust_node(arg, path * ".args[$i]") for (i, arg) in enumerate(args)
        ]
        return _sibling_join(op == "and" ? :all : :any, children, profile, path)
    elseif op == "not"
        object = _wire_object(value, ("op", "expr"), path)
        return Filters.Not(_decode_rust_node(object["expr"], path * ".expr"))
    end
    object = _wire_object(value, ("op", "field", "value"), path)
    shared_op = op == "starts_with" ? "startsWith" : op == "ends_with" ? "endsWith" : op
    _sibling_leaf(object["field"], shared_op, object["value"], profile, path)
end

function _decode_sibling(data, profile, limits)
    _wire_preflight(data, limits, [0, 0])
    try
        ts = profile === :typescript_v1
        entity_key, node_key = ts ? ("model", "where") : ("target", "expr")
        envelope = _wire_object(data, ("version", entity_key, node_key), "\$")
        envelope["version"] isa Integer &&
        !(envelope["version"] isa Bool) &&
        envelope["version"] == 1 ||
            _sibling_error(profile, "\$.version", "expected version 1")
        envelope[entity_key] == "pane" ||
            _sibling_error(profile, "\$", "only pane criteria are supported")
        ts ? _decode_typescript_node(envelope[node_key], "\$.where") :
        _decode_rust_node(envelope[node_key], "\$.expr")
    catch error
        error isa WireCriteriaError || rethrow()
        _sibling_error(profile, error.path, error.message)
    end
end

function _encode_sibling_leaf(field, profile, path)
    token = get(_SIBLING_FIELD_TOKENS, field["field"], nothing)
    token === nothing &&
        _sibling_error(profile, path, "field is outside the pane scalar subset")
    match = field["match"]
    op = match["op"]
    if op == "ne"
        equal = Dict(
            "field"=>field["field"],
            "match"=>Dict("op"=>"eq", "value"=>match["value"]),
        )
        child = _encode_sibling_leaf(equal, profile, path)
        return profile === :typescript_v1 ? Dict("NOT"=>[child]) :
               Dict("op"=>"not", "expr"=>child)
    end
    value = if op == "eq"
        _sibling_scalar(match["value"], token, profile, path)
    elseif op == "in"
        [_sibling_scalar(v, token, profile, path) for v in match["values"]]
    elseif op in ("contains", "startsWith", "endsWith")
        match["case"] == "sensitive" ||
            _sibling_error(profile, path, "case-folding policies are not shared")
        match["value"]
    else
        _sibling_error(profile, path, "operator is outside the verified shared subset")
    end
    if profile === :typescript_v1
        return Dict(token => op == "eq" ? value : Dict(op=>value))
    end
    rust_op = op == "startsWith" ? "starts_with" : op == "endsWith" ? "ends_with" : op
    Dict("op"=>rust_op, "field"=>token, "value"=>value)
end

function _encode_sibling_node(node, profile, path)
    op = node["op"]
    if op == "not"
        child = _encode_sibling_node(node["arg"], profile, path * ".arg")
        return profile === :typescript_v1 ? Dict("NOT"=>[child]) :
               Dict("op"=>"not", "expr"=>child)
    end
    children = if op == "fields"
        [_encode_sibling_leaf(field, profile, path) for field in node["fields"]]
    else
        [_encode_sibling_node(child, profile, path * ".args") for child in node["args"]]
    end
    isempty(children) &&
        _sibling_error(profile, path, "empty criteria have no shared constant encoding")
    length(children) == 1 && return only(children)
    if profile === :typescript_v1
        return Dict((op == "any" ? "OR" : "AND") => children)
    end
    Dict("op"=>(op == "any" ? "or" : "and"), "args"=>children)
end

function _encode_sibling(q, profile, limits)
    _wire_check_criterion(q, limits, Ref(0), 1)
    _criterion_entity(q) in (:pane, :any) ||
        _sibling_error(profile, "\$", "only pane criteria are supported")
    document = encode_where(q; entity=:pane, limits)
    node = _encode_sibling_node(document["where"], profile, "\$")
    result =
        profile === :typescript_v1 ? Dict("version"=>1, "model"=>"pane", "where"=>node) :
        Dict("version"=>1, "target"=>"pane", "expr"=>node)
    _wire_preflight(result, limits, [0, 0])
    result
end

"""
    decode_typescript_where(data; limits=WhereLimits()) -> Criterion

Import the pinned TypeScript version-1 `version/model/where` wire profile's
verified pane scalar subset. Boolean and integer wire operands use canonical
strings. Support equality, membership, case-sensitive text and nonempty Boolean
composition. `NOT` arrays mean every child is false. Relations, null, aliases,
case folding and other operators raise `UnsupportedCriterion`.

Preflight bounds and duplicate checks run before translation. Supply captured,
available field values when comparing ports; absent/uncaptured graph states are
outside this profile. No I/O or JSON dependency is introduced.
"""
decode_typescript_where(data; limits::WhereLimits=WhereLimits()) =
    _decode_sibling(data, :typescript_v1, limits)

"""Export owned inert data for the same subset as `decode_typescript_where`."""
encode_typescript_where(q::Criterion; limits::WhereLimits=WhereLimits()) =
    _encode_sibling(q, :typescript_v1, limits)

"""
    decode_rust_where(data; limits=WhereLimits()) -> Criterion

Import the pinned Rust version-1 `version/target/expr` wire profile's verified
pane scalar subset. Boolean values remain Boolean; integer operands are
canonical unsigned 32-bit decimal strings. The supported meanings and
refusals match `decode_typescript_where`. Rust `and`/`or` require two children.
"""
decode_rust_where(data; limits::WhereLimits=WhereLimits()) =
    _decode_sibling(data, :rust_v1, limits)

"""Export owned inert data for the same subset as `decode_rust_where`."""
encode_rust_where(q::Criterion; limits::WhereLimits=WhereLimits()) =
    _encode_sibling(q, :rust_v1, limits)

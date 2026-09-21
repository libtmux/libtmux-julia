function _source_path(path)
    path === nothing && return nothing
    path = _string(path, "\$.source_path"; empty=false)
    isabspath(path) || _fail(:path, "\$.source_path", "source_path must be absolute")
    normpath(path)
end

# Syntax belongs to JSON; this scan bounds its work before recursive parsing.
function _json_bounds(text, limits)
    quoted, escaped, scalar = false, false, false
    depth, nodes = 0, 0
    for byte in codeunits(text)
        if quoted
            if escaped
                escaped = false
            elseif byte == UInt8('\\')
                escaped = true
            elseif byte == UInt8('"')
                quoted = false
            end
        elseif byte == UInt8('"')
            quoted, scalar = true, false
            nodes += 1
        elseif byte in (UInt8('{'), UInt8('['))
            depth += 1
            nodes += 1
            scalar = false
            depth <= limits.max_depth || _fail(:limit, "\$", "JSON nesting limit exceeded")
        elseif byte in (UInt8('}'), UInt8(']'))
            depth -= 1
            scalar = false
        elseif byte in (0x20, 0x09, 0x0a, 0x0d, UInt8(','), UInt8(':'))
            scalar = false
        elseif !scalar
            scalar = true
            nodes += 1
        end
        nodes <= limits.max_nodes || _fail(:limit, "\$", "JSON value count limit exceeded")
    end
end

# Event admission runs before YAML's recursive composer and constructors.
# These YAML 0.4 APIs are covered by the dependency admission tests.
function _yaml_bounds(text, limits)
    events = YAML.EventStream(YAML.TokenStream(IOBuffer(text)))
    depth, nodes, documents = 0, 0, 0
    while true
        event = YAML.forward!(events)
        event === nothing && break
        if event isa YAML.DocumentStartEvent
            documents += 1
            documents <= 1 ||
                _fail(:documents, "\$", "exactly one YAML document is required")
        elseif event isa YAML.AliasEvent
            _fail(:unsupported, "\$", "YAML aliases are not supported")
        elseif event isa
               Union{YAML.MappingStartEvent,YAML.SequenceStartEvent,YAML.ScalarEvent}
            nodes += 1
            event.anchor === nothing ||
                _fail(:unsupported, "\$", "YAML anchors are not supported")
            tag = event.tag
            tag === nothing ||
                tag in (
                    "tag:yaml.org,2002:map",
                    "tag:yaml.org,2002:seq",
                    "tag:yaml.org,2002:str",
                    "tag:yaml.org,2002:int",
                    "tag:yaml.org,2002:bool",
                    "tag:yaml.org,2002:null",
                    "tag:yaml.org,2002:float",
                ) ||
                _fail(:unsupported, "\$", "YAML tag is outside the JSON-compatible subset")
            if !(event isa YAML.ScalarEvent)
                depth += 1
                depth <= limits.max_depth ||
                    _fail(:limit, "\$", "YAML nesting limit exceeded")
            end
        elseif event isa Union{YAML.MappingEndEvent,YAML.SequenceEndEvent}
            depth -= 1
        end
        nodes <= limits.max_nodes || _fail(:limit, "\$", "YAML value count limit exceeded")
    end
end

function _yaml_mapping(constructor, node)
    result = Dict{String,Any}()
    for (keynode, valuenode) in node.value
        keynode.tag == "tag:yaml.org,2002:merge" &&
            _fail(:unsupported, "\$", "YAML merge keys are not supported")
        key = YAML.construct_object(constructor, keynode)
        key isa AbstractString || _fail(:type, "\$", "mapping keys must be strings")
        haskey(result, key) && _fail(:duplicate, "\$", "duplicate YAML mapping key")
        result[String(key)] = YAML.construct_object(constructor, valuenode)
    end
    result
end

"""
    parse_config(text; format=:yaml, source_path=nothing, limits=ConfigLimits())

Parse one bounded UTF-8 YAML or JSON document. Reject duplicate keys before
collapse, YAML aliases/merges and non-JSON tags. Preserve inert command text.
A supplied source path must be absolute; parsing never reads that path.
"""
function parse_config(
    text::AbstractString;
    format::Symbol=:yaml,
    source_path=nothing,
    limits::ConfigLimits=ConfigLimits(),
)
    ncodeunits(text) <= limits.max_bytes ||
        _fail(:limit, "\$", "document byte limit exceeded")
    isvalid(text) || _fail(:encoding, "\$", "document must contain valid UTF-8")
    source = _source_path(source_path)
    format in (:yaml, :json) || throw(ArgumentError("format must be :yaml or :json"))
    data = try
        if format == :json
            _json_bounds(text, limits)
            JSON.parse(
                text;
                dicttype=Dict{String,Any},
                duplicate_keys=:error,
                allownan=false,
            )
        else
            _yaml_bounds(text, limits)
            YAML.load(text, Dict("tag:yaml.org,2002:map" => _yaml_mapping))
        end
    catch error
        error isa WorkspaceConfigError && rethrow()
        error isa JSON.DuplicateKeyError &&
            _fail(:duplicate, "\$", "duplicate JSON object key")
        error isa InterruptException && rethrow()
        error isa OutOfMemoryError && rethrow()
        # Parser diagnostics can echo credentials embedded in configuration.
        _fail(:syntax, "\$", "invalid $(format) document")
    end
    _bound_data(data, limits)
    WorkspaceDocument(data, source, limits)
end

"""
    read_config(path; format=nothing, limits=ConfigLimits()) -> WorkspaceDocument

Read at most `max_bytes + 1` bytes from an explicitly supplied file. Infer YAML
from `.yaml`/`.yml` and JSON from `.json`; otherwise require `format`.
The absolute source path supplies the default directory during `expand`.
"""
function read_config(
    path::AbstractString;
    format=nothing,
    limits::ConfigLimits=ConfigLimits(),
)
    path = _string(path, "\$.source_path"; empty=false)
    if format === nothing
        extension = lowercase(splitext(path)[2])
        format =
            extension in (".yaml", ".yml") ? :yaml :
            extension == ".json" ? :json :
            throw(ArgumentError("unknown file extension; specify format=:yaml or :json"))
    end
    bytes = open(path, "r") do io
        read(io, limits.max_bytes + 1)
    end
    parse_config(String(bytes); format, source_path=abspath(path), limits)
end

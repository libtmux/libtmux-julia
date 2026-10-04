const _DISCOVERY_LIMITS = LibTmux.WhereLimits(
    max_depth=24,
    max_nodes=512,
    max_string_bytes=1024,
    max_items=64,
    max_bytes=8192,
)
const _DISCOVERY_MAX_PANES = 4096

_discovery_columns() = sort!([
    String(name) for ((entity, name), spec) in LibTmux._CRITERIA_FIELDS if
    entity === :pane && spec.relation === :scalar
])

function _scope_schema()
    Dict(
        "oneOf"=>[
            _json_object(
                Dict(
                    field=>merge(_string_schema(64), Dict("pattern"=>pattern)),
                    "generation"=>_string_schema(128),
                );
                required=[field, "generation"],
            ) for (field, pattern) in
            (("sessionId", raw"^\$(0|[1-9][0-9]*)$"), ("windowId", raw"^@(0|[1-9][0-9]*)$"))
        ],
    )
end

function _where_schema()
    node = Dict("\$ref"=>"#/\$defs/criteriaNode")
    scalar = Dict("type"=>["string", "number", "boolean", "null"])
    operator = Dict(
        "oneOf"=>[
            _json_object(
                Dict(
                    "op"=>Dict("enum"=>["eq", "ne", "ge", "le", "gt", "lt"]),
                    "value"=>scalar,
                );
                required=["op", "value"],
            ),
            _json_object(
                Dict(
                    "op"=>Dict("const"=>"in"),
                    "values"=>Dict("type"=>"array", "maxItems"=>64, "items"=>scalar),
                );
                required=["op", "values"],
            ),
            _json_object(
                Dict(
                    "op"=>Dict("enum"=>["contains", "startsWith", "endsWith"]),
                    "value"=>_string_schema(1024),
                    "case"=>Dict("enum"=>["sensitive", "ascii_insensitive"]),
                );
                required=["op", "value", "case"],
            ),
            _json_object(
                Dict(
                    "op"=>Dict("enum"=>["is", "anyRelated", "allRelated", "noRelated"]),
                    "where"=>node,
                );
                required=["op", "where"],
            ),
        ],
    )
    tree = Dict(
        "oneOf"=>[
            _json_object(
                Dict(
                    "op"=>Dict("enum"=>["all", "any"]),
                    "args"=>Dict("type"=>"array", "items"=>node, "maxItems"=>64),
                );
                required=["op", "args"],
            ),
            _json_object(
                Dict("op"=>Dict("const"=>"not"), "arg"=>node);
                required=["op", "arg"],
            ),
            _json_object(
                Dict(
                    "op"=>Dict("const"=>"fields"),
                    "fields"=>Dict(
                        "type"=>"array",
                        "maxItems"=>64,
                        "items"=>_json_object(
                            Dict(
                                "field"=>Dict(
                                    "enum"=>sort!(collect(keys(LibTmux._WIRE_FIELDS))),
                                ),
                                "match"=>operator,
                            );
                            required=["field", "match"],
                        ),
                    ),
                );
                required=["op", "fields"],
            ),
        ],
    )
    schema = _json_object(
        Dict(
            "schema"=>Dict("const"=>"libtmux.julia.where"),
            "version"=>Dict("const"=>1),
            "entity"=>Dict("const"=>"pane"),
            "where"=>node,
        );
        required=["schema", "version", "entity", "where"],
    )
    schema["description"] = "Native inert pane criteria; field types and relation targets use the core catalog. Maximum nesting 24, 512 nodes, 64 items, 1024 bytes per string, 8192 string/key bytes total."
    # This schema is nested in a tool schema, so definitions belong at that root.
    schema, Dict("criteriaNode"=>tree)
end

function _discovery_plan!(args, input)
    args["limit"] = _integer(get(input, "limit", 32), 1, 128)
    args["offset"] = _integer(get(input, "offset", 0), 0, 1000000)
    args["scope"] = nothing
    if haskey(input, "scope")
        scope = input["scope"]
        _check_object(scope, ("sessionId", "windowId", "generation"), ("generation",))
        (haskey(scope, "sessionId") ⊻ haskey(scope, "windowId")) ||
            throw(ArgumentError("scope requires exactly one sessionId or windowId"))
        kind = haskey(scope, "sessionId") ? :session : :window
        field = kind === :session ? "sessionId" : "windowId"
        id = _text(scope[field], 64)
        kind === :session ? LibTmux.SessionID(id) : LibTmux.WindowID(id)
        generation = _text(scope["generation"], 128)
        isempty(generation) && throw(ArgumentError("generation cannot be empty"))
        args["scope"] = (; kind, id, generation)
    end
    args["where"] = nothing
    args["whereWire"] = nothing
    if haskey(input, "where")
        criterion = LibTmux.decode_where(input["where"]; limits=_DISCOVERY_LIMITS)
        LibTmux._criterion_entity(criterion) in (:pane, :any) ||
            throw(ArgumentError("discovery criteria must select panes"))
        input["where"]["entity"] == "pane" ||
            throw(ArgumentError("discovery criteria must select panes"))
        args["where"] = criterion
        args["whereWire"] =
            LibTmux.encode_where(criterion; entity=:pane, limits=_DISCOVERY_LIMITS)
    end
    args["columns"] = nothing
    if haskey(input, "columns")
        columns = input["columns"]
        columns isa AbstractVector && 1 <= length(columns) <= 16 ||
            throw(ArgumentError("columns requires 1 to 16 scalar names"))
        approved = _discovery_columns()
        labels = [_text(name, 64) for name in columns]
        all(label -> label in approved, labels) ||
            throw(ArgumentError("columns must name scalar pane fields from the catalog"))
        names = Tuple(Symbol(label) for label in labels)
        # Validate even empty observations before any external I/O.
        LibTmux.project_rows(LibTmux.Selection(LibTmux.PaneSnapshot[]); columns=names)
        args["columns"] = names
    end
    args["pageFingerprint"] = nothing
    if haskey(input, "pageToken")
        args["offset"] == 0 ||
            throw(ArgumentError("pageToken cannot accompany a nonzero offset"))
        token = _text(input["pageToken"], 80)
        parsed = match(r"^v1\.(0|[1-9][0-9]{0,6})\.([0-9a-f]{64})$", token)
        parsed === nothing && throw(ArgumentError("invalid pageToken"))
        args["offset"] = _integer(parse(Int, parsed[1]), 0, 1000000)
        args["pageFingerprint"] = parsed[2]
    end
    args
end

function _discovery_capture(app, scope, context)
    if scope === nothing
        captured = LibTmux.snapshot(app.server; _tool_kwargs(context)...)
        return captured, LibTmux.panes(captured), nothing, "complete_observed_graph"
    end
    path = _tool_socket_path(app, context)
    identity = LibTmux.ServerIdentity(; socket_path=path, generation=scope.generation)
    ref =
        scope.kind === :session ? LibTmux.SessionRef(identity, scope.id) :
        LibTmux.WindowRef(identity, scope.id)
    parent = LibTmux.snapshot(app.server, ref; _tool_kwargs(context)...)
    captured = LibTmux.snapshotof(parent)
    if scope.kind === :window
        return captured, LibTmux.panes(parent), parent, "window_scope"
    end
    items = LibTmux.PaneSnapshot[]
    seen = Set{LibTmux.PaneID}()
    control = _discovery_control(context)
    for window in LibTmux.windows(parent), pane in LibTmux.panes(window)
        LibTmux._criterion_checkpoint!(control)
        pane.id in seen && continue
        push!(seen, pane.id)
        push!(items, pane)
    end
    LibTmux._criterion_checkpoint!(control; force=true)
    captured, LibTmux.Selection(items; snapshot=captured), parent, "session_scope"
end

function _discovery_contexts(links; clipped)
    [
        Dict(
            "sessionId"=>string(link.session_id),
            "sessionName"=>clipped ? _clip(link.session.name, 128) : link.session.name,
            "windowId"=>string(link.window_id),
            "windowName"=>clipped ? _clip(link.window.name, 128) : link.window.name,
            "windowIndex"=>link.index,
        ) for link in links
    ]
end
_discovery_value(value::LibTmux.EntityID) = string(value)
_discovery_value(value) = value

function _discovery_row(pane, links, caller, projection; clipped, contexts=nothing)
    contexts === nothing && (
        contexts =
            _discovery_contexts(clipped ? Iterators.take(links, 8) : links; clipped)
    )
    row = Dict{String,Any}(
        "target"=>_target_wire(pane.ref),
        "caller"=>pane.ref == caller,
        "contexts"=>contexts,
        "contextsTruncated"=>length(links)>8,
        "fieldsTruncated"=>false,
    )
    if projection !== nothing
        values = Dict{String,Any}()
        for (name, value) in pairs(projection)
            values[String(name)] =
                clipped && value isa String ? _clip(value, 256) : _discovery_value(value)
            row["fieldsTruncated"] |= value isa String && ncodeunits(value)>256
        end
        row["values"] = values
    else
        merge!(
            row,
            Dict(
                "active"=>pane.active,
                "dead"=>pane.dead,
                "command"=>pane.current_command === nothing ? nothing :
                           clipped ? _clip(pane.current_command, 256) :
                           pane.current_command,
                "title"=>clipped ? _clip(pane.title, 256) : pane.title,
                "width"=>pane.width,
                "height"=>pane.height,
            ),
        )
        row["fieldsTruncated"] =
            ncodeunits(pane.title)>256 ||
            (pane.current_command !== nothing && ncodeunits(pane.current_command)>256)
    end
    row["fieldsTruncated"] |= any(
        link -> ncodeunits(link.session.name)>128 || ncodeunits(link.window.name)>128,
        Iterators.take(links, 8),
    )
    row
end

struct _DiscoveryCheckpoint <: Function
    context::_ToolContext
end
function (checkpoint::_DiscoveryCheckpoint)()
    context = checkpoint.context
    LibTmux.iscancelled(context.cancel) && throw(LibTmux.RequestCancelled(false))
    _tool_remaining(context)
    nothing
end


_discovery_control(context) = LibTmux._CriterionTraversal{Function}(
    _DiscoveryCheckpoint(context),
    0,
    nothing,
    nothing,
)

# This cache belongs to one captured snapshot and scope. Physical-window indices
# preserve contextual link order; equal IDs from another capture cannot share it.
struct _DiscoveryWindowFacets
    links::LibTmux.Selection
    contexts::Vector{Dict{String,Any}}
    clipped::Vector{Dict{String,Any}}
end
struct _DiscoveryRows <: AbstractVector{Dict{String,Any}}
    captured::LibTmux.Snapshot
    selected::LibTmux.Selection
    parent::Union{Nothing,LibTmux.SessionSnapshot,LibTmux.WindowSnapshot}
    caller::Union{Nothing,LibTmux.PaneRef}
    projection::Union{Nothing,LibTmux.RowProjection}
    windows::Dict{Int,_DiscoveryWindowFacets}
    control::LibTmux._CriterionTraversal{Function}
    session_links::Union{Nothing,Dict{Int,LibTmux.Selection}}
end
function _DiscoveryRows(captured, selected, parent, caller, projection, windows, control)
    groups = nothing
    if parent isa LibTmux.SessionSnapshot
        items = Dict{Int,Vector{LibTmux.WindowLink}}()
        for link in LibTmux.windowlinks(parent)
            LibTmux._criterion_checkpoint!(control)
            group = get!(items, getfield(link.window, :_index)) do
                LibTmux.WindowLink[]
            end
            push!(group, link)
        end
        groups = Dict{Int,LibTmux.Selection}()
        for (index, links) in items
            LibTmux._criterion_checkpoint!(control)
            groups[index] = LibTmux.Selection(links; snapshot=captured)
        end
    end
    _DiscoveryRows(captured, selected, parent, caller, projection, windows, control, groups)
end
Base.size(rows::_DiscoveryRows) = size(rows.selected)
Base.IndexStyle(::Type{_DiscoveryRows}) = IndexLinear()
function _discovery_window(rows::_DiscoveryRows, pane)
    LibTmux.snapshotof(pane) === rows.captured || error("discovery capture changed")
    window = pane.window
    get!(rows.windows, getfield(window, :_index)) do
        links = if rows.session_links === nothing
            LibTmux.windowlinks(window)
        else
            selected = get(rows.session_links, getfield(window, :_index), nothing)
            selected === nothing ?
            LibTmux.Selection(LibTmux.WindowLink[]; snapshot=rows.captured) : selected
        end
        raw, clipped = Dict{String,Any}[], Dict{String,Any}[]
        for (index, link) in enumerate(links)
            LibTmux._criterion_checkpoint!(rows.control)
            push!(raw, only(_discovery_contexts((link,); clipped=false)))
            index <= 8 && push!(clipped, only(_discovery_contexts((link,); clipped=true)))
        end
        _DiscoveryWindowFacets(links, raw, clipped)
    end
end
function _discovery_row_at(rows::_DiscoveryRows, index; clipped)
    LibTmux._criterion_checkpoint!(rows.control)
    pane = rows.selected[index]
    window = _discovery_window(rows, pane)
    _discovery_row(
        pane,
        window.links,
        rows.caller,
        rows.projection === nothing ? nothing : rows.projection[index];
        clipped,
        contexts=clipped ? window.clipped : window.contexts,
    )
end
Base.getindex(rows::_DiscoveryRows, index::Int) =
    _discovery_row_at(rows, index; clipped=false)

mutable struct _DiscoveryDigest
    hash::SHA.SHA2_256_CTX
    buffer::Vector{UInt8}
    used::Int
    control::LibTmux._CriterionTraversal{Function}
end
function _discovery_digest_flush!(state::_DiscoveryDigest)
    state.used == 0 && return nothing
    LibTmux._criterion_checkpoint!(state.control; force=true)
    SHA.update!(state.hash, state.buffer, state.used)
    state.used = 0
    LibTmux._criterion_checkpoint!(state.control; force=true)
    nothing
end
function _discovery_digest_write!(state::_DiscoveryDigest, bytes::AbstractVector{UInt8})
    offset = 1
    while offset <= length(bytes)
        count = min(length(state.buffer) - state.used, length(bytes) - offset + 1)
        copyto!(state.buffer, state.used + 1, bytes, offset, count)
        state.used += count
        offset += count
        state.used == length(state.buffer) && _discovery_digest_flush!(state)
    end
    nothing
end
_discovery_digest_write!(state::_DiscoveryDigest, text::AbstractString) =
    _discovery_digest_write!(state, codeunits(text))

function _canonical_digest_string!(state::_DiscoveryDigest, value::AbstractString)
    _discovery_digest_write!(state, "\"")
    start = firstindex(value)
    while start <= ncodeunits(value)
        stop = prevind(value, min(start + 32768, ncodeunits(value) + 1))
        encoded = JSON.json(SubString(value, start, stop))
        _discovery_digest_write!(state, @view codeunits(encoded)[2:(end-1)])
        start = nextind(value, stop)
        LibTmux._criterion_checkpoint!(state.control; force=ncodeunits(value) > 32768)
    end
    _discovery_digest_write!(state, "\"")
    nothing
end
function _canonical_digest!(state::_DiscoveryDigest, value)
    LibTmux._criterion_checkpoint!(state.control)
    if value isa AbstractDict
        _discovery_digest_write!(state, "{")
        for (index, (key, item)) in enumerate(sort!(collect(pairs(value)); by=first))
            index == 1 || _discovery_digest_write!(state, ",")
            _canonical_digest_string!(state, String(key))
            _discovery_digest_write!(state, ":")
            _canonical_digest!(state, item)
        end
        _discovery_digest_write!(state, "}")
    elseif value isa Union{AbstractVector,Tuple}
        _discovery_digest_write!(state, "[")
        for (index, item) in enumerate(value)
            index == 1 || _discovery_digest_write!(state, ",")
            _canonical_digest!(state, item)
        end
        _discovery_digest_write!(state, "]")
    elseif value isa AbstractString
        _canonical_digest_string!(state, value)
    else
        _discovery_digest_write!(state, JSON.json(value))
    end
    nothing
end
function _discovery_fingerprint(value, control)
    state = _DiscoveryDigest(SHA.SHA2_256_CTX(), Vector{UInt8}(undef, 65536), 0, control)
    _canonical_digest!(state, value)
    _discovery_digest_flush!(state)
    bytes2hex(SHA.digest!(state.hash))
end

function _list_panes(app, args, context)
    captured, candidates, parent, coverage = _discovery_capture(app, args["scope"], context)
    length(candidates) <= _DISCOVERY_MAX_PANES || throw(
        _ToolFailure(
            "discovery_limit",
            "observation exceeds 4096 panes; select a session or window scope",
        ),
    )
    control = _discovery_control(context)
    items = eltype(candidates)[]
    for pane in candidates
        LibTmux._criterion_checkpoint!(control)
        _pane_permitted(
            app,
            (; paneId=string(pane.id), generation=captured.identity.generation),
        ) && push!(items, pane)
    end
    selected = LibTmux.Selection(items; snapshot=captured)
    LibTmux._criterion_checkpoint!(control; force=true)
    args["where"] === nothing || (
        selected = LibTmux._filter_where(
            args["where"],
            selected,
            _DiscoveryCheckpoint(context),
        )
    )
    LibTmux._criterion_checkpoint!(control; force=true)
    projection =
        args["columns"] === nothing ? nothing :
        LibTmux._project_rows(selected, args["columns"], _DiscoveryCheckpoint(context))
    raw = _DiscoveryRows(
        captured,
        selected,
        parent,
        app.caller,
        projection,
        Dict{Int,_DiscoveryWindowFacets}(),
        control,
    )
    candidate_ids = String[]
    for pane in candidates
        LibTmux._criterion_checkpoint!(control)
        push!(candidate_ids, string(pane.id))
    end
    scope = args["scope"]
    fingerprint = _discovery_fingerprint(
        Dict{String,Any}(
            "generation"=>captured.identity.generation,
            "scope"=>scope === nothing ? nothing :
                     Dict(
                "kind"=>String(scope.kind),
                "id"=>scope.id,
                "generation"=>scope.generation,
            ),
            "where"=>args["whereWire"],
            "columns"=>args["columns"],
            "candidateIds"=>candidate_ids,
            "rows"=>raw,
        ),
        control,
    )
    prior = args["pageFingerprint"]
    prior === nothing ||
        (prior == fingerprint && args["offset"] <= length(selected)) ||
        throw(
            _ToolFailure(
                "observation_changed",
                "discovery observation or query changed; restart without pageToken",
            ),
        )
    offset, limit = args["offset"], args["limit"]
    rows = Dict{String,Any}[]
    for i = (offset+1):min(length(selected), offset+limit)
        push!(rows, _discovery_row_at(raw, i; clipped=true))
    end
    next = offset + length(rows)
    more = next < length(selected)
    _tool_remaining(context)
    LibTmux.iscancelled(context.cancel) && throw(LibTmux.RequestCancelled(false))
    Dict(
        "panes"=>rows,
        "total"=>length(selected),
        "nextOffset"=>more ? next : nothing,
        "nextPageToken"=>more ? "v1.$next.$fingerprint" : nothing,
        "truncated"=>more,
        "coverage"=>coverage,
        "contextsCoverage"=>parent isa LibTmux.SessionSnapshot ? "selected_session" :
                            "all_observed_links",
        "pagination"=>"verified_discovery_facets",
        "generationGuarantee"=>"best_effort",
        "terminalContent"=>"data",
    )
end

const _TOOL_NAMES = (
    "list_panes",
    "capture_pane",
    "send_keys",
    "paste_text",
    "resize_pane",
    "kill_pane",
    "run_operations",
    "create_session",
    "teardown_session",
    "wait_for_text",
    "send_keys_and_wait",
)
const _ROUTINE_TOOLS = ("list_panes", "capture_pane", "send_keys")
const _READ_ONLY_TOOLS = ("list_panes", "capture_pane", "wait_for_text")
const _TOOL_ARGUMENTS = Dict(
    "wait_for_text"=>(("target", "text"), ("text",)),
    "send_keys_and_wait"=>(("target", "text", "keys", "literal"), ("text", "keys")),
    "list_panes"=>(("limit", "offset"), ()),
    "capture_pane"=>(("target", "lines", "maxBytes"), ()),
    "send_keys"=>(("target", "keys", "literal"), ("keys",)),
    "paste_text"=>(("target", "text"), ("text",)),
    "resize_pane"=>(("target", "width", "height"), ()),
    "kill_pane"=>(("target",), ()),
    "run_operations"=>(("operations",), ("operations",)),
    "create_session"=>(("name", "command"), ("name", "command")),
    "teardown_session"=>(("sessionId", "generation"), ("sessionId", "generation")),
)

_tool_can_mutate(name) = !(name in _READ_ONLY_TOOLS)

struct _ToolFailure <: Exception
    code::String
    message::String
end
Base.showerror(io::IO, error::_ToolFailure) = print(io, error.message)

struct _ToolEffectsError <: Exception
    cause::Exception
end
Base.showerror(io::IO, error::_ToolEffectsError) = showerror(io, error.cause)

struct _ApplicationCall
    token::LibTmux.CancellationToken
    finished::Base.Event
end

"""
    Application(server; caller=nothing, allowed_tools=("list_panes", "capture_pane", "send_keys"),
                allowed_panes=nothing, allow_create=false, timeout=5.0,
                max_capture_bytes=65536, max_result_bytes=1048576)

Configure an MCP application without I/O. `server` is an explicit borrowed
endpoint. Omitted pane targets use only `caller`; there is no ambient/current
pane fallback. `allowed_panes=nothing` permits any explicitly addressed pane;
otherwise copy the supplied generation-bound references as the allowlist.
Tool names and pane policy also apply to each item in `run_operations`.

Creation requires both an enabled `create_session` tool and `allow_create=true`.
The application owns those sessions and their observed panes, and tears down
its sessions on `close`. It never owns the borrowed daemon or caller session.
"""
struct Application
    server::LibTmux.Server
    caller::Union{Nothing,LibTmux.PaneRef}
    allowed_tools::Tuple{Vararg{String}}
    allow_create::Bool
    timeout::Float64
    max_capture_bytes::Int
    max_result_bytes::Int
    _allowed_panes::Union{Nothing,Vector{LibTmux.PaneRef}}
    _condition::Threads.Condition
    _state::Base.RefValue{Symbol}
    _next::Base.RefValue{UInt64}
    _active::Dict{UInt64,_ApplicationCall}
    _owned::Dict{LibTmux.SessionRef,Vector{LibTmux.PaneRef}}
    _creating::Base.RefValue{Int}
end

function Application(
    server::LibTmux.Server;
    caller::Union{Nothing,LibTmux.PaneRef}=nothing,
    allowed_tools=_ROUTINE_TOOLS,
    allowed_panes=nothing,
    allow_create::Bool=false,
    timeout::Real=5.0,
    max_capture_bytes::Int=65536,
    max_result_bytes::Int=1048576,
)
    names = Tuple(String(name) for name in allowed_tools)
    length(names) <= length(_TOOL_NAMES) &&
    all(name -> name in _TOOL_NAMES, names) &&
    length(unique(names)) == length(names) ||
        throw(ArgumentError("unknown or duplicate tool name"))
    names == ("run_operations",) &&
        throw(ArgumentError("run_operations requires at least one enabled item tool"))
    refs =
        allowed_panes === nothing ? nothing : LibTmux.PaneRef[ref for ref in allowed_panes]
    refs === nothing ||
        length(refs) <= 256 ||
        throw(ArgumentError("at most 256 allowed panes"))
    for ref in (caller === nothing ? () : (caller,)) ∪ (refs === nothing ? () : Tuple(refs))
        server.socket_path === nothing ||
            ref.server.socket_path == server.socket_path ||
            throw(
                ArgumentError(
                    "caller and allowed panes must belong to the configured endpoint",
                ),
            )
    end
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget <= 30 ||
        throw(ArgumentError("timeout must be between zero and 30 seconds"))
    1 <= max_capture_bytes <= 262144 ||
        throw(ArgumentError("capture limit must be between 1 and 262144 bytes"))
    1024 <= max_result_bytes <= 1048576 ||
        throw(ArgumentError("result limit must be between 1024 and 1048576 bytes"))
    Application(
        server,
        caller,
        names,
        allow_create,
        budget,
        max_capture_bytes,
        max_result_bytes,
        refs,
        Threads.Condition(),
        Ref(:open),
        Ref(UInt64(0)),
        Dict{UInt64,_ApplicationCall}(),
        Dict{LibTmux.SessionRef,Vector{LibTmux.PaneRef}}(),
        Ref(0),
    )
end

Base.isopen(app::Application) = lock(() -> app._state[] === :open, app._condition)
Base.show(io::IO, app::Application) = print(
    io,
    "Application(",
    app.server,
    ", tools=",
    app.allowed_tools,
    ", open=",
    isopen(app),
    ")",
)

function _application_call(f, app, upstream)
    call = _ApplicationCall(LibTmux.CancellationToken(), Base.Event())
    key = lock(app._condition) do
        app._state[] === :open || throw(_ToolFailure("closed", "application is closed"))
        length(app._active) < 16 ||
            throw(_ToolFailure("busy", "application request capacity exhausted"))
        app._next[] += 1
        app._active[app._next[]] = call
        app._next[]
    end
    subscription = nothing
    try
        subscription = LibTmux.on_cancel(() -> LibTmux.cancel!(call.token), upstream)
        LibTmux.iscancelled(call.token) && throw(LibTmux.RequestCancelled(false))
        f((; started=time_ns(), budget=app.timeout, cancel=call.token))
    finally
        subscription === nothing || close(subscription)
        lock(app._condition) do
            delete!(app._active, key)
            notify(call.finished)
        end
    end
end

function _tool_remaining(context)
    remaining = context.budget - (time_ns() - context.started) / 1e9
    remaining > 0 || throw(LibTmux.DeadlineExceeded(context.budget, false, nothing))
    remaining
end
_tool_kwargs(context) = (; timeout=_tool_remaining(context), cancel=context.cancel)

"Cancel and join active calls, then tear down only application-owned sessions."
function Base.close(app::Application)
    calls = lock(app._condition) do
        while app._state[] === :closing
            wait(app._condition)
        end
        app._state[] === :closed && return nothing
        app._state[] = :closing
        collect(values(app._active))
    end
    calls === nothing && return nothing
    errors = Exception[]
    try
        for call in calls
            try
                LibTmux.cancel!(call.token)
            catch error
                push!(errors, error)
            end
        end
        foreach(call -> wait(call.finished), calls)
        owned = lock(() -> collect(keys(app._owned)), app._condition)
        context = (; started=time_ns(), budget=0.9, cancel=nothing)
        captured =
            isempty(owned) ? nothing :
            LibTmux.snapshot(app.server; _tool_kwargs(context)...)
        for session in owned
            try
                _remove_owned_session(app, session, context; captured)
            catch error
                push!(errors, error)
            end
        end
    finally
        lock(app._condition) do
            empty!(app._owned)
            app._state[] = :closed
            notify(app._condition; all=true)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    nothing
end

_json_object(properties; required=String[]) = Dict{String,Any}(
    "type"=>"object",
    "properties"=>properties,
    "required"=>required,
    "additionalProperties"=>false,
)
_string_schema(limit; description="") = Dict{String,Any}(
    "type"=>"string",
    "maxLength"=>limit,
    "description"=>isempty(description) ? "Valid UTF-8; at most $limit bytes" : description,
)
_integer_schema(low, high; default=nothing) = merge(
    Dict{String,Any}("type"=>"integer", "minimum"=>low, "maximum"=>high),
    default === nothing ? Dict() : Dict("default"=>default),
)
function _target_schema()
    _json_object(
        Dict(
            "paneId"=>merge(_string_schema(64), Dict("pattern"=>"^%(0|[1-9][0-9]*)\$")),
            "generation"=>_string_schema(
                128;
                description="Opaque generation from list_panes",
            ),
        );
        required=["paneId", "generation"],
    )
end

function _tool_schema(app, name)
    properties = Dict{String,Any}()
    required = String[]
    if name == "list_panes"
        properties["limit"] = _integer_schema(1, 128; default=32)
        properties["offset"] = _integer_schema(0, 1000000; default=0)
    elseif name == "run_operations"
        properties["operations"] = Dict(
            "type"=>"array",
            "minItems"=>1,
            "maxItems"=>8,
            "items"=>Dict(
                "oneOf"=>[
                    _json_object(
                        Dict(
                            "tool"=>Dict("const"=>tool),
                            "arguments"=>_tool_schema(app, tool),
                        );
                        required=["tool", "arguments"],
                    ) for tool in app.allowed_tools if tool != "run_operations"
                ],
            ),
        )
        push!(required, "operations")
    elseif name == "create_session"
        properties["name"] = merge(_string_schema(64), Dict("pattern"=>"^[A-Za-z0-9_-]+\$"))
        properties["command"] = Dict(
            "type"=>"array",
            "minItems"=>1,
            "maxItems"=>32,
            "items"=>_string_schema(1024),
            "description"=>"Executable and argv; no shell expansion",
        )
        push!(required, "name", "command")
    elseif name == "teardown_session"
        properties["sessionId"] = _string_schema(64)
        properties["generation"] = _string_schema(128)
        append!(required, ["sessionId", "generation"])
    else
        properties["target"] = merge(
            _target_schema(),
            Dict(
                "description" => "Explicit captured target; omission requires a configured caller pane",
            ),
        )
        app.caller === nothing && push!(required, "target")
        if name == "capture_pane"
            properties["lines"] = _integer_schema(1, 1000; default=100)
            properties["maxBytes"] =
                _integer_schema(1, app.max_capture_bytes; default=app.max_capture_bytes)
        elseif name in ("send_keys", "send_keys_and_wait")
            properties["keys"] = Dict(
                "type"=>"array",
                "minItems"=>1,
                "maxItems"=>64,
                "items"=>_string_schema(1024),
            )
            properties["literal"] = Dict("type"=>"boolean", "default"=>false)
            push!(required, "keys")
        elseif name == "paste_text"
            properties["text"] = _string_schema(65536)
            push!(required, "text")
        elseif name == "resize_pane"
            properties["width"] = _integer_schema(1, 10000)
            properties["height"] = _integer_schema(1, 10000)
        end
    end
    if name in ("wait_for_text", "send_keys_and_wait")
        properties["text"] =
            merge(_string_schema(min(1024, app.max_capture_bytes)), Dict("minLength"=>1))
        push!(required, "text")
    end
    schema = _json_object(properties; required)
    name == "resize_pane" &&
        (schema["anyOf"] = [Dict("required"=>["width"]), Dict("required"=>["height"])])
    schema
end

function _tool_output_schema(app, name)
    text = Dict("type"=>"string")
    boolean = Dict("type"=>"boolean")
    integer = Dict("type"=>"integer")
    fields = Dict{String,Any}()
    if name == "list_panes"
        context = _json_object(
            Dict(
                "sessionId"=>text,
                "sessionName"=>text,
                "windowId"=>text,
                "windowName"=>text,
                "windowIndex"=>integer,
            );
            required=["sessionId", "sessionName", "windowId", "windowName", "windowIndex"],
        )
        row = _json_object(
            Dict(
                "target"=>_target_schema(),
                "active"=>boolean,
                "dead"=>boolean,
                "command"=>Dict("type"=>["string", "null"]),
                "title"=>text,
                "width"=>integer,
                "height"=>integer,
                "caller"=>boolean,
                "contexts"=>Dict("type"=>"array", "items"=>context, "maxItems"=>8),
                "contextsTruncated"=>boolean,
                "fieldsTruncated"=>boolean,
            );
            required=[
                "target",
                "active",
                "dead",
                "command",
                "title",
                "width",
                "height",
                "caller",
                "contexts",
                "contextsTruncated",
                "fieldsTruncated",
            ],
        )
        merge!(
            fields,
            Dict(
                "panes"=>Dict("type"=>"array", "items"=>row, "maxItems"=>128),
                "total"=>integer,
                "nextOffset"=>Dict("type"=>["integer", "null"]),
                "truncated"=>boolean,
                "coverage"=>text,
                "generationGuarantee"=>text,
                "terminalContent"=>text,
            ),
        )
    elseif name in ("wait_for_text", "send_keys_and_wait")
        merge!(
            fields,
            Dict(
                "target"=>_target_schema(),
                "matched"=>boolean,
                "text"=>text,
                "source"=>Dict("enum"=>["baseline", "output"]),
                "evidence"=>Dict("const"=>"literal_text"),
                "continuity"=>Dict("const"=>"reset"),
                "keysSent"=>boolean,
                "terminalContent"=>Dict("const"=>"data"),
                "generationGuarantee"=>text,
            ),
        )
    elseif name == "capture_pane"
        merge!(
            fields,
            Dict(
                "target"=>_target_schema(),
                "text"=>text,
                "truncated"=>boolean,
                "lineLimit"=>integer,
                "byteLimit"=>integer,
                "encoding"=>text,
                "terminalContent"=>text,
            ),
        )
    elseif name == "run_operations"
        merge!(
            fields,
            Dict(
                "completed"=>Dict(
                    "type"=>"array",
                    "maxItems"=>8,
                    "items"=>_json_object(
                        Dict("tool"=>text, "result"=>Dict("type"=>"object"));
                        required=["tool", "result"],
                    ),
                ),
                "failedIndex"=>Dict("type"=>"null"),
                "atomic"=>Dict("const"=>false),
            ),
        )
    elseif name in ("create_session", "teardown_session")
        merge!(fields, Dict("sessionId"=>text, "generation"=>text, "completed"=>boolean))
        if name == "create_session"
            fields["panes"] =
                Dict("type"=>"array", "items"=>_target_schema(), "maxItems"=>256)
            fields["ownership"] = Dict("const"=>"application")
        end
    else
        merge!(
            fields,
            Dict(
                "target"=>_target_schema(),
                "completed"=>boolean,
                "generationGuarantee"=>text,
            ),
        )
    end
    success = _json_object(fields; required=collect(keys(fields)))
    error = _json_object(
        Dict(
            "code"=>text,
            "message"=>text,
            "effects"=>Dict("enum"=>["none", "possible"]),
            "retryable"=>boolean,
        );
        required=["code", "message", "effects", "retryable"],
    )
    failure =
        Dict("type"=>"object", "properties"=>Dict("error"=>error), "required"=>["error"])
    if name == "run_operations"
        completed_summary = _json_object(
            Dict(
                "tool"=>text,
                "completed"=>Dict("const"=>true),
                "resultOmitted"=>Dict("const"=>true),
            );
            required=["tool", "completed", "resultOmitted"],
        )
        limit_error = _json_object(
            Dict(
                "code"=>Dict("const"=>"result_limit"),
                "message"=>text,
                "effects"=>Dict("enum"=>["none", "possible"]),
                "retryable"=>boolean,
            );
            required=["code", "message", "effects", "retryable"],
        )
        limit_fields = Dict(
            "completed"=>Dict("type"=>"array", "maxItems"=>8, "items"=>completed_summary),
            "error"=>limit_error,
            "atomic"=>Dict("const"=>false),
        )
        limited_success = _json_object(
            merge(limit_fields, Dict("failedIndex"=>Dict("type"=>"null")));
            required=[collect(keys(limit_fields)); "failedIndex"],
        )
        original_error = _json_object(Dict("code"=>text); required=["code"])
        limited_partial = _json_object(
            merge(
                limit_fields,
                Dict("failedIndex"=>_integer_schema(1, 8), "originalError"=>original_error),
            );
            required=vcat(collect(keys(limit_fields)), ["failedIndex", "originalError"]),
        )
        partial = _json_object(
            merge(fields, Dict("failedIndex"=>_integer_schema(1, 8), "error"=>error));
            required=[collect(keys(fields)); "error"],
        )
        return Dict(
            "type"=>"object",
            "anyOf"=>[success, partial, limited_success, limited_partial, failure],
        )
    end
    Dict("type"=>"object", "anyOf"=>[success, failure])
end

function _check_object(value, fields, required=())
    value isa AbstractDict && all(key -> key isa String && key in fields, keys(value)) ||
        throw(ArgumentError("expected an object with documented argument names"))
    all(key -> haskey(value, key), required) ||
        throw(ArgumentError("missing a required argument"))
    value
end
function _text(value, limit)
    value isa String &&
    isvalid(value) &&
    !occursin('\0', value) &&
    ncodeunits(value) <= limit || throw(
        ArgumentError("text must be valid UTF-8 without NUL and within its byte limit"),
    )
    value
end
function _integer(value, low, high)
    value isa Integer && !(value isa Bool) && low <= value <= high ||
        throw(ArgumentError("integer must be between $low and $high"))
    Int(value)
end
function _pane_permitted(app, target)
    app._allowed_panes === nothing && return true
    allowed = lock(app._condition) do
        [app._allowed_panes; collect(Iterators.flatten(values(app._owned)))]
    end
    any(
        ref ->
            string(ref.id) == target.paneId && ref.server.generation == target.generation,
        allowed,
    )
end
function _target_input(app, value)
    if value === nothing
        app.caller === nothing && throw(
            _ToolFailure("target_required", "supply a target or configure a caller pane"),
        )
        target = (; paneId=string(app.caller.id), generation=app.caller.server.generation)
    else
        _check_object(value, ("paneId", "generation"), ("paneId", "generation"))
        id, generation = _text(value["paneId"], 64), _text(value["generation"], 128)
        LibTmux.PaneID(id)
        isempty(generation) && throw(ArgumentError("generation cannot be empty"))
        target = (; paneId=id, generation)
    end
    _pane_permitted(app, target) ||
        throw(_ToolFailure("target_denied", "pane is not allowed by this application"))
    target
end

function _plan_tool(app, name, input)
    name in app.allowed_tools || throw(_ToolFailure("tool_denied", "tool is not enabled"))
    fields, required = _TOOL_ARGUMENTS[name]
    _check_object(input, fields, required)
    args = Dict{String,Any}()
    if name == "list_panes"
        args["limit"] = _integer(get(input, "limit", 32), 1, 128)
        args["offset"] = _integer(get(input, "offset", 0), 0, 1000000)
    elseif name == "run_operations"
        operations = input["operations"]
        operations isa AbstractVector && 1 <= length(operations) <= 8 ||
            throw(ArgumentError("operations must contain between 1 and 8 items"))
        plans = Any[]
        for operation in operations
            _check_object(operation, ("tool", "arguments"), ("tool", "arguments"))
            tool = _text(operation["tool"], 64)
            tool != "run_operations" ||
                throw(ArgumentError("nested batches are not supported"))
            push!(plans, _plan_tool(app, tool, operation["arguments"]))
        end
        args["plans"] = plans
    elseif name == "create_session"
        app.allow_create || throw(
            _ToolFailure("creation_denied", "session creation requires allow_create=true"),
        )
        args["name"] = _text(input["name"], 64)
        occursin(r"^[A-Za-z0-9_-]+$", args["name"]) ||
            throw(ArgumentError("invalid session name"))
        command = input["command"]
        command isa AbstractVector && 1 <= length(command) <= 32 ||
            throw(ArgumentError("command requires 1 to 32 argv entries"))
        args["command"] = [_text(item, 1024) for item in command]
        isempty(first(args["command"])) &&
            throw(ArgumentError("command executable cannot be empty"))
        startswith(first(args["command"]), '-') &&
            throw(ArgumentError("use ./-name or an absolute executable path"))
        sum(ncodeunits, args["command"]) <= 8192 ||
            throw(ArgumentError("command exceeds 8192 bytes"))
    elseif name == "teardown_session"
        args["sessionId"] = _text(input["sessionId"], 64)
        LibTmux.SessionID(args["sessionId"])
        args["generation"] = _text(input["generation"], 128)
        _owned_session_ref(app, args["sessionId"], args["generation"])
    else
        haskey(input, "target") &&
            input["target"] === nothing &&
            throw(ArgumentError("target cannot be null"))
        args["target"] = _target_input(app, get(input, "target", nothing))
        if name == "capture_pane"
            args["lines"] = _integer(get(input, "lines", 100), 1, 1000)
            args["maxBytes"] = _integer(
                get(input, "maxBytes", app.max_capture_bytes),
                1,
                app.max_capture_bytes,
            )
        elseif name in ("send_keys", "send_keys_and_wait")
            key_arguments = input["keys"]
            key_arguments isa AbstractVector && 1 <= length(key_arguments) <= 64 ||
                throw(ArgumentError("keys requires 1 to 64 strings"))
            args["keys"] = [_text(key, 1024) for key in key_arguments]
            sum(ncodeunits, args["keys"]) <= 8192 ||
                throw(ArgumentError("keys exceed 8192 bytes"))
            args["literal"] = get(input, "literal", false)
            args["literal"] isa Bool || throw(ArgumentError("literal must be Boolean"))
        elseif name == "paste_text"
            args["text"] = _text(input["text"], 65536)
        elseif name == "resize_pane"
            for dimension in ("width", "height")
                haskey(input, dimension) &&
                    (args[dimension] = _integer(input[dimension], 1, 10000))
            end
            length(args) > 1 || throw(ArgumentError("supply width or height"))
        end
    end
    if name in ("wait_for_text", "send_keys_and_wait")
        args["text"] = _text(input["text"], min(1024, app.max_capture_bytes))
        isempty(args["text"]) && throw(ArgumentError("text cannot be empty"))
    end
    (; name, args)
end

function _resolve_target(app, target, context)
    _pane_permitted(app, target) ||
        throw(_ToolFailure("target_denied", "pane is no longer allowed"))
    path = app.server.socket_path
    if path === nothing
        path = LibTmux.snapshot(app.server; _tool_kwargs(context)...).identity.socket_path
    end
    identity = LibTmux.ServerIdentity(; socket_path=path, generation=target.generation)
    LibTmux.PaneRef(identity, target.paneId)
end
_target_wire(ref::LibTmux.PaneRef) =
    Dict("paneId"=>string(ref.id), "generation"=>ref.server.generation)

function _clip(text::AbstractString, limit)
    ncodeunits(text) <= limit && return String(text)
    stop = limit
    while stop > 0 && !isvalid(text, stop + 1)
        stop -= 1
    end
    stop == 0 ? "" : String(SubString(text, 1, prevind(text, stop + 1)))
end

function _list_panes(app, args, context)
    snapshot = LibTmux.snapshot(app.server; _tool_kwargs(context)...)
    selected = filter(
        pane -> _pane_permitted(
            app,
            (; paneId=string(pane.id), generation=snapshot.identity.generation),
        ),
        LibTmux.panes(snapshot),
    )
    offset, limit = args["offset"], args["limit"]
    rows = Dict{String,Any}[]
    for pane in Iterators.take(Iterators.drop(selected, offset), limit)
        links = LibTmux.windowlinks(pane.window)
        contexts = [
            Dict(
                "sessionId"=>string(link.session_id),
                "sessionName"=>_clip(link.session.name, 128),
                "windowId"=>string(link.window_id),
                "windowName"=>_clip(link.window.name, 128),
                "windowIndex"=>link.index,
            ) for link in Iterators.take(links, 8)
        ]
        push!(
            rows,
            Dict(
                "target"=>_target_wire(pane.ref),
                "active"=>pane.active,
                "dead"=>pane.dead,
                "command"=>pane.current_command === nothing ? nothing :
                           _clip(pane.current_command, 256),
                "title"=>_clip(pane.title, 256),
                "width"=>pane.width,
                "height"=>pane.height,
                "caller"=>pane.ref == app.caller,
                "contexts"=>contexts,
                "contextsTruncated"=>length(links) > 8,
                "fieldsTruncated"=>ncodeunits(pane.title) > 256 ||
                                   (
                                       pane.current_command !== nothing &&
                                       ncodeunits(pane.current_command) > 256
                                   ) ||
                                   any(
                                       link ->
                                           ncodeunits(link.session.name) > 128 ||
                                           ncodeunits(link.window.name) > 128,
                                       Iterators.take(links, 8),
                                   ),
            ),
        )
    end
    next = offset + length(rows)
    Dict(
        "panes"=>rows,
        "total"=>length(selected),
        "nextOffset"=>next < length(selected) ? next : nothing,
        "truncated"=>next < length(selected),
        "coverage"=>"complete_observed_graph",
        "generationGuarantee"=>"best_effort",
        "terminalContent"=>"data",
    )
end

function _capture(app, ref, args, context)
    truncated = false
    bytes = try
        LibTmux.capture_bytes(
            app.server,
            ref;
            start_line=(-args["lines"]),
            max_bytes=args["maxBytes"],
            _tool_kwargs(context)...,
        )
    catch error
        error isa LibTmux.OutputLimitExceeded &&
        error.stream === :stdout &&
        error.result !== nothing || rethrow()
        truncated = true
        error.result.stdout
    end
    # A byte limit may cut a code point. Keep complete prefix characters;
    # malformed sequences within that prefix still raise a decoding error.
    text = LibTmux.decode!(LibTmux.TextDecoder(), bytes; final=(!truncated))
    lines = split(text, '\n'; keepempty=true)
    trailing = endswith(text, '\n')
    count = length(lines) - Int(trailing)
    if count > args["lines"]
        lines = lines[(count-args["lines"]+1):end]
        text = join(lines, '\n')
        truncated = true
    end
    Dict(
        "target"=>_target_wire(ref),
        "text"=>text,
        "truncated"=>truncated,
        "lineLimit"=>args["lines"],
        "byteLimit"=>args["maxBytes"],
        "encoding"=>"utf-8",
        "terminalContent"=>"data",
    )
end

function _wait_text(app, ref, plan, context)
    captured = LibTmux.snapshot(app.server; _tool_kwargs(context)...)
    captured.identity == ref.server || throw(LibTmux.StaleReference(string(ref.id)))
    pane = findfirst(pane -> pane.ref == ref, LibTmux.panes(captured))
    pane === nothing && throw(LibTmux.StaleReference(string(ref.id)))
    links = LibTmux.windowlinks(LibTmux.panes(captured)[pane].window)
    isempty(links) && throw(LibTmux.StaleReference(string(ref.id)))
    session = first(links).session.ref
    keys_sent = false
    function matched(source)
        context.progress("matched")
        Dict(
            "target"=>_target_wire(ref),
            "matched"=>true,
            "text"=>plan.args["text"],
            "source"=>source,
            "evidence"=>"literal_text",
            "continuity"=>"reset",
            "keysSent"=>keys_sent,
            "terminalContent"=>"data",
            "generationGuarantee"=>"best_effort",
        )
    end
    try
        LibTmux.open_control(app.server, session; _tool_kwargs(context)...) do connection
            LibTmux.observe_output(
                connection,
                ref;
                max_bytes=app.max_capture_bytes,
                _tool_kwargs(context)...,
            ) do stream
                if plan.name == "wait_for_text"
                    baseline = LibTmux.capture_baseline(
                        stream;
                        max_bytes=app.max_capture_bytes,
                        _tool_kwargs(context)...,
                    )
                    text =
                        LibTmux.decode!(LibTmux.TextDecoder(), baseline.bytes; final=true)
                    occursin(plan.args["text"], text) && return matched("baseline")
                else
                    LibTmux.send_keys(
                        app.server,
                        ref,
                        plan.args["keys"]...;
                        literal=plan.args["literal"],
                        _tool_kwargs(context)...,
                    )
                    keys_sent = true
                end
                context.progress("waiting")
                decoder = LibTmux.TextDecoder()
                tail = ""
                while true
                    event = take!(stream; _tool_kwargs(context)...)
                    text = tail * LibTmux.decode!(decoder, event.bytes)
                    occursin(plan.args["text"], text) && return matched("output")
                    # Only a pattern-sized suffix can participate in a future
                    # match. Never join the independent screen baseline here.
                    first_byte =
                        max(1, ncodeunits(text) - ncodeunits(plan.args["text"]) + 1)
                    tail =
                        isempty(text) ? "" :
                        String(SubString(text, nextind(text, first_byte - 1)))
                end
            end
        end
    catch error
        keys_sent && throw(_ToolEffectsError(error))
        rethrow()
    end
end

function _execute_tool(app, plan, context)
    name, args = plan.name, plan.args
    name == "list_panes" && return _list_panes(app, args, context)
    if name == "run_operations"
        results = Dict{String,Any}[]
        for (index, operation) in enumerate(args["plans"])
            result = try
                _execute_tool(app, operation, context)
            catch error
                detail = _tool_error(error, operation.name)
                any(result -> _tool_can_mutate(result["tool"]), results) &&
                    (detail["effects"] = "possible")
                return Dict(
                    "completed"=>results,
                    "failedIndex"=>index,
                    "error"=>detail,
                    "atomic"=>false,
                )
            end
            push!(results, Dict("tool"=>operation.name, "result"=>result))
        end
        return Dict("completed"=>results, "failedIndex"=>nothing, "atomic"=>false)
    elseif name == "create_session" || name == "teardown_session"
        return _session_operation(app, plan, context)
    end
    ref = _resolve_target(app, args["target"], context)
    name == "capture_pane" && return _capture(app, ref, args, context)
    name in ("wait_for_text", "send_keys_and_wait") &&
        return _wait_text(app, ref, plan, context)
    if name == "send_keys"
        LibTmux.send_keys(
            app.server,
            ref,
            args["keys"]...;
            literal=args["literal"],
            _tool_kwargs(context)...,
        )
    elseif name == "paste_text"
        LibTmux.paste_text(app.server, ref, args["text"]; _tool_kwargs(context)...)
    elseif name == "resize_pane"
        LibTmux.resize_pane(
            app.server,
            ref;
            width=get(args, "width", nothing),
            height=get(args, "height", nothing),
            _tool_kwargs(context)...,
        )
    elseif name == "kill_pane"
        LibTmux.kill_pane(app.server, ref; _tool_kwargs(context)...)
    end
    Dict(
        "target"=>_target_wire(ref),
        "completed"=>true,
        "generationGuarantee"=>"best_effort",
    )
end

function _session_operation(app, plan, context)
    if plan.name == "create_session"
        lock(app._condition) do
            length(app._owned) + app._creating[] < 8 ||
                throw(_ToolFailure("owned_limit", "at most eight owned sessions"))
            app._creating[] += 1
        end
        ref = nothing
        try
            ref = LibTmux.new_session(
                app.server;
                name=plan.args["name"],
                command=plan.args["command"],
                _tool_kwargs(context)...,
            )
            lock(app._condition) do
                app._owned[ref] = LibTmux.PaneRef[]
            end
            captured = LibTmux.snapshot(app.server; _tool_kwargs(context)...)
            captured.identity == ref.server || throw(LibTmux.StaleReference(string(ref.id)))
            refs = unique([
                occurrence.pane.ref for
                occurrence in LibTmux.paneoccurrences(captured) if
                occurrence.link.session_id == ref.id
            ])
            length(refs) <= 256 || throw(
                _ToolFailure("owned_limit", "created session exceeds 256 observed panes"),
            )
            lock(app._condition) do
                app._owned[ref] = refs
            end
            return Dict(
                "sessionId"=>string(ref.id),
                "generation"=>ref.server.generation,
                "panes"=>_target_wire.(refs),
                "ownership"=>"application",
                "completed"=>true,
            )
        catch original
            if ref !== nothing
                cleanup = (; started=time_ns(), budget=0.9, cancel=nothing)
                try
                    _remove_owned_session(app, ref, cleanup)
                catch error
                    throw(CompositeException([original, error]))
                end
            end
            rethrow()
        finally
            lock(app._condition) do
                app._creating[] -= 1
            end
        end
    end
    ref = _owned_session_ref(app, plan.args["sessionId"], plan.args["generation"])
    _remove_owned_session(app, ref, context)
    Dict(
        "sessionId"=>string(ref.id),
        "generation"=>ref.server.generation,
        "completed"=>true,
    )
end

function _owned_session_ref(app, id, generation)
    refs = lock(app._condition) do
        [
            ref for ref in keys(app._owned) if
            string(ref.id) == id && ref.server.generation == generation
        ]
    end
    length(refs) == 1 || throw(
        _ToolFailure("ownership_required", "session is not owned by this application"),
    )
    only(refs)
end

function _remove_owned_session(app, ref, context; captured=nothing)
    captured === nothing ||
        captured.identity == ref.server ||
        throw(LibTmux.StaleReference(string(ref.id)))
    if captured === nothing ||
       any(session -> session.ref == ref, LibTmux.sessions(captured))
        try
            LibTmux.kill_session(app.server, ref; _tool_kwargs(context)...)
        catch error
            error isa LibTmux.CommandError || rethrow()
            current = LibTmux.snapshot(app.server; _tool_kwargs(context)...)
            current.identity == ref.server &&
            !any(session -> session.ref == ref, LibTmux.sessions(current)) || rethrow()
        end
    end
    lock(app._condition) do
        delete!(app._owned, ref)
    end
    nothing
end

function _tool_error(error, name)
    if error isa _ToolEffectsError
        result = _tool_error(error.cause, name)
        result["effects"] = "possible"
        return result
    end
    code =
        error isa _ToolFailure ? error.code :
        error isa ArgumentError ? "invalid_arguments" :
        error isa LibTmux.StaleReference ? "stale_target" :
        error isa LibTmux.CrossServerReference ? "wrong_server" :
        error isa LibTmux.RequestCancelled ? "cancelled" :
        error isa LibTmux.DeadlineExceeded ? "deadline" :
        error isa LibTmux.OutputLimitExceeded ? "output_limit" :
        error isa LibTmux.ObservationLost ? "observation_lost" : "operation_failed"
    mutating = _tool_can_mutate(name)
    uncertain =
        mutating && (
            error isa
            Union{LibTmux.CommandError,LibTmux.CreationResponseError,CompositeException} ||
            error isa Union{LibTmux.ProcessIOError,LibTmux.OutputLimitExceeded} &&
            error.result !== nothing ||
            error isa Union{LibTmux.RequestCancelled,LibTmux.DeadlineExceeded} && error.sent
        )
    Dict(
        "code"=>code,
        "message"=>_clip(sprint(showerror, error), 512),
        "effects"=>uncertain ? "possible" : "none",
        "retryable"=>false,
    )
end

function _result_limit_payload(name, payload)
    completed = get(payload, "completed", nothing)
    original = get(payload, "error", nothing)
    previous_mutation =
        name == "run_operations" &&
        completed isa AbstractVector &&
        any(result -> _tool_can_mutate(result["tool"]), completed)
    original_effects = original isa AbstractDict ? get(original, "effects", "none") : "none"
    effects =
        previous_mutation ||
        original_effects == "possible" ||
        (name != "run_operations" && _tool_can_mutate(name)) ? "possible" : "none"
    error = Dict(
        "code"=>"result_limit",
        "message"=>"result exceeds the configured byte limit; request fewer rows, lines or operations",
        "effects"=>effects,
        "retryable"=>false,
    )
    name == "run_operations" && completed isa AbstractVector || return Dict("error"=>error)
    result = Dict{String,Any}(
        "completed"=>[
            Dict("tool"=>item["tool"], "completed"=>true, "resultOmitted"=>true) for
            item in completed
        ],
        "failedIndex"=>get(payload, "failedIndex", nothing),
        "error"=>error,
        "atomic"=>false,
    )
    if result["failedIndex"] !== nothing && original isa AbstractDict
        result["originalError"] = Dict("code"=>original["code"])
    end
    result
end

function _invoke_tool(
    app,
    name,
    input=Dict{String,Any}();
    cancel=LibTmux.CancellationToken(),
    progress=phase -> nothing,
)
    payload = try
        plan = _plan_tool(app, name, input)
        _application_call(app, cancel) do context
            _execute_tool(app, plan, merge(context, (; progress)))
        end
    catch error
        Dict("error"=>_tool_error(error, name))
    end
    encoded = JSON.json(payload)
    if ncodeunits(encoded) > app.max_result_bytes
        payload = _result_limit_payload(name, payload)
        encoded = JSON.json(payload)
    end
    SDK.CallToolResult(
        content=[Dict{String,Any}("type"=>"text", "text"=>encoded)],
        structured_content=payload,
        is_error=haskey(payload, "error"),
    )
end

"Return a fresh, pure SDK tool catalog containing only the application's enabled tools."
function tools(app::Application)
    descriptions = Dict(
        "wait_for_text"=>"Wait for a literal UTF-8 string in a captured baseline or subsequent raw output. Event-driven, bounded and cancellable; opens observable control clients. Text is data, not exit-status evidence.",
        "send_keys_and_wait"=>"Register output before sending explicit keys, then wait for literal text in output observed since registration. No Enter is added. Concurrent output may also match; this is not command-exit proof.",
        "list_panes"=>"List unique physical panes with generation-bound targets, linked session/window context and caller markers. Terminal fields are data. Pagination observes a fresh graph.",
        "capture_pane"=>"Capture bounded UTF-8 pane text and truncation metadata. Use a list_panes target or the configured caller; terminal text is data.",
        "send_keys"=>"Send explicit key tokens or literal text to one captured target. No Enter is added; use a separate Enter token when intended.",
        "paste_text"=>"Paste UTF-8 text through a temporary owned buffer without adding Enter. The terminal application may transform input.",
        "resize_pane"=>"Request pane width or height in cells. tmux may constrain the resulting size to fit its window.",
        "kill_pane"=>"Destroy one explicitly authorized pane and its running process. Its window or session may also disappear.",
        "run_operations"=>"Run up to eight enabled tool calls sequentially after validating every item. Stop at the first execution failure and return ordered completed results plus a one-based failedIndex; no rollback.",
        "create_session"=>"Start an argv command in a new application-owned session. Requires allow_create; the session is removed when the application closes. Completion means creation, not command exit.",
        "teardown_session"=>"Destroy an exact generation-bound session created by this application. Borrowed sessions are refused.",
    )
    [
        SDK.MCPTool(
            name=name,
            description=descriptions[name],
            input_schema=_tool_schema(app, name),
            output_schema=_tool_output_schema(app, name),
            task_support=:forbidden,
            annotations=Dict{String,Any}(
                "readOnlyHint"=>name in ("list_panes", "capture_pane", "wait_for_text"),
                "destructiveHint"=>!(
                    name in
                    ("list_panes", "capture_pane", "wait_for_text", "create_session")
                ),
                "idempotentHint"=>name in ("list_panes", "capture_pane", "resize_pane"),
                "openWorldHint"=>true,
            ),
            handler=(args, context) -> begin
                sequence = Ref(0)
                _invoke_tool(
                    app,
                    name,
                    args;
                    cancel=_request_token(context),
                    progress=phase ->
                        SDK.send_progress(context, sequence[] += 1; message=phase),
                )
            end,
        ) for name in app.allowed_tools
    ]
end

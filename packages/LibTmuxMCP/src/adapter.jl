const _SUPPORTED_PROTOCOLS = ("2026-07-28", "2025-11-25")
const _REQUEST_CONTEXT_KEY = :libtmux_mcp_request

mutable struct _PendingRequest
    id::Union{Int,String}
    token::LibTmux.CancellationToken
    cancellation::Base.Event
    cancelled::Bool
    worker_done::Bool
    reply_done::Bool
end
_PendingRequest(id) =
    _PendingRequest(id, LibTmux.CancellationToken(), Base.Event(), false, false, false)

struct _Outbound
    message::String
    pending::Union{Nothing,_PendingRequest}
    final::Bool
end
mutable struct _Egress
    condition::Threads.Condition
    items::Vector{_Outbound}
    bytes::Int
    max_items::Int
    max_bytes::Int
    closed::Bool
end
_Egress(items, bytes) = _Egress(Threads.Condition(), _Outbound[], 0, items, bytes, false)

struct _Job
    message::String
    pending::_PendingRequest
    state::SDK.ServerState
end
mutable struct _Dispatcher
    lock::ReentrantLock
    pending::Dict{Union{Int,String},_PendingRequest}
    replies::Dict{Union{Int,String},_PendingRequest}
    jobs::Channel{_Job}
    output::_Egress
    closed::Bool
    failure::Union{Nothing,Exception}
end

function _retire_locked!(dispatcher, pending)
    if pending.worker_done && pending.reply_done
        for ledger in (dispatcher.pending, dispatcher.replies)
            get(ledger, pending.id, nothing) === pending && delete!(ledger, pending.id)
        end
    end
end
function _enqueue_reply!(dispatcher, id, message)
    pending = lock(dispatcher.lock) do
        dispatcher.closed && return nothing
        request = _PendingRequest(id)
        request.worker_done = true
        dispatcher.replies[id] = request
        request
    end
    pending === nothing && return false
    _enqueue!(dispatcher, message, pending; final=true) ||
        _finish_reply!(dispatcher, pending)
end
function _finish_reply!(dispatcher, pending)
    pending === nothing && return
    lock(dispatcher.lock) do
        pending.reply_done = true
        _retire_locked!(dispatcher, pending)
    end
end

function _enqueue!(dispatcher, message, pending=nothing; final=false)
    output = dispatcher.output
    bytes = ncodeunits(message)
    lock(output.condition) do
        output.closed && return false
        length(output.items) < output.max_items &&
        bytes <= output.max_bytes - output.bytes ||
            throw(ArgumentError("MCP output capacity exhausted"))
        push!(output.items, _Outbound(message, pending, final))
        output.bytes += bytes
        notify(output.condition)
        true
    end
end
function _take_output!(output)
    lock(output.condition) do
        while isempty(output.items) && !output.closed
            wait(output.condition)
        end
        isempty(output.items) && return nothing
        item = popfirst!(output.items)
        output.bytes -= ncodeunits(item.message)
        item
    end
end

function _record_failure_locked!(dispatcher, error)
    previous = dispatcher.failure
    previous === error && return
    dispatcher.failure =
        previous === nothing ? error : CompositeException([previous, error])
end

function _abort!(dispatcher, transport, error=nothing)
    tokens = lock(dispatcher.lock) do
        interrupted =
            dispatcher.closed && (
                error isa EOFError ||
                (error isa InvalidStateException && error.state === :closed)
            )
        error === nothing || interrupted || _record_failure_locked!(dispatcher, error)
        dispatcher.closed && return nothing
        dispatcher.closed = true
        tokens = LibTmux.CancellationToken[]
        for pending in
            Iterators.flatten((values(dispatcher.pending), values(dispatcher.replies)))
            pending.cancelled = true
            pending.reply_done = true
            notify(pending.cancellation)
            push!(tokens, pending.token)
        end
        empty!(dispatcher.replies)
        # Queued jobs remain in the channel for workers to retire without dispatch.
        close(dispatcher.jobs)
        tokens
    end
    tokens === nothing && return nothing
    for token in tokens
        try
            LibTmux.cancel!(token)
        catch error
            lock(() -> _record_failure_locked!(dispatcher, error), dispatcher.lock)
        end
    end
    lock(dispatcher.output.condition) do
        dispatcher.output.closed = true
        empty!(dispatcher.output.items)
        dispatcher.output.bytes = 0
        notify(dispatcher.output.condition; all=true)
    end
    try
        SDK.close(transport)
    catch cleanup
        lock(dispatcher.lock) do
            _record_failure_locked!(dispatcher, cleanup)
        end
    end
    nothing
end

struct _DispatchTransport{T<:SDK.Transport} <: SDK.Transport
    underlying::T
    dispatcher::_Dispatcher
end
_is_closed(dispatcher) = lock(() -> dispatcher.closed, dispatcher.lock)
SDK.is_connected(transport::_DispatchTransport) = !_is_closed(transport.dispatcher)
SDK.close(transport::_DispatchTransport) =
    _abort!(transport.dispatcher, transport.underlying)
function SDK.write_message(transport::_DispatchTransport, message::String)
    pending = get(task_local_storage(), _REQUEST_CONTEXT_KEY, nothing)
    try
        _enqueue!(transport.dispatcher, message, pending)
    catch error
        # SDK send_progress catches transport errors. Retire here before its
        # catch can turn output overflow into a successful, still-live request.
        _abort!(transport.dispatcher, transport.underlying, error)
        rethrow()
    end
    nothing
end

function _wait_for_cancellation(context)
    pending = get(task_local_storage(), _REQUEST_CONTEXT_KEY, nothing)
    pending isa _PendingRequest && pending.id == context.request_id ||
        throw(ArgumentError("no admitted MCP request context"))
    wait(pending.cancellation)
end
function _request_token(context)
    pending = get(task_local_storage(), _REQUEST_CONTEXT_KEY, nothing)
    pending isa _PendingRequest && pending.id == context.request_id ||
        throw(ArgumentError("no admitted MCP request context"))
    pending.token
end

function _state_snapshot(state)
    result = SDK.ServerState()
    result.initialized = state.initialized
    result.running = state.running
    result.protocol_version = state.protocol_version
    result
end
function _protocol_error(id, code, message)
    SDK.serialize_message(
        SDK.JSONRPCError(id=id, error=SDK.ErrorInfo(code=code, message=message)),
    )
end

function _bounded_json(message, max_bytes)
    ncodeunits(message) <= max_bytes ||
        throw(ArgumentError("MCP input byte limit exceeded"))
    isvalid(message) || throw(ArgumentError("MCP input is not UTF-8"))
    quoted, escaped, scalar = false, false, false
    depth, tokens = 0, 0
    for byte in codeunits(message)
        if quoted
            if escaped
                escaped = false
            elseif byte == 0x5c
                escaped = true
            elseif byte == 0x22
                quoted = false
            end
        elseif byte == 0x22
            quoted = true
            scalar = false
            tokens += 1
        elseif byte in (0x5b, 0x7b)
            depth += 1
            tokens += 1
            scalar = false
        elseif byte in (0x5d, 0x7d)
            depth -= 1
            scalar = false
        elseif byte in (0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x3a)
            scalar = false
        elseif !scalar
            scalar = true
            tokens += 1
        end
        depth <= 64 && tokens <= 16384 ||
            throw(ArgumentError("MCP input structure limit exceeded"))
    end
    JSON.parse(message; dicttype=Dict{String,Any}, duplicate_keys=:error, allownan=false)
end

function _discovery_response(response)
    response === nothing && return nothing
    object = JSON.parse(response; dicttype=Dict{String,Any})
    if haskey(object, "result")
        result = object["result"]
        result["supportedVersions"] = collect(_SUPPORTED_PROTOCOLS)
        # The pinned SDK advertises its tasks extension unconditionally.
        capabilities = result["capabilities"]
        filter!(pair -> first(pair) == "tools", capabilities)
    end
    JSON.json(object)
end

function _cancel_request!(dispatcher, id)
    token = lock(dispatcher.lock) do
        pending = get(dispatcher.pending, id, get(dispatcher.replies, id, nothing))
        pending === nothing && return nothing
        pending.cancelled = true
        notify(pending.cancellation)
        pending.token
    end
    token === nothing || LibTmux.cancel!(token)
    nothing
end

# The pinned SDK materializes nested JSON objects with Symbol keys. Normalize
# that representation only; arbitrary Julia dictionaries keep strict JSON keys.
_sdk_arguments(value) = value
_sdk_arguments(value::AbstractVector) = map(_sdk_arguments, value)
_sdk_arguments(value::SDK.JSON3.Object) =
    Dict{String,Any}(String(key) => _sdk_arguments(item) for (key, item) in pairs(value))
function _sdk_arguments(value::AbstractDict)
    all(key -> key isa String, keys(value)) ||
        throw(ArgumentError("JSON object keys must be strings"))
    Dict{String,Any}(key => _sdk_arguments(item) for (key, item) in pairs(value))
end
function _adapt_tool(tool::SDK.MCPTool)
    properties = (;
        (
            name => getfield(tool, name) for
            name in fieldnames(SDK.MCPTool) if name != :handler
        )...
    )
    SDK.MCPTool(;
        properties...,
        handler=(arguments, context) -> tool.handler(_sdk_arguments(arguments), context),
    )
end

"""
Private, pinned SDK adapter. The transport is owned by this call: close must
interrupt its reads/writes. A fixed worker pool owns ordinary tool requests;
only the writer performs outbound transport I/O. State-changing protocol
messages remain serialized in the caller/reader. No task extension is admitted.
"""
function _serve_transport(
    transport::SDK.Transport,
    tools;
    workers::Int=4,
    capacity::Int=16,
    max_input_bytes::Int=2 * 1024^2,
    max_output_bytes::Int=8 * 1024^2,
    logger::AbstractLogger=SimpleLogger(stderr, Logging.Warn),
)
    1 <= workers <= capacity <= 256 ||
        throw(ArgumentError("require 1 <= workers <= capacity <= 256"))
    max_input_bytes > 0 && max_output_bytes > 0 ||
        throw(ArgumentError("MCP byte limits must be positive"))
    dispatcher = _Dispatcher(
        ReentrantLock(),
        Dict{Union{Int,String},_PendingRequest}(),
        Dict{Union{Int,String},_PendingRequest}(),
        Channel{_Job}(capacity),
        _Egress(2 * capacity + 8, max_output_bytes),
        false,
        nothing,
    )
    wrapper = _DispatchTransport(transport, dispatcher)
    config = SDK.ServerConfig(
        name="libtmux",
        version="0.1.0",
        capabilities=SDK.Capability[SDK.ToolCapability()],
    )
    server = SDK.Server(config; transport=wrapper)
    for tool in tools
        tool isa SDK.MCPTool && tool.task_support === :forbidden ||
            throw(ArgumentError("only ordinary MCP tools are admitted"))
        SDK.register!(server, _adapt_tool(tool))
    end
    state = SDK.ServerState()
    writer = Threads.@spawn begin
        try
            while true
                item = _take_output!(dispatcher.output)
                item === nothing && break
                permitted = lock(dispatcher.lock) do
                    !dispatcher.closed &&
                        (item.pending === nothing || !item.pending.cancelled)
                end
                # This decision is the write commit point. Cancellation cannot
                # undo bytes from a write already committed before it arrived.
                permitted && SDK.write_message(transport, item.message)
                item.final && _finish_reply!(dispatcher, item.pending)
            end
        catch error
            _abort!(dispatcher, transport, error)
        end
    end
    pool = [
        Threads.@spawn begin
            with_logger(logger) do
                for job in dispatcher.jobs
                    pending = job.pending
                    task_local_storage(_REQUEST_CONTEXT_KEY, pending)
                    try
                        allowed = lock(dispatcher.lock) do
                            !dispatcher.closed && !pending.cancelled
                        end
                        if allowed
                            response = SDK.process_message(server, job.state, job.message)
                            if response !== nothing
                                _enqueue!(dispatcher, response, pending; final=true) ||
                                    _finish_reply!(dispatcher, pending)
                            else
                                _finish_reply!(dispatcher, pending)
                            end
                        else
                            _finish_reply!(dispatcher, pending)
                        end
                    catch error
                        _abort!(dispatcher, transport, error)
                    finally
                        delete!(task_local_storage(), _REQUEST_CONTEXT_KEY)
                        lock(dispatcher.lock) do
                            pending.worker_done = true
                            pending.cancelled && (pending.reply_done = true)
                            _retire_locked!(dispatcher, pending)
                        end
                    end
                end
            end
        end for _ = 1:workers
    ]
    try
        with_logger(logger) do
            while !_is_closed(dispatcher)
                message = SDK.read_message(transport)
                message === nothing && break
                object = try
                    _bounded_json(message, max_input_bytes)
                catch error
                    error isa Union{ArgumentError,JSON.DuplicateKeyError} || rethrow()
                    _enqueue!(
                        dispatcher,
                        _protocol_error(
                            nothing,
                            -32700,
                            "Invalid or over-limit JSON input",
                        ),
                    )
                    continue
                end
                if !(object isa AbstractDict) ||
                   get(object, "jsonrpc", nothing) != "2.0" ||
                   !(get(object, "method", nothing) isa String)
                    _enqueue!(
                        dispatcher,
                        _protocol_error(nothing, -32600, "Invalid JSON-RPC request"),
                    )
                    continue
                end
                method = object["method"]
                params = get(object, "params", Dict{String,Any}())
                if !haskey(object, "id")
                    if method == "notifications/cancelled" && params isa AbstractDict
                        id = get(params, "requestId", nothing)
                        id isa Union{Int,String} &&
                            !(id isa Bool) &&
                            _cancel_request!(dispatcher, id)
                    elseif method == "notifications/initialized"
                        SDK.process_message(server, state, message)
                    end
                    continue
                end
                id = object["id"]
                if !(id isa Union{Int,String}) || id isa Bool
                    _enqueue!(
                        dispatcher,
                        _protocol_error(
                            nothing,
                            -32600,
                            "Request ID must be an integer or string",
                        ),
                    )
                    continue
                end
                duplicate = lock(dispatcher.lock) do
                    haskey(dispatcher.pending, id) || haskey(dispatcher.replies, id)
                end
                if duplicate
                    _enqueue!(
                        dispatcher,
                        _protocol_error(nothing, -32600, "Duplicate active request ID"),
                    )
                    continue
                end
                metadata = params isa AbstractDict ? get(params, "_meta", nothing) : nothing
                version =
                    metadata isa AbstractDict ?
                    get(metadata, "io.modelcontextprotocol/protocolVersion", nothing) :
                    nothing
                if version !== nothing && version != first(_SUPPORTED_PROTOCOLS)
                    _enqueue_reply!(
                        dispatcher,
                        id,
                        _protocol_error(id, -32602, "Unsupported modern protocol version"),
                    )
                    continue
                end
                if method == "tools/call"
                    admitted = lock(dispatcher.lock) do
                        length(dispatcher.pending) < capacity || return nothing
                        pending = _PendingRequest(id)
                        dispatcher.pending[id] = pending
                        pending
                    end
                    if admitted === nothing
                        _enqueue_reply!(
                            dispatcher,
                            id,
                            _protocol_error(id, -32000, "Request capacity exhausted"),
                        )
                    else
                        put!(
                            dispatcher.jobs,
                            _Job(message, admitted, _state_snapshot(state)),
                        )
                    end
                elseif method in ("server/discover", "initialize", "tools/list", "ping")
                    if method == "initialize"
                        idle = lock(dispatcher.lock) do
                            isempty(dispatcher.pending) && isempty(dispatcher.replies)
                        end
                        if !idle ||
                           !(params isa AbstractDict) ||
                           get(params, "protocolVersion", nothing) !=
                           last(_SUPPORTED_PROTOCOLS)
                            _enqueue_reply!(
                                dispatcher,
                                id,
                                _protocol_error(
                                    id,
                                    -32602,
                                    "Legacy initialization requires an idle session and version 2025-11-25",
                                ),
                            )
                            continue
                        end
                    end
                    response = SDK.process_message(server, state, message)
                    method == "server/discover" &&
                        (response = _discovery_response(response))
                    response === nothing || _enqueue_reply!(dispatcher, id, response)
                else
                    _enqueue_reply!(
                        dispatcher,
                        id,
                        _protocol_error(id, -32601, "Method is not enabled"),
                    )
                end
            end
        end
    catch error
        _is_closed(dispatcher) || _abort!(dispatcher, transport, error)
    finally
        _abort!(dispatcher, transport)
        foreach(fetch, pool)
        fetch(writer)
    end
    dispatcher.failure === nothing || throw(dispatcher.failure)
    (;
        tasks=[pool; writer],
        remaining=length(dispatcher.pending) + length(dispatcher.replies),
    )
end

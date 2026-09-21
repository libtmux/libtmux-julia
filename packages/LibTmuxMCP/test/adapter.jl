using Test, LibTmuxMCP, ModelContextProtocol, Logging
import JSON as Codec
const SDK = ModelContextProtocol

@testset "MCP package metadata" begin
    @test Base.pkgversion(LibTmuxMCP) isa VersionNumber
    @test LibTmuxMCP._PACKAGE_VERSION == Base.pkgversion(LibTmuxMCP)
end

function protocol_request(id, method, params=Dict())
    metadata = Dict(
        "io.modelcontextprotocol/protocolVersion"=>"2026-07-28",
        "io.modelcontextprotocol/clientCapabilities"=>Dict(),
    )
    Codec.json(
        Dict(
            "jsonrpc"=>"2.0",
            "id"=>id,
            "method"=>method,
            "params"=>merge(Dict("_meta"=>metadata), params),
        ),
    )
end
protocol_response(t) = Codec.parse(take!(t.output); dicttype=Dict{String,Any})
legacy_request(id, method, params=Dict()) =
    Codec.json(Dict("jsonrpc"=>"2.0", "id"=>id, "method"=>method, "params"=>params))
cancel_request(id) = Codec.json(
    Dict(
        "jsonrpc"=>"2.0",
        "method"=>"notifications/cancelled",
        "params"=>Dict("requestId"=>id),
    ),
)

mutable struct MemoryProtocol <: SDK.Transport
    input::Channel{Union{Nothing,String}}
    output::Channel{String}
    lock::ReentrantLock
    connected::Bool
end

mutable struct GatedProtocol <: SDK.Transport
    input::Channel{Union{Nothing,String}}
    output::Channel{String}
    entered::Channel{String}
    read_entries::Channel{Union{Nothing,String}}
    release::Base.Event
    lock::ReentrantLock
    connected::Bool
    write_error::Union{Nothing,Exception}
    close_error::Union{Nothing,Exception}
    close_calls::Int
end
GatedProtocol(; write_error=nothing, close_error=nothing) = GatedProtocol(
    Channel{Union{Nothing,String}}(32),
    Channel{String}(32),
    Channel{String}(32),
    Channel{Union{Nothing,String}}(32),
    Base.Event(),
    ReentrantLock(),
    true,
    write_error,
    close_error,
    0,
)
function SDK.read_message(t::GatedProtocol)
    message = take!(t.input)
    put!(t.read_entries, message)
    message
end
SDK.is_connected(t::GatedProtocol) = lock(() -> t.connected, t.lock)
function SDK.write_message(t::GatedProtocol, value::String)
    put!(t.entered, value)
    wait(t.release)
    lock(t.lock) do
        t.write_error === nothing || throw(t.write_error)
        t.connected || throw(EOFError())
    end
    put!(t.output, value)
    nothing
end
function SDK.close(t::GatedProtocol)
    lock(t.lock) do
        t.connected = false
        isopen(t.input) && close(t.input)
        notify(t.release)
        t.close_calls += 1
        t.close_error === nothing || throw(t.close_error)
    end
    nothing
end

@testset "blocked writer permits cancellation and clean EOF" begin
    transport = GatedProtocol()
    entered, finished = Base.Event(), Base.Event()
    tool = SDK.MCPTool(
        name="wait",
        description="Wait for cancellation",
        input_schema=Dict("type"=>"object"),
        handler=(args, context) -> begin
            notify(entered)
            LibTmuxMCP._wait_for_cancellation(context)
            notify(finished)
            SDK.TextContent(text="cancelled response")
        end,
    )
    task = Threads.@spawn try
        LibTmuxMCP._serve_transport(transport, [tool]; workers=1, capacity=1)
    catch error
        error
    end
    try
        put!(transport.input, protocol_request("wait", "tools/call", Dict("name"=>"wait")))
        wait(entered)
        put!(transport.input, protocol_request("blocked-discovery", "server/discover"))
        @test Codec.parse(take!(transport.entered))["id"] == "blocked-discovery"
        put!(
            transport.input,
            Codec.json(
                Dict(
                    "jsonrpc"=>"2.0",
                    "method"=>"notifications/cancelled",
                    "params"=>Dict("requestId"=>"wait"),
                ),
            ),
        )
        wait(finished)
        @test !isready(transport.output)
        put!(transport.input, nothing)
        result = fetch(task)
        @test !(result isa Exception)
        if !(result isa Exception)
            @test all(istaskdone, result.tasks) && result.remaining == 0
        end
        @test !SDK.is_connected(transport)
    finally
        SDK.close(transport)
        fetch(task)
    end
end
MemoryProtocol() = MemoryProtocol(
    Channel{Union{Nothing,String}}(32),
    Channel{String}(32),
    ReentrantLock(),
    true,
)
SDK.read_message(t::MemoryProtocol) = take!(t.input)
SDK.write_message(t::MemoryProtocol, value::String) = (put!(t.output, value); nothing)
SDK.is_connected(t::MemoryProtocol) = lock(() -> t.connected, t.lock)
function SDK.close(t::MemoryProtocol)
    lock(t.lock) do
        t.connected = false
        isopen(t.input) && close(t.input)
        isopen(t.output) && close(t.output)
    end
    nothing
end

@testset "ordinary MCP waits preserve discovery and cancellation" begin
    @test isdefined(LibTmuxMCP, :_serve_transport)
    if isdefined(LibTmuxMCP, :_serve_transport)
        transport = MemoryProtocol()
        entered = Channel{Any}(4)
        finished = Channel{Any}(4)
        original_logger = global_logger()
        handler = (args, context) -> begin
            put!(entered, context.request_id)
            LibTmuxMCP._wait_for_cancellation(context)
            put!(finished, context.request_id)
            SDK.TextContent(text="must be suppressed")
        end
        tool = SDK.MCPTool(
            name="wait",
            description="Wait for cancellation",
            input_schema=Dict("type"=>"object", "additionalProperties"=>false),
            handler=handler,
        )
        task = Threads.@spawn LibTmuxMCP._serve_transport(
            transport,
            [tool];
            workers=2,
            capacity=2,
        )
        try
            put!(transport.input, protocol_request("discovery", "server/discover"))
            discovery = protocol_response(transport)
            @test discovery["id"] == "discovery"
            @test discovery["result"]["supportedVersions"] == ["2026-07-28", "2025-11-25"]
            @test discovery["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["version"] ==
                  string(Base.pkgversion(LibTmuxMCP))
            for id in ("first", 2)
                put!(
                    transport.input,
                    protocol_request(
                        id,
                        "tools/call",
                        Dict("name"=>"wait", "arguments"=>Dict()),
                    ),
                )
                @test take!(entered) == id
            end
            put!(
                transport.input,
                protocol_request(
                    "busy",
                    "tools/call",
                    Dict("name"=>"wait", "arguments"=>Dict()),
                ),
            )
            @test haskey(protocol_response(transport), "error")
            put!(transport.input, protocol_request("still-responsive", "server/discover"))
            @test protocol_response(transport)["id"] == "still-responsive"
            put!(
                transport.input,
                Codec.json(
                    Dict(
                        "jsonrpc"=>"2.0",
                        "method"=>"notifications/cancelled",
                        "params"=>Dict("requestId"=>"first"),
                    ),
                ),
            )
            @test take!(finished) == "first"
            put!(transport.input, protocol_request("barrier", "server/discover"))
            @test protocol_response(transport)["id"] == "barrier"
            @test !isready(transport.output)
            put!(transport.input, nothing)
            result = fetch(task)
            @test take!(finished) == 2
            @test all(istaskdone, result.tasks)
            @test result.remaining == 0
            @test !transport.connected
            @test global_logger() === original_logger
        finally
            istaskdone(task) || (isopen(transport.input) && put!(transport.input, nothing))
            fetch(task)
        end
    end
end

@testset "genuine write failures survive a shutdown race" begin
    for (failure, eof_first) in (
        (ErrorException("write failed"), false),
        (ErrorException("write failed during close"), true),
        (EOFError(), false),
    )
        transport = GatedProtocol(; write_error=failure)
        task = Threads.@spawn try
            LibTmuxMCP._serve_transport(transport, SDK.MCPTool[]; workers=1, capacity=1)
        catch error
            error
        end
        try
            put!(transport.input, protocol_request("discovery", "server/discover"))
            take!(transport.entered)
            eof_first ? put!(transport.input, nothing) : notify(transport.release)
            @test fetch(task) === failure
            @test !SDK.is_connected(transport)
        finally
            SDK.close(transport)
            fetch(task)
        end
    end
end

@testset "legacy state, modern discovery, identity and progress" begin
    transport = MemoryProtocol()
    entered, finished = Channel{Any}(2), Channel{Any}(2)
    handler =
        (args, context) -> begin
            SDK.send_progress(context, 1; total=2)
            put!(
                entered,
                (context.request_id, SDK.request_protocol_version(context), context.state),
            )
            LibTmuxMCP._wait_for_cancellation(context)
            SDK.send_progress(context, 2; total=2)
            put!(finished, context.request_id)
            SDK.TextContent(text="cancelled")
        end
    tool = SDK.MCPTool(
        name="wait",
        description="Wait for cancellation",
        input_schema=Dict("type"=>"object"),
        handler=handler,
    )
    task =
        Threads.@spawn LibTmuxMCP._serve_transport(transport, [tool]; workers=2, capacity=2)
    init = Dict(
        "protocolVersion"=>"2025-11-25",
        "capabilities"=>Dict(),
        "clientInfo"=>Dict("name"=>"test", "version"=>"1"),
    )
    try
        put!(transport.input, legacy_request("initialize", "initialize", init))
        response = protocol_response(transport)
        @test response["result"]["protocolVersion"] == "2025-11-25"
        @test response["result"]["serverInfo"]["version"] ==
              string(Base.pkgversion(LibTmuxMCP))
        @test Set(keys(response["result"]["capabilities"])) == Set(["tools"])
        put!(
            transport.input,
            Codec.json(Dict("jsonrpc"=>"2.0", "method"=>"notifications/initialized")),
        )
        put!(
            transport.input,
            legacy_request(
                1,
                "tools/call",
                Dict("name"=>"wait", "_meta"=>Dict("progressToken"=>"legacy-progress")),
            ),
        )
        legacy = take!(entered)
        @test legacy[1:2] == (1, "2025-11-25")
        @test protocol_response(transport)["params"]["progressToken"] == "legacy-progress"
        modern = Codec.parse(
            protocol_request("1", "tools/call", Dict("name"=>"wait"));
            dicttype=Dict{String,Any},
        )
        modern["params"]["_meta"]["progressToken"] = 17
        put!(transport.input, Codec.json(modern))
        admitted = take!(entered)
        @test admitted[1:2] == ("1", "2026-07-28")
        @test admitted[3] !== legacy[3]
        @test protocol_response(transport)["params"]["progressToken"] == 17
        put!(transport.input, protocol_request(1, "tools/call", Dict("name"=>"wait")))
        duplicate = protocol_response(transport)
        @test duplicate["id"] === nothing &&
              duplicate["error"]["message"] == "Duplicate active request ID"
        put!(transport.input, legacy_request("reinitialize", "initialize", init))
        @test protocol_response(transport)["error"]["code"] == -32602
        put!(transport.input, protocol_request("discover", "server/discover"))
        discovery = protocol_response(transport)
        @test Set(keys(discovery["result"]["capabilities"])) == Set(["tools"])
        @test discovery["result"]["supportedVersions"] == ["2026-07-28", "2025-11-25"]
        put!(transport.input, cancel_request(1))
        @test take!(finished) === 1
        put!(transport.input, protocol_request("barrier", "server/discover"))
        @test protocol_response(transport)["id"] == "barrier"
        @test !isready(transport.output)
        put!(transport.input, cancel_request("1"))
        @test take!(finished) == "1"
        put!(transport.input, nothing)
        result = fetch(task)
        @test result.remaining == 0 && all(istaskdone, result.tasks)
    finally
        isopen(transport.input) && put!(transport.input, nothing)
        fetch(task)
    end
end

@testset "progress queue overflow closes instead of blocking admission" begin
    for (limit, message, count) in ((65536, "tick", 32), (4096, repeat("x", 8192), 1))
        transport = GatedProtocol()
        produced = Base.Event()
        tool = SDK.MCPTool(
            name="burst",
            description="Produce progress",
            input_schema=Dict("type"=>"object"),
            handler=(args, context) -> begin
                for index = 1:count
                    SDK.send_progress(context, index; message)
                end
                notify(produced)
                LibTmuxMCP._wait_for_cancellation(context)
                SDK.TextContent(text="cancelled")
            end,
        )
        task = Threads.@spawn try
            LibTmuxMCP._serve_transport(
                transport,
                [tool];
                workers=1,
                capacity=1,
                max_output_bytes=limit,
            )
        catch error
            error
        end
        try
            put!(transport.input, protocol_request("blocked", "server/discover"))
            take!(transport.entered)
            request = Codec.parse(
                protocol_request("burst", "tools/call", Dict("name"=>"burst"));
                dicttype=Dict{String,Any},
            )
            request["params"]["_meta"]["progressToken"] = "burst"
            put!(transport.input, Codec.json(request))
            wait(produced)
            @test !SDK.is_connected(transport)
            isopen(transport.input) && put!(transport.input, nothing)
            failure = fetch(task)
            @test failure isa ArgumentError &&
                  occursin("output capacity", sprint(showerror, failure))
        finally
            SDK.close(transport)
            fetch(task)
        end
    end
end

@testset "writer and cleanup errors are both retained" begin
    primary, cleanup = ErrorException("write failed"), ErrorException("close failed")
    transport = GatedProtocol(; write_error=primary, close_error=cleanup)
    task = Threads.@spawn try
        LibTmuxMCP._serve_transport(transport, SDK.MCPTool[]; workers=1, capacity=1)
    catch error
        error
    end
    try
        put!(transport.input, protocol_request("discovery", "server/discover"))
        take!(transport.entered)
        notify(transport.release)
        failure = fetch(task)
        @test failure isa CompositeException
        if failure isa CompositeException
            @test failure.exceptions == [primary, cleanup]
        end
        @test transport.close_calls == 1
    finally
        SDK.is_connected(transport) && try
            SDK.close(transport)
        catch
        end
        fetch(task)
    end
end

@testset "discovery identity lasts until its queued reply retires" begin
    transport = GatedProtocol()
    task = Threads.@spawn LibTmuxMCP._serve_transport(
        transport,
        SDK.MCPTool[];
        workers=1,
        capacity=1,
    )
    try
        put!(transport.input, protocol_request("same", "server/discover"))
        take!(transport.entered)
        put!(transport.input, protocol_request("same", "tools/list"))
        put!(transport.input, protocol_request("barrier", "server/discover"))
        # The reader takes the barrier only after admitting the duplicate.
        for _ = 1:3
            take!(transport.read_entries)
        end
        notify(transport.release)
        @test protocol_response(transport)["id"] == "same"
        duplicate = protocol_response(transport)
        @test get(duplicate, "id", missing) === nothing &&
              get(get(duplicate, "error", Dict()), "message", "") ==
              "Duplicate active request ID"
        @test protocol_response(transport)["id"] == "barrier"
        put!(transport.input, nothing)
        @test fetch(task).remaining == 0
    finally
        SDK.close(transport)
        fetch(task)
    end
end

@testset "request boundary rejects ambiguous identities and over-limit JSON" begin
    transport = MemoryProtocol()
    task = Threads.@spawn LibTmuxMCP._serve_transport(
        transport,
        SDK.MCPTool[];
        workers=1,
        capacity=1,
        max_input_bytes=512,
    )
    try
        requests = (
            (protocol_request(true, "ping"), -32600),
            (protocol_request(1.5, "ping"), -32600),
            ("{", -32700),
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":2,\"method\":\"ping\"}", -32700),
            (repeat("[", 65) * repeat("]", 65), -32700),
            (repeat(" ", 513), -32700),
            (
                protocol_request(
                    "unsupported",
                    "ping",
                    Dict(
                        "_meta" => Dict(
                            "io.modelcontextprotocol/protocolVersion"=>"2025-03-26",
                        ),
                    ),
                ),
                -32602,
            ),
        )
        for (request, code) in requests
            put!(transport.input, request)
            @test protocol_response(transport)["error"]["code"] == code
        end
        put!(transport.input, nothing)
        result = fetch(task)
        @test result.remaining == 0 && all(istaskdone, result.tasks)
    finally
        isopen(transport.input) && put!(transport.input, nothing)
        fetch(task)
    end
end

@testset "a failing cancellation callback does not skip other requests" begin
    transport = MemoryProtocol()
    entered = Channel{Any}(2)
    failure = ErrorException("cancellation hook failed")
    tool = SDK.MCPTool(
        name="wait",
        description="Wait for core cancellation",
        input_schema=Dict("type"=>"object"),
        handler=(args, context) -> begin
            token = LibTmuxMCP._request_token(context)
            cancelled = Base.Event()
            subscription = LibTmuxMCP.LibTmux.on_cancel(token) do
                notify(cancelled)
                context.request_id == "bad" && throw(failure)
            end
            put!(entered, token)
            try
                wait(cancelled)
                SDK.TextContent(text="cancelled")
            finally
                close(subscription)
            end
        end,
    )
    task = Threads.@spawn try
        LibTmuxMCP._serve_transport(transport, [tool]; workers=2, capacity=2)
    catch error
        error
    end
    tokens = Any[]
    try
        for id in ("bad", "other")
            put!(transport.input, protocol_request(id, "tools/call", Dict("name"=>"wait")))
            push!(tokens, take!(entered))
        end
        put!(transport.input, nothing)
        result = fetch(task)
        @test result isa Exception &&
              occursin("cancellation hook failed", sprint(showerror, result))
        @test all(LibTmuxMCP.LibTmux.iscancelled, tokens)
        @test !SDK.is_connected(transport)
    finally
        isopen(transport.input) && put!(transport.input, nothing)
        fetch(task)
    end
end

@testset "SDK nested JSON arguments retain string-key policy" begin
    server = LibTmuxMCP.LibTmux.Server(socket_path="/tmp/libtmux-julia-uncontacted/s")
    identity = LibTmuxMCP.LibTmux.ServerIdentity(
        socket_path=server.socket_path,
        generation="observed",
    )
    caller = LibTmuxMCP.LibTmux.PaneRef(identity, "%1")
    app = Application(
        server;
        caller,
        allowed_panes=[caller],
        allowed_tools=("capture_pane", "send_keys", "run_operations"),
    )
    transport = MemoryProtocol()
    task = Threads.@spawn LibTmuxMCP._serve_transport(
        transport,
        tools(app);
        workers=1,
        capacity=1,
    )
    try
        target = Dict("paneId"=>"%999999", "generation"=>"observed")
        calls = (
            ("capture_pane", Dict("target"=>target)),
            (
                "run_operations",
                Dict(
                    "operations"=>[
                        Dict(
                            "tool"=>"send_keys",
                            "arguments"=>Dict("target"=>target, "keys"=>["blocked"]),
                        ),
                    ],
                ),
            ),
        )
        for (name, arguments) in calls
            put!(
                transport.input,
                protocol_request(
                    name,
                    "tools/call",
                    Dict("name"=>name, "arguments"=>arguments),
                ),
            )
            response = protocol_response(transport)["result"]
            @test response["isError"]
            @test response["structuredContent"]["error"]["code"] == "target_denied"
        end
        @test_throws ArgumentError LibTmuxMCP._check_object(
            Dict(:paneId=>"%1"),
            ("paneId",),
        )
        put!(transport.input, nothing)
        @test fetch(task).remaining == 0
    finally
        isopen(transport.input) && put!(transport.input, nothing)
        fetch(task)
        close(app)
    end
end

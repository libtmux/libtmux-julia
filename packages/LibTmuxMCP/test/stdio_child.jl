using LibTmuxMCP
import ModelContextProtocol as SDK

waiting = SDK.MCPTool(
    name="wait",
    description="Admission probe: wait until cancellation",
    input_schema=Dict("type"=>"object"),
    handler=(args, context) -> begin
        SDK.send_progress(context, 0; total=1, message="waiting")
        LibTmuxMCP._wait_for_cancellation(context)
        SDK.TextContent(text="must not be emitted after cancellation")
    end,
)
transport = LibTmuxMCP._StdioTransport(stdin, stdout)
catalog = if ARGS == ["backpressure"]
    [
        SDK.MCPTool(
            name="large",
            description="Retirement probe: fill the real default stdout pipe",
            input_schema=Dict("type"=>"object"),
            handler=(args, context) -> SDK.TextContent(text=repeat("x", 2 * 1024^2)),
        ),
    ]
else
    [waiting]
end
LibTmuxMCP._serve_transport(transport, catalog; workers=2, capacity=2)

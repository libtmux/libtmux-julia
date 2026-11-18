using Test, LibTmux, LibTmuxMCP

@testset "MCP capability discovery preserves policy and native evidence" begin
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        new_session(server; name="capabilities", command=["/bin/cat"])
        app = Application(server)
        limited = Application(server; allowed_tools=("list_panes",))
        bounded =
            Application(server; allowed_tools=("get_capabilities",), max_result_bytes=1024)
        try
            tool = only(filter(t -> t.name == "get_capabilities", tools(app)))
            @test tool.annotations["readOnlyHint"]
            @test !tool.annotations["destructiveHint"]
            @test isempty(tool.input_schema["properties"])
            @test !tool.input_schema["additionalProperties"]
            invoke(args=Dict(); kwargs...) =
                LibTmuxMCP._invoke_tool(app, "get_capabilities", args; kwargs...)
            result = invoke()
            @test !result.is_error
            payload = result.structured_content
            native = capabilities(server)
            @test payload["generation"] == native.generation
            @test payload["version"] == native.version
            @test Set(payload["enabledTools"]) == Set(t.name for t in tools(app))
            @test Set(c["id"] for c in payload["features"]) ==
                  Set(c.id for c in native.features)
            for entry in payload["features"]
                @test entry["supported"] == supports(native, entry["id"])
            end
            for entry in payload["workarounds"]
                @test entry["active"] == workaround(native, entry["id"]).active
            end
            success =
                only(filter(s -> "features" in s["required"], tool.output_schema["anyOf"]))
            @test Set(keys(payload)) == Set(success["required"])
            @test Set(keys(first(payload["features"]))) ==
                  Set(success["properties"]["features"]["items"]["required"])
            @test invoke(Dict("target"=>"%0")).structured_content["error"]["code"] ==
                  "invalid_arguments"
            token = CancellationToken()
            cancel!(token)
            @test invoke(; cancel=token).structured_content["error"]["code"] == "cancelled"
            denied = LibTmuxMCP._invoke_tool(limited, "get_capabilities", Dict())
            @test denied.structured_content["error"]["code"] == "tool_denied"
            short = LibTmuxMCP._invoke_tool(bounded, "get_capabilities", Dict())
            @test short.structured_content["error"]["code"] == "result_limit"
            @test short.structured_content["error"]["effects"] == "none"
        finally
            close(app)
            close(limited)
            close(bounded)
        end
        @test isopen(app) == false
        @test length(sessions(snapshot(server))) == 1
    end
end

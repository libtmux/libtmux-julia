using Test, LibTmux, LibTmuxMCP
import ModelContextProtocol as ToolSDK

tool_result(app, name, args=Dict(); kwargs...) =
    LibTmuxMCP._invoke_tool(app, name, args; kwargs...)
pane_target(ref) = Dict("paneId"=>string(ref.id), "generation"=>ref.server.generation)

if isempty(ARGS) || any(arg -> arg in ("baseline", "unit", "all"), ARGS)
    @testset "MCP failures preserve possible effects after process admission" begin
        result = CommandResult(UInt8[0x61], UInt8[], 0, 0)
        for failure in (
            ProcessIOError(:stdout, EOFError(), result),
            OutputLimitExceeded(:stdout, 1, result),
        )
            @test LibTmuxMCP._tool_error(failure, "send_keys")["effects"] == "possible"
            @test LibTmuxMCP._tool_error(failure, "capture_pane")["effects"] == "none"
        end
    end

    @testset "MCP application catalog is pure and policy is copied" begin
        permitted = ["list_panes", "capture_pane", "send_keys", "run_operations"]
        app = LibTmuxMCP.Application(
            Server(socket_path="/tmp/libtmux-julia-uncontacted/s");
            allowed_tools=permitted,
        )
        empty!(permitted)
        catalog = LibTmuxMCP.tools(app)
        @test Set(tool.name for tool in catalog) ==
              Set(["list_panes", "capture_pane", "send_keys", "run_operations"])
        @test all(
            tool -> tool.input_schema !== nothing && tool.output_schema !== nothing,
            catalog,
        )
        @test all(tool -> tool.task_support === :forbidden, catalog)
        @test only(filter(tool->tool.name=="capture_pane", catalog)).annotations["readOnlyHint"]
        @test !only(filter(tool->tool.name=="send_keys", catalog)).annotations["idempotentHint"]
        @test all(
            tool -> "target" in tool.input_schema["required"],
            filter(tool -> tool.name in ("capture_pane", "send_keys"), catalog),
        )
        caller = PaneRef(
            ServerIdentity(socket_path=app.server.socket_path, generation="1:1"),
            "%0",
        )
        caller_app = Application(app.server; caller)
        try
            @test all(
                tool -> !("target" in tool.input_schema["required"]),
                filter(
                    tool -> tool.name in ("capture_pane", "send_keys"),
                    tools(caller_app),
                ),
            )
        finally
            close(caller_app)
        end
        capture_schema =
            only(filter(tool -> tool.name == "capture_pane", catalog)).output_schema
        @test "text" in capture_schema["anyOf"][1]["required"]
        batch_schema =
            only(filter(tool -> tool.name == "run_operations", catalog)).output_schema
        partial = filter(batch_schema["anyOf"]) do branch
            Set(get(branch, "required", String[])) ==
            Set(["completed", "failedIndex", "error", "atomic"])
        end
        @test length(partial) == 1
        if length(partial) == 1
            fields = only(partial)["properties"]
            @test fields["failedIndex"] == LibTmuxMCP._integer_schema(1, 8)
            @test Set(fields["completed"]["items"]["required"]) == Set(["tool", "result"])
            @test Set(fields["error"]["required"]) ==
                  Set(["code", "message", "effects", "retryable"])
            @test fields["atomic"] == Dict("const"=>false)
        end
        succeeded = filter(batch_schema["anyOf"]) do branch
            Set(get(branch, "required", String[])) ==
            Set(["completed", "failedIndex", "atomic"])
        end
        @test length(succeeded) == 1
        length(succeeded) == 1 &&
            @test only(succeeded)["properties"]["failedIndex"] == Dict("type"=>"null")
        @test_throws ArgumentError LibTmuxMCP.Application(
            Server(socket_path="/tmp/libtmux-julia-uncontacted/s");
            allowed_tools=["unknown"],
        )
        @test_throws ArgumentError Application(
            Server(socket_path="/tmp/libtmux-julia-uncontacted/s");
            allowed_tools=("run_operations",),
        )
        close(app)
        @test !isopen(app)
        @test close(app) === nothing
    end

end

if isempty(ARGS) || any(arg -> arg in ("baseline", "integration", "all"), ARGS)
    @testset "MCP tools use exact authorized real-tmux targets" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
        )
        LibTmux.with_server(;
            tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
            env=environment,
        ) do server
            signal = "mcp-tools-ready"
            command = [
                "/bin/sh",
                "-c",
                "IFS= read -r line; printf '%s\\n' \"\$line\"; \"\$1\" -N -S \"\$2\" wait-for -S \"\$3\"; exec /bin/cat",
                "sh",
                server.tmux,
                server.socket_path,
                signal,
            ]
            session = new_session(server; name="caller", command)
            caller = only(panes(snapshot(server))).ref
            other = split_window(server, caller; command=["/bin/cat"])
            allowed = [caller]
            app = Application(
                server;
                caller,
                allowed_panes=allowed,
                allowed_tools=(
                    "list_panes",
                    "capture_pane",
                    "send_keys",
                    "paste_text",
                    "resize_pane",
                    "kill_pane",
                    "run_operations",
                ),
            )
            empty!(allowed)
            try
                listing = tool_result(app, "list_panes")
                @test !listing.is_error
                row = only(listing.structured_content["panes"])
                @test row["target"] == pane_target(caller) && row["caller"]
                @test only(row["contexts"])["sessionName"] == "caller"
                @test listing.structured_content["generationGuarantee"] == "best_effort"
                denied = tool_result(
                    app,
                    "send_keys",
                    Dict("target"=>pane_target(other), "keys"=>["blocked"]),
                )
                @test denied.is_error &&
                      denied.structured_content["error"]["code"] == "target_denied"
                sent = tool_result(app, "send_keys", Dict("keys"=>["hello λ", "Enter"]))
                @test !sent.is_error && sent.structured_content["completed"]
                run_command(server, "wait-for", signal; timeout=0.9)
                captured = tool_result(app, "capture_pane")
                @test !captured.is_error &&
                      occursin("hello λ", captured.structured_content["text"])
                @test captured.structured_content["terminalContent"] == "data"
                bounded = tool_result(app, "capture_pane", Dict("maxBytes"=>7))
                @test !bounded.is_error && bounded.structured_content["truncated"]
                @test bounded.structured_content["text"] == "hello "
                before = captured.structured_content["text"]
                batch = tool_result(
                    app,
                    "run_operations",
                    Dict(
                        "operations"=>[
                            Dict(
                                "tool"=>"send_keys",
                                "arguments"=>Dict("keys"=>["must-not-arrive"]),
                            ),
                            Dict(
                                "tool"=>"kill_pane",
                                "arguments"=>Dict("target"=>pane_target(other)),
                            ),
                        ],
                    ),
                )
                @test batch.is_error &&
                      batch.structured_content["error"]["code"] == "target_denied"
                @test tool_result(app, "capture_pane").structured_content["text"] == before
                pasted = tool_result(app, "paste_text", Dict("text"=>"paste text"))
                @test !pasted.is_error
                @test isempty(run_command(server, "list-buffers").stdout)
                resized = tool_result(app, "resize_pane", Dict("height"=>5))
                @test !resized.is_error
                no_caller = Application(server)
                try
                    missing = tool_result(no_caller, "capture_pane")
                    @test missing.is_error &&
                          missing.structured_content["error"]["code"] == "target_required"
                    stale = tool_result(
                        no_caller,
                        "capture_pane",
                        Dict(
                            "target" => Dict(
                                "paneId"=>string(caller.id),
                                "generation"=>"stale",
                            ),
                        ),
                    )
                    @test stale.is_error &&
                          stale.structured_content["error"]["code"] == "stale_target"
                finally
                    close(no_caller)
                end
                batch_app = Application(
                    server;
                    caller,
                    allowed_tools=("send_keys", "capture_pane", "run_operations"),
                )
                try
                    partial = tool_result(
                        batch_app,
                        "run_operations",
                        Dict(
                            "operations"=>[
                                Dict(
                                    "tool"=>"send_keys",
                                    "arguments"=>Dict("keys"=>["batch-started"]),
                                ),
                                Dict(
                                    "tool"=>"capture_pane",
                                    "arguments"=>Dict(
                                        "target" => Dict(
                                            "paneId"=>string(caller.id),
                                            "generation"=>"stale",
                                        ),
                                    ),
                                ),
                            ],
                        ),
                    )
                    @test partial.is_error && partial.structured_content["failedIndex"] == 2
                    @test only(partial.structured_content["completed"])["result"]["completed"]
                    @test partial.structured_content["error"]["code"] == "stale_target"
                finally
                    close(batch_app)
                end
                token = CancellationToken()
                cancel!(token)
                cancelled =
                    tool_result(app, "send_keys", Dict("keys"=>["cancelled"]); cancel=token)
                @test cancelled.is_error &&
                      cancelled.structured_content["error"]["code"] == "cancelled"
                killed = tool_result(app, "kill_pane")
                @test !killed.is_error
                @test capture_pane(server, other) isa String
            finally
                close(app)
            end
            @test tool_result(app, "list_panes").structured_content["error"]["code"] ==
                  "closed"
        end
    end

    @testset "MCP creation and teardown retain application ownership" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
        )
        LibTmux.with_server(;
            tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
            env=environment,
        ) do server
            borrowed = new_session(server; name="borrowed", command=["/bin/cat"])
            caller = only(panes(snapshot(server))).ref
            names = (
                "list_panes",
                "create_session",
                "teardown_session",
                "capture_pane",
                "send_keys",
                "run_operations",
            )
            app = Application(
                server;
                caller,
                allowed_panes=[caller],
                allowed_tools=names,
                allow_create=true,
            )
            try
                denied = tool_result(
                    app,
                    "teardown_session",
                    Dict(
                        "sessionId"=>string(borrowed.id),
                        "generation"=>borrowed.server.generation,
                    ),
                )
                @test denied.is_error &&
                      denied.structured_content["error"]["code"] == "ownership_required"
                created = tool_result(
                    app,
                    "create_session",
                    Dict("name"=>"owned", "command"=>["/bin/cat"]),
                )
                @test !created.is_error
                data = created.structured_content
                @test data["ownership"] == "application" && length(data["panes"]) == 1
                @test !tool_result(app, "capture_pane", Dict("target"=>only(data["panes"]))).is_error
                @test length(tool_result(app, "list_panes").structured_content["panes"]) ==
                      2
                removed = tool_result(
                    app,
                    "teardown_session",
                    Dict("sessionId"=>data["sessionId"], "generation"=>data["generation"]),
                )
                @test !removed.is_error
                @test length(sessions(snapshot(server))) == 1
                leftover = tool_result(
                    app,
                    "create_session",
                    Dict("name"=>"cleanup", "command"=>["/bin/cat"]),
                )
                @test !leftover.is_error
                finished = tool_result(
                    app,
                    "create_session",
                    Dict("name"=>"finished", "command"=>["/bin/cat"]),
                )
                @test !finished.is_error
                kill_session(
                    server,
                    SessionRef(caller.server, finished.structured_content["sessionId"]),
                )
            finally
                close(app)
            end
            @test only(sessions(snapshot(server))).ref == borrowed
            restricted = Application(
                server;
                allowed_panes=[caller],
                allowed_tools=["create_session"],
            )
            try
                denied = tool_result(
                    restricted,
                    "create_session",
                    Dict("name"=>"not-created", "command"=>["/bin/cat"]),
                )
                @test denied.is_error &&
                      denied.structured_content["error"]["code"] == "creation_denied"
            finally
                close(restricted)
            end
        end
    end

end

# Outer integration: three fresh dual-client control connections exercise real cancellation cleanup.
if any(arg -> arg in ("observation", "all"), ARGS)
    @testset "MCP literal waits use observations and own cancellation" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
        )
        LibTmux.with_server(;
            tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
            env=environment,
        ) do server
            command = [
                "/bin/sh",
                "-c",
                "while IFS= read -r line; do printf 'reply:%s\\n' \"\$line\"; done",
            ]
            new_session(server; name="observed", command)
            caller = only(panes(snapshot(server))).ref
            app = Application(
                server;
                caller,
                allowed_panes=[caller],
                allowed_tools=("wait_for_text", "send_keys_and_wait"),
            )
            try
                sent = tool_result(
                    app,
                    "send_keys_and_wait",
                    Dict("keys"=>["λ-ready", "Enter"], "text"=>"reply:λ-ready"),
                )
                @test !sent.is_error
                @test sent.structured_content["source"] == "output" &&
                      sent.structured_content["keysSent"]
                @test sent.structured_content["evidence"] == "literal_text"
                baseline = tool_result(app, "wait_for_text", Dict("text"=>"reply:λ-ready"))
                @test !baseline.is_error &&
                      baseline.structured_content["source"] == "baseline"
                @test baseline.structured_content["continuity"] == "reset"
                entered = Channel{Any}(2)
                token = CancellationToken()
                task = Threads.@spawn begin
                    result = tool_result(
                        app,
                        "send_keys_and_wait",
                        Dict("text"=>"reply:λ-ready", "keys"=>["unfinished"]);
                        cancel=token,
                        progress=phase -> phase == "waiting" && put!(entered, :waiting),
                    )
                    put!(entered, result)
                    result
                end
                @test take!(entered) === :waiting
                cancel!(token)
                result = fetch(task)
                @test result.is_error &&
                      result.structured_content["error"]["code"] == "cancelled"
                @test result.structured_content["error"]["effects"] == "possible"
                @test isempty(clients(snapshot(server)))
            finally
                close(app)
            end
        end
    end
end

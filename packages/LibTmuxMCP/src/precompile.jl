# Cache pure consumer paths. No endpoints, files, processes or streams open here.
@setup_workload begin
    let endpoint = LibTmux.Server(socket_path="/tmp/libtmux-precompile/s")
        identity =
            LibTmux.ServerIdentity(socket_path=endpoint.socket_path, generation="sample")
        caller = LibTmux.PaneRef(identity, "%0")
        @compile_workload begin
            app = Application(
                endpoint;
                caller,
                allowed_panes=[caller],
                allowed_tools=_TOOL_NAMES,
                allow_create=true,
            )
            for tool in tools(app)
                JSON.json(tool.input_schema)
                JSON.json(tool.output_schema)
                _adapt_tool(tool)
            end
            target = Dict("paneId"=>"%0", "generation"=>"sample")
            inputs = (
                ("list_panes", Dict()),
                ("capture_pane", Dict("target"=>target)),
                ("send_keys", Dict("keys"=>["text", "Enter"])),
                ("paste_text", Dict("text"=>"λ")),
                ("resize_pane", Dict("width"=>80)),
                ("kill_pane", Dict()),
                ("wait_for_text", Dict("text"=>"ready")),
                ("send_keys_and_wait", Dict("keys"=>["Enter"], "text"=>"ready")),
                ("create_session", Dict("name"=>"sample", "command"=>["cat"])),
                (
                    "run_operations",
                    Dict(
                        "operations"=>[
                            Dict("tool"=>"send_keys", "arguments"=>Dict("keys"=>["Enter"])),
                        ],
                    ),
                ),
            )
            for (name, arguments) in inputs
                message = JSON.json(
                    Dict(
                        "jsonrpc"=>"2.0",
                        "id"=>name,
                        "method"=>"tools/call",
                        "params"=>Dict("name"=>name, "arguments"=>arguments),
                    ),
                )
                _bounded_json(message, 2097152)
                request = SDK.parse_message(message)
                _plan_tool(app, name, _sdk_arguments(request.params.arguments))
            end
            for arguments in (
                Dict("target"=>Dict("paneId"=>"%1", "generation"=>"sample")),
                Dict("lines"=>0),
            )
                result = _invoke_tool(app, "capture_pane", arguments)
                SDK.serialize_message(SDK.JSONRPCResponse(id="error", result=result))
            end
            for cause in (
                LibTmux.RequestCancelled(true),
                LibTmux.DeadlineExceeded(0.9, true, nothing),
                LibTmux.StaleReference("%0"),
                ArgumentError("invalid argument"),
            )
                JSON.json(_tool_error(cause, "send_keys"))
            end
            _cli_options(["--help"])
            _cli_options([
                "--socket",
                endpoint.socket_path,
                "--caller-pane",
                "%0",
                "--allow-pane",
                "%0",
                "--tool",
                "capture_pane",
                "--timeout",
                "5",
                "--workers",
                "2",
                "--capacity",
                "4",
            ])
            _protocol_error("sample", -32602, "Invalid arguments")
            close(app)
        end
    end
end

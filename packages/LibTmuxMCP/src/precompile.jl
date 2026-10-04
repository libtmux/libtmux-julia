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
                (
                    "list_panes",
                    Dict(
                        "where"=>LibTmux.encode_where(LibTmux.PaneWhere(title="sample")),
                        "columns"=>["id", "title"],
                        "scope"=>Dict("windowId"=>"@0", "generation"=>"sample"),
                    ),
                ),
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
                JSON.json(_tool_error(cause, true))
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
            # Compile successful discovery signatures without dispatching a tool.
            plan_type = NamedTuple{(:name, :args),Tuple{String,Dict{String,Any}}}
            tags = map((:session, :window, :pane, :client, :windowlink)) do kind
                Tuple{ntuple(_ -> Int, length(LibTmux._snapshot_integer_fields(Val(kind))))...}
            end
            snapshot_type = LibTmux.Snapshot{tags...}
            pane_type = LibTmux.PaneSnapshot{snapshot_type}
            pane_selection = LibTmux.Selection{pane_type}
            link_selection = LibTmux.Selection{LibTmux.WindowLink{snapshot_type}}
            precompile(Tuple{typeof(_list_panes),Application,Dict{String,Any},_ToolContext})
            precompile(Tuple{typeof(_execute_tool),Application,plan_type,_ToolContext})
            precompile(Tuple{_DiscoveryCheckpoint})
            # These leaves occur in a fresh successful listing trace; compiling
            # signatures preserves the first tool call as the first dispatch.
            precompile(Tuple{typeof(_discovery_capture),Application,Nothing,_ToolContext})
            precompile(
                Tuple{
                    Type{_DiscoveryRows},
                    snapshot_type,
                    pane_selection,
                    Nothing,
                    LibTmux.PaneRef,
                    Nothing,
                    Dict{Int,_DiscoveryWindowFacets},
                    LibTmux._CriterionTraversal{Function},
                },
            )
            precompile(Tuple{typeof(_discovery_window),_DiscoveryRows,pane_type})
            precompile(
                Tuple{
                    typeof(Core.kwcall),
                    NamedTuple{(:clipped,),Tuple{Bool}},
                    typeof(_discovery_contexts),
                    Tuple{LibTmux.WindowLink{snapshot_type}},
                },
            )
            precompile(Tuple{typeof(_plan_tool),Application,String,Dict{Any,Any}})
            precompile(
                Tuple{
                    typeof(_invoke_tool),
                    Application,
                    String,
                    Dict{String,Vector{Dict{String,Any}}},
                },
            )
            for Type in (
                Nothing,
                Bool,
                Int,
                Float64,
                String,
                Symbol,
                Dict{String,Any},
                Dict{String,String},
                Vector{Symbol},
                Vector{String},
                Vector{Dict{String,Any}},
                _DiscoveryRows,
            )
                precompile(Tuple{typeof(_canonical_digest!),_DiscoveryDigest,Type})
            end
            precompile(Tuple{typeof(_canonical_digest_string!),_DiscoveryDigest,String})
            precompile(
                Tuple{
                    typeof(_discovery_fingerprint),
                    Dict{String,Any},
                    LibTmux._CriterionTraversal{Function},
                },
            )
            precompile(
                Tuple{
                    typeof(Core.kwcall),
                    NamedTuple{(:clipped,),Tuple{Bool}},
                    typeof(_discovery_row_at),
                    _DiscoveryRows,
                    Int,
                },
            )
            for caller_type in (Nothing, LibTmux.PaneRef)
                kwargs_type =
                    NamedTuple{(:clipped, :contexts),Tuple{Bool,Vector{Dict{String,Any}}}}
                precompile(
                    Tuple{
                        typeof(Core.kwcall),
                        kwargs_type,
                        typeof(_discovery_row),
                        pane_type,
                        link_selection,
                        caller_type,
                        Nothing,
                    },
                )
            end
            for operator in (
                LibTmux.Filters.Contains,
                LibTmux.Filters.StartsWith,
                LibTmux.Filters.EndsWith,
            )
                precompile(
                    Tuple{
                        typeof(LibTmux._matches),
                        operator,
                        String,
                        LibTmux._CriterionTraversal{Function},
                    },
                )
            end
            precompile(
                Tuple{
                    typeof(LibTmux._project_rows),
                    pane_selection,
                    Vector{Symbol},
                    _DiscoveryCheckpoint,
                },
            )
            close(app)
        end
    end
end

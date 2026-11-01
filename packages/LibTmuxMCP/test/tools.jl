using Test, LibTmux, LibTmuxMCP
import ModelContextProtocol as ToolSDK

tool_result(app, name, args=Dict(); kwargs...) =
    LibTmuxMCP._invoke_tool(app, name, args; kwargs...)
pane_target(ref) = Dict("paneId"=>string(ref.id), "generation"=>ref.server.generation)

if isempty(ARGS) || any(arg -> arg in ("baseline", "unit", "all"), ARGS)
    @testset "MCP waits expose per-call total budgets" begin
        endpoint = Server(socket_path="/tmp/libtmux-julia-uncontacted/s")
        caller = PaneRef(
            ServerIdentity(socket_path=endpoint.socket_path, generation="1:1"),
            "%0",
        )
        app = Application(endpoint; caller, allowed_tools=("wait_for_text",), timeout=0.9)
        try
            properties = only(tools(app)).input_schema["properties"]
            @test haskey(properties, "timeoutSeconds")
            plan = try
                LibTmuxMCP._plan_tool(
                    app,
                    "wait_for_text",
                    Dict("text"=>"ready", "timeoutSeconds"=>0.05),
                )
            catch error
                error
            end
            @test plan isa NamedTuple
            plan isa NamedTuple && @test plan.args["timeoutSeconds"] == 0.05
            for invalid in (0, -1, true, NaN, Inf, 1.0)
                result = tool_result(
                    app,
                    "wait_for_text",
                    Dict("text"=>"ready", "timeoutSeconds"=>invalid),
                )
                @test result.is_error &&
                      result.structured_content["error"]["effects"] == "none"
            end
        finally
            close(app)
        end
    end

    @testset "MCP call owner preserves validation and deferred callback admission" begin
        mktempdir("/tmp"; prefix="ltj-mcp-") do directory
            endpoint = Server(socket_path=joinpath(directory, "s"))
            caller = PaneRef(
                ServerIdentity(socket_path=endpoint.socket_path, generation="1:1"),
                "%0",
            )
            app =
                Application(endpoint; caller, allowed_tools=("capture_pane",), timeout=0.9)
            name = SubString("capture_pane suffix", 1, 12)
            cancelled = CancellationToken()
            cancel!(cancelled)
            try
                for (arguments, token, code) in (
                    (Dict("lines"=>0), CancellationToken(), "invalid_arguments"),
                    (Dict("maxBytes"=>1), cancelled, "cancelled"),
                    (Dict("maxBytes"=>1), CancellationToken(), "operation_failed"),
                )
                    result = tool_result(app, name, arguments; cancel=token, progress=1)
                    detail = result.structured_content["error"]
                    @test result.is_error &&
                          (detail["code"], detail["effects"]) == (code, "none")
                    @test isempty(app._active) && isopen(app)
                end
                close(app)
                result = tool_result(app, name, Dict("maxBytes"=>1); progress=1)
                detail = result.structured_content["error"]
                @test result.is_error &&
                      (detail["code"], detail["effects"]) == ("closed", "none")
                @test isempty(app._active) && !isopen(app)
            finally
                close(app)
            end
        end
    end

    @testset "MCP failures preserve whole-call I/O admission" begin
        result = CommandResult(UInt8[0x61], UInt8[], 0, 0)
        for failure in (
            ProcessIOError(:stdout, EOFError(), result),
            OutputLimitExceeded(:stdout, 1, result),
        )
            @test LibTmuxMCP._tool_error(failure, true)["effects"] == "possible"
            @test LibTmuxMCP._tool_error(failure, false)["effects"] == "none"
        end
        @testset "cancelled expired calls preserve admission" begin
            token = CancellationToken()
            cancel!(token)
            for admitted in (false, true)
                effects = Ref(admitted)
                context = LibTmuxMCP._ToolContext(
                    time_ns() - UInt64(1_000_000_000),
                    0.1,
                    token,
                    identity,
                    effects,
                )
                failure = try
                    LibTmuxMCP._tool_kwargs(context)
                catch error
                    error
                end
                @test failure isa RequestCancelled
                @test effects[] === admitted
            end
        end
    end

    @testset "MCP version failures preserve admitted effects" begin
        failure = LibTmux.UnsupportedTmuxVersion("3.2a", "3.3a", "")
        for admitted in (false, true)
            error = LibTmuxMCP._tool_error(failure, admitted)
            @test error["code"] == "unsupported_tmux"
            @test error["effects"] == (admitted ? "possible" : "none")
            @test occursin("3.3a", error["message"])
            @test occursin("Upgrade tmux", error["message"])
        end
        probe = LibTmux.CommandError(
            LibTmux.CommandResult(UInt8[], UInt8[], 1, 0),
            "version probe",
        )
        for admitted in (false, true)
            error = LibTmuxMCP._tool_error(probe, admitted)
            @test error["effects"] == (admitted ? "possible" : "none")
        end
    end

    @testset "MCP names the operation that a tmux release cannot support" begin
        failure = LibTmux.UnsupportedCapability(
            :open_control,
            "control acquisition requires tmux 3.7",
        )
        for admitted in (false, true)
            error = LibTmuxMCP._tool_error(failure, admitted)
            @test error["code"] == "unsupported_capability" &&
                  error["effects"] == (admitted ? "possible" : "none")
            @test occursin("3.7", error["message"])
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
        @test !only(filter(tool->tool.name=="capture_pane", catalog)).annotations["readOnlyHint"]
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
            Set(["completed", "failedIndex", "error", "atomic"]) &&
                get(branch["properties"]["failedIndex"], "type", nothing) == "integer"
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
        limited_success = filter(batch_schema["anyOf"]) do branch
            Set(get(branch, "required", String[])) ==
            Set(["completed", "failedIndex", "error", "atomic"]) &&
                branch["properties"]["failedIndex"] == Dict("type"=>"null")
        end
        @test length(limited_success) == 1
        if length(limited_success) == 1
            fields = only(limited_success)["properties"]
            @test fields["failedIndex"] == Dict("type"=>"null")
            @test Set(fields["completed"]["items"]["required"]) ==
                  Set(["tool", "completed", "resultOmitted"])
            @test fields["completed"]["items"]["properties"]["completed"] ==
                  Dict("const"=>true)
            @test fields["completed"]["items"]["properties"]["resultOmitted"] ==
                  Dict("const"=>true)
            @test fields["error"]["properties"]["code"] == Dict("const"=>"result_limit")
        end
        limited_partial = filter(batch_schema["anyOf"]) do branch
            Set(get(branch, "required", String[])) ==
            Set(["completed", "failedIndex", "error", "atomic", "originalError"])
        end
        @test length(limited_partial) == 1
        if length(limited_partial) == 1
            fields = only(limited_partial)["properties"]
            @test fields["failedIndex"] == LibTmuxMCP._integer_schema(1, 8)
            @test Set(fields["originalError"]["required"]) == Set(["code"])
        end
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

if isempty(ARGS) || any(arg -> arg in ("effects", "integration", "all"), ARGS)
    if isdefined(Main, :include_test_file)
        Main.include_test_file(@__MODULE__, joinpath(@__DIR__, "effects.jl"))
    else
        Base.include(@__MODULE__, joinpath(@__DIR__, "effects.jl"))
    end
end

# The waiting tools observe through control clients (tmux 3.7) and poll the
# screen below it, so the evidence they report differs by release.
mcp_control_supported = LibTmux._version_at_least(
    last(split(readchomp(`$(get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) -V`))),
    LibTmux.CONTROL_MINIMUM_TMUX,
)

if isempty(ARGS) || any(arg -> arg in ("baseline", "integration", "all"), ARGS)
    @testset "MCP tools use exact authorized real-tmux targets" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
            Main.TestSandbox.child_entries()...,
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
                # A daemon below the floor is refused by every tool before it acts.
                mktempdir(; prefix="ltj-mcp-adm-") do directory
                    script = joinpath(directory, "tmux")
                    write(
                        script,
                        raw"""#!/bin/sh
previous=
for argument in "$@"; do
    if [ "$previous" = -C ]; then
        printf 'unknown command: %s3.2a\n' "${argument%\#\{version\}}" >&2
        exit 1
    fi
    previous=$argument
done
exit 99
""",
                    )
                    chmod(script, 0o700)
                    refused = Server(socket_path=server.socket_path, tmux=script)
                    old_app = Application(
                        refused;
                        caller,
                        allowed_tools=(
                            "list_panes",
                            "send_keys",
                            "paste_text",
                            "kill_pane",
                        ),
                    )
                    try
                        before_keys =
                            tool_result(app, "capture_pane").structured_content["text"]
                        for (name, arguments) in (
                            ("list_panes", Dict()),
                            ("send_keys", Dict("keys"=>["must-not-arrive"])),
                            ("paste_text", Dict("text"=>"must-not-arrive")),
                            ("kill_pane", Dict()),
                        )
                            refusal = tool_result(old_app, name, arguments)
                            @test refusal.is_error
                            error = refusal.structured_content["error"]
                            @test error["code"] == "unsupported_tmux" &&
                                  error["effects"] == "none"
                        end
                        @test tool_result(app, "capture_pane").structured_content["text"] ==
                              before_keys
                        @test length(panes(snapshot(server))) == 2
                    finally
                        close(old_app)
                    end
                end
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
                    @test partial.structured_content["error"]["effects"] == "possible"
                finally
                    close(batch_app)
                end
                large = "result-limit-" * repeat("x", 2048)
                @test !tool_result(app, "paste_text", Dict("text"=>large)).is_error
                captured_large = tool_result(app, "capture_pane", Dict("maxBytes"=>4096))
                @test ncodeunits(captured_large.structured_content["text"]) > 1024
                limited_app = Application(
                    server;
                    caller,
                    allowed_tools=("capture_pane", "send_keys", "run_operations"),
                    max_result_bytes=1024,
                )
                try
                    limited_success = tool_result(
                        limited_app,
                        "run_operations",
                        Dict(
                            "operations"=>[
                                Dict(
                                    "tool"=>"capture_pane",
                                    "arguments"=>Dict("maxBytes"=>4096),
                                ),
                            ],
                        ),
                    )
                    @test limited_success.is_error
                    success_payload = limited_success.structured_content
                    @test Set(keys(success_payload)) ==
                          Set(["completed", "failedIndex", "error", "atomic"])
                    @test success_payload["failedIndex"] === nothing
                    @test success_payload["atomic"] === false
                    @test success_payload["error"]["code"] == "result_limit"
                    @test success_payload["error"]["effects"] == "possible"
                    @test only(success_payload["completed"]) == Dict(
                        "tool"=>"capture_pane",
                        "completed"=>true,
                        "resultOmitted"=>true,
                    )
                    limited_partial = tool_result(
                        limited_app,
                        "run_operations",
                        Dict(
                            "operations"=>[
                                Dict(
                                    "tool"=>"send_keys",
                                    "arguments"=>Dict(
                                        "keys"=>["result-limit-effect"],
                                        "literal"=>true,
                                    ),
                                ),
                                Dict(
                                    "tool"=>"capture_pane",
                                    "arguments"=>Dict("maxBytes"=>4096),
                                ),
                                Dict(
                                    "tool"=>"capture_pane",
                                    "arguments"=>Dict(
                                        "target"=>Dict(
                                            "paneId"=>string(caller.id),
                                            "generation"=>"stale",
                                        ),
                                    ),
                                ),
                            ],
                        ),
                    )
                    @test limited_partial.is_error
                    partial_payload = limited_partial.structured_content
                    @test Set(keys(partial_payload)) == Set([
                        "completed",
                        "failedIndex",
                        "error",
                        "atomic",
                        "originalError",
                    ])
                    @test partial_payload["failedIndex"] == 3
                    @test partial_payload["atomic"] === false
                    @test partial_payload["error"]["code"] == "result_limit"
                    @test partial_payload["error"]["effects"] == "possible"
                    @test partial_payload["originalError"] == Dict("code"=>"stale_target")
                    @test partial_payload["completed"] == [
                        Dict("tool"=>"send_keys", "completed"=>true, "resultOmitted"=>true),
                        Dict(
                            "tool"=>"capture_pane",
                            "completed"=>true,
                            "resultOmitted"=>true,
                        ),
                    ]
                finally
                    close(limited_app)
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
            Main.TestSandbox.child_entries()...,
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

    @testset "the MCP command line reaches the server a variable names, and a flag beats it" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
            Main.TestSandbox.child_entries()...,
        )
        LibTmux.with_server(;
            tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
            env=environment,
        ) do server
            new_session(server; name="selected", command=["/bin/cat"])
            pane = only(panes(snapshot(server))).ref
            arguments = ["--tmux", server.tmux, "--caller-pane", string(pane.id)]
            withenv(
                "LIBTMUX_SOCKET_PATH" => server.socket_path,
                "LIBTMUX_SOCKET" => nothing,
            ) do
                # No flag: the variable chose the server, so its pane resolves.
                app = LibTmuxMCP._cli_application(LibTmuxMCP._cli_options(arguments))
                try
                    @test app.caller == pane
                finally
                    close(app)
                end
                # A flag leaves the variable unread: nothing listens on this socket.
                absent = joinpath(dirname(server.socket_path), "absent")
                options = LibTmuxMCP._cli_options([arguments; "--socket"; absent])
                @test_throws Exception LibTmuxMCP._cli_application(options)
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
            Main.TestSandbox.child_entries()...,
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
                @test sent.structured_content["source"] ==
                      (mcp_control_supported ? "output" : "screen") &&
                      sent.structured_content["keysSent"]
                @test sent.structured_content["evidence"] == "literal_text"
                baseline = tool_result(app, "wait_for_text", Dict("text"=>"reply:λ-ready"))
                @test !baseline.is_error &&
                      baseline.structured_content["source"] ==
                      (mcp_control_supported ? "baseline" : "screen")
                @test baseline.structured_content["continuity"] == "reset"
                callback_failure = tool_result(
                    app,
                    "wait_for_text",
                    Dict("text"=>"reply:λ-ready");
                    progress=phase -> error("progress callback stopped"),
                )
                @test callback_failure.is_error &&
                      callback_failure.structured_content["error"]["code"] ==
                      "operation_failed" &&
                      callback_failure.structured_content["error"]["effects"] == "possible"
                @test isempty(clients(snapshot(server)))
                for (name, result) in
                    (("send_keys_and_wait", sent), ("wait_for_text", baseline))
                    schema =
                        only(filter(tool -> tool.name == name, tools(app))).output_schema
                    continuity = schema["anyOf"][1]["properties"]["continuity"]
                    actual = result.structured_content["continuity"]
                    @test haskey(continuity, "const") ? actual == continuity["const"] :
                          actual in continuity["enum"]
                end
                started = time_ns()
                limited = tool_result(
                    app,
                    "wait_for_text",
                    Dict("text"=>"not-emitted", "timeoutSeconds"=>0.1),
                )
                elapsed = (time_ns() - started) / 1e9
                deadline_result =
                    limited.is_error &&
                    limited.structured_content["error"]["code"] == "deadline"
                deadline_result ||
                    println("unexpected wait result: ", limited.structured_content)
                @test deadline_result
                @test limited.structured_content["error"]["effects"] == "possible"
                elapsed < 2.0 ||
                    println(stderr, "MCP literal deadline call_seconds=", elapsed)
                @test elapsed < 2.0
                @test isempty(clients(snapshot(server)))
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
    @testset "MCP waits match text wrapped across screen rows" begin
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
            Main.TestSandbox.child_entries()...,
        )
        LibTmux.with_server(;
            tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
            env=environment,
        ) do server
            # Wider than the 80-column pane, so tmux soft-wraps it.
            printed = repeat("0123456789", 12) * "end"
            command = ["/bin/sh", "-c", "printf '%s\\n' $printed; exec cat"]
            new_session(server; name="wrapped", command)
            caller = only(panes(snapshot(server))).ref
            app = Application(
                server;
                caller,
                allowed_panes=[caller],
                allowed_tools=("wait_for_text", "send_keys_and_wait"),
            )
            try
                # The match crosses the wrap point at column 80.
                spanning = printed[60:end]
                @test occursin('\n', capture_pane(server, caller)) &&
                      !occursin(spanning, capture_pane(server, caller))
                baseline = tool_result(app, "wait_for_text", Dict("text"=>spanning))
                @test !baseline.is_error && baseline.structured_content["matched"]
                typed = repeat("abcdefghij", 12) * "typed"
                sent = tool_result(
                    app,
                    "send_keys_and_wait",
                    Dict("keys"=>[typed, "Enter"], "text"=>typed[60:end]),
                )
                @test !sent.is_error && sent.structured_content["matched"]
            finally
                close(app)
            end
        end
    end

    @testset "MCP waits fail with the output so far when the pane or server ends" begin
        # A killed server lingers while another client is attached; the stopped
        # client keeps it alive so the wait must still see the server end.
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
            Main.TestSandbox.child_entries()...,
        )
        for (ending, stopped) in ((:pane, false), (:server, false), (:server, true))
            LibTmux.with_server(;
                tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
                env=environment,
            ) do server
                new_session(server; name="anchor", command=["/bin/cat"])
                anchor = only(panes(snapshot(server))).ref
                holder = nothing
                holder_pid = nothing
                if stopped
                    release =
                        LibTmux._daemon_version(server, LibTmux._client_environment(ENV))
                    mode =
                        LibTmux._version_at_least(release, LibTmux.CONTROL_MINIMUM_TMUX) ?
                        "control" : "pty"
                    pidfile = server.socket_path * ".client"
                    holder = run(
                        pipeline(
                            `python3 -I $(joinpath(@__DIR__, "stopped_client.py")) $(server.tmux) $(server.socket_path) anchor $pidfile $mode`;
                            stdout=devnull,
                            stderr=devnull,
                        );
                        wait=false,
                    )
                    @test timedwait(() -> isfile(pidfile), 20.0) === :ok
                    holder_pid = parse(Int, read(pidfile, String))
                    run(`kill -STOP $holder_pid`)
                end
                command = ["/bin/sh", "-c", "printf 'before-end\\n'; sleep 30"]
                fresh_pane(name) = begin
                    new_session(server; name, command)
                    only(filter(pane -> pane.ref != anchor, panes(snapshot(server)))).ref
                end
                caller = fresh_pane("ending")
                app = Application(
                    server;
                    caller,
                    allowed_panes=[caller],
                    allowed_tools=("wait_for_text", "send_keys_and_wait"),
                )
                try
                    for tool in ("wait_for_text", "send_keys_and_wait")
                        waiting = Channel{Any}(1)
                        arguments = Dict{String,Any}("text"=>"never-printed")
                        tool == "send_keys_and_wait" && (arguments["keys"] = ["x"])
                        task = Threads.@spawn tool_result(
                            app,
                            tool,
                            arguments;
                            progress=phase ->
                                phase == "waiting" && put!(waiting, :waiting),
                        )
                        @test take!(waiting) === :waiting
                        # Let the wait capture the pane once before it ends.
                        sleep(1.0)
                        if ending === :pane
                            kill_pane(server, caller)
                        else
                            run_command(server, "kill-server")
                            # A stopped client can keep the killed daemon alive,
                            # which then answers "server exited unexpectedly";
                            # a daemon that already left answers "no server
                            # running".
                            stopped && @test occursin(
                                r"server exited unexpectedly|no server running",
                                try
                                    run_command(server, "list-sessions")
                                    ""
                                catch error
                                    sprint(showerror, error)
                                end,
                            )
                        end
                        @test timedwait(() -> istaskdone(task), 20.0) === :ok
                        result = fetch(task)
                        error = result.structured_content["error"]
                        error["code"] == "pane_died" || println(
                            "unexpected wait failure: ",
                            ending,
                            " ",
                            tool,
                            " ",
                            error,
                        )
                        @test result.is_error && error["code"] == "pane_died"
                        @test error["effects"] == "possible"
                        @test ending === :server ? occursin("server", error["message"]) :
                              occursin("pane", error["message"])
                        tool == "wait_for_text" &&
                            @test occursin("before-end", error["output"])
                        ending === :server && break
                        # The next tool needs a fresh pane to wait on.
                        caller = fresh_pane("again")
                        close(app)
                        app = Application(
                            server;
                            caller,
                            allowed_panes=[caller],
                            allowed_tools=("wait_for_text", "send_keys_and_wait"),
                        )
                    end
                finally
                    close(app)
                    if holder_pid !== nothing
                        run(ignorestatus(`kill -KILL $holder_pid`))
                        kill(holder)
                    end
                end
            end
        end
    end
end

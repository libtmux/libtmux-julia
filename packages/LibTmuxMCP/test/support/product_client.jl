# An independent MCP client for the installed launcher, run against a real tmux
# server that already holds the pane it may use. It speaks the stdio protocol
# directly and does not use the package's own transport.
module ProductClient

using ..StdioClient
import ..StdioClient: JSON

export product_client

check(condition, message...) = condition || error(string(message...))

"Whether tmux allows control acquisition: 3.7 or newer, not a 3.7 prerelease."
function control_supported(tmux)
    report = last(split(readchomp(`$tmux -V`)))
    parsed = match(r"^(?:next-(\d+)\.(\d+)|(\d+)\.(\d+)(?:[a-z]|-rc\d*)?)$", report)
    parsed === nothing && return false
    release = (
        parse(Int, something(parsed[1], parsed[3])),
        parse(Int, something(parsed[2], parsed[4])),
    )
    prerelease = startswith(report, "next-") || occursin("-rc", report)
    release > (3, 7) || (release == (3, 7) && !prerelease)
end

const TOOLS = [
    "list_panes",
    "capture_pane",
    "send_keys",
    "create_session",
    "teardown_session",
    "run_operations",
    "wait_for_text",
    "send_keys_and_wait",
]

function partial_batch_schema(schema)
    required = Set(["completed", "failedIndex", "error", "atomic"])
    matches = [
        branch for branch in schema["anyOf"] if
        Set(get(branch, "required", String[])) == required &&
            get(branch["properties"]["failedIndex"], "type", nothing) == "integer"
    ]
    check(length(matches) == 1, "one partial-batch schema branch: ", schema)
    only(matches)
end

function assert_partial_batch(payload, schema)
    fields = partial_batch_schema(schema)["properties"]
    check(Set(keys(payload)) == Set(keys(fields)), "partial batch fields: ", payload)
    failed = payload["failedIndex"]
    check(failed isa Integer, "failedIndex is an integer")
    check(
        fields["failedIndex"]["minimum"] <= failed <= fields["failedIndex"]["maximum"],
        "failedIndex in range",
    )
    check(payload["atomic"] === fields["atomic"]["const"], "atomic matches the schema")
    check(
        payload["completed"] isa AbstractVector &&
            length(payload["completed"]) <= fields["completed"]["maxItems"],
        "completed list",
    )
    properties = Set(keys(fields["completed"]["items"]["properties"]))
    for item in payload["completed"]
        check(Set(keys(item)) == properties, "completed item fields: ", item)
        check(
            item["tool"] isa AbstractString && item["result"] isa AbstractDict,
            "completed item types",
        )
    end
    error_schema = fields["error"]
    # A failed wait adds its optional `output`; every other error omits it.
    given = Set(keys(payload["error"]))
    check(
        Set(error_schema["required"]) <= given <= Set(keys(error_schema["properties"])),
        "error fields: ",
        payload,
    )
    check(
        payload["error"]["code"] isa AbstractString &&
            payload["error"]["message"] isa AbstractString,
        "error text",
    )
    check(
        payload["error"]["effects"] in error_schema["properties"]["effects"]["enum"],
        "error effects",
    )
    check(payload["error"]["retryable"] isa Bool, "error retryable")
end

function product_client(launcher, socket_option, socket, tmux, pane, profile)
    check(socket_option in ("--socket", "--socket-name"), "socket option")
    check(profile in ("2026-07-28", "2025-11-25"), "protocol profile")
    started = time()
    tools = reduce(
        vcat,
        (
            ["--tool", name] for name in (
                "list_panes",
                "capture_pane",
                "send_keys",
                "create_session",
                "teardown_session",
                "run_operations",
                "wait_for_text",
                "send_keys_and_wait",
            )
        ),
    )
    child = spawn_child([
        launcher,
        socket_option,
        socket,
        "--tmux",
        tmux,
        "--caller-pane",
        pane,
        "--allow-pane",
        pane,
        tools...,
        "--allow-create",
    ])
    function send(identity, method, params=Dict{String,Any}())
        values = Dict{String,Any}(params)
        if profile == "2026-07-28"
            values["_meta"] = merge(
                Dict(
                    "io.modelcontextprotocol/protocolVersion" => profile,
                    "io.modelcontextprotocol/clientCapabilities" => Dict(),
                ),
                get(values, "_meta", Dict()),
            )
        end
        data = Dict{String,Any}("jsonrpc" => "2.0", "method" => method, "params" => values)
        identity === nothing || (data["id"] = identity)
        send_line(child, data)
    end
    receive() = receive_line(child)
    function call(identity, name, arguments=Dict{String,Any}())
        send(identity, "tools/call", Dict("name" => name, "arguments" => arguments))
        response = receive()
        check(
            response["id"] == identity && haskey(response, "result"),
            "tool call response: ",
            response,
        )
        response["result"]
    end
    ok(result) = !get(result, "isError", false)
    try
        if profile == "2026-07-28"
            send(1, "server/discover")
            check(
                receive()["result"]["supportedVersions"] == ["2026-07-28", "2025-11-25"],
                "supported versions",
            )
        else
            send(
                1,
                "initialize",
                Dict(
                    "protocolVersion" => profile,
                    "capabilities" => Dict(),
                    "clientInfo" =>
                        Dict("name" => "libtmux-public-consumer", "version" => "1"),
                ),
            )
            check(
                receive()["result"]["protocolVersion"] == profile,
                "negotiated protocol version",
            )
            send(nothing, "notifications/initialized")
        end
        send(2, "tools/list")
        listed = receive()["result"]["tools"]
        check(Set(tool["name"] for tool in listed) == Set(TOOLS), "the tool catalog")
        check(
            all(
                tool -> haskey(tool, "inputSchema") && haskey(tool, "outputSchema"),
                listed,
            ),
            "tool schemas",
        )
        for tool in listed
            row = get(
                get(tool, "_meta", Dict()),
                "com.git-pull.libtmux-mcp/capability",
                Dict(),
            )
            check(
                get(row, "toolset", "") in ("inspect", "manage", "execute", "teardown") &&
                    get(row, "processReach", nothing) isa AbstractString &&
                    get(row, "tmuxEffects", nothing) isa AbstractVector,
                "capability row of ",
                tool["name"],
                ": ",
                row,
            )
        end
        run_operations_schema = only(
            tool["outputSchema"] for tool in listed if tool["name"] == "run_operations"
        )
        listing = call(3, "list_panes")
        check(ok(listing), listing)
        panes = listing["structuredContent"]["panes"]
        check(length(panes) == 1, "one pane")
        row = only(panes)
        check(row["target"]["paneId"] == pane && row["caller"], "the caller pane: ", row)
        capture = call(4, "capture_pane")
        check(
            ok(capture) && capture["structuredContent"]["terminalContent"] == "data",
            capture,
        )
        sent = call(
            5,
            "send_keys",
            Dict("keys" => ["literal client input"], "literal" => true),
        )
        check(ok(sent), sent)
        denied = call(
            6,
            "capture_pane",
            Dict(
                "target" => Dict(
                    "paneId" => "%999999",
                    "generation" => row["target"]["generation"],
                ),
            ),
        )
        check(
            denied["isError"] &&
                denied["structuredContent"]["error"]["code"] == "target_denied",
            denied,
        )
        observed = call(
            "echo",
            "send_keys_and_wait",
            Dict(
                "keys" => ["observed-marker"],
                "literal" => true,
                "text" => "observed-marker",
            ),
        )
        check(ok(observed), observed)
        # The waiting tools observe through a control client on tmux 3.7 and newer,
        # and poll the screen below it.
        check(
            observed["structuredContent"]["source"] ==
            (control_supported(tmux) ? "output" : "screen"),
            "wait source",
        )
        send(
            "waiting",
            "tools/call",
            Dict(
                "name" => "wait_for_text",
                "arguments" => Dict("text" => "never-produced-marker"),
                "_meta" => Dict("progressToken" => "waiting"),
            ),
        )
        progress = receive()
        check(get(progress, "method", nothing) == "notifications/progress", progress)
        send("concurrent", "tools/list")
        check(receive()["id"] == "concurrent", "a concurrent request is answered")
        send(nothing, "notifications/cancelled", Dict("requestId" => "waiting"))
        creation(name) = Dict(
            "tool" => "create_session",
            "arguments" => Dict("name" => name, "command" => ["/bin/cat"]),
        )
        batch = call(
            7,
            "run_operations",
            Dict(
                "operations" => [
                    creation("client-owned"),
                    creation("borrowed"),
                    creation("client-not-run"),
                ],
            ),
        )
        check(batch["isError"], batch)
        partial = batch["structuredContent"]
        check(
            JSON.parse(batch["content"][1]["text"]; dicttype=Dict{String,Any}) == partial,
            "text mirrors structured content",
        )
        assert_partial_batch(partial, run_operations_schema)
        check(partial["failedIndex"] == 2 && partial["atomic"] === false, partial)
        check(
            [item["tool"] for item in partial["completed"]] == ["create_session"],
            partial,
        )
        check(
            partial["error"]["code"] == "operation_failed" &&
                partial["error"]["effects"] == "possible",
            partial,
        )
        created = only(item["result"] for item in partial["completed"])
        check(created["ownership"] == "application" && created["completed"], created)
        not_run = call(
            8,
            "create_session",
            Dict("name" => "client-not-run", "command" => ["/bin/cat"]),
        )
        check(ok(not_run), not_run)
        for (identity, session) in ((9, not_run["structuredContent"]), (10, created))
            removed = call(
                identity,
                "teardown_session",
                Dict(
                    "sessionId" => session["sessionId"],
                    "generation" => session["generation"],
                ),
            )
            check(ok(removed), removed)
            check(
                removed["structuredContent"]["sessionId"] == session["sessionId"] &&
                    removed["structuredContent"]["completed"],
                removed,
            )
        end
        created = call(
            11,
            "create_session",
            Dict("name" => "client-owned", "command" => ["/bin/cat"]),
        )
        check(ok(created), created)
        send(12, profile == "2026-07-28" ? "server/discover" : "ping")
        alive = receive()
        check(
            alive["id"] == 12 && haskey(alive, "result") && !haskey(alive, "error"),
            alive,
        )
        profile == "2026-07-28" && check(
            alive["result"]["supportedVersions"] == ["2026-07-28", "2025-11-25"],
            alive,
        )
        close_stdin!(child)
        wait_for_exit(child, 10.0)
        check(
            !process_running(child.process) && child.process.exitcode == 0,
            "launcher exit: ",
            String(copy(child.diagnostics)),
        )
        check(
            isempty(child.pending) && isempty(read_rest(child.stdout, 1)),
            "unexpected late protocol output",
        )
        diagnostics = vcat(child.diagnostics, read_rest(child.stderr, 1024 * 1024))
        check(isempty(diagnostics), String(diagnostics))
        println(
            "PASS installed MCP $profile discovery/catalog/partial/teardown/observation/cancel/EOF $(round(time() - started; digits=3))s",
        )
    finally
        finish!(child)
    end
end

end

using Test, LibTmux, LibTmuxMCP

# Outer: real hooks, attachment and creation cleanup require an owned daemon.
@testset "MCP whole-call effects include configured hooks" begin
    directory = Ref("")
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
        directory[] = dirname(server.socket_path)
        new_session(server; name="effects", command=["/bin/cat"])
        caller = only(panes(snapshot(server))).ref
        app = Application(
            server;
            caller,
            allowed_tools=("list_panes", "capture_pane", "wait_for_text", "run_operations"),
            timeout=0.9,
        )
        try
            catalog = tools(app)
            @test [tool.annotations["readOnlyHint"] for tool in catalog] == fill(false, 4)
            @test [tool.annotations["destructiveHint"] for tool in catalog] == fill(true, 4)
            @test [tool.annotations["idempotentHint"] for tool in catalog] == fill(false, 4)
            set_hook(
                server,
                :global_session,
                "after-capture-pane",
                "set-environment -g LTJ_CAPTURE_HOOK observed",
            )
            rejected = LibTmuxMCP._invoke_tool(app, "capture_pane", Dict("lines"=>0))
            @test rejected.is_error &&
                  rejected.structured_content["error"]["effects"] == "none"
            @test get_environment(server, :global, "LTJ_CAPTURE_HOOK") === nothing
            cancelled = CancellationToken()
            cancel!(cancelled)
            unsent = LibTmuxMCP._invoke_tool(app, "capture_pane"; cancel=cancelled)
            @test unsent.is_error && unsent.structured_content["error"]["effects"] == "none"
            @test get_environment(server, :global, "LTJ_CAPTURE_HOOK") === nothing
            captured = LibTmuxMCP._invoke_tool(app, "capture_pane", Dict("maxBytes"=>1))
            @test !captured.is_error && captured.structured_content["truncated"]
            @test get_environment(server, :global, "LTJ_CAPTURE_HOOK").value == "observed"

            set_hook(
                server,
                :global_session,
                "after-list-sessions",
                "set-environment -g LTJ_LIST_HOOK observed",
            )
            @test get_environment(server, :global, "LTJ_LIST_HOOK") === nothing
            partial = LibTmuxMCP._invoke_tool(
                app,
                "run_operations",
                Dict(
                    "operations"=>[
                        Dict("tool"=>"list_panes", "arguments"=>Dict()),
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
            @test partial.is_error && partial.structured_content["failedIndex"] == 2
            @test only(partial.structured_content["completed"])["tool"] == "list_panes"
            @test partial.structured_content["error"]["effects"] == "possible"
            @test get_environment(server, :global, "LTJ_LIST_HOOK").value == "observed"

            set_hook(
                server,
                :global_session,
                "client-attached",
                "set-environment -g LTJ_ATTACH_HOOK observed",
            )
            token = CancellationToken()
            waited = LibTmuxMCP._invoke_tool(
                app,
                "wait_for_text",
                Dict("text"=>"never-emitted");
                cancel=token,
                progress=phase -> phase == "waiting" && cancel!(token),
            )
            @test waited.is_error &&
                  waited.structured_content["error"]["code"] == "cancelled"
            @test waited.structured_content["error"]["effects"] == "possible"
            @test get_environment(server, :global, "LTJ_ATTACH_HOOK").value == "observed"
            @test isempty(clients(snapshot(server)))
        finally
            close(app)
        end

        wrapper = joinpath(directory[], "creation-probe")
        trigger = joinpath(directory[], "creation-seen")
        quote_sh(value) = "'" * replace(value, "'"=>"'\\''") * "'"
        real_tmux = quote_sh(something(Sys.which(server.tmux)))
        write(
            wrapper,
            """
            #!/bin/sh
            for argument do
                if [ "\$argument" = new-session ]; then
                    $real_tmux "\$@"
                    status=\$?
                    if [ "\$status" = 0 ]; then
                        : > $(quote_sh(trigger))
                    fi
                    exit "\$status"
                fi
                if [ "\$argument" = list-sessions ] && [ -f $(quote_sh(trigger)) ]; then
                    rm -- $(quote_sh(trigger))
                    printf 'invalid-format-row\\n'
                    exit 0
                fi
            done
            exec $real_tmux "\$@"
            """,
        )
        chmod(wrapper, 0o700)
        creating = Application(
            Server(; socket_path=server.socket_path, tmux=wrapper);
            allowed_tools=("create_session",),
            allow_create=true,
            timeout=0.9,
        )
        try
            failed = LibTmuxMCP._invoke_tool(
                creating,
                "create_session",
                Dict("name"=>"cleanup-probe", "command"=>["/bin/cat"]),
            )
            @test failed.is_error
            @test failed.structured_content["error"]["effects"] == "possible"
            @test !ispath(trigger)
            @test isempty(creating._owned)
            @test [session.name for session in sessions(snapshot(server))] == ["effects"]
        finally
            close(creating)
        end
    end
    @test !ispath(directory[])
end

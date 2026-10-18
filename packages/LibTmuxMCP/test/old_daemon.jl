using Test, LibTmux, LibTmuxMCP

tool_result(app, name, args=Dict(); kwargs...) =
    LibTmuxMCP._invoke_tool(app, name, args; kwargs...)

# Real tmux 3.0a and 3.1c daemons behind a current client. The reject lanes set
# `LIBTMUX_TEST_REQUIRE_OLD_DAEMON` so that absent builds fail the run instead
# of skipping this file.
#
# A cached release must not outlive the daemon: an old release that takes
# over the socket is refused, and its pane keeps running.
@testset "MCP refuses an old daemon that replaced a checked one" begin
    current = get(ENV, "LIBTMUX_TEST_CLIENT_TMUX", get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))
    builds = get(ENV, "LIBTMUX_TEST_OLD_TMUX_BUILDS", "")
    require = get(ENV, "LIBTMUX_TEST_REQUIRE_OLD_DAEMON", "") == "1"
    required = require || !isempty(builds)
    require && @test !isempty(builds)
    releases = split(get(ENV, "LIBTMUX_TEST_OLD_TMUX_RELEASES", "3.0a 3.1c"))
    exercised = 0
    for release in releases
        old = joinpath(builds, release, "bin", "tmux")
        required && @test isfile(old)
        isfile(old) || (@info "no real tmux $release under the old builds"; continue)
        exercised += 1
        mktempdir(; prefix="ltj-mcp-warm-") do directory
            socket = joinpath(directory, "s")
            server = Server(socket_path=socket, tmux=current)
            LibTmux._clear_version_cache!()
            @test success(`$current -S $socket -f /dev/null new-session -d -s warm`)
            caller = only(panes(snapshot(server))).ref
            app = Application(
                server;
                caller,
                allowed_tools=("list_panes", "send_keys", "kill_pane"),
            )
            try
                @test !tool_result(app, "list_panes").is_error
                run(pipeline(`$current -S $socket kill-server`; stderr=devnull))
                for _ = 1:100
                    ispath(socket) || break
                    sleep(0.05)
                end
                @test success(`$old -S $socket -f /dev/null new-session -d -s old`)
                # The refusal repeats; the stale entry does not come back.
                for _ = 1:2,
                    (name, arguments) in (
                        ("list_panes", Dict()),
                        ("send_keys", Dict("keys"=>["must-not-arrive"])),
                        ("kill_pane", Dict()),
                    )

                    refusal = tool_result(app, name, arguments)
                    @test refusal.is_error
                    error = refusal.structured_content["error"]
                    @test error["code"] == "unsupported_tmux" && error["effects"] == "none"
                end
                names = readchomp(
                    ignorestatus(`$old -S $socket list-panes -a -F '#{session_name}'`),
                )
                @test names == "old"
            finally
                close(app)
                for tmux in (old, current)
                    run(
                        pipeline(
                            ignorestatus(`$tmux -S $socket kill-server`);
                            stderr=devnull,
                        ),
                    )
                end
            end
        end
    end
    # Every requested release ran; a skipped loop is a failure where required.
    required && @test exercised == length(releases)
end

@testset "typed control session and topology operations" begin
    admitted =
        hasmethod(new_session, Tuple{ControlConnection}) &&
        hasmethod(link_window, Tuple{ControlConnection,WindowLinkRef,SessionRef})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            anchor = new_session(server; name="control-topology", command=["/bin/cat"])
            open_control(server, anchor) do connection
                field(target, name) =
                    only(read_formats(connection, target, FormatField(name))).value
                graph = snapshot(connection)
                original = only(windowlinks(graph))
                alpha = WindowLinkRef(original)
                first_pane = only(panes(graph)).ref
                before = connection.submitted
                @test_throws UnsupportedCapability new_session(
                    connection;
                    name="bad\n%end 1 2 1",
                )
                @test_throws ArgumentError select_layout(
                    connection,
                    alpha.window,
                    "bad\n%end 1 2 1",
                )
                @test_throws ArgumentError resize_pane(connection, first_pane; width=true)
                @test_throws ArgumentError move_pane(
                    connection,
                    first_pane,
                    first_pane;
                    direction=:diagonal,
                )
                cancelled = CancellationToken()
                cancel!(cancelled)
                @test_throws RequestCancelled new_session(
                    connection;
                    name="cancelled",
                    cancel=cancelled,
                )
                @test connection.submitted == before

                beta_session = new_session(
                    connection;
                    name="beta-#{literal};雪;",
                    command=["/bin/cat"],
                )
                @test beta_session.server == connection.identity
                @test field(beta_session, "session_name") == "beta-#{literal};雪;"
                @test_throws ControlCommandError new_session(
                    connection;
                    name="beta-#{literal};雪;",
                )
                beta = WindowLinkRef(
                    beta_session,
                    WindowRef(connection.identity, field(beta_session, "window_id")),
                    parse(Int, field(beta_session, "window_index")),
                )
                destination = PaneRef(connection.identity, field(beta_session, "pane_id"))
                @test rename_session(connection, beta_session, "renamed-#{literal};") isa
                      ControlResult
                @test field(beta_session, "session_name") == "renamed-#{literal};"
                rename_window(connection, alpha.window, "window-#{literal};雪;")
                @test field(alpha.window, "window_name") == "window-#{literal};雪;"
                resize_window(connection, alpha.window; width=100, height=40)
                @test field(alpha.window, "window_width") == "100"
                sibling = split_window(
                    connection,
                    first_pane;
                    direction=:right,
                    command=["/bin/cat"],
                )
                resize_pane(connection, first_pane; width=30)
                @test field(first_pane, "pane_width") == "30"
                select_pane(connection, sibling)
                @test field(sibling, "pane_active") == "1"
                @test select_layout(connection, alpha.window, :even_horizontal) isa
                      ControlResult
                custom_layout = field(alpha.window, "window_layout")
                @test select_layout(connection, alpha.window, custom_layout) isa
                      ControlResult
                before = connection.submitted
                @test_throws ArgumentError select_layout(
                    connection,
                    alpha.window,
                    "invalid-layout",
                )
                @test connection.submitted == before
                invalid_checksum =
                    (first(custom_layout) == '0' ? "1" : "0") * custom_layout[2:end]
                @test_throws ControlCommandError select_layout(
                    connection,
                    alpha.window,
                    invalid_checksum,
                )
                @test select_layout(connection, alpha.window, "even-h") isa ControlResult
                if field(alpha.window, "version") in ("3.2a", "3.3", "3.3a", "3.4")
                    @test_throws UnsupportedCapability select_layout(
                        connection,
                        alpha.window,
                        :main_horizontal_mirrored,
                    )
                else
                    @test select_layout(
                        connection,
                        alpha.window,
                        :main_horizontal_mirrored,
                    ) isa ControlResult
                end

                link_window(connection, alpha, beta_session; index=4)
                shared = WindowLinkRef(beta_session, alpha.window, 4)
                move_window(connection, shared, beta_session; index=5)
                @test_throws StaleReference unlink_window(connection, shared)
                unlink_window(connection, WindowLinkRef(beta_session, alpha.window, 5))
                link_window(connection, alpha, anchor; index=7)
                duplicate = WindowLinkRef(anchor, alpha.window, 7)
                select_window(connection, duplicate)
                @test field(anchor, "window_index") == "7"
                unlink_window(connection, duplicate)
                @test field(anchor, "window_index") == string(alpha.index)
                @test_throws ControlCommandError unlink_window(connection, alpha)
                @test_throws ControlCommandError move_window(
                    connection,
                    alpha,
                    beta_session;
                    index=beta.index,
                )

                move_pane(connection, sibling, destination; direction=:right, size=20)
                @test field(sibling, "window_id") == string(beta.window.id)
                swap_pane(connection, first_pane, sibling)
                @test field(first_pane, "window_id") == string(beta.window.id)
                @test field(sibling, "window_id") == string(alpha.window.id)
                swap_window(connection, alpha, beta)
                @test_throws StaleReference select_window(connection, alpha)
                @test_throws ControlCommandError respawn_pane(
                    connection,
                    sibling;
                    command=["/bin/cat"],
                )
                @test respawn_pane(
                    connection,
                    sibling;
                    kill_running=true,
                    command=["/bin/cat"],
                ) isa ControlResult
                @test respawn_window(
                    connection,
                    beta.window;
                    kill_running=true,
                    command=["/bin/cat"],
                ) isa ControlResult
                @test field(beta.window, "window_panes") == "1"

                count_before = connection.submitted
                stale = PaneRef(
                    ServerIdentity(socket_path=fixture.socket, generation="stale"),
                    sibling.id,
                )
                @test_throws StaleReference swap_pane(connection, sibling, stale)
                foreign = PaneRef(
                    ServerIdentity(socket_path=fixture.socket*"-other", generation="stale"),
                    sibling.id,
                )
                @test_throws CrossServerReference move_pane(connection, sibling, foreign)
                @test connection.submitted == count_before
                @test_throws ControlCommandError kill_session(
                    connection,
                    SessionRef(connection.identity, "\$999999"),
                )
                @test_throws ControlCommandError select_pane(
                    connection,
                    PaneRef(connection.identity, "%999999"),
                )
                extra = new_window(connection, anchor; command=["/bin/cat"])
                extra_pane = PaneRef(connection.identity, field(extra, "pane_id"))
                killed = split_window(connection, extra_pane; command=["/bin/cat"])
                @test kill_pane(connection, killed) isa ControlResult
                @test kill_window(connection, extra) isa ControlResult
                @test kill_session(connection, beta_session) isa ControlResult
                @test isopen(connection)
                @test field(anchor, "session_id") == string(anchor.id)
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

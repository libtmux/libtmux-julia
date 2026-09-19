@testset "exact topology references" begin
    @test isdefined(LibTmux, :WindowLinkRef)
    @test isdefined(LibTmux, :move_pane)
    if isdefined(LibTmux, :WindowLinkRef) && isdefined(LibTmux, :move_pane)
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            alpha = new_session(server; name="alpha", command=["/bin/cat"])
            beta = new_session(server; name="beta", command=["/bin/cat"])
            initial = snapshot(server)
            alpha_link = LibTmux.WindowLinkRef(
                only(windowlinks(only(filter(s -> s.ref == alpha, sessions(initial))))),
            )
            beta_link = LibTmux.WindowLinkRef(
                only(windowlinks(only(filter(s -> s.ref == beta, sessions(initial))))),
            )
            source =
                only(panes(only(filter(w -> w.ref == alpha_link.window, windows(initial))))).ref
            destination =
                only(panes(only(filter(w -> w.ref == beta_link.window, windows(initial))))).ref
            field(target, name) = chomp(
                decode_text(
                    run_command(
                        server,
                        "display-message",
                        "-p",
                        "-t",
                        string(target.id),
                        "#{" * name * "}",
                    ).stdout,
                ),
            )

            @test_throws ArgumentError LibTmux.WindowLinkRef(alpha, alpha_link.window, -1)
            @test_throws ArgumentError LibTmux.WindowLinkRef(alpha, alpha_link.window, true)
            @test_throws ArgumentError LibTmux.resize_window(server, alpha_link.window)
            @test_throws ArgumentError LibTmux.resize_pane(server, source; width=0)
            @test_throws ArgumentError LibTmux.move_pane(
                server,
                source,
                destination;
                direction=:diagonal,
            )

            LibTmux.link_window(server, alpha_link, beta; index=4)
            shared = LibTmux.WindowLinkRef(beta, alpha_link.window, 4)
            linked = snapshot(server)
            @test length(windows(linked)) == 2 && length(windowlinks(linked)) == 3
            LibTmux.move_window(server, shared, beta; index=5)
            @test_throws StaleReference LibTmux.unlink_window(server, shared)
            moved_link = LibTmux.WindowLinkRef(beta, alpha_link.window, 5)
            LibTmux.unlink_window(server, moved_link)
            @test length(windows(snapshot(server))) == 2
            @test_throws CommandError LibTmux.unlink_window(server, alpha_link)
            @test_throws CommandError LibTmux.move_window(
                server,
                alpha_link,
                beta;
                index=beta_link.index,
            )

            LibTmux.rename_session(server, alpha, "renamed-#{literal};")
            LibTmux.rename_window(server, alpha_link.window, "window-#{literal};")
            @test field(alpha, "session_name") == "renamed-#{literal};"
            @test field(alpha_link.window, "window_name") == "window-#{literal};"
            LibTmux.resize_window(server, alpha_link.window; width=100, height=40)
            @test field(alpha_link.window, "window_width") == "100"
            sibling = split_window(server, source; direction=:right, command=["/bin/cat"])
            LibTmux.resize_pane(server, source; width=30)
            @test field(source, "pane_width") == "30"
            LibTmux.move_pane(server, sibling, destination; direction=:right, size=20)
            @test field(sibling, "pane_id") == string(sibling.id)
            @test field(sibling, "window_id") == string(beta_link.window.id)
            LibTmux.swap_pane(server, source, sibling)
            @test field(source, "window_id") == string(beta_link.window.id)
            @test field(sibling, "window_id") == string(alpha_link.window.id)

            LibTmux.swap_window(server, alpha_link, beta_link)
            @test_throws StaleReference LibTmux.unlink_window(server, alpha_link)
            @test field(alpha_link.window, "window_id") == string(alpha_link.window.id)
            @test_throws CommandError LibTmux.respawn_pane(
                server,
                sibling;
                command=["/bin/cat"],
            )
            LibTmux.respawn_pane(server, sibling; kill_running=true, command=["/bin/cat"])
            @test field(sibling, "pane_id") == string(sibling.id)
            LibTmux.respawn_window(
                server,
                beta_link.window;
                kill_running=true,
                command=["/bin/cat"],
            )
            @test length(
                panes(
                    only(filter(w -> w.ref == beta_link.window, windows(snapshot(server)))),
                ),
            ) == 1

            stale = PaneRef(
                ServerIdentity(socket_path=fixture.socket, generation="stale"),
                sibling.id,
            )
            @test_throws StaleReference LibTmux.swap_pane(server, sibling, stale)
            foreign = PaneRef(
                ServerIdentity(
                    socket_path=joinpath(fixture.directory, "other"),
                    generation=sibling.server.generation,
                ),
                sibling.id,
            )
            @test_throws CrossServerReference LibTmux.move_pane(server, sibling, foreign)
            @test_throws UnsupportedCapability LibTmux.rename_session(
                server,
                alpha,
                "strict";
                strict=true,
            )
            cancelled = CancellationToken()
            cancel!(cancelled)
            @test_throws RequestCancelled LibTmux.rename_session(
                server,
                alpha,
                "cancelled";
                cancel=cancelled,
            )

            input_pipe = Pipe()
            command = setenv(
                Cmd([
                    fixture.tmux,
                    "-u",
                    "-N",
                    "-S",
                    fixture.socket,
                    "-f",
                    "/dev/null",
                    "-C",
                    "--",
                    "attach-session",
                    "-t",
                    string(alpha.id),
                    ";",
                    "wait-for",
                    "-S",
                    "client-attached",
                ]),
                fixture.env,
            )
            client_process = run(
                pipeline(
                    ignorestatus(command);
                    stdin=input_pipe,
                    stdout=devnull,
                    stderr=devnull,
                );
                wait=false,
            )
            close(input_pipe.out)
            try
                run_command(server, "wait-for", "client-attached"; timeout=0.9)
                client = only(clients(snapshot(server))).ref
                old_client = ClientRef(client.server, ClientID(client.id.name, "stale"))
                @test_throws StaleReference LibTmux.detach_client(server, old_client)
                LibTmux.switch_client(server, client, beta)
                @test only(clients(snapshot(server))).session.ref == beta
                LibTmux.detach_client(server, client)
                @test isempty(clients(snapshot(server)))
                @test_throws StaleReference LibTmux.detach_client(server, client)
            finally
                close(input_pipe)
                process_running(client_process) && kill(client_process, Base.SIGKILL)
                wait(client_process)
            end
        end
    end
end

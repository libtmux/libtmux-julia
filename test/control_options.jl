@testset "exact control configuration and inheritance" begin
    admitted =
        hasmethod(get_option, Tuple{ControlConnection,SessionRef,String}) &&
        hasmethod(get_hook, Tuple{ControlConnection,SessionRef,String})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="control-options", command=["/bin/cat"])
            graph = snapshot(server)
            window = only(windows(graph)).ref
            pane = only(panes(graph)).ref
            run_command(server, "set-option", "-g", "--", "@unsafe\n%end 1 2 1", "ignored")
            open_control(server, session) do connection
                before = connection.submitted
                @test_throws ArgumentError set_option(
                    connection,
                    pane,
                    "status-left",
                    "wrong",
                )
                @test_throws ArgumentError get_option(connection, session, "status-format")
                @test_throws UnsupportedCapability get_option(
                    connection,
                    session,
                    "no-such-option",
                )
                @test_throws ArgumentError get_hook(connection, session, "status-left")
                @test_throws UnsupportedCapability set_option(
                    connection,
                    :server,
                    "escape-time",
                    "bad\n%end 1 2 1",
                )
                @test_throws UnsupportedCapability get_environment(
                    connection,
                    session,
                    "LIBTMUX_NO_READ",
                )
                @test_throws UnsupportedCapability set_hook(
                    connection,
                    session,
                    "after-new-window",
                    raw"bad\012command",
                )
                @test_throws UnsupportedCapability set_hook(
                    connection,
                    session,
                    "after-new-window",
                    raw"$BAD_COMMAND",
                )
                token = CancellationToken()
                cancel!(token)
                @test_throws RequestCancelled get_option(
                    connection,
                    session,
                    "@local";
                    cancel=token,
                )
                stale = SessionRef(
                    ServerIdentity(socket_path=fixture.socket, generation="old"),
                    session.id,
                )
                foreign = SessionRef(
                    ServerIdentity(socket_path=fixture.socket*"-other", generation="other"),
                    session.id,
                )
                @test_throws StaleReference get_option(connection, stale, "@local")
                @test_throws CrossServerReference unset_hook(
                    connection,
                    foreign,
                    "after-new-window",
                )
                @test connection.submitted == before
                @test_throws ControlCommandError get_option(
                    connection,
                    SessionRef(connection.identity, "\$999999"),
                    "@local",
                )
                value = "quoted \"\$literal\" ' \\ \tline\n%end 1 2 1\e雪"
                @test set_option(connection, :global_session, "@local", value) isa
                      ControlResult
                @test get_option(connection, session, "@local") === nothing
                @test get_option(connection, session, "@local"; inherit=true) == value
                @test set_option(connection, session, "@local", "") isa ControlResult
                @test get_option(connection, session, "@local"; inherit=true) == ""
                @test unset_option(connection, session, "@local") isa ControlResult
                @test get_option(connection, session, "@local"; inherit=true) == value
                set_option(connection, :global_window, "@local", "global window")
                @test get_option(connection, pane, "@local"; inherit=true) ==
                      "global window"
                set_option(connection, window, "@local", "window")
                @test get_option(connection, pane, "@local"; inherit=true) == "window"
                set_option(connection, pane, "@local", "pane")
                @test get_option(connection, pane, "@local") == "pane"
                @test get_option(connection, :server, "escape-time") isa String
                scalar_command = run_command(
                    server,
                    "show-options",
                    "-s",
                    "--",
                    "default-client-command";
                    check=false,
                )
                if scalar_command.exitcode == 0
                    @test set_option(
                        connection,
                        :server,
                        "default-client-command",
                        "display-message noop",
                    ) isa ControlResult
                    @test get_option(connection, :server, "default-client-command") ==
                          "display-message noop"
                    @test set_option(connection, :server, "default-client-command", "") isa
                          ControlResult
                    @test get_option(connection, :server, "default-client-command") == ""
                    unset_option(connection, :server, "default-client-command")
                else
                    @test_throws ControlCommandError set_option(
                        connection,
                        :server,
                        "default-client-command",
                        "display-message noop",
                    )
                end
                version = only(read_formats(connection, pane, FormatField("version"))).value
                if LibTmux._tmux_option_metadata("destroy-unattached", version) === nothing
                    refused = try
                        get_option(connection, session, "destroy-unattached")
                    catch error
                        error
                    end
                    @test refused isa UnsupportedCapability
                    @test refused.operation === :get_option
                    @test occursin("tmux $(repr(version))", refused.detail)
                    @test occursin("session $(string(session.id))", refused.detail)
                    @test !occursin(fixture.socket, refused.detail)
                else
                    @test get_option(connection, :global_session, "destroy-unattached") isa
                          String
                end
                for literal in (
                    "~",
                    "'",
                    "\"",
                    "\\",
                    "\$ENV",
                    String(UInt8[1:31; 127]),
                    raw"\$ENV",
                    raw"\\$ENV",
                    raw"${ENV} $_env $9 $- $",
                )
                    set_option(connection, session, "@literal", literal)
                    @test get_option(connection, session, "@literal") == literal
                    if isascii(literal) && all(c -> !iscntrl(c), literal)
                        @test get_option(server, session, "@literal") == literal
                    end
                end
                @test_throws ControlCommandError set_option(
                    connection,
                    :server,
                    "escape-time",
                    "bad",
                )
                set_option(connection, :global_session, "status-format", "parent"; index=7)
                set_option(connection, session, "status-format", value; index=7)
                @test get_option(connection, session, "status-format"; index=7) == value
                @test get_option(
                    connection,
                    session,
                    "status-format";
                    index=6,
                    inherit=true,
                ) === nothing
                unset_option(connection, session, "status-format"; index=7)
                @test get_option(
                    connection,
                    session,
                    "status-format";
                    index=7,
                    inherit=true,
                ) === nothing
                set_hook(
                    connection,
                    :global_session,
                    "after-new-window",
                    "set-option -g @hook-first 'literal #{pane_id};'";
                    index=2,
                )
                set_hook(
                    connection,
                    :global_session,
                    "after-new-window",
                    "set-option -g @hook-second second";
                    index=9,
                )
                @test get_hook(connection, session, "after-new-window") === nothing
                inherited = get_hook(connection, session, "after-new-window"; inherit=true)
                @test [h.index for h in inherited] == [2, 9]
                @test all(h -> h.inherited, inherited)
                @test occursin("@hook-first", first(inherited).command)
                @test get_option(connection, :global_session, "@hook-first") === nothing
                new_window(connection, session; command=["/bin/cat"])
                @test get_option(connection, :global_session, "@hook-first") ==
                      "literal #{pane_id};"
                set_hook(connection, session, "after-new-window", "")
                @test isempty(
                    get_hook(connection, session, "after-new-window"; inherit=true),
                )
                unset_hook(connection, session, "after-new-window")
                @test length(
                    get_hook(connection, session, "after-new-window"; inherit=true),
                ) == 2
                set_hook(
                    connection,
                    pane,
                    "pane-mode-changed",
                    "display-message noop";
                    index=5,
                )
                @test only(get_hook(connection, pane, "pane-mode-changed")).index == 5
                @test_throws ControlCommandError set_hook(
                    connection,
                    pane,
                    "pane-mode-changed",
                    "no-such-command",
                )
                @test isempty(get_hook(connection, pane, "pane-mode-changed"))
                set_hook(
                    connection,
                    pane,
                    "pane-mode-changed",
                    "display-message noop";
                    index=5,
                )
                @test_throws ControlCommandError set_hook(
                    connection,
                    pane,
                    "pane-mode-changed",
                    "no-such-command";
                    index=5,
                )
                @test only(get_hook(connection, pane, "pane-mode-changed")).index == 5
                unset_hook(connection, pane, "pane-mode-changed"; index=5)
                @test isempty(get_hook(connection, pane, "pane-mode-changed"))
                unset_hook(connection, pane, "pane-mode-changed")
                @test get_hook(connection, pane, "pane-mode-changed") === nothing
                @test isopen(connection)
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

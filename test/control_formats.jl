@testset "typed formats on a pinned control connection" begin
    admitted = hasmethod(read_formats, Tuple{ControlConnection,PaneRef,FormatField{String}})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            text = joinpath(fixture.directory, "雪\tline\n%end 1 2 1\n\\literal")
            mkdir(text)
            session = new_session(
                server;
                name="control-formats",
                command=["/bin/cat"],
                start_directory=text,
            )
            captured = snapshot(server)
            pane = only(panes(captured)).ref
            window = only(windows(captured)).ref
            open_control(server, session) do connection
                fields = [
                    FormatField("pane_current_path"),
                    FormatField("pane_current_path"),
                    FormatField("pane_width", Int),
                    FormatField("pane_active", Bool),
                ]
                result = read_formats(connection, pane, fields)
                @test [v.value for v in result[1:2]] == [text, text]
                @test result[3].value > 0 && result[4].value === true
                @test all(v -> v.availability === :present, result)
                @test only(read_formats(connection, session, FormatField("session_id"))).value ==
                      string(session.id)
                @test only(read_formats(connection, window, FormatField("window_id"))).value ==
                      string(window.id)
                for T in (String, Int, Bool)
                    absent = only(
                        read_formats(
                            connection,
                            pane,
                            FormatField("libtmux_unavailable", T),
                        ),
                    )
                    @test absent.availability === :unverified
                    @test absent.value === (T === String ? "" : nothing)
                end
                error = try
                    read_formats(connection, pane, FormatField("session_name", Int))
                catch exception
                    exception
                end
                @test error isa FormatValueError
                @test error.result isa ControlResult && !error.result.failed
                @test error.raw == "control-formats"
                @test_throws OutputLimitExceeded read_formats(
                    connection,
                    pane,
                    FormatField("pane_current_path");
                    max_output_bytes=1,
                )
                @test isopen(connection)
                other = split_window(connection, pane; command=["/bin/cat"])
                for target in (pane, other)
                    @test only(read_formats(connection, target, FormatField("pane_id"))).value ==
                          string(target.id)
                end
                for missing in (
                    SessionRef(session.server, "\$999999"),
                    WindowRef(session.server, "@999999"),
                    PaneRef(session.server, "%999999"),
                )
                    @test_throws ControlCommandError read_formats(
                        connection,
                        missing,
                        FormatField("pane_id"),
                    )
                    @test isopen(connection)
                end
                before = connection.submitted
                @test_throws ArgumentError read_formats(connection, pane, FormatField[])
                cancelled = CancellationToken()
                cancel!(cancelled)
                @test_throws RequestCancelled read_formats(
                    connection,
                    pane,
                    FormatField("pane_id");
                    cancel=cancelled,
                )
                stale = PaneRef(
                    ServerIdentity(socket_path=fixture.socket, generation="stale"),
                    pane.id,
                )
                @test_throws StaleReference read_formats(
                    connection,
                    stale,
                    FormatField("pane_id"),
                )
                @test connection.submitted == before
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

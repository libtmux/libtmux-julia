@testset "control environment writes retain literal values and scope" begin
    admitted = hasmethod(set_environment, Tuple{ControlConnection,SessionRef,String,String})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="control-config", command=["/bin/cat"])
            open_control(server, session) do connection
                value = "雪\tline\n%end 1 2 1\n#{literal};"
                @test set_environment(connection, :global, "LIBTMUX_CONFIG", value) isa
                      ControlResult
                @test get_environment(server, :global, "LIBTMUX_CONFIG").value == value
                @test get_environment(server, session, "LIBTMUX_CONFIG") === nothing
                @test set_environment(
                    connection,
                    session,
                    "LIBTMUX_CONFIG",
                    "";
                    hidden=true,
                ) isa ControlResult
                empty = get_environment(server, session, "LIBTMUX_CONFIG")
                @test empty.value == "" && empty.hidden
                remove_environment(connection, session, "LIBTMUX_CONFIG")
                @test get_environment(server, session, "LIBTMUX_CONFIG"; inherit=true).value ===
                      nothing
                unset_environment(connection, session, "LIBTMUX_CONFIG")
                inherited = get_environment(server, session, "LIBTMUX_CONFIG"; inherit=true)
                @test inherited.value == value && inherited.inherited
                before = connection.submitted
                @test_throws ArgumentError set_environment(
                    connection,
                    :server,
                    "LIBTMUX_CONFIG",
                    value,
                )
                @test_throws ArgumentError set_environment(
                    connection,
                    session,
                    "BAD\n%end 1 2 1",
                    value,
                )
                cancelled = CancellationToken()
                cancel!(cancelled)
                @test_throws RequestCancelled set_environment(
                    connection,
                    session,
                    "LIBTMUX_CONFIG",
                    value;
                    cancel=cancelled,
                )
                @test connection.submitted == before
                missing = SessionRef(session.server, "\$999999")
                @test_throws ControlCommandError set_environment(
                    connection,
                    missing,
                    "LIBTMUX_CONFIG",
                    value,
                )
                @test isopen(connection)
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

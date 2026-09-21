@testset "typed control client operations" begin
    admitted =
        hasmethod(switch_client, Tuple{ControlConnection,ClientRef,SessionRef}) &&
        hasmethod(detach_client, Tuple{ControlConnection,ClientRef})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            anchor = new_session(server; name="client-anchor", command=["/bin/cat"])
            destination =
                new_session(server; name="client-destination", command=["/bin/cat"])
            open_control(server, anchor) do connection
                identity = connection.identity
                unknown = ClientRef(identity, ClientID("unknown", "1:1"))
                stale = ClientRef(
                    ServerIdentity(socket_path=fixture.socket, generation="stale"),
                    unknown.id,
                )
                foreign = ClientRef(
                    ServerIdentity(socket_path=fixture.socket*"-other", generation="other"),
                    unknown.id,
                )
                foreign_session = SessionRef(foreign.server, destination.id)
                unsafe = ClientRef(identity, ClientID("unsafe\n%end 1 2 1", "1:1"))
                spaced = ClientRef(identity, ClientID("unsafe name", "1:1"))
                cancelled = CancellationToken()
                cancel!(cancelled)
                before = connection.submitted
                @test_throws StaleReference detach_client(connection, stale)
                @test_throws CrossServerReference detach_client(connection, foreign)
                @test_throws CrossServerReference switch_client(
                    connection,
                    unknown,
                    foreign_session,
                )
                @test_throws UnsupportedCapability detach_client(connection, unsafe)
                @test_throws UnsupportedCapability switch_client(
                    connection,
                    spaced,
                    destination,
                )
                @test_throws RequestCancelled switch_client(
                    connection,
                    unknown,
                    destination;
                    cancel=cancelled,
                )
                @test_throws RequestCancelled detach_client(
                    connection,
                    unknown;
                    cancel=cancelled,
                )
                @test connection.submitted == before

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
                        string(anchor.id),
                        ";",
                        "wait-for",
                        "-S",
                        "client-ready",
                    ]),
                    fixture.env,
                )
                victim = run(
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
                    run_command(server, "wait-for", "client-ready"; timeout=0.9)
                    graph = snapshot(connection)
                    client = only(filter(c -> c.pid == getpid(victim), clients(graph))).ref
                    old = ClientRef(identity, ClientID(client.id.name, "stale"))
                    @test_throws StaleReference detach_client(connection, old)
                    @test_throws StaleReference detach_client(connection, unknown)
                    @test switch_client(connection, client, destination) isa ControlResult
                    switched =
                        only(filter(c -> c.ref == client, clients(snapshot(connection))))
                    @test switched.session.ref == destination
                    @test switch_client(
                        connection,
                        client,
                        anchor;
                        update_environment=true,
                    ) isa ControlResult
                    @test detach_client(connection, client) isa ControlResult
                    @test all(c -> c.ref != client, clients(snapshot(connection)))
                    @test_throws StaleReference detach_client(connection, client)
                    @test isopen(connection)
                finally
                    close(input_pipe)
                    OwnedTmux.stop!(victim)
                    wait(victim)
                end
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

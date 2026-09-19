# Integration: owns two clients and proves capture cancellation and buffer cleanup.
@testset "control capture uses an owned binary spool" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        new_session(server; name="capture", command=["/bin/cat"])
        snap = snapshot(server)
        session = only(sessions(snap)).ref
        result = run_command(
            server,
            "split-window",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-t",
            string(only(panes(snap)).id),
            "",
        )
        pane = PaneRef(session.server, chomp(decode_text(result.stdout)))
        payload = "%begin 1 2 1\r\n%end 1 2 1\r\n%output %0 guard text\r\né 雪\r\n"
        run_command(
            server,
            "display-message",
            "-I",
            "-t",
            string(pane.id);
            input=codeunits(payload),
        )
        expected = capture_bytes(server, pane)
        @test occursin("%end 1 2 1", decode_text(expected))
        open_control(server, session) do connection
            captured = snapshot(connection)
            @test entitykey.(panes(captured)) == entitykey.(panes(snapshot(server)))
            @test length(clients(captured)) == 2
            @test only(filter(PaneWhere(active=true), panes(captured))).id ==
                  only(panes(snap)).id
            @test capture_bytes(connection, pane) == expected
            @test capture_pane(connection, pane) == decode_text(expected)
            @test_throws OutputLimitExceeded capture_bytes(connection, pane; max_bytes=1)
            @test isempty(run_command(server, "list-buffers").stdout)
            @test_throws ControlCommandError capture_bytes(
                connection,
                PaneRef(pane.server, "%999999"),
            )
            token = CancellationToken()
            cancel!(token)
            before = connection.submitted
            @test_throws RequestCancelled capture_bytes(connection, pane; cancel=token)
            @test connection.submitted == before
            @test_throws CrossServerReference capture_bytes(
                connection,
                PaneRef(
                    ServerIdentity(socket_path=fixture.socket * "-other", generation="1"),
                    "%0",
                ),
            )
            @test isempty(run_command(server, "list-buffers").stdout)
            @test isopen(connection)

            observe_output(connection, pane) do stream
                cursor = observation_cursor(stream)
                baseline = capture_baseline(stream)
                @test baseline.bytes == expected && baseline.continuity === :reset
                @test baseline.before.sequence <= baseline.after.sequence
                @test observation_cursor(stream) == cursor
            end
            notifications(connection) do stream
                @test_throws ArgumentError capture_baseline(stream)
            end

            # The hook holds completion after capture has created its buffer.
            set_hook(
                server,
                :global_session,
                "after-capture-pane",
                "wait-for -S capture-created ; wait-for capture-release",
            )
            active = CancellationToken()
            pending = Threads.@spawn try
                capture_bytes(connection, pane; cancel=active)
            catch error
                error
            end
            try
                run_command(server, "wait-for", "capture-created"; timeout=0.9)
                cancel!(active)
            finally
                run_command(server, "wait-for", "-S", "capture-release")
                unset_hook(server, :global_session, "after-capture-pane")
            end
            outcome = fetch(pending)
            @test outcome isa RequestCancelled && outcome.sent
            @test isempty(run_command(server, "list-buffers").stdout)
            @test isopen(connection)
        end
    end
end

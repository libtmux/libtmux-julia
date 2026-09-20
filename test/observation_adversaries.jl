function adversary_output(stream, expected)
    bytes = UInt8[]
    cursors = ObservationCursor[]
    started = time_ns()
    while length(bytes) < length(expected)
        remaining = 0.9 - (time_ns() - started) / 1e9
        event = take!(stream; timeout=remaining)
        event isa PaneOutput || error("expected pane output")
        append!(bytes, event.bytes)
        push!(cursors, event.cursor)
    end
    @test bytes == expected
    @test all(diff([cursor.sequence for cursor in cursors]) .> 0)
    last(cursors)
end

@testset "baseline output and target transitions" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session = new_session(
            server;
            name="observation-adversaries",
            command=[
                "/bin/sh",
                "-c",
                "stty raw -echo || exit; \"\$1\" -N -S \"\$2\" wait-for -S raw-ready; exec /bin/cat",
                "sh",
                fixture.tmux,
                fixture.socket,
            ],
        )
        run_command(server, "wait-for", "raw-ready"; timeout=0.9)
        target = only(panes(snapshot(server))).ref
        destination_window =
            new_window(server, session; name="destination", command=["/bin/cat"])
        destination = only(
            panes(
                only(filter(w -> w.ref == destination_window, windows(snapshot(server)))),
            ),
        ).ref
        retired = Ref{ControlConnection}()
        open_control(server, session) do connection
            retired[] = connection
            observe_output(connection, target) do primary
                observe_output(connection, target) do observer
                    initial = observation_cursor(primary)
                    before = collect(codeunits("before-λ"))
                    during = collect(codeunits("during-雪"))
                    after = collect(codeunits("after-☃"))
                    send_keys(server, target, String(copy(before)); literal=true)
                    before_cursor = adversary_output(observer, before)
                    set_hook(
                        server,
                        :global_session,
                        "after-capture-pane",
                        "wait-for -S baseline-captured ; wait-for baseline-release",
                    )
                    during_cursor = nothing
                    baseline = @sync begin
                        capturing = Threads.@spawn capture_baseline(primary)
                        try
                            run_command(server, "wait-for", "baseline-captured"; timeout=0.9)
                            send_keys(server, target, String(copy(during)); literal=true)
                            during_cursor = adversary_output(observer, during)
                            @test !istaskdone(capturing)
                            @test observation_cursor(primary) == initial
                        finally
                            try
                                run_command(
                                    server,
                                    "wait-for",
                                    "-S",
                                    "baseline-release";
                                    timeout=0.9,
                                )
                            finally
                                unset_hook(server, :global_session, "after-capture-pane")
                            end
                        end
                        fetch(capturing)
                    end
                    @test baseline.continuity === :reset
                    @test baseline.before.sequence >= before_cursor.sequence
                    @test baseline.after.sequence >= during_cursor.sequence
                    @test observation_cursor(primary) == initial
                    @test occursin(String(copy(before)), decode_text(baseline.bytes))
                    @test !occursin(String(copy(during)), decode_text(baseline.bytes))
                    send_keys(server, target, String(copy(after)); literal=true)
                    after_cursor = adversary_output(observer, after)
                    @test after_cursor.sequence > baseline.after.sequence
                    @test adversary_output(primary, [before; during; after]) == after_cursor
                end
            end
            observe_output(connection, target) do moved
                old_cursor = observation_cursor(moved)
                move_pane(server, target, destination; direction=:right)
                @test_throws ObservationLost take!(moved; timeout=0.9)
                @test_throws ObservationLost capture_baseline(moved)
                @test_throws ObservationLost observe_output(
                    connection,
                    target;
                    after=old_cursor,
                )
                observed = only(filter(p -> p.ref == target, panes(snapshot(connection))))
                @test observed.window.ref == destination_window
            end
            observe_output(connection, target) do dying
                @test capture_baseline(dying).continuity === :reset
                kill_pane(server, target)
                @test_throws ObservationLost take!(dying; timeout=0.9)
                @test_throws ObservationLost capture_baseline(dying)
                @test_throws ControlTargetError observe_output(connection, target)
                @test all(p -> p.ref != target, panes(snapshot(connection)))
            end
            @test isopen(connection)
        end
        @test all(istaskdone, retired[].workers)
        @test process_exited(retired[].process)
        @test process_exited(retired[].cleanup.process)
        @test isempty(clients(snapshot(server)))
    end
end

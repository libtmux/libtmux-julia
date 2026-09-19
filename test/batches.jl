# Outer integration: owned control clients exercise retirement and cancellation.
@testset "finite batches and groups" begin
    @test isdefined(LibTmux, :TmuxCommand)
    if isdefined(LibTmux, :TmuxCommand)
        command = LibTmux.TmuxCommand
        arguments = ["kill-pane", "-t", "%9"]
        frozen = command(arguments)
        arguments[3] = "%10"
        @test frozen.arguments == ("kill-pane", "-t", "%9")
        @test_throws ArgumentError command(String[])
        @test_throws ArgumentError command("kill-pane", "\0")
        @test isempty(
            LibTmux.run_batch(
                Server(socket_name="unused", tmux="absent"),
                LibTmux.TmuxCommand[],
            ),
        )
        isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")
        OwnedTmux.with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="batches", command=["cat"])
            anchor = only(panes(snapshot(server))).ref
            open_control(server, session; capacity=2) do connection
                left = split_window(server, anchor; command=["cat"])
                right = split_window(server, anchor; command=["cat"])
                commands = [
                    command("kill-pane", "-t", "%999999"),
                    command("kill-pane", "-t", string(left.id)),
                    command("kill-pane", "-t", string(right.id)),
                ]
                batch = LibTmux.run_batch(connection, commands; concurrency=2)
                @test getproperty.(batch, :status) == [:failed, :completed, :completed]
                @test getproperty.(batch, :index) == [1, 2, 3]
                @test all(result -> result.acknowledged && result.completed, batch)
                @test isopen(connection)
                @test only(LibTmux._control_rows(connection, "list-panes", ["pane_id"])) ==
                      [string(anchor.id)]

                left = split_window(server, anchor; command=["cat"])
                right = split_window(server, anchor; command=["cat"])
                commands = [
                    command("kill-pane", "-t", string(left.id)),
                    command("kill-pane", "-t", "%999999"),
                    command("kill-pane", "-t", string(right.id)),
                ]
                group = LibTmux.run_group(connection, commands)
                @test getproperty.(group, :status) == [:completed, :failed, :skipped]
                @test group.retired && !group.opaque
                @test group[1].acknowledged &&
                      group[2].acknowledged &&
                      !group[3].acknowledged
                @test !group[3].completed
                @test [string(right.id)] in
                      LibTmux._control_rows(connection, "list-panes", ["pane_id"])

                before = connection.submitted
                @test_throws ArgumentError LibTmux.run_batch(
                    connection,
                    [
                        command("kill-pane", "-t", string(right.id)),
                        command("capture-pane", "-p"),
                    ],
                )
                @test connection.submitted == before
                cancelled = CancellationToken()
                cancel!(cancelled)
                cancelled_batch = LibTmux.run_batch(
                    connection,
                    [command("kill-pane", "-t", string(right.id))];
                    cancel=cancelled,
                )
                @test only(cancelled_batch).status === :skipped
                cancelled_group = LibTmux.run_group(
                    connection,
                    [command("kill-pane", "-t", string(right.id))];
                    cancel=cancelled,
                )
                @test only(cancelled_group).status === :skipped && !cancelled_group.retired
                @test connection.submitted == before

                success = LibTmux.run_group(
                    connection,
                    [command("kill-pane", "-t", string(right.id))],
                )
                @test only(success).status === :completed && success.retired
                opaque = LibTmux.run_group(
                    server,
                    [
                        command("display-message", "-p", ";"),
                        command("kill-pane", "-t", "%999999"),
                        command("display-message", "-p", "skipped"),
                    ],
                )
                @test opaque.opaque &&
                      !opaque.retired &&
                      all(result -> result.status === :unknown, opaque)
                @test opaque.aggregate.exitcode != 0 &&
                      opaque.aggregate.stdout == codeunits(";\n")
                ordinary =
                    LibTmux.run_batch(server, [command("display-message", "-p", "value")])
                @test only(ordinary).status === :unknown &&
                      only(ordinary).result.stdout == codeunits("value\n")
                @test !only(ordinary).completed && only(ordinary).acknowledged

                victim = split_window(server, anchor; command=["cat"])
                signal = control_signal(connection)
                waiting = Threads.@spawn wait(signal)
                lock(connection.lock) do
                    while signal.request === nothing || signal.request.frame === nothing
                        wait(connection.changed)
                    end
                end
                cancellation = CancellationToken()
                sent_group = Threads.@spawn LibTmux.run_group(
                    connection,
                    [command("kill-pane", "-t", string(victim.id))];
                    cancel=cancellation,
                )
                lock(connection.lock) do
                    while !any(
                        request -> request.command == "command-group" && request.sent,
                        connection.pending,
                    )
                        wait(connection.changed)
                    end
                end
                cancel!(cancellation)
                uncertain = fetch(sent_group)
                @test only(uncertain).status === :unknown && !uncertain.retired
                @test uncertain.error isa RequestCancelled && uncertain.error.sent
                notify(signal)
                fetch(waiting)
                @test !(
                    [string(victim.id)] in
                    LibTmux._control_rows(connection, "list-panes", ["pane_id"])
                )
                @test only(uncertain).status === :unknown
            end

            terminal = open_control(server, session)
            kill(terminal.process, Base.SIGKILL)
            wait(terminal.supervisor)
            lost =
                LibTmux.run_batch(terminal, [command("kill-pane", "-t", string(anchor.id))])
            @test only(lost).status === :skipped && !only(lost).acknowledged
            close(terminal)
            @test run_command(server, "has-session", "-t", string(session.id)).exitcode == 0
        end
    end
end

@testset "owned control connection" begin
    @test isdefined(LibTmux, :open_control)
    if isdefined(LibTmux, :open_control)
        if !isdefined(Main, :OwnedTmux)
            include("support/owned_tmux.jl")
        end
        OwnedTmux.with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="control", command=["cat"])
            @test_throws ArgumentError LibTmux.open_control(
                server,
                session;
                capacity=big(typemax(Int)) + 1,
            )
            @test_throws ArgumentError LibTmux.open_control(server, session; capacity=true)
            @test isempty(run_command(server, "list-clients", "-F", "#{client_pid}").stdout)
            connection = LibTmux.open_control(server, session; capacity=1)
            try
                @test isopen(connection)
                @test repr(connection) ==
                      "ControlConnection(session=" *
                      repr(string(session.id)) *
                      ", state=open)"
                flags = split(
                    chomp(
                        String(
                            run_command(server, "list-clients", "-F", "#{client_flags}").stdout,
                        ),
                    ),
                    '\n',
                )
                @test length(flags) == 2
                @test all(
                    line -> all(
                        flag -> flag in split(line, ','),
                        ["ignore-size", "no-output", "UTF-8"],
                    ),
                    flags,
                )
                @test LibTmux._control_rows(
                    connection,
                    "list-sessions",
                    ["session_id", "session_name"],
                ) == [[string(session.id), "control"]]
                @test LibTmux._control_rows(connection, "display-message", ["pid"])[1][1] ==
                      string(getpid(fixture.process))
                @test_throws ArgumentError run_command(connection, "capture-pane", "-p")
                @test_throws ArgumentError run_command(
                    connection,
                    "wait-for",
                    "borrowed-channel",
                )
                @test_throws ArgumentError LibTmux._control_rows(
                    connection,
                    "list-panes",
                    ["#{evil}"],
                )
                @test_throws LibTmux.ControlCommandError run_command(
                    connection,
                    "kill-pane",
                    "-t",
                    "%99999",
                )
                @test isopen(connection)

                cancelled = CancellationToken()
                cancel!(cancelled)
                before = connection.submitted
                @test_throws RequestCancelled run_command(
                    connection,
                    "kill-session",
                    "-t",
                    string(session.id);
                    cancel=cancelled,
                )
                @test connection.submitted == before

                latched = LibTmux.control_signal(connection)
                @test_throws ArgumentError LibTmux.control_signal(connection)
                notify(latched)
                wait(latched)
                @test connection.submitted == before
                @test isempty(connection.signals)

                active = CancellationToken()
                signal = LibTmux.control_signal(connection)
                waiting = Threads.@spawn try
                    wait(signal; cancel=active)
                catch error
                    error
                end
                lock(connection.lock) do
                    while isempty(connection.pending) ||
                          first(connection.pending).frame === nothing
                        wait(connection.changed)
                    end
                end
                @test !istaskdone(waiting)
                lock(connection.cleanup.lock) do
                    cancel!(active)
                    outcome = fetch(waiting)
                    @test outcome isa RequestCancelled && outcome.sent
                    @test lock(() -> length(connection.pending), connection.lock) == 1

                    queued_cancel = CancellationToken()
                    queued = Threads.@spawn try
                        run_command(
                            connection,
                            "kill-session",
                            "-t",
                            string(session.id);
                            cancel=queued_cancel,
                        )
                    catch error
                        error
                    end
                    cancel!(queued_cancel)
                    queued_outcome = fetch(queued)
                    @test queued_outcome isa RequestCancelled && !queued_outcome.sent
                end
                @test LibTmux._control_rows(connection, "list-sessions", ["session_id"]) ==
                      [[string(session.id)]]
                @test lock(() -> isempty(connection.pending), connection.lock)

                signalled = LibTmux.control_signal(connection)
                normal_wait = Threads.@spawn wait(signalled)
                lock(connection.lock) do
                    while signalled.request === nothing ||
                          signalled.request.frame === nothing
                        wait(connection.changed)
                    end
                end
                @test !istaskdone(normal_wait)
                notify(signalled)
                @test fetch(normal_wait) === nothing
                @test signalled.cleanup_done && isempty(connection.signals)
                external = LibTmux.control_signal(connection)
                external_wait = Threads.@spawn try
                    wait(external)
                catch error
                    error
                end
                lock(connection.lock) do
                    while external.request === nothing || external.request.frame === nothing
                        wait(connection.changed)
                    end
                end
                run_command(server, "wait-for", "-S", external.name)
                @test fetch(external_wait) === nothing
                @test external.cleanup_done
                unsafe_client =
                    ClientRef(connection.identity, ClientID("missing\n%end 1 2 1", "probe"))
                @test_throws ArgumentError LibTmux._control_rows(
                    connection,
                    "display-message",
                    ["pid"];
                    target=unsafe_client,
                )
                absent_pane = PaneRef(connection.identity, "%999999")
                @test_throws LibTmux.ControlTargetError LibTmux._control_rows(
                    connection,
                    "display-message",
                    ["pid"];
                    target=absent_pane,
                )
                @test isopen(connection)
            finally
                close(connection)
            end
            @test !isopen(connection)
            @test all(istaskdone, connection.workers)
            @test istaskdone(connection.supervisor)
            @test process_exited(connection.process)
            @test process_exited(connection.cleanup.process)
            @test all(istaskdone, connection.cleanup.workers)
            @test istaskdone(connection.cleanup_worker)
            @test istaskdone(connection.stop_timer_task) &&
                  istaskdone(connection.cleanup.stop_timer_task)
            @test_throws LibTmux.ControlConnectionError run_command(
                connection,
                "kill-pane",
                "-t",
                "%0",
            )
            close(connection)
            @test run_command(server, "has-session", "-t", string(session.id)).exitcode == 0

            closing = LibTmux.open_control(server, session; capacity=1)
            signal = LibTmux.control_signal(closing)
            blocked = Threads.@spawn try
                wait(signal)
            catch error
                error
            end
            lock(closing.lock) do
                while signal.request === nothing || signal.request.frame === nothing
                    wait(closing.changed)
                end
            end
            close(closing)
            @test fetch(blocked) isa LibTmux.ControlConnectionError
            @test signal.cleanup_done &&
                  isempty(closing.pending) &&
                  isempty(closing.signals)
            @test process_exited(closing.process) && process_exited(closing.cleanup.process)
            @test isempty(
                String(run_command(server, "list-clients", "-F", "#{client_pid}").stdout),
            )

            lost = LibTmux.open_control(server, session)
            kill(lost.process, Base.SIGKILL)
            wait(lost.supervisor)
            wait(lost.cleanup.supervisor)
            close(lost)
            @test !isopen(lost) && process_exited(lost.cleanup.process)

            interrupted = nothing
            interrupted_signal = nothing
            cleanup_before = 0
            combined = try
                LibTmux.open_control(server, session) do owned
                    interrupted = owned
                    interrupted_signal = LibTmux.control_signal(owned)
                    interrupted_wait = Threads.@spawn try
                        wait(interrupted_signal)
                    catch error
                        error
                    end
                    lock(owned.lock) do
                        while interrupted_signal.request === nothing ||
                              interrupted_signal.request.frame === nothing
                            wait(owned.changed)
                        end
                    end
                    cleanup_before = owned.cleanup.submitted
                    kill(owned.process, Base.SIGKILL)
                    wait(owned.supervisor)
                    @test fetch(interrupted_wait) isa LibTmux.ControlConnectionError
                    error("body failure")
                end
            catch error
                error
            end
            @test combined isa CompositeException
            @test combined.exceptions[1] isa ErrorException
            @test combined.exceptions[2] isa LibTmux.ControlCleanupError
            @test !interrupted_signal.cleanup_done
            @test_throws LibTmux.ControlCleanupError close(interrupted)
            @test interrupted.cleanup.submitted == cleanup_before + 4
            @test process_exited(interrupted.cleanup.process)
            @test istaskdone(interrupted.cleanup_worker)

            hooked = LibTmux.open_control(server, session)
            try
                run_command(
                    server,
                    "set-hook",
                    "-g",
                    "after-list-sessions",
                    "display-message -p unexpected",
                )
                @test_throws LibTmux.ControlConnectionError LibTmux._control_rows(
                    hooked,
                    "list-sessions",
                    ["session_id"],
                )
            finally
                run_command(server, "set-hook", "-gu", "after-list-sessions")
                close(hooked)
            end
            @test !isopen(hooked)

            concurrent = LibTmux.open_control(server, session; capacity=4)
            try
                jobs = map(1:8) do index
                    Threads.@spawn begin
                        if isodd(index)
                            LibTmux._control_rows(concurrent, "display-message", ["pid"])
                        else
                            run_command(concurrent, "kill-pane", "-t", "%99999"; check=false)
                        end
                    end
                end
                results = fetch.(jobs)
                @test all(
                    index ->
                        isodd(index) ?
                        results[index] == [[string(getpid(fixture.process))]] :
                        results[index].failed,
                    eachindex(results),
                )
                @test isopen(concurrent)
                earlier, later =
                    LibTmux.control_signal(concurrent), LibTmux.control_signal(concurrent)
                first_wait = Threads.@spawn try
                    wait(earlier; timeout=0.9)
                catch error
                    error
                end
                lock(concurrent.lock) do
                    while earlier.request === nothing || earlier.request.frame === nothing
                        wait(concurrent.changed)
                    end
                end
                second_wait = Threads.@spawn try
                    wait(later; timeout=0.9)
                catch error
                    error
                end
                lock(concurrent.lock) do
                    while later.request === nothing || !later.request.sent
                        wait(concurrent.changed)
                    end
                end
                before_release = concurrent.cleanup.submitted
                notify(later)
                lock(concurrent.cleanup.lock) do
                    while concurrent.cleanup.submitted == before_release ||
                          !isempty(concurrent.cleanup.pending)
                        wait(concurrent.cleanup.changed)
                    end
                end
                notify(earlier)
                @test fetch(first_wait) === nothing && fetch(second_wait) === nothing
                @test earlier.cleanup_done && later.cleanup_done
                @test isempty(concurrent.signals) && isempty(concurrent.pending)
                window = only(
                    only(
                        LibTmux._control_rows(
                            concurrent,
                            "list-windows",
                            ["window_id"];
                            target=session,
                        ),
                    ),
                )
                for batch = 0:9
                    arguments = String[]
                    for index = 1:26
                        isempty(arguments) || push!(arguments, ";")
                        append!(
                            arguments,
                            [
                                "rename-window",
                                "-t",
                                window,
                                "event-" * string(batch * 26 + index),
                            ],
                        )
                    end
                    run_command(server, arguments...)
                end
                @test LibTmux._control_rows(concurrent, "display-message", ["pid"]) ==
                      [[string(getpid(fixture.process))]]
                @test LibTmux._control_rows(
                    concurrent.cleanup,
                    "display-message",
                    ["pid"],
                ) == [[string(getpid(fixture.process))]]
                notifications(concurrent; kinds=(Symbol("window-renamed"),)) do stream
                    @test isempty(stream.queue)
                    run_command(server, "rename-window", "-t", window, "after-registration")
                    @test endswith(
                        String(take!(stream; timeout=0.9).bytes),
                        " after-registration",
                    )
                end
                abandoned = LibTmux.control_signal(concurrent)
                close(concurrent)
                @test abandoned.cleanup_done && abandoned.request === nothing
            finally
                close(concurrent)
            end

            stale = SessionRef(
                ServerIdentity(socket_path=session.server.socket_path, generation="stale"),
                session.id,
            )
            @test_throws StaleReference LibTmux.open_control(server, stale)
            @test run_command(server, "has-session", "-t", string(session.id)).exitcode == 0
        end
    end
end

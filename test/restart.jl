using Test, LibTmux
isdefined(@__MODULE__, :OwnedTmux) || include("support/owned_tmux.jl")

function with_replacement_tmux(f, previous)
    # Abrupt loss drops the old queue; graceful tmux shutdown flushes wait channels.
    kill(previous.process, Base.SIGKILL)
    wait(previous.process)
    rm(previous.socket; force=true)
    monitor = OwnedTmux.FolderMonitor(previous.directory)
    process = watcher = nothing
    log = open(joinpath(previous.directory, "replacement-stderr"), "w+")
    try
        command = setenv(
            Cmd([previous.tmux, "-D", "-S", previous.socket, "-f", "/dev/null"]),
            previous.env,
        )
        process =
            run(pipeline(command; stdin=devnull, stdout=devnull, stderr=log); wait=false)
        replacement = OwnedTmux.Fixture(
            previous.tmux,
            previous.directory,
            previous.socket,
            previous.env,
            process,
        )
        watcher = Threads.@spawn begin
            wait(process)
            close(monitor)
        end
        OwnedTmux.await_ready(replacement, monitor)
        @test readchomp(
            OwnedTmux.tmuxcmd(replacement, "display-message", "-p", "#{pid}"),
        ) == string(getpid(process))
        f(replacement)
    finally
        try
            process === nothing || OwnedTmux.stop!(process)
        finally
            close(monitor)
            watcher === nothing || wait(watcher)
            close(log)
        end
    end
end

function await_restart_request(predicate, connection)
    expired = Ref(false)
    timer, task = LibTmux._owned_timer(0.9) do
        lock(connection.lock) do
            expired[] = true
            notify(connection.changed; all=true)
        end
    end
    try
        lock(connection.lock) do
            while !predicate()
                expired[] && error("control request readiness timed out")
                isopen(connection) || error("control closed before request readiness")
                wait(connection.changed)
            end
        end
    finally
        close(timer)
        wait(task)
    end
end

@testset "daemon replacement at one owned socket" begin
    original = Ref{Any}()
    replacement = Ref{Any}()
    sentinel = ErrorException("restart proof body failure")
    outcome = try
        OwnedTmux.with_tmux() do fixture
            original[] = fixture
            original_pid = getpid(fixture.process)
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="original", command=["/bin/cat"])
            pane = only(panes(snapshot(server))).ref
            connection = open_control(server, session)
            signal = control_signal(connection)
            waiting = Threads.@spawn try
                wait(signal)
            catch error
                error
            end
            queued = nothing
            retired = false
            try
                await_restart_request(connection) do
                    signal.request !== nothing && signal.request.frame !== nothing
                end
                queued = Threads.@spawn try
                    rename_session(connection, session, "must-not-replay")
                catch error
                    error
                end
                await_restart_request(connection) do
                    any(
                        request -> request.command == "rename-session" && request.sent,
                        connection.pending,
                    )
                end
                @test !istaskdone(queued)
                @test only(sessions(snapshot(server))).name == "original"
                with_replacement_tmux(fixture) do fresh_fixture
                    replacement[] = fresh_fixture
                    fresh_server = Server(
                        socket_path=fresh_fixture.socket,
                        tmux=fresh_fixture.tmux,
                    )
                    fresh_session = new_session(
                        fresh_server;
                        name="replacement",
                        command=["/bin/cat"],
                    )
                    fresh_pane = only(panes(snapshot(fresh_server))).ref
                    @test session.id == fresh_session.id && pane.id == fresh_pane.id
                    @test session.server.socket_path == fresh_session.server.socket_path
                    @test session.server.generation != fresh_session.server.generation
                    @test original_pid != getpid(fresh_fixture.process)
                    first_failure, queued_failure = fetch(waiting), fetch(queued)
                    @test first_failure isa LibTmux.ControlConnectionError &&
                          first_failure.sent
                    @test queued_failure isa LibTmux.ControlConnectionError &&
                          queued_failure.sent
                    wait(connection.supervisor)
                    @test !isopen(connection)
                    retirement = try
                        close(connection)
                    catch error
                        error
                    end
                    retired = true
                    @test retirement isa LibTmux.ControlCleanupError
                    @test !signal.cleanup_done
                    @test process_exited(connection.process) &&
                          process_exited(connection.cleanup.process)
                    submitted = connection.submitted
                    @test_throws StaleReference capture_bytes(fresh_server, pane)
                    @test_throws StaleReference rename_session(
                        fresh_server,
                        session,
                        "stale-subprocess",
                    )
                    @test_throws StaleReference open_control(fresh_server, session)
                    @test_throws LibTmux.ControlConnectionError rename_session(
                        connection,
                        session,
                        "closed-replay",
                    )
                    @test connection.submitted == submitted
                    @test only(sessions(snapshot(fresh_server))).name == "replacement"
                    open_control(fresh_server, fresh_session) do fresh_connection
                        before = fresh_connection.submitted
                        @test_throws StaleReference send_keys(
                            fresh_connection,
                            pane,
                            "stale input";
                            literal=true,
                        )
                        @test fresh_connection.submitted == before
                        rename_session(fresh_connection, fresh_session, "fresh-operation")
                        @test capture_bytes(fresh_connection, fresh_pane) isa Vector{UInt8}
                    end
                    @test only(sessions(snapshot(fresh_server))).name == "fresh-operation"
                    @test process_running(fresh_fixture.process)
                    throw(sentinel)
                end
            finally
                if !retired
                    try
                        close(connection)
                    catch error
                        error isa LibTmux.ControlCleanupError || rethrow()
                    end
                end
                @test process_exited(connection.process) &&
                      process_exited(connection.cleanup.process)
                @test all(istaskdone, connection.workers) &&
                      all(istaskdone, connection.cleanup.workers)
                @test istaskdone(connection.supervisor) &&
                      istaskdone(connection.cleanup.supervisor) &&
                      istaskdone(connection.cleanup_worker)
                wait(waiting)
                queued === nothing || wait(queued)
            end
        end
    catch error
        error
    end
    @test outcome === sentinel
    @test process_exited(original[].process) && process_exited(replacement[].process)
    @test !ispath(original[].directory)
end

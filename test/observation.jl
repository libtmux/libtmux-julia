function await_observation(predicate, connection, message)
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
                expired[] && error(message)
                wait(connection.changed)
            end
        end
    finally
        close(timer)
        wait(task)
    end
end

Base.@noinline function drop_format_observation(connection, pane)
    stream = LibTmux.subscribe_format(connection, pane, "pane_dead")
    take!(stream; timeout=2.0)
    lock(() -> connection.submitted, connection.lock)
end

Base.@noinline function abandon_notifications!(streams)
    empty!(streams)
    nothing
end

@testset "bounded observations" begin
    @test isdefined(LibTmux, :ObservationStream)
    if isdefined(LibTmux, :ObservationStream)
        isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")
        OwnedTmux.with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="observation", command=["cat"])
            pane = only(panes(snapshot(server))).ref
            connection = open_control(server, session)
            beginning = nothing
            try
                names = (Symbol("pane-mode-changed"),)
                fast = LibTmux.notifications(connection; kinds=names, capacity=8)
                slow = LibTmux.notifications(connection; kinds=names, capacity=1)
                beginning = LibTmux.observation_cursor(fast)
                event = LibTmux._ControlNotification(
                    only(names),
                    collect(codeunits("%pane-mode-changed %0")),
                )
                for _ = 1:3
                    LibTmux._control_event(connection, event)
                end
                @test_throws LibTmux.ObservationLost take!(slow)
                byte_limited = LibTmux.notifications(connection; kinds=names, max_bytes=1)
                LibTmux._control_event(connection, event)
                @test_throws LibTmux.ObservationLost take!(byte_limited)
                first_event = take!(fast)
                first_event.bytes[1] = 0x00
                @test take!(fast).bytes[1] == UInt8('%')
                @test take!(fast).cursor.sequence == beginning.sequence + 3
                take!(fast)
                replay = LibTmux.notifications(connection; kinds=names, after=beginning)
                @test take!(replay).bytes[1] == UInt8('%')
                close(replay)
                @test iterate(replay) === nothing
                @test LibTmux._control_rows(connection, "display-message", ["pid"]) ==
                      [[string(getpid(fixture.process))]]
                other_consumer = Threads.@spawn try
                    take!(fast)
                catch error
                    error
                end
                @test fetch(other_consumer) isa ArgumentError
                close(fast)
                for _ = 1:257
                    LibTmux._control_event(connection, event)
                end
                @test_throws LibTmux.ObservationLost LibTmux.notifications(
                    connection;
                    after=beginning,
                )
                @test length(connection.observation.history) <= 256
                @test connection.observation.bytes <= 4*1024*1024

                output = LibTmux.observe_output(connection, pane)
                binary = collect(UInt8(0):UInt8(255))
                LibTmux._control_event(
                    connection,
                    LibTmux._ControlOutput(
                        parse(UInt64, string(pane.id)[2:end]),
                        nothing,
                        binary,
                    ),
                )
                @test take!(output).bytes == binary
                wanted = collect(codeunits("control-output-☃"))
                send_keys(server, pane, String(copy(wanted)); literal=true)
                got = UInt8[]
                while length(got) < length(wanted)
                    append!(got, take!(output; timeout=0.9).bytes)
                end
                @test got == wanted
                position = LibTmux.observation_cursor(output)
                @test position.server == connection.identity && position.pane == pane.id
                @test position.epoch ==
                      LibTmux._observation_boundary(connection, pane).epoch
                close(output)

                cancelled = CancellationToken()
                stream = LibTmux.notifications(connection; kinds=names)
                reader = Threads.@spawn try
                    take!(stream; cancel=cancelled)
                catch error
                    error
                end
                lock(connection.lock) do
                    while stream.consumer === nothing
                        wait(connection.changed)
                    end
                end
                cancel!(cancelled)
                @test fetch(reader) isa RequestCancelled
                close(stream)

                reset = LibTmux.observe_output(connection, pane)
                before_reset = LibTmux.observation_cursor(reset)
                split_window(server, pane; command=["cat"])
                @test_throws LibTmux.ObservationLost take!(reset; timeout=0.9)
                close(reset)
                @test_throws LibTmux.ObservationLost LibTmux.observe_output(
                    connection,
                    pane;
                    after=before_reset,
                )

                # The real format-subscription cadence is approximately one
                # second; this belongs to integration, not the pure inner tier.
                format = LibTmux.subscribe_format(connection, pane, "pane_dead")
                update = take!(format; timeout=2.0)
                @test update isa LibTmux.FormatUpdate && update.bytes == codeunits("0")
                @test update.session == session &&
                      update.pane == pane &&
                      update.window_index == 0
                set_option(server, pane, "remain-on-exit", "on")
                respawn_pane(server, pane; kill_running=true, command=["true"])
                @test take!(format; timeout=2.0).bytes == codeunits("1")
                close(format)
                @test format.cleanup_done

                dropped = LibTmux.subscribe_format(connection, pane, "pane_dead")
                @test take!(dropped; timeout=2.0) isa LibTmux.FormatUpdate
                cleanup_before = lock(() -> connection.submitted, connection.lock)
                lock(connection.lock) do
                    Base.finalize(dropped)
                end
                await_observation(connection, "dropped observation cleanup timed out") do
                    !dropped.open && dropped.cleanup_done
                end
                @test !isopen(dropped) && dropped.cleanup_done && dropped.error === nothing
                @test lock(() -> connection.submitted, connection.lock) ==
                      cleanup_before + 1
                @test isempty(connection.observation.streams)

                abandoned_before = drop_format_observation(connection, pane)
                GC.gc(true)
                await_observation(connection, "abandoned observation cleanup timed out") do
                    hub = connection.observation
                    isempty(hub.streams) &&
                        isempty(hub.cleanup) &&
                        !hub.cleaning &&
                        connection.submitted == abandoned_before + 1
                end
                @test isempty(connection.observation.streams)

                capacity_streams =
                    [LibTmux.notifications(connection; kinds=names) for _ = 1:64]
                abandon_notifications!(capacity_streams)
                capacity_result = lock(connection.lock) do
                    GC.gc(true)
                    @test count(
                        ref -> ref.value === nothing,
                        connection.observation.streams,
                    ) == 64
                    try
                        LibTmux.notifications(connection; kinds=names)
                    catch error
                        error
                    end
                end
                @test capacity_result isa ArgumentError
                capacity_result isa LibTmux.ObservationStream && close(capacity_result)
                await_observation(connection, "observation cleanup did not become idle") do
                    hub = connection.observation
                    isempty(hub.streams) &&
                        isempty(hub.cleanup) &&
                        !hub.cleaning &&
                        hub.reservations == 0
                end
                @test isempty(connection.observation.streams)
                @test connection.observation.reservations == 0

                @test_throws ErrorException LibTmux.notifications(connection) do scoped
                    LibTmux._control_event(connection, event)
                    for _ in scoped
                        error("consumer failed")
                    end
                end
                @test isempty(connection.observation.streams)
                pending = LibTmux.notifications(connection; kinds=names)
                closed_reader = Threads.@spawn try
                    take!(pending)
                catch error
                    error
                end
                lock(connection.lock) do
                    while pending.consumer === nothing
                        wait(connection.changed)
                    end
                end
                close(connection)
                @test fetch(closed_reader) isa EOFError
            finally
                close(connection)
            end
            @test istaskdone(connection.observation.worker)
            lost = open_control(server, session)
            try
                @test_throws LibTmux.ObservationLost LibTmux.notifications(
                    lost;
                    after=beginning,
                )
                events = LibTmux.notifications(lost)
                kill(lost.process, Base.SIGKILL)
                @test_throws LibTmux.ObservationLost take!(events; timeout=0.9)
            finally
                close(lost)
            end
            @test istaskdone(lost.observation.worker)
        end
    end
end

isdefined(@__MODULE__, :AttachedClient) ||
    include(joinpath(@__DIR__, "support", "attached_client.jl"))
using .AttachedClient

using Test, LibTmux

# The screen wait polls `capture-pane`, so every case here runs on each
# supported release. A pane that must change for the test follows a file, to
# which the test appends when the wait is ready for the next step.

const SCREEN_ENV = Dict(
    "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
    "TERM" => "xterm-256color",
    "SHELL" => "/bin/sh",
    Main.TestSandbox.child_entries()...,
)

screen_server(f) =
    with_server(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=SCREEN_ENV)

# A pane that runs `command`. An anchor session keeps the server alive when
# the pane's own session ends.
function screen_pane(server, command; name="screen")
    isempty(panes(snapshot(server))) &&
        new_session(server; name="anchor", command=["/bin/cat"])
    anchor = [p.ref for p in panes(snapshot(server))]
    new_session(server; name, command)
    only(filter(p -> !(p.ref in anchor), panes(snapshot(server)))).ref
end

# A pane that shows `content`, then each text that `feed` appends.
function feed_pane(server, content=""; name="screen")
    file = joinpath(dirname(server.socket_path), "feed-$name-$(time_ns())")
    write(file, content)
    pane = screen_pane(server, ["tail", "-n", "+1", "-f", file]; name)
    feed(text) = open(io -> write(io, text), file, "a")
    pane, feed
end

# A pane that shows `content` and ends, so remain-on-exit keeps its last screen.
function dead_pane(server, content)
    file = joinpath(dirname(server.socket_path), "dead-$(time_ns())")
    write(file, content)
    screen_pane(server, ["cat", file])
end

function after(f, delay)
    @async begin
        sleep(delay)
        f()
    end
end

function outcome(f)
    try
        f()
    catch error
        error
    end
end

@testset "screen waits poll the visible screen on every release" begin
    @testset "text printed after entry matches as output" begin
        screen_server() do server
            pane, feed = feed_pane(server)
            after(() -> feed("late-needle\n"), 1)
            result = wait_for_text(server, pane, "late-needle"; timeout=10)
            @test result isa ScreenWaitResult
            @test result.source === :output && !result.matched_at_entry
            @test occursin("late-needle", result.text) && result.dropped_bytes == 0
        end
    end

    @testset "text already on screen needs baseline" begin
        screen_server() do server
            pane, _ = feed_pane(server, "already\n")
            sleep(0.5)
            result = wait_for_text(server, pane, "already"; baseline=true)
            @test result.source === :baseline && result.matched_at_entry
            @test outcome(() -> wait_for_text(server, pane, "already"; timeout=0.8)) isa
                  DeadlineExceeded
        end
    end

    @testset "a needle across the wrap column matches" begin
        screen_server() do server
            line = repeat("a", 77) * "wrapneedle" * repeat("b", 63)
            pane, feed = feed_pane(server)
            after(() -> feed("$line\n"), 1)
            result = wait_for_text(server, pane, "wrapneedle"; timeout=10)
            @test result.source === :output && occursin("wrapneedle", result.text)
        end
    end

    @testset "an alternate screen round trip invents no match" begin
        screen_server() do server
            pane, feed = feed_pane(server, "needle\n")
            sleep(0.5)
            steps =
                [after(() -> feed("\e[?1049h"), 0.5), after(() -> feed("\e[?1049l"), 1.5)]
            @test outcome(() -> wait_for_text(server, pane, "needle"; timeout=3.5)) isa
                  DeadlineExceeded
            foreach(wait, steps)
            after(() -> feed("needle\n"), 0.5)
            again = wait_for_text(server, pane, "needle"; timeout=10)
            @test again.source === :output && !again.matched_at_entry
        end
    end

    @testset "an entry read on the alternate screen invents no match" begin
        screen_server() do server
            pane, feed = feed_pane(server, "needle\n\e[?1049h")
            sleep(0.5)
            after(() -> feed("\e[?1049l"), 0.5)
            @test outcome(() -> wait_for_text(server, pane, "needle"; timeout=3)) isa
                  DeadlineExceeded
            feed("needle\n")
            sleep(0.5)
            @test wait_for_text(server, pane, "needle"; baseline=true, timeout=5).source ===
                  :baseline
        end
    end

    @testset "a large visible screen and long history raise no output limit" begin
        screen_server() do server
            pane, _ = feed_pane(
                server,
                join(fill(repeat("0", 400), 5000), "\n") * "\ntail-needle\n",
            )
            run_command(
                server,
                "resize-window",
                "-t",
                string(pane.id),
                "-x",
                "500",
                "-y",
                "200",
            )
            sleep(1.0)
            result = wait_for_text(server, pane, "tail-needle"; baseline=true, timeout=10)
            @test result.source === :baseline
            @test ncodeunits(result.text) <= 65536 && result.dropped_bytes > 0
        end
    end

    @testset "text that scrolled off the screen is not seen" begin
        screen_server() do server
            pane, _ = feed_pane(server, "scrolled-needle\n" * join(1:100, "\n") * "\n")
            sleep(1.0)
            @test outcome(
                () -> wait_for_text(
                    server,
                    pane,
                    "scrolled-needle";
                    baseline=true,
                    timeout=1,
                ),
            ) isa DeadlineExceeded
        end
    end

    @testset "a killed pane ends the wait with the earlier text" begin
        screen_server() do server
            pane, _ = feed_pane(server, "before-end\n")
            sleep(0.5)
            after(() -> kill_pane(server, pane), 0.7)
            started = time()
            ended = outcome(
                () -> wait_for_text(server, pane, "never"; interval=0.1, timeout=20),
            )
            @test ended isa ScreenWaitEnded
            ended isa ScreenWaitEnded && @test ended.reason === :pane_exited
            ended isa ScreenWaitEnded && @test occursin("before-end", ended.text)
            @test time() - started < 5
        end
    end

    # A pane that remains on exit scrolls its screen up one row for the death
    # message, so these scripts print on the last rows to keep the text visible.
    @testset "a dead pane kept by remain-on-exit ends the wait" begin
        screen_server() do server
            new_session(server; name="anchor", command=["/bin/cat"])
            run_command(server, "set-option", "-g", "remain-on-exit", "on")
            pane = dead_pane(server, "\n"^30 * "finished\n")
            sleep(1.0)
            ended = outcome(() -> wait_for_text(server, pane, "never"; timeout=10))
            @test ended isa ScreenWaitEnded
            ended isa ScreenWaitEnded && @test ended.reason === :pane_exited
            ended isa ScreenWaitEnded && @test occursin("finished", ended.text)
        end
    end

    @testset "a match on a dead pane's last screen wins over its death" begin
        screen_server() do server
            new_session(server; name="anchor", command=["/bin/cat"])
            run_command(server, "set-option", "-g", "remain-on-exit", "on")
            pane = dead_pane(server, "\n"^30 * "final-needle\n")
            sleep(1.0)
            @test occursin("final-needle", capture_pane(server, pane))
            result = wait_for_text(server, pane, "final-needle"; baseline=true)
            @test result.source === :baseline && result.matched_at_entry
        end
    end

    @testset "a killed server ends the wait" begin
        screen_server() do server
            pane, _ = feed_pane(server, "before-end\n")
            sleep(0.5)
            after(() -> kill_server(server; confirm=true), 0.7)
            ended = outcome(() -> wait_for_text(server, pane, "never"; timeout=20))
            @test ended isa ScreenWaitEnded
            ended isa ScreenWaitEnded && @test ended.reason === :server_exited
        end
    end

    @testset "a killed server held by a stopped client ends the wait" begin
        screen_server() do server
            anchor = screen_pane(server, ["sleep", "30"]; name="anchor-held")
            pane, _ = feed_pane(server, "before-end\n")
            release = LibTmux._daemon_version(server, LibTmux._client_environment(ENV))
            mode =
                LibTmux._version_at_least(release, LibTmux.CONTROL_MINIMUM_TMUX) ?
                "control" : "pty"
            holder = attach_client(
                server.tmux,
                server.socket_path,
                "anchor-held";
                control=mode == "control",
            )
            try
                stop!(holder)
                after(() -> kill_server(server; confirm=true), 0.7)
                started = time()
                ended = outcome(() -> wait_for_text(server, pane, "never"; timeout=20))
                @test ended isa ScreenWaitEnded
                ended isa ScreenWaitEnded && @test ended.reason === :server_exited
                @test time() - started < 10
            finally
                close(holder)
            end
            @test anchor isa PaneRef
        end
    end

    @testset "only the read's own marker names the pane" begin
        marker = "libtmux-screen-0123456789abcdef"
        read(stdout, stderr) = LibTmux._screen_parse(
            LibTmux.CommandResult(Vector{UInt8}(stdout), Vector{UInt8}(stderr), 1, 0),
            marker,
            "%3",
            "77:88",
        )
        line(fields) = "unknown command: $(marker)$(fields)|\n"
        fence = "unknown command: libtmux-version-feedface\n"
        live = read("screen\n", fence * line("%3-0-0-77-88"))
        @test live.state === :live && live.text == "screen\n" && !live.alternate
        @test read("s\n", line("%3-1-0-77-88")).state === :pane_exited
        @test read("s\n", line("%4-0-0-77-88")).state === :pane_exited
        @test read("s\n", line("%3-0-1-77-88")).alternate
        # A refused fence prints only its own line, which is no verdict.
        @test_throws CommandError read("", fence)
        @test_throws CommandError read("partial", line("%3-0-0-77-88"))
        # A pane from another server generation is refused, not read.
        @test_throws StaleReference read("s\n", line("%3-0-0-77-89"))
        @test_throws StaleReference read("s\n", line("%3-0-0-78-88"))
        @test read("", "can't find pane: %3\n").state === :pane_exited
        @test read("", "no server running on /tmp/x\n").state === :server_exited
        @test read("", "server exited unexpectedly\n").state === :server_exited
        @test read("", "lost server\n").state === :server_exited
        # A capture that completed before the marker failed is kept.
        kept = read("kept\n", "can't find pane: %3\n")
        @test kept.state === :pane_exited && kept.text == "kept\n"
        @test read("partial", "can't find pane: %3\n").text === nothing
    end

    @testset "a poisoned release cache still reads through the fence" begin
        screen_server() do server
            pane, _ = feed_pane(server, "fenced\n")
            sleep(0.5)
            LibTmux._remember_release!(server, "9.9")
            @test wait_for_text(server, pane, "fenced"; baseline=true).source === :baseline
        end
    end

    @testset "cancellation wakes the sleep" begin
        screen_server() do server
            pane = screen_pane(server, ["sleep", "30"])
            sleep(0.5)
            token = CancellationToken()
            watch_screen(server, pane; interval=10, timeout=60, cancel=token) do screen
                after(() -> cancel!(token), 1.0)
                started = time()
                cancelled = outcome(() -> wait_for_text(screen, "never"))
                @test cancelled isa RequestCancelled
                @test time() - started < 5
            end
            early = CancellationToken()
            after(() -> cancel!(early), 0.0)
            started = time()
            @test outcome(
                () -> wait_for_text(
                    server,
                    pane,
                    "never";
                    interval=10,
                    timeout=60,
                    cancel=early,
                ),
            ) isa RequestCancelled
            @test time() - started < 5
        end
    end

    # A fired or cancelled timer closes itself, so only a sleep that is torn
    # down by another error shows whether the wait closes its own timer.
    @testset "an interrupted sleep closes its timer" begin
        screen_server() do server
            pane = screen_pane(server, ["sleep", "30"])
            watched = Ref{Any}(nothing)
            task = @async watch_screen(server, pane; interval=30, timeout=60) do screen
                watched[] = screen
                wait_for_text(screen, "never")
            end
            @test timedwait(
                () ->
                    watched[] !== nothing &&
                    watched[].timer isa Timer &&
                    isopen(watched[].timer),
                10.0,
            ) === :ok
            schedule(task, InterruptException(); error=true)
            @test outcome(() -> fetch(task)) isa TaskFailedException
            @test !isopen(watched[].timer)
        end
    end

    @testset "a timeout shorter than the interval still reads once" begin
        screen_server() do server
            pane = screen_pane(server, ["sleep", "30"])
            counter = joinpath(dirname(server.socket_path), "reads")
            run_command(
                server,
                "set-hook",
                "-g",
                "after-capture-pane",
                "run-shell -b 'echo x >> $counter'",
            )
            @test outcome(
                () -> wait_for_text(server, pane, "never"; interval=10, timeout=1.5),
            ) isa DeadlineExceeded
            # The entry read and the first read of the wait both run before the sleep.
            @test timedwait(
                () -> isfile(counter) && length(readlines(counter)) >= 2,
                5.0,
            ) === :ok
        end
    end

    @testset "reads run the capture hook and no other hook" begin
        screen_server() do server
            pane, feed = feed_pane(server)
            directory = dirname(server.socket_path)
            names = ("display-message", "list-panes", "show-options", "capture-pane")
            for name in names
                run_command(
                    server,
                    "set-hook",
                    "-g",
                    "after-$name",
                    "run-shell -b 'echo x >> $directory/hook-$name'",
                )
            end
            after(() -> feed("hooked\n"), 1.5)
            wait_for_text(server, pane, "hooked"; interval=0.5, timeout=10)
            sleep(1.0)
            counts = Dict(
                name => (
                    isfile("$directory/hook-$name") ?
                    length(readlines("$directory/hook-$name")) : 0
                ) for name in names
            )
            # Reads are paced by the interval; a loop without a sleep reads far
            # more often than the wait's duration allows.
            @test 2 <= counts["capture-pane"] <= 12
            @test counts["display-message"] == 0
            @test counts["list-panes"] == 0
            @test counts["show-options"] == 0
        end
    end

    @testset "the handle takes the entry read before keys are sent" begin
        screen_server() do server
            pane = screen_pane(server, ["cat"])
            sleep(0.5)
            result = watch_screen(server, pane; timeout=10) do screen
                send_keys(server, pane, "ready-now", "Enter")
                wait_for_text(screen, "ready-now")
            end
            @test result.source === :output && !result.matched_at_entry
            held = watch_screen(identity, server, pane)
            @test_throws ArgumentError wait_for_text(held, "x")
        end
    end

    @testset "a screen wait attaches no control client" begin
        screen_server() do server
            pane, feed = feed_pane(server)
            directory = dirname(server.socket_path)
            run_command(
                server,
                "set-hook",
                "-g",
                "client-attached",
                "run-shell -b 'echo x >> $directory/attached'",
            )
            after(() -> feed("routed\n"), 1.5)
            result = wait_for_text(server, pane, "routed"; timeout=10)
            @test result.source === :output
            sleep(1.0)
            @test !isfile("$directory/attached")
        end
    end

    @testset "a match that arrives with the pane's death wins" begin
        screen_server() do server
            new_session(server; name="anchor", command=["/bin/cat"])
            run_command(server, "set-option", "-g", "remain-on-exit", "on")
            # The pane ends when the test closes its end of the FIFO.
            fifo = joinpath(dirname(server.socket_path), "dead")
            run(`mkfifo $fifo`)
            pane = screen_pane(server, ["cat", fifo])
            writer = open(fifo, "w")
            write(writer, "\n"^30)
            flush(writer)
            sleep(0.5)
            after(() -> (write(writer, "last-needle\n"); close(writer)), 0.5)
            result = wait_for_text(server, pane, "last-needle"; timeout=10)
            @test result.source === :output && !result.matched_at_entry
        end
    end

    @testset "a pane from a replaced server is refused" begin
        screen_server() do server
            old, _ = feed_pane(server, "OLDSERVER\n")
            kill_server(server; confirm=true)
            sleep(0.5)
            new_session(server; name="anchor2", command=["/bin/cat"])
            new, _ = feed_pane(server, "NEWSERVER\n"; name="second")
            @test old.id == new.id && old.server != new.server
            sleep(0.5)
            @test_throws StaleReference wait_for_text(
                server,
                old,
                "NEWSERVER";
                baseline=true,
                timeout=3,
            )
            @test wait_for_text(server, new, "NEWSERVER"; baseline=true).source ===
                  :baseline
            # The fixture owns only the first daemon; stop the restarted one.
            kill_server(server; confirm=true)
        end
    end

    @testset "every wait in a block counts against the block's entry read" begin
        screen_server() do server
            pane, feed = feed_pane(server)
            after(() -> feed("again\n"), 1)
            watch_screen(server, pane; timeout=10) do screen
                first = wait_for_text(screen, "again")
                second = wait_for_text(screen, "again")
                @test first.source === :output && second.source === :output
                @test !first.matched_at_entry && !second.matched_at_entry
            end
        end
    end

    @testset "arguments are checked before any tmux command" begin
        server = Server(; socket_name="libtmux-never-started", tmux="/nonexistent/tmux")
        pane = PaneRef(ServerIdentity(socket_path="/nonexistent", generation="1:1"), "%0")
        @test_throws ArgumentError wait_for_text(server, pane, "")
        @test_throws ArgumentError wait_for_text(server, pane, "long"; max_bytes=2)
        @test_throws ArgumentError wait_for_text(server, pane, "x"; interval=0)
        @test_throws ArgumentError wait_for_text(server, pane, "x"; timeout=-1)
        @test_throws ArgumentError wait_for_text(server, pane, "x"; max_bytes=0)
        # A reference from another socket is refused before any tmux command.
        owned = Server(; socket_path="/nonexistent/sock", tmux="/nonexistent/tmux")
        @test_throws CrossServerReference wait_for_text(owned, pane, "x")
    end
end

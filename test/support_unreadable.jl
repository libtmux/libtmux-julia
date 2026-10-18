@testset "tmux older than 3.2 is refused, not reported as a probe failure" begin
    # What tmux 3.1 (daemon), a 3.0 daemon and a client older than 3.2 print for
    # `tmux -N -- run-shell -C <marker>`.
    diagnostics = (
        "usage: run-shell [-b] [-t target-pane] shell-command",
        "server version is too old for client",
        "tmux: unknown option -- N\nusage: tmux [-2CluvV] [-c shell-command]",
    )
    mktempdir(; prefix="ltj-old-") do directory
        script = joinpath(directory, "tmux-old")
        socket = joinpath(directory, "s")
        old = Server(socket_path=socket, tmux=script)
        commands = [LibTmux.TmuxCommand("list-sessions")]
        for diagnostic in diagnostics
            rm(script * ".calls"; force=true)
            write(
                script,
                """#!/bin/sh
printf '%s\\n' "\$*" >> "\$0.calls"
cat >&2 <<'DIAGNOSTIC'
$diagnostic
DIAGNOSTIC
exit 1
""",
            )
            chmod(script, 0o700)
            failure = try
                run_command(old, "new-session", "-d", "-s", "refused")
            catch error
                error
            end
            @test failure isa UnsupportedTmuxVersion
            failure isa UnsupportedTmuxVersion &&
                @test occursin("3.1 or older", sprint(showerror, failure))
            # The probe, then `-V` to name the client in the refusal.
            calls = readlines(script * ".calls")
            @test all(contains("run-shell -C"), filter(!=("-V"), calls))
            @test !ispath(socket)

            batch = LibTmux.run_batch(old, commands; timeout=60)
            @test only(batch).status === :failed && !only(batch).acknowledged
        end

        # A probe that fails for another reason is a command error that never
        # dispatched anything.
        write(script, "#!/bin/sh\necho 'boom' >&2\nexit 1\n")
        probe = try
            run_command(old, "new-session", "-d", "-s", "refused")
        catch error
            error
        end
        @test probe isa LibTmux.CommandError && LibTmux._not_dispatched(probe)
        batch = LibTmux.run_batch(old, commands; timeout=60)
        @test only(batch).status === :failed && !only(batch).acknowledged
    end
end

# tmux 3.0a and 3.1c servers keep the client's stdout open after the client
# exits with the diagnostic. The double leaves a background child holding it.
@testset "an old daemon that holds stdout open is still refused promptly" begin
    mktempdir(; prefix="ltj-held-") do directory
        script = joinpath(directory, "tmux-held")
        pidfile = joinpath(directory, "holder.pid")
        write(
            script,
            """#!/bin/sh
echo 'usage: run-shell [-b] [-t target-pane] shell-command' >&2
sleep 20 &
echo \$! > '$pidfile'
exit 1
""",
        )
        chmod(script, 0o700)
        server = Server(socket_path=joinpath(directory, "s"), tmux=script)
        # Only Linux lists a process's descriptors under /proc.
        descriptors() = Sys.islinux() ? length(readdir("/proc/self/fd")) : 0
        try
            before = descriptors()
            for _ = 1:3
                started = time_ns()
                failure = try
                    run_command(server, "list-sessions"; timeout=10)
                catch error
                    error
                end
                @test failure isa UnsupportedTmuxVersion
                @test (time_ns() - started) / 1e9 < 5
            end
            Sys.islinux() && @test descriptors() <= before
        finally
            for pid in split(isfile(pidfile) ? read(pidfile, String) : "")
                run(ignorestatus(`kill $pid`))
            end
        end

        # Output that arrives slowly, within the quiet interval, is kept whole.
        write(
            script,
            """#!/bin/sh
printf a
sleep 0.1
printf b
sleep 0.1
printf c
""",
        )
        result = LibTmux._run_process(`$script`)
        @test String(result.stdout) == "abc" && result.exitcode == 0
    end
end

# The real tmux 3.0a and 3.1c builds, when present, as the old client and as the
# old daemon behind a current client.
@testset "real tmux 3.0a and 3.1c builds are refused" begin
    # `LIBTMUX_TEST_CLIENT_TMUX` names the current client when the cell's own
    # `LIBTMUX_TEST_TMUX` is the old release. Where the builds are named, a
    # listed release that is missing fails instead of skipping.
    current = get(ENV, "LIBTMUX_TEST_CLIENT_TMUX", get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))
    builds = get(ENV, "LIBTMUX_TEST_OLD_TMUX_BUILDS", "")
    required = !isempty(builds)
    releases = split(get(ENV, "LIBTMUX_TEST_OLD_TMUX_RELEASES", "3.0a 3.1c"))
    if required
        client = last(split(readchomp(`$current -V`)))
        @test LibTmux._version_at_least(client, LibTmux.MINIMUM_TMUX_VERSION)
    end
    for release in releases
        old = joinpath(builds, release, "bin", "tmux")
        required && @test isfile(old)
        isfile(old) ||
            (@info "no real tmux $release under LIBTMUX_TEST_OLD_TMUX_BUILDS"; continue)
        mktempdir(; prefix="ltj-real-old-") do directory
            socket = joinpath(directory, "s")
            # As the client: no daemon is needed to refuse.
            failure = try
                run_command(Server(socket_path=socket, tmux=old), "list-sessions")
            catch error
                error
            end
            @test failure isa UnsupportedTmuxVersion
            failure isa UnsupportedTmuxVersion && @test occursin(
                "the server or the client is tmux 3.1 or older (the client reports $release)",
                sprint(showerror, failure),
            )
            @test !ispath(socket)

            # As the daemon behind a current client.
            started =
                success(ignorestatus(`$old -S $socket -f /dev/null new-session -d -s old`))
            @test started
            try
                started = time_ns()
                failure = try
                    run_command(
                        Server(socket_path=socket, tmux=current),
                        "list-sessions";
                        timeout=30,
                    )
                catch error
                    error
                end
                @test (time_ns() - started) / 1e9 < 10
                @test failure isa UnsupportedTmuxVersion
                # The current client is known to be new, so only the server is old.
                failure isa UnsupportedTmuxVersion && @test occursin(
                    "the server is tmux 3.1 or older (the client reports ",
                    sprint(showerror, failure),
                )
                names = readchomp(
                    ignorestatus(`$old -S $socket list-sessions -F '#{session_name}'`),
                )
                @test names == "old"
            finally
                run(ignorestatus(`$old -S $socket kill-server`))
            end
        end
    end
end

# A release remembered for an endpoint must not outlive the daemon: an old
# release that takes over the socket is refused every time, without effect.
@testset "an old daemon that replaced a checked one is refused" begin
    current = get(ENV, "LIBTMUX_TEST_CLIENT_TMUX", get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))
    builds = get(ENV, "LIBTMUX_TEST_OLD_TMUX_BUILDS", "")
    required = !isempty(builds)
    for release in split(get(ENV, "LIBTMUX_TEST_OLD_TMUX_RELEASES", "3.0a 3.1c"))
        old = joinpath(builds, release, "bin", "tmux")
        required && @test isfile(old)
        isfile(old) || (@info "no real tmux $release under the old builds"; continue)
        mktempdir(; prefix="ltj-warm-") do directory
            socket = joinpath(directory, "s")
            server = Server(socket_path=socket, tmux=current)
            LibTmux._clear_version_cache!()
            @test success(`$current -S $socket -f /dev/null new-session -d -s warm`)
            try
                @test startswith(
                    String(run_command(server, "list-sessions").stdout),
                    "warm",
                )
                @test LibTmux._cached_release(server) !== nothing

                run(pipeline(`$current -S $socket kill-server`; stderr=devnull))
                for _ = 1:100
                    ispath(socket) || break
                    sleep(0.05)
                end
                @test success(`$old -S $socket -f /dev/null new-session -d -s old`)

                for _ = 1:2
                    failure = try
                        run_command(server, "new-session", "-d", "-s", "refused")
                    catch error
                        error
                    end
                    @test failure isa UnsupportedTmuxVersion
                    @test LibTmux._not_dispatched(failure)
                end
                @test LibTmux._cached_release(server) === nothing
                names = readchomp(
                    ignorestatus(`$old -S $socket list-sessions -F '#{session_name}'`),
                )
                @test names == "old"
            finally
                for tmux in (old, current)
                    run(
                        pipeline(
                            ignorestatus(`$tmux -S $socket kill-server`);
                            stderr=devnull,
                        ),
                    )
                end
            end
        end
    end
end

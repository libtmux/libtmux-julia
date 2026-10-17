isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")

# A scripted client forwards to the real executable, optionally answering the
# release probe or `-V` itself, and records every invocation.
function scripted_client(directory, real; name="tmux")
    script = joinpath(directory, name)
    write(
        script,
        """#!/bin/sh
printf '%s\\n' "\$*" >> "\$0.calls"
if [ "\$1" = -V ] && [ -f "\$0.banner" ]; then cat "\$0.banner"; exit 0; fi
previous=
for argument in "\$@"; do
    if [ "\$previous" = -C ] && [ -f "\$0.probe" ]; then
        printf 'unknown command: %s%s\\n' "\${argument%\\#\\{version\\}}" "\$(cat "\$0.probe")" >&2
        exit 1
    fi
    previous=\$argument
done
exec $(repr(real)) "\$@"
""",
    )
    chmod(script, 0o700)
    script
end

recorded_calls(script) = isfile(script * ".calls") ? readlines(script * ".calls") : String[]

option_value(fixture, name) =
    readchomp(ignorestatus(OwnedTmux.tmuxcmd(fixture, "show-options", "-gqv", name)))

# After-hooks queue behind the command that fired them.
function await_option(fixture, name; attempts=100)
    for _ = 1:attempts
        value = option_value(fixture, name)
        isempty(value) || return value
        sleep(0.02)
    end
    ""
end

@testset "release probe fires no hooks" begin
    OwnedTmux.with_tmux() do fixture
        # Hooks run in a session's context, so the daemon needs one.
        @test success(OwnedTmux.tmuxcmd(fixture, "new-session", "-d", "-s", "hooks"))
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        environment = LibTmux._client_environment(ENV)
        version = LibTmux._daemon_version(server, environment)
        @test version isa String && LibTmux._version_at_least(version, "3.3a")

        hooks = ["after-display-message" => "@hook_display"]
        error_hook = LibTmux._version_at_least(version, "3.5")
        error_hook && push!(hooks, "command-error" => "@hook_error")
        for (hook, marker) in hooks
            hook_set = OwnedTmux.tmuxcmd(
                fixture,
                "set-hook",
                "-g",
                hook,
                "set-option -g $marker fired",
            )
            @test success(hook_set)
        end

        # Probing neither reads the version through display-message nor trips either hook.
        @test LibTmux._daemon_version(server, environment) == version
        @test LibTmux._check_version(server, environment).version == version
        @test option_value(fixture, "@hook_display") == ""
        error_hook && @test option_value(fixture, "@hook_error") == ""

        # Controls: the hooks are armed and an ordinary command does fire them.
        run_command(server, "display-message", "-p", "control")
        @test await_option(fixture, "@hook_display") == "fired"
        if error_hook
            run_command(server, "kill-pane", "-t", "%999999"; check=false)
            @test await_option(fixture, "@hook_error") == "fired"
        end
    end
end

@testset "the version check probes the daemon and fences dispatch" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    mktempdir(; prefix="ltj-adm-") do directory
        OwnedTmux.with_tmux() do fixture
            sentinel = OwnedTmux.tmuxcmd(
                fixture,
                "new-session",
                "-d",
                "-s",
                "sentinel",
                "-x",
                "80",
                "-y",
                "24",
            )
            @test success(sentinel)
            environment = LibTmux._client_environment(ENV)
            sessions() = readlines(
                ignorestatus(OwnedTmux.tmuxcmd(fixture, "list-sessions", "-F", "#{session_name}")),
            )

            # A live endpoint is checked against the daemon and keeps -N.
            script = scripted_client(directory, fixture.tmux)
            server = Server(socket_path=fixture.socket, tmux=script)
            run_command(server, "list-sessions")
            calls = recorded_calls(script)
            @test any(contains("run-shell -C libtmux-version-"), calls)
            @test all(contains(" -N "), calls)
            @test any(contains("if-shell -F #{==:#{version},"), calls)

            # A daemon that no longer matches the version it reported runs nothing.
            write(script * ".probe", "9.9")
            rm(script * ".calls")
            failure = try
                run_command(server, "new-session", "-d", "-s", "replaced")
            catch error
                error
            end
            @test failure isa UnsupportedTmuxVersion
            failure isa UnsupportedTmuxVersion &&
                @test occursin("changed after the version check", failure.detail)
            @test sessions() == ["sentinel"]
            @test_throws UnsupportedTmuxVersion run_command(
                server,
                "new-session",
                "-d",
                "-s",
                "replaced";
                check=false,
            )
            batch = LibTmux.run_batch(
                server,
                [LibTmux.TmuxCommand("new-session", "-d", "-s", "replaced")];
                timeout=60,
            )
            @test only(batch).status === :failed &&
                  only(batch).error isa UnsupportedTmuxVersion
            group = LibTmux.run_group(
                server,
                [LibTmux.TmuxCommand("new-session", "-d", "-s", "replaced")];
                timeout=60,
            )
            @test only(group).status === :skipped &&
                  group.error isa UnsupportedTmuxVersion
            @test sessions() == ["sentinel"]
            rm(script * ".probe")

            # A replacement that claims an old release is refused at the probe.
            write(script * ".probe", "3.2a")
            rm(script * ".calls")
            @test_throws UnsupportedTmuxVersion run_command(
                server,
                "new-session",
                "-d",
                "-s",
                "old",
            )
            @test length(recorded_calls(script)) == 1
            @test sessions() == ["sentinel"]
            rm(script * ".probe")

            # The probe's output must name the version; anything else fails loudly.
            write(script * ".probe", "")
            @test_throws UnsupportedTmuxVersion run_command(server, "list-sessions")
            rm(script * ".probe")
        end
    end
end

@testset "absent endpoints check the executable that would start them" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    mktempdir(; prefix="ltj-adm-") do directory
        socket = joinpath(directory, "s")
        script = scripted_client(directory, tmux)
        server = Server(socket_path=socket, tmux=script)
        # A cold daemon must not read the caller's configuration.
        environment = Dict(
            "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
            "HOME" => directory,
            "XDG_CONFIG_HOME" => directory,
            "TERM" => "xterm-256color",
            "SHELL" => "/bin/sh",
        )

        # Cleanup of an absent endpoint is a no-op after its probe.
        @test run_command(server, "kill-server"; env=environment).exitcode == 0
        calls = recorded_calls(script)
        @test length(calls) == 1 && contains(calls[1], "run-shell -C")

        # Executables below the floor, or silent about it, never start a daemon.
        for banner in ("tmux 3.2a", "tmux 3.3", "tmux next-3.3a", "tmux master", "3.3a", "")
            write(script * ".banner", banner * "\n")
            rm(script * ".calls")
            @test_throws UnsupportedTmuxVersion run_command(
                server,
                "new-session",
                "-d",
                "-s",
                "cold";
                env=environment,
            )
            @test length(recorded_calls(script)) == 2
            @test !ispath(socket)
        end
        write(script * ".banner", "other 3.3a\n")
        @test_throws UnsupportedTmuxVersion run_command(
            server,
            "start-server";
            env=environment,
        )
        @test !ispath(socket)
        rm(script * ".banner")

        # Release 3.3a prints its executable's basename in place of `tmux`.
        released = last(split(readchomp(`$tmux -V`)))
        for name in ("tmux", "renamed-tmux"), banner in ("tmux", name)
            script = scripted_client(directory, tmux; name)
            server = Server(socket_path=socket, tmux=script)
            write(script * ".banner", "$banner $released\n")
            rm(script * ".calls"; force=true)
            try
                result = run_command(
                    server,
                    "new-session",
                    "-d",
                    "-s",
                    "cold",
                    "-P",
                    "-F",
                    "#{session_name}";
                    env=environment,
                )
                @test String(result.stdout) == "cold\n"
                calls = recorded_calls(script)
                @test length(calls) == 3 && !contains(calls[3], " -N ")
                @test contains(calls[3], "if-shell -F #{==:#{version},$released}")
            finally
                run(ignorestatus(`$tmux -S $socket kill-server`))
                for _ = 1:100
                    ispath(socket) || break
                    sleep(0.05)
                end
            end
        end
    end
end

@testset "owned servers check the executable before creating state" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    mktempdir(; prefix="ltj-adm-") do parent
        withenv("TMPDIR" => parent) do
            script = scripted_client(parent, tmux)
            write(script * ".banner", "tmux 3.2a\n")
            @test_throws UnsupportedTmuxVersion LibTmux.open_server(tmux=script)
            @test sort(readdir(parent)) == ["tmux", "tmux.banner", "tmux.calls"]
            @test recorded_calls(script) == ["-V"]
            rm(script * ".banner")
            owned = LibTmux.open_server(tmux=script)
            try
                @test isopen(owned)
            finally
                close(owned)
            end
        end
    end
end

@testset "control connections check the daemon's version before attaching" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    mktempdir(; prefix="ltj-adm-") do directory
        OwnedTmux.with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session =
                new_session(server; name="control-version-check", command=["/bin/cat"])
            script = scripted_client(directory, fixture.tmux)
            scripted = Server(socket_path=fixture.socket, tmux=script)
            write(script * ".probe", "3.2a")
            @test_throws UnsupportedTmuxVersion open_control(scripted, session) do _
                error("control attached to an unsupported daemon")
            end
            @test recorded_calls(script) |> length == 1
            rm(script * ".probe")
        end
    end
end

@testset "control attach reads identity without firing hooks" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session = new_session(server; name="identity", command=["/bin/cat"])
        hook = OwnedTmux.tmuxcmd(
            fixture,
            "set-hook",
            "-g",
            "after-display-message",
            "set-option -g @hook_identity fired",
        )
        @test success(hook)
        open_control(server, session) do connection
            @test isopen(connection)
            @test connection.identity == session.server
        end
        @test option_value(fixture, "@hook_identity") == ""

        # Control: the hook is armed and an ordinary display-message fires it.
        run_command(server, "display-message", "-p", "control")
        @test await_option(fixture, "@hook_identity") == "fired"

        # A stale reference is refused by the same hook-free comparison.
        stale = SessionRef(
            ServerIdentity(socket_path=fixture.socket, generation="1:2"),
            string(session.id),
        )
        @test_throws StaleReference open_control(server, stale) do _
            error("attached to a stale session")
        end
    end
end

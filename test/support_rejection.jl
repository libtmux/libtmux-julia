isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")

# Runs against an executable below the supported floor: `LIBTMUX_TEST_TMUX`
# names the rejected release, and `LIBTMUX_TEST_CLIENT_TMUX` optionally names a
# newer client that must not qualify the older daemon.
@testset "releases below the floor are refused before any effect" begin
    rejected = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    release = last(split(readchomp(`$rejected -V`)))
    @test !LibTmux._version_at_least(release, LibTmux.MINIMUM_TMUX_VERSION)
    clients = unique(filter(!isempty, [rejected, get(ENV, "LIBTMUX_TEST_CLIENT_TMUX", "")]))

    for client in clients
        OwnedTmux.with_tmux(; tmux=rejected) do fixture
            native(args...) = OwnedTmux.tmuxcmd(fixture, args...)
            @test success(native("new-session", "-d", "-s", "sentinel"))
            @test success(native("set-buffer", "-b", "sentinel", "kept"))
            sessions() =
                readlines(ignorestatus(native("list-sessions", "-F", "#{session_name}")))
            buffers() =
                readlines(ignorestatus(native("list-buffers", "-F", "#{buffer_name}")))

            # Control: the daemon itself accepts these effects.
            @test success(native("new-session", "-d", "-s", "native"))
            @test success(native("kill-session", "-t", "=native"))
            @test sessions() == ["sentinel"] && buffers() == ["sentinel"]

            server = Server(socket_path=fixture.socket, tmux=client)
            refused(f) =
                try
                    f()
                    nothing
                catch error
                    error
                end
            attempts = (
                () -> run_command(server, "new-session", "-d", "-s", "refused"),
                () -> run_command(server, "set-buffer", "-b", "refused", "x"; check=false),
                () -> run_command(server, "kill-server"),
                () -> run_command(server, "list-sessions"),
                () -> snapshot(server),
                () -> new_session(server; name="refused"),
            )
            for attempt in attempts
                failure = refused(attempt)
                @test failure isa UnsupportedTmuxVersion
                failure isa UnsupportedTmuxVersion && @test failure.observed == release
            end

            commands = [LibTmux.TmuxCommand("new-session", "-d", "-s", "refused")]
            batch = LibTmux.run_batch(server, commands; timeout=60)
            @test only(batch).status === :failed &&
                  only(batch).error isa UnsupportedTmuxVersion &&
                  !only(batch).acknowledged
            group = LibTmux.run_group(server, commands; timeout=60)
            @test only(group).status === :skipped && group.error isa UnsupportedTmuxVersion

            reference = SessionRef(
                ServerIdentity(socket_path=fixture.socket, generation="1:2"),
                "\$0",
            )
            @test_throws UnsupportedTmuxVersion open_control(server, reference) do _
                error("control attached to an unsupported daemon")
            end

            @test sessions() == ["sentinel"] && buffers() == ["sentinel"]
            @test isempty(
                readlines(ignorestatus(native("show-options", "-gqv", "@refused"))),
            )
        end

        # A cold endpoint is checked against the executable that would start it.
        mktempdir(; prefix="ltj-reject-") do directory
            socket = joinpath(directory, "s")
            cold = Server(socket_path=socket, tmux=rejected)
            failure = try
                run_command(cold, "new-session", "-d", "-s", "refused")
            catch error
                error
            end
            @test failure isa UnsupportedTmuxVersion && failure.observed == release
            @test !ispath(socket) && isempty(readdir(directory))
            withenv("TMPDIR" => directory) do
                @test_throws UnsupportedTmuxVersion LibTmux.open_server(tmux=rejected)
            end
            @test isempty(readdir(directory))
        end
    end
end

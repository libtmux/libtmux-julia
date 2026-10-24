isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")

release_of(server) = LibTmux._daemon_version(server, LibTmux._client_environment(ENV))

# A scripted client that reports `release` and refuses everything else, so a
# guard that dispatches anything after the release probe is visible.
function release_client(directory, release; name="tmux")
    script = joinpath(directory, name)
    write(
        script,
        """#!/bin/sh
printf '%s\\n' "\$*" >> "\$0.calls"
previous=
for argument in "\$@"; do
    if [ "\$previous" = -C ]; then
        printf 'unknown command: %s$release\\n' "\${argument%\\#\\{version\\}}" >&2
        exit 1
    fi
    previous=\$argument
done
exit 99
""",
    )
    chmod(script, 0o700)
    script
end

@testset "control acquisition requires tmux 3.7 before attaching" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        release = release_of(server)
        session = new_session(server; name="acquire", command=["/bin/cat"])
        clients() = readlines(
            ignorestatus(OwnedTmux.tmuxcmd(fixture, "list-clients", "-F", "#{client_pid}")),
        )
        if LibTmux._version_at_least(release, "3.7")
            open_control(server, session) do connection
                @test isopen(connection)
            end
        else
            failure = try
                open_control(server, session) do _
                    error("control attached below 3.7")
                end
            catch error
                error
            end
            @test failure isa UnsupportedCapability && failure.operation === :open_control
            failure isa UnsupportedCapability && @test occursin("3.7", failure.detail)
            @test isempty(clients())
        end
        @test isempty(clients())
    end
    mktempdir(; prefix="ltj-feat-") do directory
        OwnedTmux.with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="acquire", command=["/bin/cat"])
            for release in ("3.3a", "3.4", "3.6b")
                script = release_client(directory, release)
                rm(script * ".calls"; force=true)
                scripted = Server(socket_path=fixture.socket, tmux=script)
                @test_throws UnsupportedCapability open_control(scripted, session) do _
                    error("control attached below 3.7")
                end
                # Only the release probe ran; no attach client was spawned.
                @test length(readlines(script * ".calls")) == 1
            end
        end
    end
end

@testset "named-buffer deletion requires tmux 3.4" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        release = release_of(server)
        session = new_session(server; name="buffers", command=["/bin/cat"])
        pane = only(panes(snapshot(server))).ref
        buffers() = readlines(
            ignorestatus(
                OwnedTmux.tmuxcmd(fixture, "list-buffers", "-F", "#{buffer_name}"),
            ),
        )
        # An unrelated buffer that an unsafe deletion could take instead.
        @test success(OwnedTmux.tmuxcmd(fixture, "set-buffer", "-b", "bystander", "keep"))
        if LibTmux._version_at_least(release, "3.4")
            buffer = load_buffer(server, collect(codeunits("data")))
            @test delete_buffer(server, buffer) isa CommandResult
        else
            for (operation, call) in (
                (:load_buffer, () -> load_buffer(server, collect(codeunits("data")))),
                (
                    :delete_buffer,
                    () -> delete_buffer(server, BufferRef(pane.server, "bystander")),
                ),
            )
                failure = try
                    call()
                catch error
                    error
                end
                @test failure isa UnsupportedCapability && failure.operation === operation
                failure isa UnsupportedCapability && @test occursin("3.4", failure.detail)
                # The typed gate answers, not the raw-command guard behind it.
                failure isa UnsupportedCapability &&
                    @test occursin("named-buffer deletion", failure.detail)
            end
        end
        # Pasting works on every release and leaves no staged buffer behind;
        # below 3.4 the paste deletes it, so no delete can take the bystander.
        paste_bytes(server, pane, collect(codeunits("typed")))
        paste_text(server, pane, "again")
        @test buffers() == ["bystander"]
        captured = ""
        for _ = 1:100
            captured = decode_text(capture_bytes(server, pane))
            occursin("typedagain", captured) && break
            sleep(0.05)
        end
        @test occursin("typedagain", captured)
    end
end

@testset "the 3.7 name restriction follows the release ranking" begin
    restricted = LibTmux._names_restricted
    @test all(restricted, ("3.7", "3.7-rc", "3.7-rc2", "next-3.7"))
    @test !any(
        restricted,
        ("3.6b", "3.7a", "3.7d", "3.8", "3.8-rc2", "next-3.8", "master", ""),
    )
end

@testset "tmux 3.7 names are validated before dispatch" begin
    mktempdir(; prefix="ltj-feat-") do directory
        script = release_client(directory, "3.7")
        socket = joinpath(directory, "s")
        server = Server(socket_path=socket, tmux=script)
        for name in ("a.b", "a:b")
            failure = try
                new_session(server; name)
            catch error
                error
            end
            @test failure isa ArgumentError && occursin("3.7", failure.msg)
        end
        # Only the release probes ran: nothing was dispatched.
        @test all(contains("run-shell -C"), readlines(script * ".calls"))
        for release in ("3.6b", "3.7a", "3.7d", "3.8", "next-3.8")
            released = release_client(directory, release; name="tmux-$release")
            allowed = Server(socket_path=socket, tmux=released)
            # The scripted client refuses everything else, so reaching dispatch is
            # a failure other than the name check.
            failure = try
                new_session(allowed; name="a.b")
            catch error
                error
            end
            @test !(failure isa ArgumentError && occursin("rejects", failure.msg))
        end
        failure = try
            new_session(server; name="ab")
        catch error
            error
        end
        @test !(failure isa ArgumentError && occursin("rejects", failure.msg))
    end
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        release = release_of(server)
        session = new_session(server; name="names", command=["/bin/cat"])
        window = only(windows(snapshot(server))).ref
        names() = readlines(
            ignorestatus(
                OwnedTmux.tmuxcmd(fixture, "list-sessions", "-F", "#{session_name}"),
            ),
        )
        if release == "3.7"
            @test_throws ArgumentError rename_session(server, session, "x.y")
            @test_throws ArgumentError rename_window(server, window, "x:y")
            @test_throws ArgumentError new_window(server, session; name="x.y")
            @test names() == ["names"]
        else
            @test rename_session(server, session, "x.y") isa CommandResult
            @test length(names()) == 1
        end
    end
end

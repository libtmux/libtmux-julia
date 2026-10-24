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

# Calls that reached the scripted client beyond the release probe.
function dispatched(script)
    isfile(script * ".calls") || return String[]
    filter(call -> !contains(call, "run-shell -C"), readlines(script * ".calls"))
end

@testset "raw command lines meet the release requirements of typed operations" begin
    mktempdir(; prefix="ltj-feat-") do directory
        socket = joinpath(directory, "s")
        # Each case lists the releases that must be refused and some that must
        # reach tmux; the scripted client fails anything it is sent.
        cases = [
            (["delete-buffer", "-b", "keep"], ["3.3a"], ["3.4", "3.7c"]),
            (["deleteb", "-b", "keep"], ["3.3a"], ["3.4"]),
            (["delete-b", "-bkeep"], ["3.3a"], ["3.4"]),
            (["delete-buffer"], String[], ["3.3a"]),
            (["set-buffer", "-b", "keep", "-n", "other"], ["3.3a"], ["3.4"]),
            (["setb", "-nother", "-b", "keep"], ["3.3a"], ["3.4"]),
            (["set-buffer", "-b", "keep", "data"], String[], ["3.3a"]),
            (["refresh-client", "-t", "c", "-l"], ["3.3a", "3.6"], ["3.6a", "3.7c"]),
            (["refresh", "-l"], ["3.3a", "3.4", "3.5a"], ["3.6a"]),
            (["refresh-client", "-lt", "c"], ["3.3a", "3.6"], ["3.6a"]),
            (["refresh-client", "-f", "no-output"], String[], ["3.3a"]),
            (
                ["break-pane", "-s", "%0", "-t", "s:1"],
                ["3.7", "next-3.7"],
                ["3.7a", "3.6b"],
            ),
            (["breakp", "-dP", "-s", "%0"], ["3.7"], ["3.7a"]),
            (["break-p", "-s", "%0"], ["3.7"], ["3.7a"]),
            (["break-pane", "-s", "%0", "-n", "named"], String[], ["3.7"]),
            (["break-pane", "-s", "%0", "-nnamed"], String[], ["3.7"]),
            (["select-layout", "-t", "@0", "--", "-o"], ["3.3a"], ["3.4"]),
            (["selectl", "-t", "@0", "garbage"], ["3.3a"], ["3.4"]),
            (["select-layout", "-t", "@0", ""], ["3.3a"], ["3.4"]),
            (["select-layout", "-t", "@0", "e"], ["3.3a"], ["3.4"]),
            (["select-layout", "-t", "@0", "tiled"], String[], ["3.3a"]),
            (["select-layout", "-t", "@0", "ti"], String[], ["3.3a"]),
            (["select-layout", "-t", "@0", "b25f,80x24,0,0,0"], String[], ["3.3a"]),
            (["select-layout", "-t", "@0", "-o"], String[], ["3.3a"]),
        ]
        for (index, (argv, refused, reaches)) in enumerate(cases)
            for release in union(refused, reaches)
                script = release_client(directory, release; name="tmux-$release-$index")
                server = Server(socket_path=socket, tmux=script)
                failure = try
                    run_command(server, argv...)
                catch error
                    error
                end
                if release in refused
                    @test failure isa UnsupportedCapability
                    @test isempty(dispatched(script))
                else
                    @test !(failure isa UnsupportedCapability)
                    @test length(dispatched(script)) == 1
                end
            end
        end
        # Separators do not hide a refused command, and a refused command
        # stops the whole line.
        script = release_client(directory, "3.3a"; name="tmux-3.3a-list")
        server = Server(socket_path=socket, tmux=script)
        @test_throws UnsupportedCapability run_command(
            server,
            "display-message",
            "-p",
            "x",
            ";",
            "delete-buffer",
            "-b",
            "keep",
        )
        @test_throws UnsupportedCapability run_command(
            server,
            "display-message",
            "-p",
            "x;",
            "refresh-client",
            "-l",
        )
        group = run_group(
            server,
            [TmuxCommand("list-sessions"), TmuxCommand("deleteb", "-b", "keep")],
        )
        @test group.error isa UnsupportedCapability
        @test all(operation -> operation.status === :skipped, group)
        batch = run_batch(server, [TmuxCommand("refresh-client", "-l")])
        @test only(batch).status === :failed
        @test only(batch).error isa UnsupportedCapability
        @test isempty(dispatched(script))
        # An argument that only ends in a semicolon is data, not a separator.
        literal = release_client(directory, "3.3a"; name="tmux-3.3a-literal")
        server = Server(socket_path=socket, tmux=literal)
        failure = try
            run_group(server, [TmuxCommand("display-message", "-p", "refresh-client -l;")])
        catch error
            error
        end
        @test !(failure isa UnsupportedCapability)
        @test !isempty(dispatched(literal))
    end
end

@testset "tmux command names resolve the way tmux resolves them" begin
    resolve = LibTmux._resolve_tmux_command
    @test resolve("breakp") == "break-pane"
    @test resolve("break-p") == "break-pane"
    @test resolve("break") == "break-pane"
    @test resolve("deleteb") == "delete-buffer"
    @test resolve("delete-b") == "delete-buffer"
    @test resolve("refresh") == "refresh-client"
    @test resolve("new") == "new-session"
    @test resolve("neww") == "new-window"
    @test resolve("set") == "set-option"
    @test resolve("set-b") == "set-buffer"
    @test resolve("rename") == "rename-session"
    @test resolve("kill-server") == "kill-server"
    # An ambiguous prefix and an unknown word name no command.
    @test resolve("set-") === nothing
    @test resolve("kill-") === nothing
    @test resolve("nonsense") === nothing
end

@testset "a raw layout string cannot stop tmux 3.3a" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        release = release_of(server)
        new_session(server; name="layouts", command=["/bin/cat"])
        window = only(windows(snapshot(server))).ref
        argv = ("select-layout", "-t", string(window.id), "--", "-o")
        if LibTmux._version_at_least(release, "3.4")
            @test_throws CommandError run_command(server, argv...)
        else
            @test_throws UnsupportedCapability run_command(server, argv...)
        end
        @test run_command(server, "display-message", "-p", "alive").stdout ==
              codeunits("alive\n")
    end
end

# On tmux 3.3a the clipboard query stops the server at once; from 3.4 to 3.6 it
# returns, and the server stops when the client leaves before its terminal
# answers. The refusal must keep the daemon up while a client is attached.
@testset "the clipboard query is refused before 3.6a and the server stays up" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        release = release_of(server)
        new_session(server; name="clip", command=["/bin/cat"])
        if !LibTmux._version_at_least(release, LibTmux.CLIPBOARD_QUERY_MINIMUM_TMUX)
            pidfile = fixture.socket * ".client"
            holder = run(
                pipeline(
                    `python3 -I $(joinpath(@__DIR__, "attach_client.py")) $(fixture.tmux) $(fixture.socket) clip $pidfile`;
                    stdout=devnull,
                    stderr=devnull,
                );
                wait=false,
            )
            try
                @test timedwait(() -> isfile(pidfile), 20.0) === :ok
                client = ""
                deadline = time() + 10
                while isempty(client) && time() < deadline
                    client = strip(
                        decode_text(
                            run_command(server, "list-clients", "-F", "#{client_name}").stdout,
                        ),
                    )
                    isempty(client) && sleep(0.1)
                end
                @test !isempty(client)
                @test_throws UnsupportedCapability run_command(
                    server,
                    "refresh-client",
                    "-t",
                    client,
                    "-l",
                )
                # The client leaves before any terminal answer could arrive.
                run(`kill -KILL $(parse(Int, read(pidfile, String)))`)
                sleep(1.0)
                @test run_command(server, "display-message", "-p", "alive").stdout ==
                      codeunits("alive\n")
            finally
                kill(holder)
            end
        end
    end
end

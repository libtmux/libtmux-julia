@testset "typed tmux operations" begin
    @test isdefined(LibTmux, :new_session)
    if isdefined(LibTmux, :new_session)
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session_ref =
                LibTmux.new_session(server; name="typed-#{literal};", command=["/bin/cat"])
            @test session_ref isa SessionRef
            @test only(sessions(snapshot(server))).name == "typed-#{literal};"
            first_pane = only(panes(snapshot(server))).ref
            second = LibTmux.split_window(
                server,
                first_pane;
                direction=:right,
                command=["/bin/cat"],
            )
            @test second isa PaneRef && second != first_pane
            extra = LibTmux.new_window(
                server,
                session_ref;
                name="#{literal}",
                command=["/bin/cat"],
            )
            @test extra isa WindowRef
            @test any(w -> w.name == "#{literal}", windows(snapshot(server)))
            LibTmux.select_layout(server, extra, :even_horizontal)
            version = only(read_formats(server, extra, FormatField("version"))).value
            captured_layout = snapshot(server, extra).layout
            @test select_layout(server, extra, captured_layout) isa CommandResult
            if !LibTmux._version_at_least(version, "3.8")
                @test_throws UnsupportedCapability select_layout(server, extra, "{\"V\":2}")
            end
            if version in ("3.3", "3.3a", "3.4")
                @test_throws UnsupportedCapability select_layout(
                    server,
                    extra,
                    "main-vertical-mirrored",
                )
            else
                @test select_layout(server, extra, "main-vertical-mirrored") isa
                      CommandResult
            end
            wrong =
                Server(socket_path=joinpath(fixture.directory, "other"), tmux=fixture.tmux)
            @test_throws LibTmux.CrossServerReference LibTmux.kill_pane(wrong, second)
            @test_throws UnsupportedCapability LibTmux.kill_pane(
                server,
                second;
                strict=true,
            )
            stale = PaneRef(
                ServerIdentity(socket_path=fixture.socket, generation="stale"),
                second.id,
            )
            @test_throws LibTmux.StaleReference LibTmux.kill_pane(server, stale)
            @test length(panes(snapshot(server))) == 3
            LibTmux.kill_pane(server, second)
            @test length(panes(snapshot(server))) == 2
            LibTmux.kill_window(server, extra)
            @test length(windows(snapshot(server))) == 1
            LibTmux.kill_session(server, session_ref)
            @test isempty(sessions(snapshot(server)))
        end
    end
end

@testset "kill_server ends a borrowed endpoint only on request" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        LibTmux.new_session(server; name="doomed", command=["/bin/cat"])
        @test length(sessions(snapshot(server))) == 1

        # Without confirm=true nothing is sent, so the session survives.
        @test_throws ArgumentError LibTmux.kill_server(server)
        @test length(sessions(snapshot(server))) == 1

        # An endpoint that names no socket would let tmux pick the caller's own
        # server, so it is refused even when confirmed.
        unnamed = Server(; env=Dict{String,String}(), tmux=fixture.tmux)
        @test_throws ArgumentError LibTmux.kill_server(unnamed; confirm=true)
        @test length(sessions(snapshot(server))) == 1

        result = LibTmux.kill_server(server; confirm=true)
        @test result isa CommandResult && result.exitcode == 0
        @test_throws CommandError snapshot(server)
        # Ending a server that is already gone changes nothing.
        @test LibTmux.kill_server(server; confirm=true).exitcode == 0
    end
end

@testset "creation reply evidence" begin
    mktempdir(; prefix="libtmux-julia-creation-") do directory
        socket = joinpath(directory, "s")
        executable = joinpath(directory, "tmux")
        # Arguments from the eighth on are the fenced command; the probe is `run-shell`.
        Main.StandIns.install(
            executable,
            raw"""
            get(ARGS, 6, "") == "run-shell" && (
                print(stderr, "unknown command: ", chopsuffix(ARGS[8], "#{version}"), "3.7c\n");
                exit(1)
            )
            command = ARGS[8:end]
            StandIns.record(PROGRAM_FILE * ".calls", get(command, 5, ""))
            if get(command, 5, "") == "display-message"
                write(stdout, read(PROGRAM_FILE * (get(command, 7, "") == "-F" ? ".metadata" : ".codec")))
            elseif get(command, 5, "") in ("new-session", "new-window", "split-window")
                write(stdout, read(PROGRAM_FILE * ".reply"))
            else
                exit(93)
            end
            """,
        )
        write(executable * ".codec", "A\\\\B\\tC\\nD\n")
        write(executable * ".metadata", "100\t200\t3.7c\t$socket\n")
        server = Server(socket_path=socket, tmux=executable)
        identity = ServerIdentity(socket_path=socket, generation="100:200")
        session_ref = SessionRef(identity, "\$0")
        pane_ref = PaneRef(identity, "%0")

        for reply in ("\t200\t$socket\t\$0\n", "100\t\t$socket\t\$0\n", "malformed\n")
            write(executable * ".reply", reply)
            failure = try
                LibTmux.new_session(server; name="probe")
            catch error
                error
            end
            @test failure isa LibTmux.CreationResponseError
            if failure isa LibTmux.CreationResponseError
                @test failure.sent === true
                @test failure.result.stdout == codeunits(reply)
                @test failure.result.exitcode == 0
                @test failure.cause isa Exception
                @test occursin(
                    "remote effects may have occurred",
                    sprint(showerror, failure),
                )
            end
        end

        for (create, target, id) in (
            (LibTmux.new_window, session_ref, "@1"),
            (LibTmux.split_window, pane_ref, "%1"),
        )
            for (reply, cause_type) in (
                ("101\t200\t$socket\t$id\n", LibTmux.StaleReference),
                ("malformed\n", ArgumentError),
            )
                write(executable * ".reply", reply)
                failure = try
                    create(server, target)
                catch error
                    error
                end
                @test failure isa LibTmux.CreationResponseError
                if failure isa LibTmux.CreationResponseError
                    @test failure.sent === true
                    @test failure.result.stdout == codeunits(reply)
                    @test failure.cause isa cause_type
                end
            end
        end
        calls = readlines(executable * ".calls")
        @test count(==("new-session"), calls) == 3
        @test count(==("new-window"), calls) == 2
        @test count(==("split-window"), calls) == 2
        @test all(
            c -> c in ("display-message", "new-session", "new-window", "split-window"),
            calls,
        )

        rm(executable * ".calls")
        window_ref = WindowRef(identity, "@0")
        for layout in ("invalid-layout", "f", "ffff", "f,1x1,0,0,0", "ffff,", "007b,{")
            @test_throws ArgumentError select_layout(server, window_ref, layout)
        end
        for argv in (["-name"], ["-name", "argument"])
            @test_throws ArgumentError LibTmux.new_session(
                server;
                name="probe",
                command=argv,
            )
            @test_throws ArgumentError LibTmux.new_window(server, session_ref; command=argv)
            @test_throws ArgumentError LibTmux.split_window(server, pane_ref; command=argv)
        end
        @test !isfile(executable * ".calls")
        @test LibTmux._pane_command_args(["./-name", "-argument"], nothing) ==
              ["./-name", "-argument"]
        @test LibTmux._pane_command_args(["/bin/-name", "-argument"], nothing) ==
              ["/bin/-name", "-argument"]
    end
end

@testset "creation environment, indices and focus" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        created = try
            LibTmux.new_session(
                server;
                name="environment",
                environment=Dict("VALUE" => "session"),
                command=["/bin/cat"],
            )
        catch error
            error
        end
        @test created isa SessionRef
        if created isa SessionRef
            @test LibTmux.get_environment(server, created, "VALUE").value == "session"
            # Records the pane's environment, then signals the channel.
            recorder(output, channel) = Main.StandIns.julia_argv(
                """
                write(ARGS[1], ENV["VALUE"])
                run(`\$(ARGS[2]) -S \$(ARGS[3]) wait-for -S \$(ARGS[4])`)
                StandIns.exec("cat")
                """,
                output,
                fixture.tmux,
                fixture.socket,
                channel,
            )
            window_env = joinpath(fixture.directory, "window-env")
            window_ref = LibTmux.new_window(
                server,
                created;
                index=9,
                environment=("VALUE" => "#{session_name};",),
                command=recorder(window_env, "window-ready"),
            )
            LibTmux.run_command(server, "wait-for", "window-ready"; timeout=30)
            @test read(window_env, String) == "#{session_name};"
            snap = snapshot(server)
            link = only(filter(l -> window(l).ref == window_ref, windowlinks(snap)))
            @test link.index == 9
            firstpane =
                only(panes(only(filter(w -> w.ref == window_ref, windows(snap))))).ref
            pane_env = joinpath(fixture.directory, "pane-env")
            second = LibTmux.split_window(
                server,
                firstpane;
                environment=Dict("VALUE" => "pane;"),
                command=recorder(pane_env, "pane-ready"),
            )
            LibTmux.run_command(server, "wait-for", "pane-ready"; timeout=30)
            @test read(pane_env, String) == "pane;"
            LibTmux.select_pane(server, second)
            LibTmux.select_window(server, WindowLinkRef(link))
            snap = snapshot(server)
            @test only(filter(p -> p.ref == second, panes(snap))).active
            @test only(filter(l -> window(l).ref == window_ref, windowlinks(snap))).active
            @test_throws CommandError LibTmux.new_window(
                server,
                created;
                index=9,
                command=["/bin/cat"],
            )
            @test length(windows(snapshot(server))) == 2
            fake = Server(
                socket_path=joinpath(fixture.directory, "not-started"),
                tmux="missing-tmux",
            )
            for environment in (
                ("INVALID=NAME" => "x",),
                ("VALUE" => 1,),
                ("VALUE" => "a", "VALUE" => "b"),
            )
                @test_throws ArgumentError LibTmux.new_session(
                    fake;
                    name="bad",
                    environment,
                )
                @test_throws ArgumentError LibTmux.new_window(fake, created; environment)
                @test_throws ArgumentError LibTmux.split_window(fake, second; environment)
            end
            @test_throws ArgumentError LibTmux.new_window(fake, created; index=true)
            @test_throws ArgumentError LibTmux.new_window(fake, created; index=-1)
        end
    end
end

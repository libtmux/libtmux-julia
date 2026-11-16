using Test
using LibTmux
using FileWatching

@testset "pending discovery yields and cancellation joins its client" begin
    mktempdir(; prefix="ltj-cap-") do directory
        executable = joinpath(directory, "client")
        Main.StandIns.install(
            executable,
            """
            write(PROGRAM_FILE * ".pid.new", string(getpid()))
            mv(PROGRAM_FILE * ".pid.new", PROGRAM_FILE * ".pid")
            wait(Condition())
            """,
        )
        monitor = FolderMonitor(directory)
        timer = Timer(_ -> close(monitor), 0.9)
        token = CancellationToken()
        endpoint = Server(; socket_path=joinpath(directory, "s"), tmux=executable)
        pending = @async try
            capabilities(endpoint; timeout=0.9, cancel=token)
        catch error
            error
        end
        try
            while !isfile(executable * ".pid")
                isopen(monitor) || error("capability client did not reach its fixture")
                wait(monitor)
            end
            sibling = @async :responsive
            @test fetch(sibling) === :responsive
            @test !istaskdone(pending)
            pid = parse(Cint, strip(read(executable * ".pid", String)))
            cancel!(token)
            result = fetch(pending)
            @test result isa RequestCancelled && !result.sent
            @test ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1
        finally
            cancel!(token)
            wait(pending)
            close(timer)
            close(monitor)
        end
    end
end

@testset "capability discovery avoids unrelated command aliases" begin
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        session = new_session(server; name="aliases", command=["/bin/cat"])
        original = capabilities(server)
        control =
            supports(original, "control-mode") ? open_control(server, session) : nothing
        # Ordinary named operations use the aliases being tested in their preflight.
        # A bounded native observer separates fixture setup from discovery effects.
        native(args...) = LibTmux._version_process(
            [server.tmux, "-N", "-u", "-S", server.socket_path, "--", args...],
            LibTmux._client_environment(ENV, server);
            timeout=0.9,
            cancel=nothing,
            started=time_ns(),
        )
        witnesses() = String(native("list-buffers", "-F", "#{buffer_name}").stdout)
        try
            for (index, alias) in (
                (91, "run-shell=set-buffer -b cap-run-alias payload ; run"),
                (92, "if-shell=set-buffer -b cap-if-alias payload ; if"),
            )
                @test native("set-option", "-s", "command-alias[$index]", alias).exitcode ==
                      0
            end
            @test !occursin("cap-run-alias", witnesses())
            @test !occursin("cap-if-alias", witnesses())
            @test capabilities(server).generation == original.generation
            @test !occursin("cap-run-alias", witnesses())
            if control !== nothing
                @test capabilities(control).generation == original.generation
                @test !occursin("cap-if-alias", witnesses())
            end
        finally
            native("set-option", "-su", "command-alias[91]")
            native("set-option", "-su", "command-alias[92]")
            control === nothing || close(control)
        end
    end
end

@testset "public capabilities describe the responding daemon" begin
    endpoint = Ref{Server}()
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        endpoint[] = server
        session = new_session(server; name="capabilities", command=["/bin/cat"])
        observed = snapshot(server)
        before = copy(LibTmux._VERSION_CACHE)
        report = capabilities(server; timeout=0.9)
        @test report isa CapabilityReport
        @test report.generation == observed.identity.generation
        @test LibTmux._VERSION_CACHE == before
        if haskey(ENV, "LIBTMUX_TEST_CLIENT_TMUX")
            client = Server(;
                socket_path=server.socket_path,
                tmux=ENV["LIBTMUX_TEST_CLIENT_TMUX"],
            )
            @test capabilities(client).version == report.version
            @test capabilities(client).generation == report.generation
        end
        @test Set(entry.id for entry in report.features) ==
              Set(entry.id for entry in LibTmux._CAPABILITIES)
        for entry in report.features
            @test capability(report, entry.id) === entry
            @test supports(report, entry.id) == entry.supported
            @test entry.supported == LibTmux._version_at_least(report.version, entry.since)
            @test_throws MethodError push!(entry.apis, "changed")
            @test_throws MethodError push!(first(entry.commands).flags, "-Z")
        end
        for entry in report.workarounds
            @test workaround(report, entry.id) === entry
            @test entry.active == LibTmux._workaround_applies(entry.id, report.version)
            @test_throws MethodError push!(entry.releases, "0.0")
        end
        @test_throws KeyError supports(report, "missing-feature")
        @test_throws KeyError capability(report, "missing-feature")
        @test_throws KeyError workaround(report, "missing-workaround")
        @test_throws MethodError push!(report.features, first(report.features))
        token = CancellationToken()
        cancel!(token)
        @test_throws RequestCancelled capabilities(server; cancel=token)
        @test_throws ArgumentError capabilities(server; timeout=0)
        run_command(
            server,
            "set-hook",
            "-g",
            "after-display-message",
            "set-option -g @capability-query fired",
        )
        @test capabilities(server).version == report.version
        @test isempty(
            run_command(server, "show-option", "-gqv", "@capability-query").stdout,
        )
        if supports(report, "control-mode")
            control = open_control(server, session)
            try
                pinned = capabilities(control; timeout=0.9)
                @test pinned.generation == report.generation
                @test pinned.version == report.version
                @test supports(pinned, "layout-json") == supports(report, "layout-json")
                @test_throws RequestCancelled capabilities(control; cancel=token)
                LibTmux._remember_release!(server, "0.0")
                @test capabilities(control).version == report.version
                @test LibTmux._cached_release(server) == "0.0"
                LibTmux._remember_control_release!(control, "3.6a")
                @test_throws ControlCommandError capabilities(control)
                LibTmux._remember_control_release!(control, report.version)
                moved = server.socket_path * ".hidden"
                mv(server.socket_path, moved)
                try
                    @test capabilities(control).generation == report.generation
                    @test_throws CommandError capabilities(server)
                    @test !ispath(server.socket_path)
                finally
                    mv(moved, server.socket_path)
                end
            finally
                close(control)
            end
            @test_throws ControlConnectionError capabilities(control)
        end
        @test isempty(
            run_command(server, "show-option", "-gqv", "@capability-query").stdout,
        )
    end
    @test_throws CommandError capabilities(endpoint[]; timeout=0.9)
    @test !ispath(endpoint[].socket_path)
end

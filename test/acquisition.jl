@testset "captured tmux graph" begin
    @test isdefined(LibTmux, :snapshot)
    if isdefined(LibTmux, :snapshot)
        captured = with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            empty = LibTmux.snapshot(server)
            @test isempty(LibTmux.sessions(empty))
            @test isempty(LibTmux.panes(empty))
            path = joinpath(fixture.directory, "cwd\tline\né\\n")
            mkpath(path)
            run_command(
                server,
                "new-session",
                "-d",
                "-s",
                "dev",
                "-n",
                "api",
                "-c",
                path,
                "cat",
            )
            run_command(server, "split-window", "-h", "-t", "dev:api", "cat")
            run_command(server, "new-window", "-t", "dev:", "-n", "build", "cat")
            run_command(server, "new-session", "-d", "-s", "ops", "cat")
            run_command(server, "link-window", "-s", "dev:api", "-t", "ops:4")
            run_command(server, "kill-window", "-t", "ops:0")
            title = "é 雪 #{pane_id}"
            run_command(
                server,
                "select-pane",
                "-t",
                "dev:api.0",
                "-T",
                replace(title, "#" => "##"),
            )
            snap = LibTmux.snapshot(server)
            @test length(LibTmux.sessions(snap)) == 2
            @test length(LibTmux.windows(snap)) == 2
            @test length(LibTmux.panes(snap)) == 3
            @test length(LibTmux.windowlinks(snap)) == 3
            @test length(LibTmux.paneoccurrences(snap)) == 5
            @test isempty(LibTmux.clients(snap))
            @test count(p -> p.title == title, LibTmux.panes(snap)) == 1
            @test any(p -> p.current_path == path, LibTmux.panes(snap))
            @test count(
                PaneWhere(active=true, window=WindowWhere(name="api")),
                panes(snap),
            ) == 1
            @test count(
                SessionWhere(windows=Filters.AnyRelated(WindowWhere(name="api"))),
                sessions(snap),
            ) == 2
            @test onlymatch(
                WindowLinkWhere(index=4, session=SessionWhere(name="ops")),
                windowlinks(snap),
            ).window.name == "api"
            run_command(server, "rename-window", "-t", "dev:api", "changed")
            fresh = LibTmux.snapshot(server)
            @test any(w -> w.name == "api", LibTmux.windows(snap))
            @test any(w -> w.name == "changed", LibTmux.windows(fresh))
            @test LibTmux.entitykey(first(LibTmux.panes(snap))) ==
                  LibTmux.entitykey(first(LibTmux.panes(fresh)))
            token = CancellationToken()
            cancel!(token)
            @test_throws RequestCancelled LibTmux.snapshot(server; cancel=token)
            @test_throws DeadlineExceeded LibTmux.snapshot(server; timeout=nextfloat(0.0))
            snap
        end
        @test length(LibTmux.panes(captured)) == 3
        @test !isempty(sprint(show, captured))
    end
end

@testset "unavailable acquisition fields" begin
    identity =
        ServerIdentity(socket_path="/tmp/libtmux-julia-observation", generation="1:1")
    rows = (
        ss=[["\$0", "dev", "0"]],
        ws=[["@0", "api", "80", "24", "\$0", "0", "1"]],
        ps=[["%0", "@0", "0", "1", "1", "80", "24", "cat", "", "title"]],
        cs=Vector{String}[],
    )
    snap = LibTmux._snapshot_from_rows(identity, rows, (1.0, 2.0))
    pane = only(panes(snap))
    @test_throws SnapshotCoverageError pane.current_path
    @test pane.current_command == "cat"
    @test_throws SnapshotCoverageError LibTmux._observed_int("", "pane_width")
end

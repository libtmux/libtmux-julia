@testset "captured tmux graph" begin
    @test isdefined(LibTmux, :snapshot)
    if isdefined(LibTmux, :snapshot)
        captured = with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            empty = LibTmux.snapshot(server)
            @test isempty(LibTmux.sessions(empty))
            @test isempty(LibTmux.panes(empty))
            path_root = mkdir(joinpath(fixture.directory, "cwd-root"))
            linked_root = joinpath(fixture.directory, "cwd-link")
            symlink(path_root, linked_root)
            path = joinpath(linked_root, "cwd\tline\né\\n")
            mkpath(path)
            expected_path = realpath(path)
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
            @test all(
                p -> p.pid > 0 && p.tty !== nothing && p.exit_status === nothing,
                panes(snap),
            )
            @test @inferred((p -> p.pid)(first(panes(snap)))) isa Int
            @test count(p -> p.title == title, LibTmux.panes(snap)) == 1
            @test any(p -> p.current_path == expected_path, LibTmux.panes(snap))
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
            run_command(server, "resize-pane", "-Z", "-t", "dev:changed.0")
            fresh = LibTmux.snapshot(server)
            @test any(w -> w.name == "api", LibTmux.windows(snap))
            @test any(w -> w.name == "changed", LibTmux.windows(fresh))
            original_window = onlymatch(WindowWhere(name="api"), windows(snap))
            zoomed_window = onlymatch(WindowWhere(name="changed"), windows(fresh))
            @test !original_window.zoomed && zoomed_window.zoomed
            @test zoomed_window.layout == original_window.layout
            @test zoomed_window.visible_layout != zoomed_window.layout
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
        ss=[["\$0", "dev", "0", "1", "2", ""]],
        ws=[["@0", "api", "80", "24", "\$0", "0", "1", "layout", "visible", "0", "2"]],
        ps=[[
            "%0",
            "@0",
            "0",
            "1",
            "1",
            "80",
            "24",
            "cat",
            "",
            "title",
            "12",
            "",
            "",
            "0",
            "2000",
            "2",
            "3",
        ]],
        cs=Vector{String}[],
    )
    snap = LibTmux._snapshot_from_rows(identity, rows, (1.0, 2.0))
    pane = only(panes(snap))
    @test_throws SnapshotCoverageError pane.current_path
    @test pane.current_command == "cat"
    @test (pane.tty, pane.exit_status) === (nothing, nothing)
    @test (
        pane.pid,
        pane.history_size,
        pane.history_limit,
        pane.cursor_x,
        pane.cursor_y,
    ) === (12, 0, 2000, 2, 3)
    @test (pane.window.layout, pane.window.visible_layout, pane.window.zoomed) ===
          ("layout", "visible", false)
    @test (
        only(sessions(snap)).created,
        only(sessions(snap)).activity,
        only(sessions(snap)).last_attached,
    ) === (1, 2, nothing)
    changed = merge(rows, (; cs=[["client", "12", "1", "\$0", "2"]]))
    @test LibTmux._graph_signature(changed) == LibTmux._graph_signature(
        merge(changed, (; cs=[["client", "12", "1", "\$0", "9"]])),
    )
    exited = deepcopy(rows)
    exited.ps[1][13] = "7"
    @test only(panes(LibTmux._snapshot_from_rows(identity, exited, (1.0, 2.0)))).exit_status ===
          7
    @test_throws SnapshotCoverageError LibTmux._observed_int("", "pane_width")
end

@testset "real tmux format row encoding" begin
    OwnedTmux.with_tmux() do fixture
        value =
            "tab\tline\nslash\\n #{raw} π😀\r  " *
            raw"$ENV \$ENV \d ${ENV} $_env $9 $" *
            String(UInt8[1:31; 127])
        for arguments in (
            ("new-session", "-d", "-s", "rows", "cat"),
            ("set-environment", "-g", "libtmux_test_row", value),
            ("set-environment", "-g", "libtmux_test_empty", ""),
        )
            command = OwnedTmux.tmuxcmd(fixture, arguments...)
            process = run(pipeline(ignorestatus(command); stdout=devnull, stderr=devnull))
            @test success(process)
        end
        template = LibTmux._format_template(["libtmux_test_row", "libtmux_test_empty"])
        command = OwnedTmux.tmuxcmd(fixture, "list-panes", "-t", "rows:0", "-F", template)
        errors = IOBuffer()
        output = IOBuffer()
        process = run(pipeline(ignorestatus(command); stdout=output, stderr=errors))
        @test success(process)
        @test LibTmux._decode_format_rows(take!(output), 2) == [[value, ""]]
    end
end

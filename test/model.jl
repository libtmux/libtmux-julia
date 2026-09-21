@testset "captured identity and local collections" begin
    @test isdefined(LibTmux, :_build_snapshot)
    if isdefined(LibTmux, :_build_snapshot)
        identity =
            LibTmux.ServerIdentity(socket_path="/tmp/libtmux-model", generation="daemon-a")
        restarted =
            LibTmux.ServerIdentity(socket_path="/tmp/libtmux-model", generation="daemon-b")
        other = LibTmux.ServerIdentity(
            socket_path="/tmp/libtmux-model-other",
            generation="daemon-a",
        )
        pane_id = LibTmux.PaneID("%1")
        ref = LibTmux.PaneRef(identity, pane_id)
        @test string(ref.id) == "%1"
        @test ref == LibTmux.PaneRef(identity, "%1")
        @test length(
            Set([ref, LibTmux.PaneRef(restarted, "%1"), LibTmux.PaneRef(other, "%1")]),
        ) == 3
        @test_throws ArgumentError LibTmux.PaneID("@1")
        @test_throws ArgumentError LibTmux.SessionID("\$1; kill-server")
        @test_throws ArgumentError LibTmux.PaneID("%01")
        first_client = LibTmux.ClientID("/dev/pts/7", "created-precise-a")
        next_client = LibTmux.ClientID("/dev/pts/7", "created-precise-b")
        @test first_client != next_client
        @test string(first_client) == "/dev/pts/7"
        @test_throws ArgumentError LibTmux.ClientID("/dev/pts/7", "")

        session_rows = [(id="\$0", name="dev"), (id="\$1", name="ops")]
        window_rows = [(id="@1", name="api"), (id="@2", name="build")]
        pane_rows = [
            (id="%1", window_id="@1", active=true, current_command="nvim"),
            (id="%2", window_id="@1", active=false, current_command=nothing),
            (id="%3", window_id="@2", active=true, current_command="julia"),
        ]
        link_rows = [
            (session_id="\$0", window_id="@1", index=0, active=true),
            (session_id="\$0", window_id="@2", index=1, active=false),
            (session_id="\$1", window_id="@1", index=4, active=true),
        ]
        snap = LibTmux._build_snapshot(
            identity;
            sessions=session_rows,
            windows=window_rows,
            panes=pane_rows,
            windowlinks=link_rows,
            clients=[(id=first_client, session_id=nothing)],
            acquired=(1.0, 2.0),
            complete=true,
        )
        @test (
            length(LibTmux.sessions(snap)),
            length(LibTmux.windows(snap)),
            length(LibTmux.windowlinks(snap)),
            length(LibTmux.panes(snap)),
            length(LibTmux.paneoccurrences(snap)),
        ) == (2, 2, 3, 3, 5)
        @test snap.acquired == (1.0, 2.0)
        @test LibTmux.window(first(LibTmux.panes(snap))).name == "api"
        @test first(LibTmux.panes(snap)).window.name == "api"
        @test map(w -> w.name, LibTmux.windows(first(LibTmux.sessions(snap)))) ==
              ["api", "build"]
        @test LibTmux.session(only(LibTmux.clients(snap))) === nothing
        @test first(LibTmux.windowlinks(snap)).index == 0
        @test length(unique(LibTmux.entitykey, LibTmux.paneoccurrences(snap))) == 3
        @test length(unique(LibTmux.occurrencekey, LibTmux.paneoccurrences(snap))) == 5
        @test_throws ArgumentError LibTmux.PaneOccurrence(
            first(LibTmux.panes(snap)),
            LibTmux.windowlinks(snap)[2],
        )

        session_rows[1] = (id="\$0", name="changed")
        empty!(window_rows)
        empty!(pane_rows)
        empty!(link_rows)
        @test first(LibTmux.sessions(snap)).name == "dev"
        @test length(LibTmux.paneoccurrences(snap)) == 5
        ps = LibTmux.panes(snap)
        @test ps isa AbstractVector{LibTmux.PaneSnapshot}
        @test (size(ps), axes(ps), collect(eachindex(ps))) ==
              ((3,), (Base.OneTo(3),), [1, 2, 3])
        @test first(collect(ps)).window.name == "api"
        selected = filter(p -> p.active, ps)
        @test selected isa LibTmux.Selection{LibTmux.PaneSnapshot}
        @test map(p -> string(p.id), selected) == ["%1", "%3"]
        @test LibTmux.snapshotof(selected) === snap
        @test LibTmux.snapshotof(first(selected)) === snap
        @test eltype(filter(_ -> false, ps)) == LibTmux.PaneSnapshot
        @test filter(_ -> true, collect(ps)) isa Vector{LibTmux.PaneSnapshot}
        repeated = LibTmux.Selection([ps[1], ps[1], ps[3]]; snapshot=snap)
        @test map(p -> string(p.id), filter(_ -> true, repeated)) == ["%1", "%1", "%3"]
        @test map(p -> string(p.id), repeated) == map(p -> string(p.id), repeated)
        source = [ps[1], ps[3]]
        typed = LibTmux.Selection{LibTmux.PaneSnapshot}(source, snap)
        empty!(source)
        @test length(typed) == 2
        owned = similar(ps, Int, (2,))
        owned[1] = 7
        @test owned isa Vector{Int} && owned[1] == 7
        @test_throws Exception setindex!(ps, ps[2], 1)
        @test_throws ArgumentError only(ps)
        @test_throws ArgumentError only(filter(_ -> false, ps))
        @test only(filter(p -> p.current_command === "julia", ps)).id ==
              LibTmux.PaneID("%3")
        @test occursin("%1", sprint(show, ps[1]))
        @test_throws LibTmux.SnapshotCoverageError ps[1].width
        @test ps[2].current_command === nothing
    end
end

@testset "membership coverage and graph closure" begin
    @test isdefined(LibTmux, :_build_snapshot)
    if isdefined(LibTmux, :_build_snapshot)
        identity =
            LibTmux.ServerIdentity(socket_path="/tmp/libtmux-model", generation="daemon-a")
        win = LibTmux.WindowID("@1")
        partial = LibTmux._build_snapshot(
            identity;
            windows=[(id=win, name="captured")],
            complete=(:windows,),
            acquired=(1, 2),
        )
        window = only(LibTmux.windows(partial))
        @test_throws LibTmux.SnapshotCoverageError LibTmux.panes(partial)
        @test_throws LibTmux.SnapshotCoverageError LibTmux.panes(window)
        root_only = LibTmux._build_snapshot(
            identity;
            windows=[(id=win,)],
            complete=(:windows, :panes),
            acquired=(1, 2),
        )
        @test isempty(LibTmux.panes(root_only))
        @test_throws LibTmux.SnapshotCoverageError LibTmux.panes(
            only(LibTmux.windows(root_only)),
        )
        empty_membership = LibTmux._build_snapshot(
            identity;
            windows=[(id=win,)],
            complete=(:windows, (:window, win, :panes)),
            acquired=(1, 2),
        )
        @test isempty(LibTmux.panes(only(LibTmux.windows(empty_membership))))
        @test LibTmux.hascoverage(empty_membership, (:window, win, :panes))
        @test_throws ArgumentError LibTmux._build_snapshot(
            identity;
            panes=[(id="%1", window_id="@missing")],
            acquired=(1, 2),
            complete=true,
        )
        @test_throws LibTmux.InconsistentSnapshot LibTmux._build_snapshot(
            identity;
            panes=[(id="%1", window_id="@1")],
            acquired=(1, 2),
            complete=true,
        )
        @test_throws LibTmux.InconsistentSnapshot LibTmux._build_snapshot(
            identity;
            windows=[(id="@1", name="a"), (id="@1", name="b")],
            acquired=(1, 2),
        )
        duplicate = LibTmux._build_snapshot(
            identity;
            windows=[(id="@1", name="a"), (id="@1", name="a")],
            acquired=(1, 2),
            complete=true,
        )
        @test length(LibTmux.windows(duplicate)) == 1
        tags = ["one", "two"]
        frozen = LibTmux._build_snapshot(
            identity;
            windows=[(id="@1", tags=tags)],
            acquired=(1, 2),
            complete=true,
        )
        push!(tags, "three")
        @test only(LibTmux.windows(frozen)).tags == ("one", "two")
        @test_throws ArgumentError LibTmux._build_snapshot(
            identity;
            windows=[(id="@1", width=big(3))],
            acquired=(1, 2),
        )
        @test_throws ArgumentError LibTmux._build_snapshot(identity; acquired=(2, 1))
        @test_throws LibTmux.InconsistentSnapshot LibTmux._build_snapshot(
            identity;
            sessions=[(id="\$0",)],
            windows=[(id="@1",)],
            acquired=(1, 2),
            windowlinks=[
                (session_id="\$0", window_id="@1", index=0),
                (session_id="\$0", window_id="@1", index=0),
            ],
        )
    end
end

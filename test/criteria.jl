function criteria_fixture()
    identity = ServerIdentity(socket_path="/tmp/libtmux-criteria", generation="one")
    LibTmux._build_snapshot(
        identity;
        acquired=(1, 2),
        complete=true,
        sessions=[
            (id="\$0", name="dev", attached_clients=0),
            (id="\$1", name="ops", attached_clients=1),
        ],
        windows=[
            (id="@1", name="API", width=120, height=30),
            (id="@2", name="build", width=80, height=24),
        ],
        panes=[
            (
                id="%1",
                window_id="@1",
                index=0,
                active=true,
                dead=false,
                width=120,
                height=30,
                current_command="nvim",
                current_path="/app",
                title="ÉDITOR",
            ),
            (
                id="%2",
                window_id="@1",
                index=1,
                active=false,
                dead=true,
                width=120,
                height=30,
                current_command=nothing,
                current_path=nothing,
                title="shell",
            ),
            (
                id="%3",
                window_id="@2",
                index=0,
                active=true,
                dead=false,
                width=80,
                height=24,
                current_command="julia",
                current_path="/work",
                title="build",
            ),
        ],
        windowlinks=[
            (session_id="\$0", window_id="@1", index=0, active=true),
            (session_id="\$0", window_id="@2", index=1, active=false),
            (session_id="\$1", window_id="@1", index=4, active=true),
        ],
        clients=[(
            id=ClientID("client", "first"),
            name="client",
            pid=100,
            created=1,
            session_id=nothing,
        )],
    )
end

@testset "callable criteria use Base collections" begin
    @test isdefined(LibTmux, :PaneWhere)
    if isdefined(LibTmux, :PaneWhere)
        F = LibTmux.Filters
        snap = criteria_fixture()
        ps = panes(snap)
        q = LibTmux.PaneWhere(active=true, current_command=F.OneOf(["nvim", "vim"]))
        @test q isa Function
        @test map(p -> string(p.id), filter(q, ps)) == ["%1"]
        @test filter(q, ps) isa Selection{PaneSnapshot}
        @test snapshotof(filter(q, ps)) === snap
        @test filter(q, collect(ps)) isa Vector{PaneSnapshot}
        @test (any(q, ps), all(q, ps), count(q, ps), findall(q, ps)) ==
              (true, false, 1, [1])
        @test [p.id for p in ps if q(p)] == [PaneID("%1")]
        @test collect(Iterators.filter(q, ps)) == collect(filter(q, ps))
        @test (ps|>filter(q))[1].id == PaneID("%1")
        commands = ["nvim"]
        frozen = LibTmux.PaneWhere(current_command=F.OneOf(commands))
        push!(commands, "julia")
        @test count(frozen, ps) == 1
        @test count(LibTmux.PaneWhere(), ps) == 3
        @test only(filter(LibTmux.PaneWhere(current_command=nothing), ps)).id ==
              PaneID("%2")
        @test count(LibTmux.PaneWhere(width=F.AtLeast(100)), ps) == 2
        @test count(LibTmux.PaneWhere(width=F.GreaterThan(119.5)), ps) == 2
        @test count(LibTmux.PaneWhere(width=F.AtMost(80)), ps) == 1
        @test count(LibTmux.PaneWhere(width=F.LessThan(100)), ps) == 1
        @test count(LibTmux.PaneWhere(id=F.EqualTo(PaneID("%1"))), ps) == 1
        @test count(LibTmux.PaneWhere(title=F.OneOf(())), ps) == 0
        @test count(LibTmux.PaneWhere(current_command=F.NotEqualTo(nothing)), ps) == 2
        @test count(
            LibTmux.PaneWhere(title=F.Contains("ditor"; case=:ascii_insensitive)),
            ps,
        ) == 1
        @test count(
            LibTmux.PaneWhere(title=F.StartsWith("é"; case=:ascii_insensitive)),
            ps,
        ) == 0
        @test count(LibTmux.PaneWhere(current_command=F.EndsWith("im")), ps) == 1
        @test count(
            F.AllOf(LibTmux.PaneWhere(active=true), F.Not(LibTmux.PaneWhere(dead=true))),
            ps,
        ) == 2
        @test count(F.AllOf(), ps) == 3
        @test count(F.AnyOf(), ps) == 0
        @test LibTmux.onlymatch(q, ps).id == PaneID("%1")
        @test_throws LibTmux.NoMatchError LibTmux.onlymatch(
            LibTmux.PaneWhere(title="absent"),
            ps,
        )
        @test_throws LibTmux.MultipleMatchesError LibTmux.onlymatch(LibTmux.PaneWhere(), ps)
        @test_throws ArgumentError only(filter(LibTmux.PaneWhere(), ps))
        @test occursin(
            "at least two",
            sprint(showerror, LibTmux.MultipleMatchesError(:pane)),
        )
    end
end

@testset "criteria reject invalid meanings" begin
    @test isdefined(LibTmux, :PaneWhere)
    if isdefined(LibTmux, :PaneWhere)
        F = LibTmux.Filters
        for kwargs in (
            (active=F.Contains("true"),),
            (width=true,),
            (width=nothing,),
            (id=WindowID("@1"),),
            (id="%1",),
            (window=LibTmux.SessionWhere(),),
        )
            @test_throws ArgumentError LibTmux.PaneWhere(; kwargs...)
        end
        @test_throws MethodError LibTmux.PaneWhere(hidden_transport=true)
        @test_throws ArgumentError F.AtLeast(true)
        @test_throws ArgumentError F.Contains("api"; case=:unicode)
        @test_throws ArgumentError F.OneOf([Ref("mutable")])
        @test_throws ArgumentError LibTmux.PaneWhere(current_command=F.OneOf(("nvim", 1)))
        @test_throws ArgumentError F.AllOf(LibTmux.PaneWhere(), LibTmux.WindowWhere())
        @test_throws ArgumentError LibTmux.WindowWhere(panes=LibTmux.PaneWhere())
        @test_throws ArgumentError LibTmux.WindowWhere(
            panes=F.AnyRelated(LibTmux.SessionWhere()),
        )
        @test_throws ArgumentError LibTmux.PaneWhere()(first(windows(criteria_fixture())))
        @test_throws ArgumentError filter(
            LibTmux.PaneWhere(),
            filter(_ -> false, windows(criteria_fixture())),
        )
    end
end

@testset "relations retain correlation and check all coverage" begin
    @test isdefined(LibTmux, :PaneWhere)
    if isdefined(LibTmux, :PaneWhere)
        F = LibTmux.Filters
        snap = criteria_fixture()
        editor = LibTmux.PaneWhere(current_command="nvim")
        nested = LibTmux.SessionWhere(
            windows=F.AnyRelated(LibTmux.WindowWhere(panes=F.AnyRelated(editor))),
        )
        @test count(nested, sessions(snap)) == 2
        @test count(
            LibTmux.WindowLinkWhere(index=4, session=LibTmux.SessionWhere(name="ops")),
            windowlinks(snap),
        ) == 1
        @test count(
            LibTmux.PaneWhere(window=LibTmux.WindowWhere(name="API")),
            panes(snap),
        ) == 2
        @test count(LibTmux.ClientWhere(session=nothing), clients(snap)) == 1
        @test count(LibTmux.ClientWhere(session=LibTmux.SessionWhere()), clients(snap)) == 0

        identity = snap.identity
        split = LibTmux._build_snapshot(
            identity;
            acquired=(1, 2),
            complete=true,
            sessions=[(id="\$0", name="split")],
            windows=[(id="@1", name="api"), (id="@2", name="editors")],
            panes=[
                (id="%1", window_id="@1", current_command="bash"),
                (id="%2", window_id="@2", current_command="nvim"),
            ],
            windowlinks=[
                (session_id="\$0", window_id="@1", index=0),
                (session_id="\$0", window_id="@2", index=1),
            ],
        )
        correlated = LibTmux.SessionWhere(
            windows=F.AnyRelated(
                LibTmux.WindowWhere(name="api", panes=F.AnyRelated(editor)),
            ),
        )
        independent = F.AllOf(
            LibTmux.SessionWhere(windows=F.AnyRelated(LibTmux.WindowWhere(name="api"))),
            nested,
        )
        @test !correlated(only(sessions(split))) && independent(only(sessions(split)))

        empty = LibTmux._build_snapshot(
            identity;
            acquired=(1, 2),
            complete=true,
            windows=[(id="@1", name="empty")],
        )
        win = only(windows(empty))
        @test !LibTmux.WindowWhere(panes=F.AnyRelated(editor))(win)
        @test LibTmux.WindowWhere(panes=F.AllRelated(editor))(win)
        @test LibTmux.WindowWhere(panes=F.NoRelated(editor))(win)

        partial = LibTmux._build_snapshot(
            identity;
            acquired=(1, 2),
            complete=(:windows,),
            windows=[(id="@1", name="partial")],
        )
        unknown = only(windows(partial))
        @test_throws SnapshotCoverageError F.AnyOf(
            LibTmux.WindowWhere(),
            LibTmux.WindowWhere(panes=F.AnyRelated(editor)),
        )(
            unknown,
        )
        @test_throws SnapshotCoverageError F.AllOf(
            LibTmux.WindowWhere(name="wrong"),
            LibTmux.WindowWhere(width=1),
        )(
            unknown,
        )
        @test_throws SnapshotCoverageError F.Not(LibTmux.WindowWhere(width=1))(unknown)
        @test_throws SnapshotCoverageError LibTmux.WindowWhere(panes=F.NoRelated(editor))(
            unknown,
        )
        missing_child = LibTmux._build_snapshot(
            identity;
            acquired=(1, 2),
            complete=true,
            windows=[(id="@1",)],
            panes=[
                (id="%1", window_id="@1", current_command="nvim"),
                (id="%2", window_id="@1"),
            ],
        )
        @test_throws SnapshotCoverageError LibTmux.WindowWhere(panes=F.AnyRelated(editor))(
            only(windows(missing_child)),
        )
    end
end

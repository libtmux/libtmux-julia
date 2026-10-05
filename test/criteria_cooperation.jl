using Test, LibTmux

# Pure: one-call memoization must preserve extension dispatch and captured coverage.
module CriterionDispatch
using LibTmux, Test
struct PressureScalarCriterion <: LibTmux.Criterion
    _clauses::Tuple
    preflights::Base.RefValue{Int}
end
LibTmux._criterion_entity(::PressureScalarCriterion) = :pane
function LibTmux._preflight(q::PressureScalarCriterion, item)
    q.preflights[] += 1
    nothing
end
LibTmux._evaluate(::PressureScalarCriterion, item) = isodd(item.index)
struct PressureWindowCriterion <: LibTmux.Criterion end
LibTmux._criterion_entity(::PressureWindowCriterion) = :window
LibTmux._preflight(::PressureWindowCriterion, item) = nothing
LibTmux._evaluate(::PressureWindowCriterion, item) = false
struct PressureMatchedCriterion <: LibTmux.Criterion
    _clauses::Tuple
end
LibTmux._criterion_entity(::PressureMatchedCriterion) = :window
LibTmux._preflight(::PressureMatchedCriterion, item) = nothing
LibTmux._evaluate(::PressureMatchedCriterion, item) = true
LibTmux._matches(::PressureMatchedCriterion, item) = false
captured = LibTmux._build_snapshot(
    ServerIdentity(socket_path="/tmp/libtmux-pressure-pure", generation="pure");
    acquired=(1, 2),
    complete=true,
    windows=[(id="@1",)],
    panes=[(id="%$i", window_id="@1", index=i, width=1) for i = 1:4],
)
@testset "custom Criterion retains two-argument native dispatch" begin
    q=PressureScalarCriterion((), Ref(0))
    @test [string(p.id) for p in filter(q, panes(captured))] == ["%1", "%3"]
    @test q.preflights[] == 4
    related=PaneWhere(window=PressureWindowCriterion())
    @test isempty(filter(related, panes(captured)))
    matched=PaneWhere(window=PressureMatchedCriterion(()))
    @test isempty(filter(matched, panes(captured)))
    begin
        q.preflights[]=0
        @test [
            string(p.id) for p in LibTmux._filter_where(q, panes(captured), ()->nothing)
        ] == ["%1", "%3"]
        @test q.preflights[] == 4
        @test isempty(LibTmux._filter_where(related, panes(captured), ()->nothing))
        @test isempty(LibTmux._filter_where(matched, panes(captured), ()->nothing))
    end
end
end

module RelatedFallback
using LibTmux, Test
struct StatefulPressureRelated <: LibTmux.Filters.Related
    criterion::LibTmux.Criterion
    calls::Base.RefValue{Int}
end
function LibTmux._matches(op::StatefulPressureRelated, values)
    op.calls[] += 1
    op.calls[] == 1
end
struct GetterPressureRelated <: LibTmux.Filters.Related
    child::LibTmux.Criterion
    reads::Base.RefValue{Int}
end
function Base.getproperty(op::GetterPressureRelated, name::Symbol)
    name === :criterion || return getfield(op, name)
    getfield(op, :reads)[] += 1
    getfield(op, :child)
end
LibTmux._matches(op::GetterPressureRelated, values) = op.reads[] == 16
captured = LibTmux._build_snapshot(
    ServerIdentity(socket_path="/tmp/libtmux-pressure-pure", generation="pure");
    acquired=(1, 2),
    complete=true,
    windows=[(id="@1",)],
    panes=[(id="%$i", window_id="@1", width=1) for i = 1:4],
)
leaf=PaneWhere(width=Filters.AtLeast(1))
@testset "custom related operators retain native fallback" begin
    calls=Ref(0)
    related=StatefulPressureRelated(leaf, calls)
    query=PaneWhere(window=WindowWhere(panes=related))
    matched=filter(query, panes(captured))
    @test [string(p.id) for p in matched] == ["%1"]
    reads=Ref(0)
    related=GetterPressureRelated(leaf, reads)
    query=PaneWhere(window=WindowWhere(panes=related))
    reads[]=0
    matched=filter(query, panes(captured))
    @test [string(p.id) for p in matched] == ["%$i" for i = 1:4]
end
end

module NumericFallback
using LibTmux, Test
const comparisons = Ref(0)
struct StatefulPressureReal <: Real end
Base.isfinite(::StatefulPressureReal) = true
function Base.:>=(::Integer, ::StatefulPressureReal)
    comparisons[] += 1
    comparisons[] <= 4
end
struct StatefulPressureInteger <: Integer
    value::Int
end
function Base.:>=(::StatefulPressureInteger, ::Int)
    comparisons[] += 1
    comparisons[] <= 4
end
@testset "custom numeric behavior remains uncached" begin
    for kind in (:operand, :captured)
        comparisons[] = 0
        width = kind === :captured ? StatefulPressureInteger(1) : 1
        operand = kind === :operand ? StatefulPressureReal() : 1
        captured = LibTmux._build_snapshot(
            ServerIdentity(socket_path="/tmp/libtmux-pressure-pure", generation="pure");
            acquired=(1, 2),
            complete=true,
            windows=[(id="@1",)],
            panes=[(id="%$i", window_id="@1", width=width) for i = 1:4],
        )
        criterion = PaneWhere(
            window=WindowWhere(
                panes=Filters.AllRelated(PaneWhere(width=Filters.AtLeast(operand))),
            ),
        )
        selected = filter(criterion, panes(captured))
        @test [string(p.id) for p in selected] == ["%1"]
    end
end
end

module MutableViewFallback
using LibTmux, Test
mutable struct CustomPressureView <: LibTmux.EntitySnapshot
    _snapshot::LibTmux.Snapshot
    _index::Int
    window::Any
    reads::Int
end
struct CustomPressureWindow
    panes::Vector{CustomPressureView}
end
LibTmux._observation_entity(::Type{CustomPressureView}) = :pane
LibTmux._observation_entity(::Type{CustomPressureWindow}) = :window
LibTmux._kind(::CustomPressureView) = :pane
function Base.getproperty(pane::CustomPressureView, name::Symbol)
    if name === :width
        reads = getfield(pane, :reads) + 1
        setfield!(pane, :reads, reads)
        return reads == 1 ? 1 : "invalid second read"
    end
    getfield(pane, name)
end
captured = LibTmux._build_snapshot(
    ServerIdentity(socket_path="/tmp/libtmux-pressure-pure", generation="pure");
    acquired=(1, 2),
    complete=true,
)
child = CustomPressureView(captured, 1, nothing, 0)
parent = CustomPressureView(captured, 2, CustomPressureWindow([child, child]), 0)
criterion = PaneWhere(
    window=WindowWhere(panes=Filters.AllRelated(PaneWhere(width=Filters.AtLeast(1)))),
)
@test_throws ArgumentError filter(criterion, Selection([parent]))
@test child.reads == 2
end

@testset "captured memo keeps snapshots and contextual occurrences distinct" begin
    identity = ServerIdentity(socket_path="/tmp/libtmux-criteria-pure", generation="pure")
    function capture(width; complete=true)
        LibTmux._build_snapshot(
            identity;
            acquired=(1, 2),
            complete,
            windows=[(id="@1", width=80)],
            panes=[(id="%1", window_id="@1", width)],
        )
    end
    full = capture(80)
    changed = capture(120)
    partial = capture(80; complete=(:panes,))
    query = PaneWhere(window=WindowWhere(panes=Filters.AllRelated(PaneWhere(width=80))))
    mixed = Selection(
        PaneSnapshot[first(panes(full)), first(panes(changed)), first(panes(full))],
    )
    @test [snapshotof(pane) === full for pane in filter(query, mixed)] == [true, true]
    @test [
        snapshotof(pane) === full for
        pane in LibTmux._filter_where(query, mixed, ()->nothing)
    ] == [true, true]
    for outer in (
        Filters.AnyOf(PaneWhere(), query),
        Filters.AllOf(PaneWhere(width=0), query),
        Filters.Not(query),
    )
        @test_throws SnapshotCoverageError filter(outer, panes(partial))
        @test_throws SnapshotCoverageError LibTmux._filter_where(
            outer,
            panes(partial),
            ()->nothing,
        )
    end
    linked = LibTmux._build_snapshot(
        identity;
        acquired=(1, 2),
        complete=true,
        sessions=[(id="\$1", name="first"), (id="\$2", name="second")],
        windows=[(id="@1", name="same")],
        windowlinks=[
            (id="@1", window_id="@1", session_id="\$1", index=4),
            (id="@1", window_id="@1", session_id="\$2", index=7),
        ],
    )
    links=windowlinks(linked)
    occurrences=Selection([links[2], links[1], links[2], links[1]]; snapshot=linked)
    selected=filter(WindowLinkWhere(index=4, window=WindowWhere(name="same")), occurrences)
    @test [link.session_id for link in selected] == [SessionID("\$1"), SessionID("\$1")]
    @test_throws ErrorException LibTmux._filter_where(
        query,
        panes(full),
        ()->error("checkpoint"),
    )
    @test length(filter(query, panes(full))) == 1
end

@testset "controlled literal matching preserves Base boundaries" begin
    outcome(f) =
        try
            (:value, f())
        catch err
            (:error, typeof(err), sprint(showerror, err))
        end
    callback=()->nothing
    control=LibTmux._CriterionTraversal{Function}(callback, 0, nothing, nothing)
    texts=["éx", "é😀end", repeat("a", 32767)*"😀suffix", String(UInt8[0xff, 0xc2, 0x80])]
    needles=[
        "",
        "😀",
        "suffix",
        String(UInt8[0xa9]),
        String(UInt8[0xc3]),
        String(UInt8[0xa9, 0x78]),
    ]
    @test all(
        outcome(() -> LibTmux._matches(operator(needle), text, control)) ==
        outcome(() -> LibTmux._matches(operator(needle), text)) for
        operator in (Filters.Contains, Filters.StartsWith, Filters.EndsWith),
        text in texts,
        needle in needles
    )
end

module MutableTextFallback
using LibTmux, Test
mutable struct PressureChangingText
    reads::Int
end
LibTmux._observation_entity(::Type{PressureChangingText}) = :pane
function Base.getproperty(row::PressureChangingText, name::Symbol)
    name===:title || return getfield(row, name)
    row.reads+=1
    row.reads==1 ? "work" : SubString("work", 1, 4)
end
@testset "controlled text preserves mutable caller fallback" begin
    q=PaneWhere(title=Filters.Contains("work"))
    row=PressureChangingText(0)
    @test length(filter(q, Selection([row])))==1
    row.reads=0
    @test length(LibTmux._filter_where(q, Selection([row]), ()->nothing))==1
end
end

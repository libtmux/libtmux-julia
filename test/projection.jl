@testset "explicit scalar projection retains captured coverage and schema" begin
    @test isdefined(LibTmux, :project_rows)
    if isdefined(LibTmux, :project_rows)
        ps = panes(criteria_fixture())
        rows = project_rows(ps; columns=(:id, :current_command, :width))
        @test rows[1] == (id=PaneID("%1"), current_command="nvim", width=120)
        @test rows[2].current_command === nothing
        @test collect(rows) isa Vector{<:NamedTuple}
        @test snapshotof(rows) === snapshotof(ps)
        empty_rows =
            project_rows(filter(_ -> false, ps); columns=(:id, :current_command, :width))
        @test eltype(empty_rows) == eltype(rows)
        @test isempty(empty_rows)
        @test_throws ArgumentError project_rows(ps; columns=(:id, :id))
        @test_throws ArgumentError project_rows(ps; columns=(:window,))
        @test_throws ArgumentError project_rows(ps; columns=(:transport,))
        @test_throws ArgumentError project_rows(ps; columns=())
        @test_throws Exception setindex!(rows, rows[1], 1)
        @test similar(rows, Int, (2,)) isa Vector{Int}
        incomplete = LibTmux._build_snapshot(
            snapshotof(ps).identity;
            complete=true,
            acquired=(1, 2),
            windows=[(id="@1",)],
            panes=[(id="%1", window_id="@1")],
        )
        @test_throws SnapshotCoverageError project_rows(
            panes(incomplete);
            columns=(:current_command,),
        )
    end
end

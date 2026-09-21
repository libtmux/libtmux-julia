using Tables

@testset "Tables projection preserves empty columns" begin
    @test isdefined(LibTmux, :project_rows)
    if isdefined(LibTmux, :project_rows)
        ps = panes(criteria_fixture())
        rows = project_rows(ps; columns=(:id, :current_command))
        @test Tables.istable(typeof(rows))
        @test Tables.rowaccess(typeof(rows))
        @test Tables.columntable(rows) == (
            id=PaneID.(["%1", "%2", "%3"]),
            current_command=Union{Nothing,String}["nvim", nothing, "julia"],
        )
        empty_rows = project_rows(filter(_ -> false, ps); columns=(:id, :current_command))
        @test Tables.schema(empty_rows).names == (:id, :current_command)
        @test Tables.schema(empty_rows).types == (PaneID, Union{Nothing,String})
        empty_columns = Tables.columntable(empty_rows)
        @test empty_columns isa NamedTuple{(:id, :current_command)}
        @test eltype(empty_columns.current_command) == Union{Nothing,String}
        @test isempty(empty_columns.id)
    end
end

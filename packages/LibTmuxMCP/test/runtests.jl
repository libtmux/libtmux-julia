include(joinpath(@__DIR__, "..", "..", "..", "dev", "test-diagnostics.jl"))
using Test
finish_test_imports()

mode = isempty(ARGS) ? "all" : only(ARGS)
mode in ("unit", "integration", "observation", "effects", "discovery", "all") ||
    error("expected unit, integration, observation, effects, discovery, or all")
isempty(ARGS) && push!(ARGS, mode)

files = String[]
mode in ("unit", "all") && append!(files, ["adapter.jl", "stdio.jl", "cli.jl"])
push!(files, "tools.jl")
mode in ("unit", "integration", "discovery", "all") && push!(files, "discovery.jl")
mode in ("unit", "discovery", "all") && push!(files, "discovery_cooperation.jl")
if CI_TEST_DIAGNOSTICS !== nothing || get(ENV, "LIBTMUX_TEST_INVENTORY_ONLY", "0") == "1"
    inventory = [joinpath(@__DIR__, file) for file in files]
    mode in ("effects", "integration", "all") &&
        push!(inventory, joinpath(@__DIR__, "effects.jl"))
    declare_test_files(inventory)
end
for file in files
    # Each suite has its own imported SDK/core names and transport fixtures.
    include_test_file(Module(gensym(:MCPTest)), joinpath(@__DIR__, file))
end
finish_test_diagnostics()

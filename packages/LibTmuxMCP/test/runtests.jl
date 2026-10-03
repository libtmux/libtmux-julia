using Test

mode = isempty(ARGS) ? "all" : only(ARGS)
mode in ("unit", "integration", "observation", "effects", "discovery", "all") ||
    error("expected unit, integration, observation, effects, discovery, or all")
isempty(ARGS) && push!(ARGS, mode)

files = String[]
mode in ("unit", "all") && append!(files, ["adapter.jl", "stdio.jl", "cli.jl"])
push!(files, "tools.jl")
mode in ("unit", "integration", "discovery", "all") && push!(files, "discovery.jl")
for file in files
    # Each suite has its own imported SDK/core names and transport fixtures.
    Base.include(Module(gensym(:MCPTest)), joinpath(@__DIR__, file))
end

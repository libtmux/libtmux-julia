include(joinpath(@__DIR__, "..", "..", "..", "dev", "test-diagnostics.jl"))
using Test
finish_test_imports()

mode = isempty(ARGS) ? "all" : only(ARGS)
mode in (
    "unit",
    "integration",
    "observation",
    "effects",
    "discovery",
    "capabilities",
    "old-daemon",
    "all",
) || error(
    "expected unit, integration, observation, effects, discovery, capabilities, old-daemon, or all",
)
isempty(ARGS) && push!(ARGS, mode)

files = String[]
mode in ("unit", "all") && append!(files, ["adapter.jl", "stdio.jl", "cli.jl"])
if mode == "old-daemon"
    push!(files, "old_daemon.jl")
elseif mode != "capabilities"
    push!(files, "tools.jl")
end
mode in ("unit", "integration", "discovery", "all") && push!(files, "discovery.jl")
mode in ("integration", "all") && push!(files, "old_daemon.jl")
mode in ("unit", "discovery", "all") && push!(files, "discovery_cooperation.jl")
mode in ("integration", "capabilities", "all") && push!(files, "capabilities.jl")
for file in files
    # Each suite has its own imported SDK/core names and transport fixtures.
    include_test_file(Module(gensym(:MCPTest)), joinpath(@__DIR__, file))
end
finish_test_diagnostics()

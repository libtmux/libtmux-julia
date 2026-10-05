include(joinpath(@__DIR__, "..", "..", "..", "dev", "test-diagnostics.jl"))
using Test

if get(ENV, "LIBTMUX_TEST_COMPILER_CACHE", "0") == "1"
    import LibTmuxWorkspaceCheckCompiler
end
finish_test_imports()

suite = isempty(ARGS) ? "unit" : only(ARGS)
suite in ("unit", "integration", "cli", "all") || error("unknown workspace suite")
files = String[]
suite in ("unit", "all") &&
    append!(files, ["config", "script", "readiness", "cli", "cli_signal"])
suite in ("integration", "all") &&
    append!(files, ["apply", "apply_failure", "apply_cancel"])
if suite in ("cli", "all")
    # Outer: launches installed CLI consumers, including their Julia startup.
    push!(files, "cli_integration")
end
if CI_TEST_DIAGNOSTICS !== nothing || get(ENV, "LIBTMUX_TEST_INVENTORY_ONLY", "0") == "1"
    inventory = [joinpath(@__DIR__, file * ".jl") for file in files]
    "cli" in files && push!(inventory, joinpath(@__DIR__, "cli_output.jl"))
    "cli_integration" in files &&
        push!(inventory, joinpath(@__DIR__, "cli_backpressure.jl"))
    declare_test_files(inventory)
end
for file in files
    path = joinpath(@__DIR__, file * ".jl")
    if isdefined(@__MODULE__, :LibTmuxWorkspaceCheckCompiler) &&
       hasproperty(LibTmuxWorkspaceCheckCompiler.FILE_CHECKS, Symbol(file))
        run_test_file(path) do
            LibTmuxWorkspaceCheckCompiler.run_file(file)
        end
    else
        include_test_file(@__MODULE__, path)
    end
end
finish_test_diagnostics()

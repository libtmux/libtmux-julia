include(joinpath(@__DIR__, "..", "dev", "test-diagnostics.jl"))
using Test
using LibTmux

if get(ENV, "LIBTMUX_TEST_COMPILER_CACHE", "0") == "1"
    import LibTmuxCoreCheckCompiler
end
finish_test_imports()

const UNIT_FILES = (
    "server",
    "process",
    "cancellation",
    "text",
    "model",
    "lookup",
    "criteria",
    "criteria_cooperation",
    "wire",
    "sibling_wire",
    "projection",
    "format_rows",
    "options_catalog",
    "control_protocol",
)
const INTEGRATION_FILES = (
    "fixture_contract",
    "named_tmux",
    "lifecycle",
    "integration",
    "acquisition",
    "operations",
    "pane_io",
    "topology",
    "configuration",
    "formats",
    "control",
    "batches",
    "observation",
    "waits",
    "observation_adversaries",
    "restart",
    "control_io",
    "control_operations",
    "control_topology",
    "control_clients",
    "control_formats",
    "control_configuration",
    "control_options",
    "control_buffers",
)

suite = isempty(ARGS) ? "all" : only(ARGS)
files = if suite == "all"
    (UNIT_FILES..., INTEGRATION_FILES...)
elseif suite == "unit"
    UNIT_FILES
elseif suite == "integration"
    INTEGRATION_FILES
elseif suite in (UNIT_FILES..., INTEGRATION_FILES...)
    suite in ("wire", "sibling_wire", "projection") ? ("criteria", suite) : (suite,)
else
    error("expected unit, integration, all, or a test file stem")
end
if CI_TEST_DIAGNOSTICS !== nothing || get(ENV, "LIBTMUX_TEST_INVENTORY_ONLY", "0") == "1"
    inventory = [joinpath(@__DIR__, file * ".jl") for file in files]
    "process" in files && push!(inventory, joinpath(@__DIR__, "process_retirement.jl"))
    "lifecycle" in files && push!(inventory, joinpath(@__DIR__, "lifecycle_retirement.jl"))
    declare_test_files(inventory)
end
for file in files
    if isdefined(@__MODULE__, :LibTmuxCoreCheckCompiler) &&
       hasproperty(LibTmuxCoreCheckCompiler.FILE_CHECKS, Symbol(file))
        run_test_file(joinpath(@__DIR__, file * ".jl")) do
            LibTmuxCoreCheckCompiler.run_file(file)
        end
    else
        include_test_file(@__MODULE__, joinpath(@__DIR__, file * ".jl"))
    end
end
finish_test_diagnostics()

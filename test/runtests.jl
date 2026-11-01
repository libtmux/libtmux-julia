include(joinpath(@__DIR__, "..", "dev", "test-diagnostics.jl"))
using Test
using LibTmux

finish_test_imports()

const UNIT_FILES = (
    "server",
    "sandbox",
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
    "support_versions",
    "support_capabilities",
)
const INTEGRATION_FILES = (
    "fixture_contract",
    "sandbox_client",
    "sandbox_sweep",
    "named_tmux",
    "lifecycle",
    "support_check",
    "support_unreadable",
    "features",
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
    "screen_waits",
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
elseif suite == "rejection"
    ("support_rejection",)
elseif suite == "old-daemon"
    ("support_unreadable",)
elseif suite in (UNIT_FILES..., INTEGRATION_FILES...)
    suite in ("wire", "sibling_wire", "projection") ? ("criteria", suite) : (suite,)
else
    error("expected unit, integration, rejection, old-daemon, all, or a test file stem")
end
# Control acquisition needs tmux 3.7; below it the control suites are skipped
# and features.jl tests the refusal itself.
const CONTROL_FILES = (
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
control_supported = LibTmux._version_at_least(
    last(split(readchomp(`$(get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) -V`))),
    LibTmux.CONTROL_MINIMUM_TMUX,
)
if !control_supported && any(file -> file in CONTROL_FILES, files)
    @warn "control suites skipped: the test tmux is below $(LibTmux.CONTROL_MINIMUM_TMUX)"
    files = filter(file -> !(file in CONTROL_FILES), files)
end
if any(file -> file in INTEGRATION_FILES, files) && !("fixture_contract" in files)
    include("support/owned_tmux.jl")
    using .OwnedTmux
end
for file in files
    include_test_file(@__MODULE__, joinpath(@__DIR__, file * ".jl"))
end
finish_test_diagnostics()

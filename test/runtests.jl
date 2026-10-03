using Test
using LibTmux

const UNIT_FILES = (
    "server",
    "process",
    "cancellation",
    "text",
    "model",
    "criteria",
    "wire",
    "sibling_wire",
    "projection",
    "format_rows",
    "options_catalog",
    "control_protocol",
    "support_versions",
)
const INTEGRATION_FILES = (
    "fixture_contract",
    "named_tmux",
    "lifecycle",
    "support_check",
    "support_unreadable",
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
for file in files
    include(file * ".jl")
end

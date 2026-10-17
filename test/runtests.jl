using Test
using LibTmux

suite = isempty(ARGS) ? "all" : only(ARGS)
suite in ("unit", "integration", "rejection", "all") ||
    error("suite must be unit, integration, rejection or all")
if suite in ("unit", "all")
    include("server.jl")
    include("process.jl")
    include("cancellation.jl")
    include("text.jl")
    include("model.jl")
    include("criteria.jl")
    include("wire.jl")
    include("sibling_wire.jl")
    include("projection.jl")
    include("format_rows.jl")
    include("options_catalog.jl")
    include("control_protocol.jl")
    include("support_versions.jl")
end
if suite in ("integration", "all")
    # Control acquisition needs tmux 3.7; below it the control suites are skipped and
    # the refusal itself is tested by features.jl.
    control_supported = LibTmux._version_at_least(
        last(split(readchomp(`$(get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) -V`))),
        LibTmux.CONTROL_MINIMUM_TMUX,
    )
    control_supported ||
        @warn "control suites skipped: the test tmux is below $(LibTmux.CONTROL_MINIMUM_TMUX)"
    include("fixture_contract.jl")
    include("named_tmux.jl")
    include("lifecycle.jl")
    include("support_check.jl")
    include("support_unreadable.jl")
    include("features.jl")
    include("integration.jl")
    include("acquisition.jl")
    include("operations.jl")
    include("pane_io.jl")
    include("topology.jl")
    include("configuration.jl")
    include("formats.jl")
    control_supported && include("control.jl")
    control_supported && include("batches.jl")
    control_supported && include("observation.jl")
    control_supported && include("observation_adversaries.jl")
    control_supported && include("restart.jl")
    control_supported && include("control_io.jl")
    control_supported && include("control_operations.jl")
    control_supported && include("control_topology.jl")
    control_supported && include("control_clients.jl")
    control_supported && include("control_formats.jl")
    control_supported && include("control_configuration.jl")
    control_supported && include("control_options.jl")
    control_supported && include("control_buffers.jl")
end
if suite == "rejection"
    # Run against a tmux executable below the supported floor.
    include("support_rejection.jl")
end

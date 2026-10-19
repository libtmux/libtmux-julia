include(joinpath(@__DIR__, "..", "..", "..", "dev", "test-diagnostics.jl"))
using Test

finish_test_imports()

suite = isempty(ARGS) ? "unit" : only(ARGS)
suite in ("unit", "integration", "cli", "old-daemon", "all") ||
    error("unknown workspace suite")
files = String[]
suite in ("unit", "all") &&
    append!(files, ["config", "script", "readiness", "cli", "cli_signal"])
suite in ("integration", "all") &&
    append!(files, ["apply", "apply_failure", "apply_cancel"])
if suite in ("cli", "all")
    # Outer: launches installed CLI consumers, including their Julia startup.
    push!(files, "cli_integration")
end
if suite in ("integration", "old-daemon", "all")
    # Needs real builds; skips unless LIBTMUX_TEST_TMUX and the client are set.
    push!(files, "old_daemon")
end
for file in files
    include_test_file(@__MODULE__, joinpath(@__DIR__, file * ".jl"))
end
finish_test_diagnostics()

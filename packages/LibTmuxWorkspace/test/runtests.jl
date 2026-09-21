using Test

suite = isempty(ARGS) ? "unit" : only(ARGS)
suite in ("unit", "integration", "cli", "all") || error("unknown workspace suite")
if suite in ("unit", "all")
    include("config.jl")
    include("script.jl")
    include("readiness.jl")
    include("cli.jl")
    include("cli_signal.jl")
end
if suite in ("integration", "all")
    include("apply.jl")
    include("apply_failure.jl")
    include("apply_cancel.jl")
end
if suite in ("cli", "all")
    # Outer: launches installed CLI consumers, including their Julia startup.
    include("cli_integration.jl")
end

using Test

if get(ENV, "LIBTMUX_TEST_COMPILER_CACHE", "0") == "1"
    import LibTmuxWorkspaceCheckCompiler
end

suite = isempty(ARGS) ? "unit" : only(ARGS)
suite in ("unit", "integration", "cli", "all") || error("unknown workspace suite")
if suite in ("unit", "all")
    if isdefined(@__MODULE__, :LibTmuxWorkspaceCheckCompiler)
        LibTmuxWorkspaceCheckCompiler.run_file("config")
    else
        include("config.jl")
    end
    if isdefined(@__MODULE__, :LibTmuxWorkspaceCheckCompiler)
        LibTmuxWorkspaceCheckCompiler.run_file("script")
    else
        include("script.jl")
    end
    if isdefined(@__MODULE__, :LibTmuxWorkspaceCheckCompiler)
        LibTmuxWorkspaceCheckCompiler.run_file("readiness")
    else
        include("readiness.jl")
    end
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

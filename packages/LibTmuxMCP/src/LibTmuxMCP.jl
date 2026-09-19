"""
    LibTmuxMCP

MCP consumer of LibTmux. Application integration is in progress.
"""
module LibTmuxMCP

import LibTmux
import JSON
import ModelContextProtocol as SDK
using Logging
using PrecompileTools: @setup_workload, @compile_workload

export Application, tools, serve, main, install_cli

include("adapter.jl")
include("stdio.jl")
include("tools.jl")
include("cli.jl")
include("precompile.jl")

end

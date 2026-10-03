"""
    LibTmuxMCP

MCP tools over explicit tmux endpoints with bounded stdio, cancellation
and application-owned session cleanup.
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

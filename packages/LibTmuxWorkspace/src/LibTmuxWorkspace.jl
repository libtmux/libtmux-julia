"""
Parse, validate, expand and plan tmuxp-style workspaces without starting tmux.
YAML and JSON are consumer dependencies; the core remains independent.
"""
module LibTmuxWorkspace

import LibTmux
import JSON
import YAML
using PrecompileTools: @setup_workload, @compile_workload
using FileWatching: FolderMonitor
using UUIDs: uuid4
using Base64: base64encode

export ConfigLimits,
    WorkspaceConfigError,
    WorkspaceDocument,
    WorkspaceConfig,
    WindowConfig,
    PaneConfig,
    CommandConfig,
    ExpandedWorkspace,
    ExpandedWindow,
    ExpandedPane,
    PlanStep,
    WorkspacePlan,
    parse_config,
    read_config,
    validate,
    expand,
    plan,
    run_before_script,
    ScriptResult,
    BeforeScriptError,
    apply,
    freeze,
    WorkspaceApplyResult,
    WorkspaceApplyError,
    main,
    install_cli

include("config.jl")
include("parser.jl")
include("plan.jl")
include("script.jl")
include("apply.jl")
include("cli.jl")
include("precompile.jl")

end

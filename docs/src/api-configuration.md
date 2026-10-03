# Configuration and formats

Inspect or change options, hooks, and environment variables, or evaluate
tmux formats against an exact target. The [ownership guide](ownership.md)
explains live target validation and transport budgets.

## Options, hooks, and environment

```@autodocs
Modules = [LibTmux]
Pages = ["src/configuration.jl", "src/control_configuration.jl", "src/control_options.jl"]
Private = false
Order = [:module, :type, :function]
```

## Formats

```@autodocs
Modules = [LibTmux]
Pages = ["src/formats.jl", "src/control_formats.jl"]
Private = false
Order = [:module, :type, :function]
```

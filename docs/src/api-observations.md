# Observations and waits

Observe control events and pane output, then wait for text or a quiet period
within a shared deadline. The [output observation guide](observations.md)
explains stream ownership, cursors, decoding, and completion limits.

## Output streams and control events

```@autodocs
Modules = [LibTmux]
Pages = ["src/observation.jl", "src/control_io.jl"]
Private = false
Order = [:module, :type, :function]
```

## Output waits

```@autodocs
Modules = [LibTmux]
Pages = ["src/waits.jl"]
Private = false
Order = [:module, :type, :function]
```

## Text decoding

```@autodocs
Modules = [LibTmux]
Pages = ["src/text.jl"]
Private = false
Order = [:module, :type, :function]
```

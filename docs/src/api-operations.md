# Pane and window operations

Create and select entities, send input, capture output, and change window
topology. Mutation uses live entity references; the [ownership
guide](ownership.md) describes target validation and command completion.

## Creation and selection

```@autodocs
Modules = [LibTmux]
Pages = ["src/operations.jl", "src/control_operations.jl"]
Private = false
Order = [:module, :type, :function]
```

## Pane input, capture, and paste buffers

`BufferRef(identity, BufferID(name))` binds a buffer name to an observed
[`ServerIdentity`](@ref). Prefer the reference returned by [`load_buffer`](@ref)
or [`BufferInfo`](@ref). Loading transfers ownership to the caller; listing
returns borrowed references and does not reserve a buffer against replacement.

```@raw html
<p>Included source: <a href="../source/src/pane_io.jl.html#L16">buffer reference alias</a>.</p>
```

```@autodocs
Modules = [LibTmux]
Pages = ["src/pane_io.jl", "src/control_buffers.jl"]
Private = false
Order = [:module, :type, :function]
```

## Topology and client focus

```@autodocs
Modules = [LibTmux]
Pages = ["src/topology.jl", "src/control_topology.jl", "src/control_clients.jl"]
Private = false
Order = [:module, :type, :function]
```

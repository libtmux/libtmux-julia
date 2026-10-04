# Start with an owned tmux server

LibTmux separates remote operations from captured data. Create an owned
daemon for a script, or explicitly select a borrowed endpoint. Remote
functions yield on I/O and work in ordinary Julia Tasks.

This manual follows `v0.1.0-alpha.1`, an unregistered source release. Start
with [Install](installation.md), then return here for an owned-server program.
Product compatibility and the MCP/workspace applications remain under
verification; see [Compatibility](compatibility.md).

The following source is the executable `examples/owned_capture.jl` program.
It creates a session, captures the initial screen and asserts daemon cleanup.

```@eval
using Markdown
example = joinpath(@__DIR__, "..", "..", "examples", "owned_capture.jl")
Markdown.parse("```julia\n" * read(example, String) * "\n```")
```

Use [`Server`](@ref) for a borrowed endpoint. Neither construction nor local
snapshot reads contact tmux. [`from_env`](@ref) is the explicit opt-in to
ambient server selection. [`with_server`](@ref) owns its daemon; ordinary
server values do not.

Next, read [Captured queries](queries.md) for filtering and shared windows,
or [Ownership and I/O](ownership.md) for effects, cancellation and control.

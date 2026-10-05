# Changelog

## Unreleased

#### Captured queries and scoped snapshots

Find sessions, windows, and panes in captured snapshots, including linked
windows and contextual occurrences. Resolve captured references and inspect
process, history, layout, and activity fields. (#5)

#### Output waits and pane maintenance

Wait for text, application readiness, or output quietness with bounded
stream handling and cancellation. Manage pane history, titles, layouts,
zoom, movement, and output pipes through explicit operations. (#5)

#### Configuration and buffer inventories

Inspect options, hooks, environment variables, and buffers on an explicitly
selected server. Inventories preserve sparse values and distinguish owned
resources from borrowed resources. (#5)

#### MCP discovery and effects

Find the intended pane with scoped criteria, requested fields, and
pagination. MCP waits reuse the core output contract, and tool results
report possible effects across complete calls and partial batches. (#5)

#### Task-oriented documentation

Navigate API references by server, query, operation, observation, and
configuration tasks. Examples cover owned and borrowed targeting,
completion, and coordination with executable snippets. (#5)

#### Compatibility checks and benchmarks

Linux CI requires complete floor/current toolchain checks with one and
four threads; macOS checks are supplementary. Aggregate check budgets
and normal-compiler graph benchmarks expose timing and memory costs. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial Julia package suite

Add `LibTmux`, a Julia-native tmux core with explicit server selection,
captured snapshots, callable criteria, and direct or control-mode operations.
Add `LibTmuxMCP` for local stdio tools and `LibTmuxWorkspace` for planning,
applying, and freezing the documented tmuxp-compatible YAML/JSON subset through
a CLI. The suite includes runnable examples, documentation, benchmarks,
and a selected Julia/tmux CI matrix. (#1)

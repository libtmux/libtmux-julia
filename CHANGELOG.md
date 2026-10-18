# Changelog

## Unreleased

#### Require tmux 3.3a

`LibTmux` requires tmux 3.3a or newer, judged by the running tmux server's
version rather than the `tmux` executable's. Commands, owned server startup,
control attachment and the `LibTmuxWorkspace` attach refuse a server below
3.3a, including 3.3 and anything before 3.2, and a version report that names
no release, with `UnsupportedTmuxVersion` before the command has any effect.
Upgrade tmux and restart the server, or pin the previous release.
`kill-server` on an absent endpoint does nothing. The first command to an
endpoint reads the release; later commands skip the read, and a replaced or
vanished server drops the remembered release. `UnsupportedTmuxVersion` and
`MINIMUM_TMUX_VERSION` are new exports. (#17)

#### The version check runs no user hooks

Reading the server's version no longer runs a user's `after-display-message`
hook, and a server replaced after the check is refused before any command
runs. A control attach compares the server's identity without a hook too.
(#17)

#### Commands return when an exited client's pipes stay silent

`run_command` returns the output read so far once a client has exited and its
pipes stay silent for 250 ms. A tmux 3.0a or 3.1c server that keeps the
client's stdout open no longer holds the call until its deadline. (#17)

#### The option catalog starts at tmux 3.3a

The catalog drops its 3.2a and 3.3 metadata. `allow-passthrough`,
`destroy-unattached`, `pane-active-border-style` and `pane-border-style` still
need an exact pinned release. `window-linked`, `window-unlinked` and
`pane-border-format` are stable entries with one scope, and the catalog refuses
releases below the floor. (#17)

#### Captured queries and scoped snapshots

Query captured sessions, windows and panes with linked-window context and
scoped snapshots. Resolve captured references and inspect process, history,
layout and activity fields through Julia collections. (#5)

#### Output waits and pane operations

Wait for text, a predicate or received-output quietness with a shared deadline
and cancellation. Manage pane history, titles, layouts, zoom, movement and
output pipes through explicit operations. (#5)

#### Configuration and buffer inventories

Inspect options, hooks, environment variables and buffers on an explicitly
selected server. Preserve sparse values and resource ownership when managing
tmux configuration. (#5)

#### MCP discovery and effects

Find panes with scoped captured criteria, selected fields and pagination. Tool
results report possible tmux effects across configured hooks, cancellation and
partial batches. (#5)

#### API guides and source installation

Install the package suite from public source revisions. Follow API guides
organized by task and executable examples for owned or borrowed targets,
command completion and coordination. (#5)

#### CI diagnostics and scaling benchmarks

Inspect live named test progress, ranked timings and sanitized failure
artifacts in CI, with CPU samples on current Julia. Progress remains available
when sampling is disabled. Independent files continue after test failures and
soft overruns; hard limits stop work and retain partial evidence. Benchmark
captured-query scaling and process memory. (#5)

#### tmux 3.8 snapshots and layouts

Capture panes whose process ID is absent without losing the surrounding
snapshot. Reapply captured JSON layouts through direct and control clients,
with release checks before layout changes. (#5)

#### Bounded command execution

Read large inventories without compilation growing with each command count.
Version checks share the operation deadline. Interrupted control starts retain
the primary failure together with any cleanup failure. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial Julia package suite

Add `LibTmux`, a Julia-native tmux core with explicit server selection,
captured snapshots, callable criteria, and direct or control-mode operations.
Add `LibTmuxMCP` for local stdio tools and `LibTmuxWorkspace` for planning,
applying, and freezing the documented tmuxp-compatible YAML/JSON subset through
a CLI. The suite includes runnable examples, documentation, benchmarks,
and a selected Julia/tmux CI matrix. (#1)

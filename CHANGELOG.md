# Changelog

## Unreleased

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

Inspect live named test progress, ranked timings, CPU profiles and sanitized
failure artifacts in CI. Independent files continue after test failures and
soft overruns; hard limits stop work and retain partial evidence. Benchmark
captured-query scaling and process memory. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial Julia package suite

Add `LibTmux`, a Julia-native tmux core with explicit server selection,
captured snapshots, callable criteria, and direct or control-mode operations.
Add `LibTmuxMCP` for local stdio tools and `LibTmuxWorkspace` for planning,
applying, and freezing the documented tmuxp-compatible YAML/JSON subset through
a CLI. The suite includes runnable examples, documentation, benchmarks,
and a selected Julia/tmux CI matrix. (#1)

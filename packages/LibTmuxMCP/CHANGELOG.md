# Changelog

## Unreleased

#### Scoped discovery

Find panes with captured criteria, selected fields, and paginated results.
Choose session or window scope to discover the intended pane before
capture, input, or waiting. (#5)

#### Whole-call effects and output waits

Tool results distinguish validation-only rejection from calls that may
already have affected tmux, including cancellations and partial batches.
Text and quiet waits share the core stream and deadline contract. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial stdio MCP application

Run a local stdio MCP application against an explicitly selected tmux endpoint.
It exposes discoverable tmux tools with policy-controlled targets, bounded
waits, cancellation, and owned-session teardown. (#1)

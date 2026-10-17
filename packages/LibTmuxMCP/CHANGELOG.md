# Changelog

## Unreleased

#### Scoped discovery

Find panes within a chosen session or window using captured criteria, selected
fields and pagination. Discovery shares the call deadline and cancellation
budget. (#5)

#### Whole-call effects and output waits

Distinguish validation-only rejection from calls that may have affected tmux,
including configured hooks, cancellation and partial batches. Text and quiet
waits share the core stream and deadline contract. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial stdio MCP application

Run a local stdio MCP application against an explicitly selected tmux endpoint.
It exposes discoverable tmux tools with policy-controlled targets, bounded
waits, cancellation, and owned-session teardown. (#1)

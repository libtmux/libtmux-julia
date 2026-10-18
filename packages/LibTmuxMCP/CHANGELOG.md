# Changelog

## Unreleased

## 0.1.0-alpha.2 - 2026-10-18

#### Report refused tmux releases

A tool called against a tmux server below 3.3a, or one that reports no known
release, fails with the new error code `unsupported_tmux` and `effects:
none`, and `libtmux-mcp` exits at startup with the same remedy. `--help` names
the minimum release. (#17)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial stdio MCP application

Run a local stdio MCP application against an explicitly selected tmux endpoint.
It exposes discoverable tmux tools with policy-controlled targets, bounded
waits, cancellation, and owned-session teardown. (#1)

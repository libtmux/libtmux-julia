# Changelog

## Unreleased

#### Large workspace plans

Reduce compilation costs when planning large pane lists. Preserve pane order
and repeated commands. (#5)

#### Command output and failures

Stream workspace progress while preserving application failures when output
stops. Retain failure details and cleanup of owned resources. (#5)

#### Source installation

Install the workspace package from a resolvable public source revision. Follow
executable setup commands with explicit Julia and tmux requirements. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial workspace loader and CLI

Load the documented tmuxp-compatible YAML or JSON subset into an inspectable
plan, apply it to an explicitly selected tmux server, and freeze supported
workspaces. The separate CLI produces human-readable, JSON, or NDJSON
results. (#1)

# Changelog

## Unreleased

#### Require tmux 3.3a for core operations

Raise the minimum tmux release for ordinary operations to 3.3a. Every
subprocess command first reads the connected daemon's release, not the
client's `-V` report, without firing a user hook, and runs behind a fence on
that release. A daemon below 3.3a, such as 3.2a or the unpatched 3.3, an
unreadable release, or a daemon replaced after the version check raises
`UnsupportedTmuxVersion` before the command has any effect. Owned daemon
startup, control attachment and the workspace CLI's attach check the same
floor. `kill-server` on an absent endpoint does nothing. The generated option
catalog drops its 3.2a profile. (#13)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial Julia package suite

Add `LibTmux`, a Julia-native tmux core with explicit server selection,
captured snapshots, callable criteria, and direct or control-mode operations.
Add `LibTmuxMCP` for local stdio tools and `LibTmuxWorkspace` for planning,
applying, and freezing the documented tmuxp-compatible YAML/JSON subset through
a CLI. The suite includes runnable examples, documentation, benchmarks,
and a selected Julia/tmux CI matrix. (#1)

# Changelog

## Unreleased

#### Gate optional tmux features by release

Refuse control acquisition below tmux 3.7 and loading or deleting a named
buffer below 3.4 with `UnsupportedCapability`, before the operation has any
effect, and reject `:` and `.` in session and window names on tmux 3.7.
Pasting and workspace commands keep working on 3.3a: before 3.4 the paste
deletes its own staging buffer. Subprocess operations stay available on 3.3a.
Mirrored layouts now accept pre-release builds. (#14)

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

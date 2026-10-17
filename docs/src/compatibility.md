# Compatibility

| Boundary | Current evidence |
| --- | --- |
| Julia / tmux | 1.10.0 / 3.3a and 1.13.0 / 3.7c in the listed CI cells |
| Linux x86_64 | 1.10.0 / 3.3a / 1 thread and 1.13.0 / 3.7c / 4 threads passed |
| macOS arm64 | 1.13.0 / 3.7c / 1 thread passed |
| macOS x86_64 | 1.13.0 / 3.7c / 1 thread passed |
| Full package suite | Core, MCP, workspace, extensions, documentation, external imports, examples and launchers passed in all listed cells |

These are exact CI cells, not a promise for other Julia, tmux, platform,
architecture or thread combinations. An independent guide walkthrough and
benchmark baselines remain open.

The minimum tmux release for ordinary operations is 3.3a. Every subprocess
command first reads the connected daemon's release, not the client's `-V`
report, and runs behind a fence on that release; a typed operation reads the release once and the fence still checks each of its commands. A daemon below 3.3a, an
unreadable release, or a daemon replaced after the version check raises
[`UnsupportedTmuxVersion`](@ref) before the command has any effect. Reading
the release fires no `after-*` or `command-error` hook. An endpoint with no
daemon is checked against the `-V` report of the executable that would start it,
and `kill-server` on such an endpoint does nothing. Releases are compared with
their patch letters, so 3.3 is below the floor; `next-X.Y` and `X.Y-rc` rank
below `X.Y`, and a bare `master` or OpenBSD report names no release and is
refused as unrecognized. A daemon older than 3.2 has no `run-shell -C` and is
refused as unsupported the same way. Each refusal says to upgrade tmux and
restart the server, or pin the previous libtmux release. CI keeps 3.2a and 3.3
as rejection cells that assert this refusal and that nothing changed.

The repository capability manifest records implemented, deferred, excluded
and untested surfaces. tmux letter suffixes are meaningful; `3.3a` is not
silently normalized to `3.3`.

## Optional features above the floor

Some operations need a newer daemon than the 3.3a floor. Each requirement
belongs to its operation, is decided from the connected daemon before the
operation has an effect, and raises `UnsupportedCapability` naming the release.
Ordinary subprocess operations stay available on 3.3a.

| Feature | Requirement | Below it | State |
| --- | --- | --- | --- |
| Control acquisition: `open_control`, control batches, output streams, format subscriptions and the MCP waiting tools | tmux 3.7 | Refused before any attach client starts | The refusal is qualified; concurrent acquisition on 3.7 and later is unverified |
| Named-buffer deletion: `load_buffer` and `delete_buffer` | tmux 3.4 | Refused before any buffer exists | The refusal is qualified |
| `:` or `.` in session and window names | Not tmux 3.7 | Refused for that exact release before dispatch | The refusal is qualified |
| Mirrored layouts | tmux 3.5 | Refused before dispatch | Qualified |

Short control attaches crash tmux servers before 3.7, which is why acquisition
is decided first. Exact-name buffer deletion can act on an unrelated buffer
before 3.4 when the name is missing. Layout strings are validated before
dispatch on every release, because 3.3a crashes on an invalid one.

`paste_bytes`, `paste_text` and workspace commands that paste work on 3.3a.
Before 3.4 the paste itself deletes its staging buffer (`paste-buffer -d`),
because deleting by a missing name can take an unrelated buffer; a paste that
fails after the buffer was loaded leaves that one named buffer behind. The
library does not capture `run-shell` output or call `break-pane`, so those
release restrictions do not apply, and it keeps no short socket alias because
it does not attach to sockets outside its owned directories.

Local POSIX tmux is the initial transport scope. SSH, native Windows tmux,
private tmux imsg access and Python workspace plugins are excluded. Query
pushdown, portable regex/Unicode folding, general execution DAGs and remote
MCP HTTP remain deferred. Native Julia regex works in ordinary local predicates.

The core uses standard libraries. JSON/Tables integrations are package
extensions; MCP and workspace dependencies remain in their separate packages.
Julia compatibility declarations are resolver constraints, not test evidence.

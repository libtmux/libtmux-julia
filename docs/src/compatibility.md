# Compatibility

| Boundary | Current evidence |
| --- | --- |
| Julia / tmux | 1.10.0 / 3.3a, 1.13.1 / 3.7c and 1.13.1 / 3.8 on Linux, and 1.13.0 / 3.7c on macOS, in the listed CI cells |
| Linux x86_64 | 1.10.0 / 3.3a / 1 thread, 1.13.1 / 3.7c / 4 threads and 1.13.1 / 3.8 / 1 thread passed in Julia workflow run 39157326487 |
| macOS arm64 | 1.13.0 / 3.7c / 1 thread passed |
| macOS x86_64 | 1.13.0 / 3.7c / 1 thread passed |
| Full package suite | Core, MCP, workspace, extensions, documentation, external imports, examples and launchers passed in all listed cells |

These are exact CI cells, not a promise for other Julia, tmux, platform,
architecture or thread combinations. Julia 1.10.0 on tmux 3.3a is the evidence
for the Julia 1.10 floor. An independent guide walkthrough and benchmark
baselines remain open.

The minimum tmux release for ordinary operations is 3.3a. The first
subprocess command to an endpoint reads the connected daemon's release, not
the client's `-V` report. Later commands to the same executable and endpoint
skip that read and rely on a fence: every command runs behind a check on the
release it was admitted for. A daemon below 3.3a, an unreadable release, or a
daemon replaced after the version check raises [`UnsupportedTmuxVersion`](@ref)
before the command has any effect. A fence mismatch, a vanished endpoint or a
tmux 3.1 or older answer drops the remembered release, and the next read
decides. Reading the release fires no `after-*` or `command-error` hook. An
endpoint with no daemon is checked against the `-V` report of the executable
that would start it, and `kill-server` on such an endpoint does nothing.
Releases are compared with their patch letters, so 3.3 is below the floor;
`next-X.Y` and `X.Y-rc` rank below `X.Y`, and a bare `master` or OpenBSD report
names no release and is refused as unrecognized. A daemon or client of tmux 3.1
or older has no `run-shell -C` and is refused as unsupported the same way. Each
refusal says to upgrade tmux and restart the server, or pin the previous
libtmux release. CI keeps 3.0a, 3.1c, 3.2a and 3.3 as rejection cells, each
run behind a 3.3a client, that assert this refusal and that nothing changed.

The repository capability manifest records implemented, deferred, excluded
and untested surfaces. tmux letter suffixes are meaningful; `3.3a` is not
silently normalized to `3.3`.

Local POSIX tmux is the initial transport scope. SSH, native Windows tmux,
private tmux imsg access and Python workspace plugins are excluded. Query
pushdown, portable regex/Unicode folding, general execution DAGs and remote
MCP HTTP remain deferred. Native Julia regex works in ordinary local predicates.

The core uses standard libraries. JSON/Tables integrations are package
extensions; MCP and workspace dependencies remain in their separate packages.
Julia compatibility declarations are resolver constraints, not test evidence.

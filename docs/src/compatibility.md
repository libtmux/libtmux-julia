# Compatibility

The minimums are Julia 1.13.1 and tmux 3.7c. Core, MCP and workspace packages
share these requirements. The higher tmux floor excludes unsafe older control
attachment, named-buffer deletion and session/window name behavior.

Linux is the required platform. CI checks tmux 3.7c at one and four threads and
tmux 3.8 at one thread, using Julia 1.13.1. macOS jobs are optional. An unrun
platform or release is not established support; package resolution alone is
not runtime evidence.

See the [CI runs](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
for the result at a particular commit. The capability manifest retains older
baseline results separately. They do not establish that a newer commit passes.

## Version refusal

The minimum tmux release for ordinary operations is 3.7c. The first
subprocess command to an endpoint reads the connected daemon's release, not
the client's `-V` report. Later commands to the same executable and endpoint
skip that read and rely on a fence: every command runs behind a check on the
release it was admitted for. A daemon below 3.7c, an unreadable release, or a
daemon replaced after the version check raises [`UnsupportedTmuxVersion`](@ref)
before the command has any effect. A fence mismatch, a vanished endpoint or a
tmux 3.1 or older answer drops the remembered release, and the next read
decides. Reading the release fires no `after-*` or `command-error` hook. An
endpoint with no daemon is checked against the `-V` report of the executable
that would start it, and `kill-server` on such an endpoint does nothing.
Releases are compared with their patch letters, so 3.7b is below the floor;
`next-X.Y` and `X.Y-rc` rank below `X.Y`, and a bare `master` or OpenBSD report
names no release and is refused as unrecognized. A daemon or client of tmux 3.1
or older has no `run-shell -C` and is refused as unsupported the same way. Each
refusal says to upgrade tmux and restart the server, or pin the previous
libtmux release. CI keeps 3.0a, 3.1c, 3.3a and 3.6b as rejection cells, each
run behind a 3.7c client, that assert this refusal and that nothing changed.

## Optional capabilities

JSON layouts require tmux 3.8. Unsupported requests raise
`UnsupportedCapability` before dispatch. Layout strings are validated
before being sent to tmux. Other operations use the global 3.7c floor; no
older-release paste fallback or screen-polling wait is retained.

The core uses standard libraries. JSON and Tables integrations are optional
extensions. MCP and workspace dependencies remain in their own packages.

Local POSIX tmux is the transport scope. SSH, native Windows tmux, private
imsg access and Python workspace plugins are excluded. Query pushdown, portable
regex/Unicode folding, general execution DAGs and MCP HTTP remain deferred.
Native Julia regex works in ordinary local predicates.

## Verification

Whole-command times are diagnostic: aim for five seconds for focused checks,
thirty seconds for unit/quality checks and five minutes for the complete outer
checks. A slower correct result remains a pass. The runner stops test work at
fifteen minutes, retires owned processes and preserves partial evidence.
Dependency acquisition and precompilation are measured separately.

Required acceptance covers correctness, installed consumers, shipped examples
and package/documentation checks. Benchmark completion and exhaustive profiling
are separate work.

```@raw html
<p>See <a href="../source/CONTRIBUTING.md.html">the contributor guide</a> and
<a href="../source/docs/capabilities.toml.html">the capability manifest</a>
included in this build for scope and evidence.</p>
```

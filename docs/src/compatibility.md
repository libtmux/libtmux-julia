# Compatibility

The minimums are Julia 1.13.1 and tmux 3.7c. Core, MCP and workspace packages
share these requirements. The higher tmux floor excludes unsafe older control
attachment, named-buffer deletion and session/window name behavior.

CI runs Linux only. It checks tmux 3.7c at one and four threads and tmux 3.8
at one thread, using Julia 1.13.1. macOS and psmux are excluded from CI and
current support. Historical results remain available; they do not expand
the selected scope.

[The retained Linux run](https://github.com/libtmux/libtmux-julia/actions/runs/39333764109)
passed all 26 phases in each of those three cells for PR head `67da6f3`, tested
as merge commit `f0a564f`. No phases were skipped or unrun. Its four older-daemon
rejection jobs also passed. The capability manifest records both revisions and
the tested source digest, with earlier baselines separate. This evidence does
not establish that a later commit passes.

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

MCP CLI startup and wait setup still acquire the full graph within an 8 MiB
reply bound. Larger replies are unsupported at those stages. A discovery scope
narrows a listing; it cannot bypass startup or wait setup.

## Verification

Whole-command times are diagnostic: aim for five seconds for focused checks,
thirty seconds for unit/quality checks and five minutes for the complete outer
checks. A slower correct result remains a pass. The runner stops test work at
fifteen minutes, retires owned processes and preserves partial evidence.
Dependency acquisition and precompilation are measured separately.

Accept a final revision only after its affected correctness, package,
example and documentation checks pass. Fresh consumer projects must install
that source from the documented public GitHub commands and exercise the core,
MCP and workspace flows. Immutable consumer exports do not prove that install.

The shared website build and rendered output require their own verification;
a passing native manual or API export does not establish them. Use the
[CI result for the candidate commit](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
and its public-install evidence. Benchmark completion and exhaustive profiling
are separate work; excluded platforms are not acceptance gates.

```@raw html
<p>See <a href="../source/CONTRIBUTING.md.html">the contributor guide</a> and
<a href="../source/docs/capabilities.toml.html">the capability manifest</a>
included in this build for scope and evidence.</p>
```

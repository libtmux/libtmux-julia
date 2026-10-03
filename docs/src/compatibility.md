# Compatibility

Compatibility evidence belongs to an exact source revision. Complete development
gates remain open; focused correctness checks do not establish full support.

| Evidence | Scope and result |
| --- | --- |
| Baseline correctness | Revision `9e3776d07798174a3590a728d28029efcbb52780`: core, MCP, workspace, extensions, docs, external examples and launchers passed in the original four cells |
| Baseline cells | Linux x86_64: Julia 1.10.0 / tmux 3.2a / 1 thread and Julia 1.13.0 / tmux 3.7c / 4 threads; macOS arm64 and x86_64: Julia 1.13.0 / tmux 3.7c / 1 thread |
| Dependency correctness | Revision `0026771494909372fc3d5f2ea3471e156d340d9a`: Linux Julia 1.10.0 / tmux 3.3a / 1 thread, Julia 1.13.1 / tmux 3.7c / 4 threads and Julia 1.13.1 / tmux 3.8 / 1 thread passed in [dependency CI](https://github.com/libtmux/libtmux-julia/actions/runs/39157326487); this does not establish the current adoption revision or its timing gates |
| Whole-command limits | The baseline and subsequent development run exceed the complete mid/outer budgets; they provide no timing acceptance |
| Required development cells | Linux tmux 3.3a floor and current versions, each at one and four threads, plus tmux 3.8; macOS supplements these checks |
| Remaining acceptance | Final-source full gates, installed task workflows, benchmark limits and independent adoption review |

[Baseline CI](https://github.com/libtmux/libtmux-julia/actions/runs/37125764548)
and [development CI](https://github.com/libtmux/libtmux-julia/actions/runs/37141349711)
retain their individual results. [Contributing](../../CONTRIBUTING.md) defines
the complete checks and budgets. An unrun version or platform is not support;
resolver compatibility declarations are not test evidence.

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

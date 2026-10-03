# Compatibility

Compatibility evidence belongs to an exact source revision. Complete development
gates remain open; focused correctness checks do not establish full support.

| Evidence | Scope and result |
| --- | --- |
| Baseline correctness | Revision `9e3776d07798174a3590a728d28029efcbb52780`: core, MCP, workspace, extensions, docs, external examples and launchers passed in the original four cells |
| Baseline cells | Linux x86_64: Julia 1.10.0 / tmux 3.2a / 1 thread and Julia 1.13.0 / tmux 3.7c / 4 threads; macOS arm64 and x86_64: Julia 1.13.0 / tmux 3.7c / 1 thread |
| Whole-command limits | The baseline and subsequent development run exceed the complete mid/outer budgets; they provide no timing acceptance |
| Required development cells | Linux floor and current versions, each at one and four threads; macOS supplements these checks |
| Remaining acceptance | Final-source full gates, installed task workflows, benchmark limits and independent adoption review |

[Baseline CI](https://github.com/libtmux/libtmux-julia/actions/runs/37125764548)
and [development CI](https://github.com/libtmux/libtmux-julia/actions/runs/37141349711)
retain their individual results. [Contributing](../../CONTRIBUTING.md) defines
the complete checks and budgets. An unrun version or platform is not support;
resolver compatibility declarations are not test evidence.

The [capability manifest](../capabilities.toml) records implemented, deferred,
excluded and untested surfaces. tmux letter suffixes are meaningful; `3.2a`
is not silently normalized to `3.2`.

Local POSIX tmux is the initial transport scope. SSH, native Windows tmux,
private tmux imsg access and Python workspace plugins are excluded. Query
pushdown, portable regex/Unicode folding, general execution DAGs and remote
MCP HTTP remain deferred. Native Julia regex works in ordinary local predicates.

The core uses standard libraries. JSON/Tables integrations are package
extensions; MCP and workspace dependencies remain in their separate packages.

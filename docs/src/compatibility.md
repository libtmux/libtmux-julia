# Compatibility

| Boundary | Current evidence |
| --- | --- |
| Julia / tmux | 1.10.0 / 3.2a and 1.13.0 / 3.7c in the listed CI cells |
| Linux x86_64 | 1.10.0 / 3.2a / 1 thread and 1.13.0 / 3.7c / 4 threads passed |
| macOS arm64 | 1.13.0 / 3.7c / 1 thread passed |
| macOS x86_64 | 1.13.0 / 3.7c / 1 thread passed |
| Full package suite | Core, MCP, workspace, extensions, documentation, external imports, examples and launchers passed in all listed cells |

These are exact CI cells, not a promise for other Julia, tmux, platform,
architecture or thread combinations. An independent guide walkthrough and
benchmark baselines remain open.

The repository capability manifest records implemented, deferred, excluded
and untested surfaces. tmux letter suffixes are meaningful; `3.2a` is not
silently normalized to `3.2`.

Local POSIX tmux is the initial transport scope. SSH, native Windows tmux,
private tmux imsg access and Python workspace plugins are excluded. Query
pushdown, portable regex/Unicode folding, general execution DAGs and remote
MCP HTTP remain deferred. Native Julia regex works in ordinary local predicates.

The core uses standard libraries. JSON/Tables integrations are package
extensions; MCP and workspace dependencies remain in their separate packages.
Julia compatibility declarations are resolver constraints, not test evidence.

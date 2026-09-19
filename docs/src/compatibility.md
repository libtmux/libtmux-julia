# Compatibility

| Boundary | Current evidence |
| --- | --- |
| Julia | Development 1.13.0; focused checks also run on proposed floor 1.10.0 |
| tmux | Focused source/runtime checks on 3.2a and 3.7d |
| Linux x86_64 | Development host; WSL is recorded as Linux |
| macOS arm64/x86_64 | Proposed, not verified |
| Full package suite | In progress; no complete product support matrix |

A passing focused check does not admit an entire platform/version cell.
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

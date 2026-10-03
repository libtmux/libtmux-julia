# Coordinate external work

Choose completion evidence that the producer controls. A matched title, echoed
input or quiet pane does not establish script success. Use the
[command completion example](observations.md) for an authored marker plus child
exit evidence, or workspace `before_script` for a directly owned, reaped child.

Library-owned one-use signals use [`control_signal`](@ref), `wait` and `notify`.
Their names and cleanup belong to the connection. An external process with an
agreed tmux channel can use explicit [`run_command`](@ref) calls to `wait-for`,
`wait-for -S`, `wait-for -L` and `wait-for -U`. The caller owns that protocol.
Only unlock a channel the caller acquired; cancellation does not undo an
acquired lock. tmux locks do not identify a holder for a library finalizer to
verify, so an arbitrary named lock has no automatic ownership wrapper.

## Configure or run host commands

Use `run_command(server, command, arguments...)` for `run-shell`, `if-shell`,
`source-file`, `bind-key` and `unbind-key`. These operations execute tmux or
host-shell grammar. Configuration files and bindings can install lasting hooks
and commands. A reply can acknowledge setup without proving asynchronous child
completion; keep the completion channel or process evidence explicit.

Workspace planning keeps scripts and pane input inert until `apply`.
`before_script` uses argv parsing and bounded process output; intentional shell
syntax requires an explicit shell executable. This covers the shipped workspace
setup task. Raw tmux argv covers external configuration and binding tasks;
additional typed wrappers would need their own execution and ownership contract.
See [Workspace loading](workspaces.md) and [Ownership and I/O](ownership.md).

## Hand a terminal to tmux

An interactive client owns terminal input and output. The workspace launcher's
explicit `--attach` requires terminal stdin/stdout and hands them to tmux after
loading. Scripts can use `switch_client`, `detach_client`, `send_keys` and screen
capture without an implicit terminal handoff. Copy-mode commands and a caller's
own attach process remain explicit tmux tasks; LibTmux does not allocate a PTY.

## Select captured data

Use a scoped snapshot to narrow acquisition, then native collections or inert
criteria to select captured rows. Indexed relationships preserve physical
windows, session links and known coverage. General predicate pushdown stays
deferred until a measured workload needs it; tmux format filtering cannot silently
replace local relation semantics or turn unknown coverage into absence.

Environment reads over control remain refused because their raw replies and
format lookups do not preserve the complete presence, hidden, removal and origin
contract. Use an explicit `Server` read when its identity semantics suffice;
see [the transport matrix](ownership.md).

# Compatibility

The minimums are Julia 1.13.1 and tmux 3.3a. Core, MCP and workspace packages
share these requirements. A few operations need a newer tmux release and refuse
on older ones, as the optional capabilities below list; the rest of the library
keeps working on 3.3a.

CI runs Linux only, using Julia 1.13.1. It checks tmux 3.3a, 3.4, 3.5a, 3.6b,
3.7, 3.7a, 3.7b and 3.7c at one thread, 3.7c at four threads and 3.8 at one
thread. macOS and psmux are excluded from CI and current support.

The [CI result for a commit](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
is the evidence for that commit.

## Version refusal

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

## Optional capabilities

Some operations need a newer daemon than the 3.3a floor. Each requirement
belongs to its operation, is decided from the connected daemon before the
operation has an effect, and raises `UnsupportedCapability` naming the
release. Ordinary subprocess operations stay available on 3.3a.

| Feature | Requirement | Below it | State |
| --- | --- | --- | --- |
| Control acquisition: `open_control`, control batches, output streams, format subscriptions and the MCP waiting tools' control path | tmux 3.7 | Refused before any attach client starts; the MCP waiting tools poll the screen instead | Tested on every CI release |
| Named-buffer deletion and renaming: `load_buffer`, `delete_buffer`, raw `delete-buffer -b` and `set-buffer -n` | tmux 3.4 | Refused before any buffer exists or changes | Tested on every CI release |
| The clipboard query `refresh-client -l`, which stops a 3.3a server with an attached client whose terminal does not answer, and a 3.4 to 3.6 server when that client leaves before its terminal answers | tmux 3.6a | Refused before dispatch | Reproduced on 3.3a to 3.6 |
| `:` or `.` in session and window names | Not tmux 3.7 | Refused for that exact release before dispatch | Tested on 3.7 and its neighbours |
| `break-pane` without a window name | Not tmux 3.7 | Refused for that exact release, which stops on it and ignores `-n`, so `break_pane` renames the window afterwards | Tested on 3.7 |
| Mirrored layouts | tmux 3.5 | Refused before dispatch | Tested |
| JSON layouts | tmux 3.8 | Refused before dispatch | Tested |

Short control attaches crash tmux servers before 3.7, which is why acquisition
is decided first. Exact-name buffer deletion can act on an unrelated buffer
before 3.4 when the name is missing. Layout strings are validated before
dispatch on every release, because 3.3a stops on an invalid one.

The raw command paths meet the same requirements as the typed operations: a
command line given to `run_command`, `run_batch` or `run_group` is resolved the
way tmux resolves it, including aliases, unique prefixes and `;` lists, before
it is sent. Command strings that tmux parses itself are not inspected,
so a refused command that is nested reaches tmux unchanged.

### Nested commands

The body of `if-shell`, `run-shell -C`, a `{ }` block and a key binding are
parsed by tmux, not by this library. Only the first word of each command is
read, after the line given to `run_command`, `run_batch` or `run_group` is
split at `;`. These refused commands behave as follows when nested:

| Command | Releases | Failure class |
| --- | --- | --- |
| `break-pane` without `-n` | exact tmux 3.7 | the server exits |
| `select-layout` with an invalid string that has no checksum | 3.3 and 3.3a | the server exits |
| `refresh-client -l` | below 3.6a | the server exits: on 3.3a with an attached client whose terminal does not answer, and on 3.4 to 3.6 when that client leaves before its terminal answers |
| `delete-buffer -b NAME` for a missing name | below 3.4 | the newest buffer is deleted instead |
| `set-buffer -n` | below 3.4 | the newest buffer is renamed when `-b` names no buffer |

For example, on exact 3.7 `run_command(server, "if-shell", "-F", "1",
"break-pane -d")` raises `CommandError` (`server exited unexpectedly`) and the daemon is gone afterwards, while a direct
`break-pane -d` is refused with `UnsupportedCapability`. Tmux 3.7a fixed the
crash ([CHANGES](https://github.com/tmux/tmux/blob/3.7a/CHANGES#L3)); 3.7 tests
the name the wrong way round in
[`cmd-break-pane.c`](https://github.com/tmux/tmux/blob/3.7/cmd-break-pane.c#L117-L124).
The default `prefix !` binding also runs a nameless `break-pane`
([`key-bindings.c`](https://github.com/tmux/tmux/blob/3.7/key-bindings.c#L358)),
which ends the server on 3.7; rebind it with `-n` or use 3.7a. Do not rely on
the library to refuse any of these inside a nested string or a key binding.
On exact 3.7, name every nested or key-bound `break-pane` with `-n`, or
upgrade to 3.7a.

Tmux 3.6a fixed the clipboard-query crash by deleting the clipboard timer when
the tty stops (the `event_del` line in
[CHANGES](https://github.com/tmux/tmux/blob/3.6a/CHANGES#L21), `tty_stop_tty`
in `tty.c`).

`paste_bytes`, `paste_text` and workspace commands that paste work on 3.3a.
Before 3.4 the paste itself deletes its staging buffer (`paste-buffer -d`),
because deleting by a missing name can take an unrelated buffer; a paste that
fails after the buffer was loaded leaves that one named buffer behind.
`break_pane` reads the window back from the pane where tmux prints no ID for a
pane that is the last in its window (3.5 and earlier).

On releases without control support the MCP waiting tools poll `capture-pane`
every 100 ms with wrapped rows joined and report `source: "screen"`. A polled
screen cannot tell new output from old, so `send_keys_and_wait` needs more
occurrences of the text than the screen held before the keys were sent. On both
paths a pane or server that ends during the wait fails the call with code
`pane_died` and the output seen so far.

The core uses standard libraries. JSON and Tables integrations are optional
extensions. MCP and workspace dependencies remain in their own packages.

Local POSIX tmux is the transport scope. SSH, native Windows tmux, private
imsg access and Python workspace plugins are excluded. Query pushdown, portable
regex/Unicode folding, general execution DAGs and MCP HTTP remain deferred.
Native Julia regex works in ordinary local predicates.

MCP CLI startup and wait setup still acquire the full graph within an 8 MiB
reply bound. Larger replies are unsupported at those stages. A discovery scope
narrows a listing; it cannot bypass startup or wait setup.

```@raw html
<p>See <a href="../source/CONTRIBUTING.md.html">the contributor guide</a> and
<a href="../source/docs/capabilities.toml.html">the support facts</a>
for scope and evidence.</p>
```

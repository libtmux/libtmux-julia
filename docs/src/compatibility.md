# Compatibility

The minimums are Julia 1.13.1 and tmux 3.3a. Core, MCP and workspace packages
share these requirements. A few operations need a newer tmux release and refuse
on older ones, as the optional capabilities below list; the rest of the library
keeps working on 3.3a.

CI runs Linux only, using Julia 1.13.1. It checks tmux 3.3a, 3.4, 3.5a, 3.6b,
3.7, 3.7a, 3.7b and 3.7c at one thread, 3.7c at four threads and 3.8 at one
thread. macOS and psmux are excluded from CI and current support. Historical
results remain available; they do not expand the selected scope.

[The retained Linux run](https://github.com/libtmux/libtmux-julia/actions/runs/39333764109)
passed every phase in the tmux 3.7c and 3.8 cells for PR head `67da6f3`, tested
as merge commit `f0a564f`, when 3.7c was the floor. No phases were skipped or
unrun. The capability manifest records both revisions and the tested source
digest, with earlier baselines separate. This evidence does not establish that
a later commit passes.

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
| The clipboard query `refresh-client -l`, which stops a 3.3a server at once and stops a 3.4 to 3.6 server when the attached client leaves before its terminal answers | tmux 3.6a | Refused before dispatch | Reproduced on 3.3a to 3.6 |
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
it is sent. Command strings that tmux parses itself, such as the body of
`if-shell`, `run-shell -C` and brace blocks, are not inspected, so do not nest
a command that this library refuses.

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
for scope and evidence.</p>
```

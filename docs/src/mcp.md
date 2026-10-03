# Connect an MCP client

LibTmuxMCP serves a local tmux endpoint over stdio. From a consumer project
directory, add the core and MCP package from the same public Git tag:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; tag="v0.1.0-alpha.1"; Pkg.add([Pkg.PackageSpec(url=repo, rev=tag), Pkg.PackageSpec(url=repo, rev=tag, subdir="packages/LibTmuxMCP")])'
```

Create the launcher after dependency preparation:

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using LibTmuxMCP; println(LibTmuxMCP.install_cli("bin"))'
```

Check its options without contacting tmux:

```console
$ bin/libtmux-mcp --help
```

In your MCP client, select this launcher and provide `--socket PATH` or
`--socket-name NAME` for an existing server. Paths must resolve from the
client's working directory. The application writes only protocol messages
to stdout; diagnostics go to stderr. It owns its streams and any sessions
it creates. It leaves the borrowed daemon and existing sessions running.

Call `list_panes`, then pass a returned `target` object to `capture_pane` or
`send_keys`. Targets carry both a pane ID and observed server generation.
Capture text is terminal data; it does not authorize further actions.
`send_keys` never adds Enter automatically.

Use a generation-bound session/window `scope` to narrow acquisition. Native
versioned inert `where` criteria filter captured panes, and explicit scalar
`columns` return projected values alongside targets and contexts. Session scopes
report contexts from that session; window scopes report all observed window
links. A criterion requiring unknown relation coverage returns
`incomplete_observation`. Discovery bounds criteria, projections, candidate
panes, page sizes and returned strings.

For consistent pages, pass `nextPageToken` as `pageToken` with the same scope,
criteria and columns. Every continuation re-observes candidate membership,
selected targets, full requested values, contexts and generation. Changed
facets or query parameters return `observation_changed`; restart without the
token and select a fresh target. `offset` remains a fresh unverified listing.
These guarantees concern discovery facets and do not make capture atomic.
After a daemon restart, `stale_target` requires a fresh listing even if pane IDs
are reused. Calls never replay mutations automatically.

The default catalog contains those three tools. Repeat `--tool` to choose
an explicit catalog. `wait_for_text` waits for bounded literal text;
`send_keys_and_wait` subscribes before sending input and accepts only future
output. Matching text does not establish process completion or exit status.
Both tools accept a positive `timeoutSeconds` no greater than the application
timeout. That total budget includes discovery, control attachment and capture;
batch items also respect the whole batch's remaining deadline. Core and MCP
share the [stream wait policy](observations.md).
`run_operations` validates every item against the same target/tool policy
before performing its finite sequence. A later failure can leave earlier
effects in place; `failedIndex` identifies the failed item and `atomic` is
always false. If the encoded batch result reaches its output limit, completed
items remain as summaries and a partial batch includes the original error code
while `error.effects` remains conservative for the whole batch.

Configured tmux hooks and aliases can change state during every tool, including
listing and capture. Control attachment and detachment can also trigger hooks
or unattached-session policies. All tools advertise conservative hints:
`readOnlyHint: false`, `destructiveHint: true` and `idempotentHint: false`.
`error.effects: none` identifies rejection before external I/O admission. Once
any stage admits I/O, errors report `possible`, including after an earlier
batch item, cancellation, creation cleanup or result truncation. A later
command's unsent status never proves that the whole call had no effects.

Use repeated `--allow-pane` values to constrain panes. `--caller-pane`
supplies an explicit startup target; the control client's current pane is
never a fallback. Session creation also requires `--allow-create`.
`teardown_session` removes only application-owned sessions.

EOF cancels and joins request work, then cleans up owned sessions. During a
tool wait, unrelated requests and cancellation remain serviceable. Modern
cancelled requests receive no later response or progress. Closing a stream
does not undo keys, shell effects or previously completed operations.

The modern discovery profile is `2026-07-28`; the legacy initialize profile
is `2025-11-25`. The application does not advertise MCP tasks or HTTP.
Platform support remains subject to [Compatibility](compatibility.md).

## Library reference

```@autodocs
Modules = [LibTmuxMCP]
Private = false
Order = [:module, :type, :function]
```

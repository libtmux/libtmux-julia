# Connect an MCP client

LibTmuxMCP serves a local tmux endpoint over stdio. Install it into a separate
consumer environment from the repository root:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; root=pwd(); Pkg.activate(".mcp-env"); Pkg.develop([Pkg.PackageSpec(path=root), Pkg.PackageSpec(path=joinpath(root,"packages","LibTmuxMCP"))]); Pkg.instantiate()'
```

Create the launcher after dependency preparation:

```console
$ julia \
    --startup-file=no \
    --project=.mcp-env \
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

The default catalog contains those three tools. Repeat `--tool` to choose
an explicit catalog. `wait_for_text` waits for bounded literal text;
`send_keys_and_wait` subscribes before sending input and accepts only future
output. Matching text does not establish process completion or exit status.
`run_operations` validates every item against the same target/tool policy
before performing its finite sequence. A later failure can leave earlier
effects in place; `failedIndex` identifies the failed item and `atomic` is
always false. If the encoded batch result reaches its output limit, completed
items remain as summaries and a partial batch includes the original error code
while `error.effects` remains conservative for the whole batch.

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

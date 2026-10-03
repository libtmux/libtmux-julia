<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Julia MCP">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# LibTmuxMCP

Run a local stdio MCP application over an explicit tmux endpoint. The package
uses public [LibTmux][libtmux] APIs and a bounded adapter around
ModelContextProtocol.jl. The alpha is source-distributed; registry publication
and full compatibility support are pending.

</div>

[Install](#install-v010-alpha1) · [Connect a client](#connect-a-client) ·
[Tools](#targets-and-effects) · [Library use](#library-use) ·
[API reference](https://libtmux.org/en/julia/latest/mcp/reference/) ·
[Tool pages](https://libtmux.org/en/julia/latest/mcp/tools/) ·
[Guide](https://libtmux.org/en/julia/latest/mcp/source-guide/)

## Install v0.1.0-alpha.1

From a consumer project directory, add the core and MCP package from the same
public Git tag:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; tag="v0.1.0-alpha.1"; Pkg.add([Pkg.PackageSpec(url=repo, rev=tag), Pkg.PackageSpec(url=repo, rev=tag, subdir="packages/LibTmuxMCP")])'
```

Install a launcher bound to that environment with
[`install_cli`][install_cli]. Choose a writable destination; installation
refuses to overwrite an existing launcher by default.

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using LibTmuxMCP; println(install_cli("bin"))'
```

Check available options without contacting tmux:

```console
$ bin/libtmux-mcp --help
```

Configure your MCP client's executable as `bin/libtmux-mcp` and pass an
explicit socket selector. `--socket-name mcp-demo` addresses an existing
server started with `tmux -L mcp-demo`; `--socket` selects a socket path.
The launcher reads protocol messages from stdin and writes only protocol
messages to stdout. Diagnostics go to stderr.

## Connect a client

The server borrows a tmux server that is already running. Start one on its own
socket:

```console
$ tmux -L agent new-session -d -s work
```

Add the launcher to Claude Code. Use an absolute launcher path, so it resolves
from the client's working directory. Until you enable more tools, the client
sees [`list_panes`][tool_list_panes], [`capture_pane`][tool_capture_pane]
and [`send_keys`][tool_send_keys]:

```console
$ claude mcp add tmux -- "$PWD/bin/libtmux-mcp" --socket-name agent
```

Other clients take the same command and arguments in their MCP configuration.
This is the common `mcpServers` shape:

<!-- mcp-config -->

```json
{
  "mcpServers": {
    "tmux": {
      "command": "/absolute/path/to/bin/libtmux-mcp",
      "args": ["--socket-name", "agent"]
    }
  }
}
```

Enable waiting by repeating `--tool`. The list replaces the default catalog, so
name every tool you want, including the default three:

```console
$ claude mcp add tmux-wait -- \
    "$PWD/bin/libtmux-mcp" \
    --socket-name agent \
    --tool list_panes \
    --tool capture_pane \
    --tool send_keys \
    --tool wait_for_text \
    --tool send_keys_and_wait
```

To confine a client to one pane, find its ID and pass it as both the default
target and the allowed set:

```console
$ tmux -L agent list-panes -a -F '#{pane_id}'
```

```text
%0
```

```console
$ claude mcp add tmux-pane -- \
    "$PWD/bin/libtmux-mcp" \
    --socket-name agent \
    --caller-pane %0 \
    --allow-pane %0
```

With `--caller-pane`, a call that omits `target` uses that pane. Calls that
name another pane are denied. The [tool table](#targets-and-effects) lists what
each tool does.

## Develop from this checkout

From the repository root, create a separate consumer environment backed by
the local core and MCP package:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; root=pwd(); Pkg.activate(".mcp-env"); Pkg.develop([Pkg.PackageSpec(path=root), Pkg.PackageSpec(path=joinpath(root,"packages","LibTmuxMCP"))]); Pkg.instantiate()'
```

## Targets and effects

The default catalog contains [`list_panes`][tool_list_panes],
[`capture_pane`][tool_capture_pane] and [`send_keys`][tool_send_keys].

- Call [`list_panes`][tool_list_panes], then pass its `target` object to a
  pane tool. A target holds the pane ID and the observed server generation.
- Listing returns unique physical panes plus linked session and window
  contexts. It preserves the difference between one pane and several
  occurrences.
- `--caller-pane %3` resolves a default target at startup. It never uses the
  control client's current pane.
- Repeat `--allow-pane` to restrict the target set.
- Repeat `--tool` to replace the default catalog.
- The same policy applies to every item in
  [`run_operations`][tool_run_operations] before any item executes.
- The server needs tmux 3.3a or newer. A tool called against an older or
  unreadable tmux fails with code `unsupported_tmux` and `effects: none`. The
  message says to upgrade tmux and restart the server, or pin the previous
  libtmux release.

| Tool | Effect |
| --- | --- |
| [`list_panes`][tool_list_panes] | Fresh bounded graph listing with context and pagination |
| [`capture_pane`][tool_capture_pane] | Bounded UTF-8 screen text with truncation metadata |
| [`send_keys`][tool_send_keys] | Explicit key tokens or literal text; no implicit Enter |
| [`wait_for_text`][tool_wait_for_text] | Match a bounded literal in a separate baseline or future output |
| [`send_keys_and_wait`][tool_send_keys_and_wait] | Register output before sending keys, then match future text |
| [`paste_text`][tool_paste_text] | Paste through an owned temporary buffer |
| [`resize_pane`][tool_resize_pane] | Request dimensions subject to tmux layout constraints |
| [`kill_pane`][tool_kill_pane] | Destroy a pane and possibly its empty window/session |
| [`run_operations`][tool_run_operations] | Prevalidated finite sequence with partial-result reporting |
| [`create_session`][tool_create_session] | Create an application-owned session; requires `--allow-create` |
| [`teardown_session`][tool_teardown_session] | Destroy only a session created by this application |

Each tool name links to its page with the full input and output contract.

Every tool can invoke configured tmux hooks or aliases. Waits also attach and
detach control clients, which can trigger hooks and unattached-session policies.
The catalog therefore advertises `readOnlyHint: false`, `destructiveHint: true`
and `idempotentHint: false`, including for listing and capture.

`error.effects: none` means the call failed before external I/O admission, such
as argument validation, target policy or prior cancellation. Once any stage
admits tmux I/O, errors report `possible`. This includes earlier batch items,
control attachment, creation cleanup and truncated results. A later command's
unsent status cannot erase those effects. `possible` does not assert that a
change occurred; cancellation and errors never establish rollback.

### Batches

[`run_operations`][tool_run_operations] validates every item before execution,
then runs them in order.

- A successful batch returns `failedIndex: null`.
- If an item fails during execution, the error result keeps the earlier
  `completed` results, reports its one-based `failedIndex`, sets
  `atomic: false`, and does not run later items.
- A `result_limit` response keeps compact summaries of completed items, the
  `failedIndex` value, and `atomic: false`. Result values are omitted.
- For a limited partial batch, `originalError` keeps the failed item's code.
- The top-level `error.effects` annotation stays conservative for the whole
  batch.

### Terminal content and ownership

- Terminal content is returned as data. Text in a pane does not grant
  permission to invoke another tool.
- The application neither owns nor destroys the borrowed daemon or
  pre-existing sessions.
- EOF cancels and joins request work, then removes application-owned sessions.
- Cancellation does not undo shell effects or previously delivered keys.

### Waiting

- Wait tools are opt-in.
- They return literal-text evidence, never process exit or shell success.
- A prior screen match cannot satisfy
  [`send_keys_and_wait`][tool_send_keys_and_wait].
- An independent baseline is never concatenated with output across its reset
  boundary.
- Both tools share the application's deadline and byte bounds, emit bounded
  progress when requested, and release their control clients on cancellation.
- Unrelated requests remain serviceable during a wait.

## Library use

- [`Application(server; ...)`][application] configures policy without I/O.
- [`tools(app)`][tools] returns a fresh SDK catalog.
- [`serve(app; input, output)`][serve] owns and closes both streams and the
  application.
- [`main(args)`][main] provides the CLI with explicit exit codes: 0 for clean
  EOF, 2 for invalid options, 130 for interruption and 1 for startup, protocol
  or cleanup failure.

Modern discovery uses `2026-07-28`; the admitted legacy initialize profile is
`2025-11-25`. The server supports ordinary tool calls, progress and
cancellation. It does not advertise MCP tasks or HTTP transport. See
[adapter ownership](docs/adapter.md) for protocol and resource limits.

## License

[MIT](LICENSE).

[libtmux]: https://libtmux.org/en/julia/latest/reference/libtmux/
[install_cli]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-install_cli/
[application]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-application/
[tools]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-tools/
[serve]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-serve/
[main]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-main/
[tool_list_panes]: https://libtmux.org/en/julia/latest/mcp/tools/list_panes/
[tool_capture_pane]: https://libtmux.org/en/julia/latest/mcp/tools/capture_pane/
[tool_send_keys]: https://libtmux.org/en/julia/latest/mcp/tools/send_keys/
[tool_wait_for_text]: https://libtmux.org/en/julia/latest/mcp/tools/wait_for_text/
[tool_send_keys_and_wait]: https://libtmux.org/en/julia/latest/mcp/tools/send_keys_and_wait/
[tool_paste_text]: https://libtmux.org/en/julia/latest/mcp/tools/paste_text/
[tool_resize_pane]: https://libtmux.org/en/julia/latest/mcp/tools/resize_pane/
[tool_kill_pane]: https://libtmux.org/en/julia/latest/mcp/tools/kill_pane/
[tool_run_operations]: https://libtmux.org/en/julia/latest/mcp/tools/run_operations/
[tool_create_session]: https://libtmux.org/en/julia/latest/mcp/tools/create_session/
[tool_teardown_session]: https://libtmux.org/en/julia/latest/mcp/tools/teardown_session/

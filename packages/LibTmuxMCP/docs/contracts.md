# LibTmuxMCP contracts

The [README](../README.md) shows how to connect a client and which tools it
gets. This page holds the rules behind them: how targets and policy work, how
batches report partial results, what waiting proves, and what the application
owns. For protocol framing and resource limits, see
[adapter ownership](adapter.md).

## Targets and policy

The default catalog contains [`list_panes`][tool_list_panes],
[`capture_pane`][tool_capture_pane] and [`send_keys`][tool_send_keys].

- Call `list_panes`, then pass its `target` object to a pane tool. A target
  holds the pane ID and the observed server generation.
- Listing returns unique physical panes plus linked session and window contexts.
  It preserves the difference between one pane and several occurrences.
- `--caller-pane %3` resolves a default target at startup. It never uses the
  control client's current pane.
- Repeat `--allow-pane` to restrict the target set.
- Repeat `--tool` to replace the default catalog.
- The same policy applies to every item in
  [`run_operations`][tool_run_operations] before any item executes.

With `--caller-pane`, a call that omits `target` uses that pane. Calls that name
another pane are denied.

## Batches

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

## Terminal content and ownership

- Terminal content is returned as data. Text in a pane does not grant permission
  to invoke another tool.
- The application neither owns nor destroys the borrowed daemon or pre-existing
  sessions.
- EOF cancels and joins request work, then removes application-owned sessions.
- Cancellation does not undo shell effects or previously delivered keys.

## Waiting

- Wait tools are opt-in.
- They return literal-text evidence. They do not report process exit or shell
  success.
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

## Protocol profiles

Modern discovery uses `2026-07-28`; the admitted legacy initialize profile is
`2025-11-25`. The server supports ordinary tool calls, progress and
cancellation. It does not advertise MCP tasks or HTTP transport.

## Working in this checkout

From the repository root, create a separate consumer environment backed by the
local core and MCP package:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; root=pwd(); Pkg.activate(".mcp-env"); Pkg.develop([Pkg.PackageSpec(path=root), Pkg.PackageSpec(path=joinpath(root,"packages","LibTmuxMCP"))]); Pkg.instantiate()'
```

[application]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-application/
[main]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-main/
[serve]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-serve/
[tool_capture_pane]: https://libtmux.org/en/julia/latest/mcp/tools/capture_pane/
[tool_list_panes]: https://libtmux.org/en/julia/latest/mcp/tools/list_panes/
[tool_run_operations]: https://libtmux.org/en/julia/latest/mcp/tools/run_operations/
[tool_send_keys]: https://libtmux.org/en/julia/latest/mcp/tools/send_keys/
[tool_send_keys_and_wait]: https://libtmux.org/en/julia/latest/mcp/tools/send_keys_and_wait/
[tools]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-tools/

# LibTmuxMCP

Run a local stdio MCP application over an explicit tmux endpoint. The package
uses public LibTmux APIs and a bounded adapter around ModelContextProtocol.jl.
The implementation is under verification; registry publication and full
compatibility support are pending.

## Install from this checkout

Run from the repository root. This creates a separate consumer environment;
package resolution belongs to setup, outside timed checks.

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; root=pwd(); Pkg.activate(".mcp-env"); Pkg.develop([Pkg.PackageSpec(path=root), Pkg.PackageSpec(path=joinpath(root,"packages","LibTmuxMCP"))]); Pkg.instantiate()'
```

Install a launcher bound to that environment. Choose a writable destination;
installation refuses to overwrite an existing launcher by default.

```console
$ julia \
    --startup-file=no \
    --project=.mcp-env \
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

## Targets and effects

The default catalog contains `list_panes`, `capture_pane` and `send_keys`.
Call `list_panes`, then pass its `target` object to a pane tool. The target
includes the pane ID and observed server generation. Listing returns unique
physical panes plus linked session/window contexts; it preserves the
difference between one pane and several occurrences.

`--caller-pane %3` resolves a default target at startup. It never uses the
control client's current pane. Repeating `--allow-pane` restricts the target
set. Repeating `--tool` replaces the default catalog. The same policy applies
to every item in `run_operations` before any item executes.

| Tool | Effect |
| --- | --- |
| `list_panes` | Fresh bounded graph listing with context and pagination |
| `capture_pane` | Bounded UTF-8 screen text with truncation metadata |
| `send_keys` | Explicit key tokens or literal text; no implicit Enter |
| `wait_for_text` | Match a bounded literal in a separate baseline or future output |
| `send_keys_and_wait` | Register output before sending keys, then match future text |
| `paste_text` | Paste through an owned temporary buffer |
| `resize_pane` | Request dimensions subject to tmux layout constraints |
| `kill_pane` | Destroy a pane and possibly its empty window/session |
| `run_operations` | Prevalidated finite sequence with partial-result reporting |
| `create_session` | Create an application-owned session; requires `--allow-create` |
| `teardown_session` | Destroy only a session created by this application |

`run_operations` validates every item before execution, then runs them in
order. A successful batch returns `failedIndex: null`. If an item fails during
execution, the error result retains earlier `completed` results, reports its
one-based `failedIndex`, sets `atomic: false`, and does not run later items.

Terminal content is returned as data. Text in a pane does not grant
permission to invoke another tool. The application neither owns nor destroys
the borrowed daemon or pre-existing sessions. EOF cancels and joins request
work, then removes application-owned sessions. Cancellation does not undo
shell effects or previously delivered keys.

Wait tools are opt-in. They return literal-text evidence, never process exit
or shell success. A prior screen match cannot satisfy `send_keys_and_wait`.
An independent baseline is never concatenated with output across its reset
boundary. Both tools share the application's deadline and byte bounds, emit
bounded progress when requested, and release their control clients on
cancellation. Unrelated requests remain serviceable during a wait.

## Library use

`Application(server; ...)` configures policy without I/O. `tools(app)` returns
a fresh SDK catalog. `serve(app; input, output)` owns and closes both streams
and the application. `main(args)` provides the CLI with explicit exit codes:
0 for clean EOF, 2 for invalid options, 130 for interruption and 1 for startup,
protocol or cleanup failure.

Modern discovery uses `2026-07-28`; the admitted legacy initialize profile is
`2025-11-25`. The server supports ordinary tool calls, progress and
cancellation. It does not advertise MCP tasks or HTTP transport. See
[adapter ownership](docs/adapter.md) for protocol and resource limits.

## License

[MIT](LICENSE).

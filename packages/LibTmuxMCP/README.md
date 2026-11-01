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

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/julia/latest/mcp/)

Serve one tmux server to MCP clients over stdio: list panes, capture a pane and
send keys.

</div>

The package uses public [LibTmux][libtmux] APIs and a bounded adapter around
ModelContextProtocol.jl. It borrows one tmux server: the one you name, or else
the one tmux picks. Shutdown tears down only application-owned sessions.

**Contents** — [Quick start](#quick-start) ·
[Point a client at a server](#point-a-client-at-a-server) ·
[Choose the tools](#choose-the-tools) ·
[Restrict pane targets](#restrict-a-clients-pane-targets) ·
[Use the tools](#use-the-tools) · [Library use](#use-it-as-a-library) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Documentation](#documentation) ·
[API reference](https://libtmux.org/en/julia/latest/mcp/reference/) ·
[Tool pages](https://libtmux.org/en/julia/latest/mcp/tools/) ·
[Guide](https://libtmux.org/en/julia/latest/mcp/source-guide/)

## Quick start

The packages are unregistered. From a consumer project
directory, add the core and MCP package from the same revision:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision = "v0.1.1-alpha.2"; Pkg.add([Pkg.PackageSpec(url=repo, rev=revision), Pkg.PackageSpec(url=repo, rev=revision, subdir="packages/LibTmuxMCP")])'
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

The launcher reads protocol messages from stdin and writes only protocol
messages to stdout. Diagnostics go to stderr.

## Point a client at a server

### `--socket-name` and `--socket`: choose the tmux server

Pass at most one socket option. `--socket-name mcp-demo` addresses an existing
server started with `tmux -L mcp-demo`. `--socket` selects a socket path, which
must resolve from the client's working directory. Passing both is an error.

With neither option, the launcher reads `LIBTMUX_SOCKET_PATH` (a socket path,
tmux's `-S`), then `LIBTMUX_SOCKET` (a socket name, `-L`). A variable that is
empty or only whitespace counts as unset. A socket option leaves both variables
unread.

A `LIBTMUX_SOCKET` that holds a slash is refused with exit status 2, so put a
path in `LIBTMUX_SOCKET_PATH`. A relative path resolves against the launcher's
working directory.

When neither is set, the launcher passes tmux no socket and tmux picks the
server: the one `TMUX` names when the client runs inside tmux, and its `default`
socket otherwise.

A client started outside tmux therefore reaches the default server. Name a
socket when that is not the server you want.

### The `mcpServers` shape: other clients

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

## Choose the tools

The default catalog is [`list_panes`][tool_list_panes],
[`capture_pane`][tool_capture_pane] and [`send_keys`][tool_send_keys]. Each
tool name below links to its page with the full input and output contract.

| Tool | Effect |
| --- | --- |
| [`list_panes`][tool_list_panes] | Fresh bounded graph listing with context and pagination |
| [`capture_pane`][tool_capture_pane] | Bounded UTF-8 screen text with truncation metadata |
| [`send_keys`][tool_send_keys] | Explicit key tokens or literal text; no implicit Enter |
| [`wait_for_text`][tool_wait_for_text] | Match a bounded literal in a baseline, output stream or polled screen |
| [`send_keys_and_wait`][tool_send_keys_and_wait] | Send keys and wait with the path-specific freshness rules below |
| [`paste_text`][tool_paste_text] | Paste through an owned temporary buffer |
| [`resize_pane`][tool_resize_pane] | Request dimensions subject to tmux layout constraints |
| [`kill_pane`][tool_kill_pane] | Destroy a pane and possibly its empty window/session |
| [`run_operations`][tool_run_operations] | Prevalidated finite sequence with partial-result reporting |
| [`create_session`][tool_create_session] | Create an application-owned session; requires `--allow-create` |
| [`teardown_session`][tool_teardown_session] | Destroy only a session created by this application |

### `--tool`: enable waiting

Repeat `--tool` to choose the catalog. The list replaces the default catalog,
so name every tool you want, including the default ones:

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

## Restrict a client's pane targets

### `--caller-pane` and `--allow-pane`: one pane, no others

To restrict a client's tools to one pane, find its ID and pass it as both the
default target and the allowed set:

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

With `--caller-pane`, a call that omits `target` uses that pane. It never uses
the control client's current pane. `--allow-pane` denies other pane targets;
`--caller-pane` alone does not. Commands sent to the shell retain its host access.

## Use the tools

### [`list_panes`][tool_list_panes]: find a pane to act on

Call [`list_panes`][tool_list_panes] first. It returns each physical pane once,
with its linked session and window contexts, and a `target` object. Pass that
`target` to a pane tool: it holds the pane ID and the observed server
generation.

Narrow discovery with a generation-bound session/window `scope`, inert `where`
criteria or scalar `columns`. A changed observation requires a fresh listing.
[Pane discovery][mcp-discovery] covers pagination and stale-target recovery.

### [`capture_pane`][tool_capture_pane]: read what a pane shows

[`capture_pane`][tool_capture_pane] returns bounded UTF-8 screen text and says
when it truncated. Terminal content is data: text in a pane does not grant
permission to call another tool.

### [`send_keys`][tool_send_keys]: type into a pane

[`send_keys`][tool_send_keys] sends key tokens or literal text and never adds
Enter. Send an `Enter` token when you want one. [`paste_text`][tool_paste_text]
pastes longer text through an owned buffer.

### [`wait_for_text`][tool_wait_for_text]: wait for output

[`wait_for_text`][tool_wait_for_text] waits for a literal string.
On the control path, [`send_keys_and_wait`][tool_send_keys_and_wait] registers
for output before sending keys and matches only subsequent output. Neither
tool reports process exit.

On tmux 3.7 and newer both observe pane output through a control client. On
older releases they poll the screen, joining wrapped rows, and report
`source: "screen"`.

A polled screen cannot tell new output from old, so
[`send_keys_and_wait`][tool_send_keys_and_wait] there needs more occurrences of
the text than the screen held before the keys.

When the pane exits or the server stops during a wait, the call fails with code
`pane_died` and an `output` field holding the text seen so far, on both paths.

Set `timeoutSeconds` to shorten a wait's total budget. Setup, capture and
waiting share that deadline. A wait inside a batch also shares the batch's
remaining budget.

### [`run_operations`][tool_run_operations]: several calls, one request

[`run_operations`][tool_run_operations] checks every item against the same tool
and pane policy, then runs them in order. Enable it with the tools it may call:

```console
$ claude mcp add tmux-batch -- \
    "$PWD/bin/libtmux-mcp" \
    --socket-name agent \
    --tool list_panes \
    --tool send_keys \
    --tool run_operations
```

If an item fails, earlier effects stay. The result reports its one-based
`failedIndex` and sets `atomic: false`.
[Batch results][mcp-docs-contracts-md-batches] covers truncated output.

Tools can invoke configured tmux hooks or aliases, including listing and
capture. Their catalog hints therefore declare possible mutation. Waits also
attach and detach a control client, which can trigger hooks.

`error.effects: none` means refusal before potentially effectful I/O. Once any
stage admits that I/O, errors report `possible`. Earlier batch items, cleanup
and truncation retain that history; cancellation never proves rollback.

### [`create_session`][tool_create_session]: a session the server owns

[`create_session`][tool_create_session] starts a session that this application
owns, and [`teardown_session`][tool_teardown_session] removes it. Creation also
needs `--allow-create`:

```console
$ claude mcp add tmux-owned -- \
    "$PWD/bin/libtmux-mcp" \
    --socket-name agent \
    --tool list_panes \
    --tool create_session \
    --tool teardown_session \
    --allow-create
```

The application removes the sessions it created when the client closes its
input. It leaves your tmux server and existing sessions running.

### [`resize_pane`][tool_resize_pane]: ask for a size

[`resize_pane`][tool_resize_pane] requests a width or height in cells. tmux may
constrain the result to fit the window.

### [`kill_pane`][tool_kill_pane]: remove a pane

[`kill_pane`][tool_kill_pane] destroys a pane and its running process. Its
window or session goes too when it was the last pane.

## Use it as a library

### [`Application`][application]: policy without I/O

[`Application`][application] configures policy for a borrowed
[`Server`][server] and does no I/O. [`tools`][tools] returns the SDK catalog
that the policy enables:

```jldoctest
julia> using LibTmux, LibTmuxMCP

julia> app = Application(Server(socket_name="agent"));

julia> [tool.name for tool in tools(app)]
3-element Vector{String}:
 "list_panes"
 "capture_pane"
 "send_keys"
```

[`serve`][serve] runs the stdio loop. It owns and closes both streams and the
application.

### [`main`][main]: the launcher from Julia

[`main`][main] is the launcher's entry point. It returns 0 after a clean EOF, 2
for invalid options, 130 for interruption and 1 for a startup, protocol or
cleanup failure:

```jldoctest
julia> using LibTmuxMCP

julia> main(["--help"]; output=IOBuffer(), err=IOBuffer())
0

julia> main(["--bogus"]; output=IOBuffer(), err=IOBuffer())
2
```

## What it leaves out

- **Your tmux server.** Shutdown teardown targets only the sessions that
  [`create_session`][tool_create_session] made.
- **Trust in pane text.** Terminal content is returned as data, and text in a
  pane never grants permission to invoke a tool.
- **Undoing effects.** Cancellation does not undo keys already sent.
  [`run_operations`][tool_run_operations] stops at the first failure and keeps
  earlier effects.
- **Proof that a command finished.** [`wait_for_text`][tool_wait_for_text] and
  [`send_keys_and_wait`][tool_send_keys_and_wait] return literal-text evidence
  and report no exit status.
- **MCP tasks and HTTP.** The server speaks stdio and does not advertise tasks
  or HTTP transport.

[The full rules][mcp-docs-contracts-md] cover targets, batches, waiting and
ownership.

## Support and status

- **Experimental.** The packages are unregistered. Registry publication is pending.
- **Protocol.** Modern discovery uses `2026-07-28`. The legacy initialize
  profile is `2025-11-25`.
- **Julia 1.13.1 or newer and tmux 3.3a or newer.**
- **Older tmux is refused.** The initial check reports `unsupported_tmux` and
  `effects: none`. A later refusal preserves earlier possible effects. Upgrade
  tmux and restart the server, or pin a compatible libtmux release.
- **Linux, including WSL.** CI runs Linux only. macOS and psmux are excluded
  from CI.

## Documentation

| | |
| --- | --- |
| [Contracts](https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxMCP/docs/contracts.md) | Targets, batches, waiting and ownership |
| [Adapter ownership](https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxMCP/docs/adapter.md) | Protocol framing and resource limits |
| [Tool pages](https://libtmux.org/en/julia/latest/mcp/tools/) | Input and output of every tool |
| [API reference](https://libtmux.org/en/julia/latest/mcp/reference/) | Every public binding, one page each |
| [Guide](https://libtmux.org/en/julia/latest/mcp/source-guide/) | Connect a client, step by step |
| [Root README](https://github.com/libtmux/libtmux-julia/blob/master/README.md) | The core library and the other packages |

## License

[MIT][mcp-license].

[libtmux]: https://libtmux.org/en/julia/latest/reference/libtmux/
[server]: https://libtmux.org/en/julia/latest/reference/libtmux-server/
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
[mcp-docs-contracts-md]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxMCP/docs/contracts.md
[mcp-docs-contracts-md-batches]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxMCP/docs/contracts.md#batches
[mcp-license]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxMCP/LICENSE
[mcp-discovery]: https://github.com/libtmux/libtmux-julia/blob/589c726499610ce5e96844f6c9a49a41368da5ec/packages/LibTmuxMCP/docs/discovery.md

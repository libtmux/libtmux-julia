<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Julia">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# LibTmux.jl

[![Julia](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml/badge.svg)](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/julia/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-julia/blob/master/LICENSE)

Create tmux sessions, split panes, send input and capture terminal output from
Julia.

</div>

[Create a session][new_session], [capture a pane][capture_pane] and read
sessions, windows, panes and clients into a [snapshot][snapshot]. Then
[filter it][panewhere] with `filter`, `count` and other Julia collection
functions. You can also [type into a pane][send_keys] and
[read what it prints][observe_output].

It suits scripts that drive a terminal program, tests that need a real tmux,
and, through the MCP package, agents that share a terminal.

**Contents** — [Quick start](#quick-start) ·
[Find things](#find-sessions-windows-and-panes) ·
[Choose a server](#choose-which-server-to-use) ·
[Type and read](#type-into-a-pane-and-read-what-it-prints) ·
[Control connection](#reuse-a-control-connection) ·
[Examples](#run-the-example-programs) · [Packages](#packages) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Documentation](#documentation) ·
[API reference](https://libtmux.org/en/julia/latest/reference/) ·
[Field reference][repo-docs-generated-criteria-md]

The core uses only Julia standard libraries. Add an experimental companion
for MCP or workspace configuration:

| Package | Use it for |
| --- | --- |
| [**LibTmux**](#libtmux-the-core-library) | Sessions, windows, panes, snapshots and control connections |
| [LibTmuxMCP](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxMCP) | MCP tools to inspect panes, send keys and wait for output |
| [LibTmuxWorkspace](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxWorkspace) | Load and freeze tmuxp-style YAML or JSON workspaces |

## Quick start

The package is unregistered. From your Julia project's directory, add the
core at the `v0.1.1-alpha.2` tag:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision = "v0.1.1-alpha.2"; Pkg.add(Pkg.PackageSpec(url=repo, rev=revision))'
```

Use Julia 1.13.1 or newer and tmux 3.3a or newer. Have `tmux` on your `PATH`,
then open Julia in that project:

```console
$ julia --project=.
```

Create a private server and split its first window.
[`with_server`][with_server] closes the server when the block returns or
throws, and the snapshot stays readable afterwards:

```julia
using LibTmux

snap, screen = with_server() do server
    new_session(server; name="demo", command=["/bin/cat"])
    pane = only(panes(snapshot(server))).ref
    split_window(server, pane; direction=:below, command=["/bin/cat"])
    snapshot(server), capture_pane(server, pane)
end

@assert isempty(strip(screen))
println(only(sessions(snap)).name, ": ", length(panes(snap)), " panes; blank capture verified")
```

```text
demo: 2 panes; blank capture verified
```

The block calls [`new_session`][new_session], [`split_window`][split_window],
[`snapshot`][snapshot] and [`capture_pane`][capture_pane]. `screen` holds the
pane's UTF-8 text, and the panes run `cat`, so their screens start blank.

[`capture_bytes`][capture_bytes] returns the original bytes.
[`examples/owned_capture.jl`][repo-examples-owned_capture-jl] runs the same
flow and checks that the server is gone afterwards.

## Find sessions, windows, and panes

### [`snapshot`][snapshot]: what tmux has now

[`snapshot`][snapshot] reads the sessions, windows, panes and clients of a
server. [`sessions`][sessions], [`windows`][windows] and [`panes`][panes] list
what it captured. Continue with `snap` from the quick start:

```julia
for pane in panes(snap)
    println(string(pane.id), ": ", pane.current_command)
end
```

```text
%0: cat
%1: cat
```

A snapshot is a record. It does not change when tmux does, and reading it
never contacts tmux. Call `snapshot(server)` again while the server is open to
read fresh state.

### [`PaneWhere`][panewhere]: filter without asking tmux again

A closure or a reusable criterion such as [`PaneWhere`][panewhere] filters the
captured data. The comparisons come from the [`Filters`][filters] module:

```julia
filter(pane -> pane.active, panes(snap))

import LibTmux.Filters as F
wide = PaneWhere(active=true, width=F.AtLeast(80))

filter(wide, panes(snap))
count(wide, panes(snap))
any(wide, panes(snap))
[pane.id for pane in Iterators.filter(wide, panes(snap))]
```

Criteria are callable values. Filtering [`panes(snap)`][panes] returns an
ordered, read-only [`Selection`][selection]. `collect` gives you a vector, and
`only` requires exactly one result.

### [`windowlinks`][windowlinks]: a window shared by several sessions

[`windows`][windows] and [`panes`][panes] list each physical object once.
[`windowlinks`][windowlinks] and [`paneoccurrences`][paneoccurrences] keep each
session's context for a window that belongs to several.

Runnable: [`examples/shared_windows.jl`][repo-examples-shared_windows-jl]
links one window into two sessions and queries both views.

[Queries and relations][repo-docs-src-queries-md] ·
[Filterable fields][repo-docs-generated-criteria-md] ·
[JSON criteria][repo-docs-criteria-wire-md] ·
[Tables projections][repo-docs-projections-md]. At the Julia prompt,
`?PaneWhere` and `?capture_pane` show API help.

## Choose which server to use

### [`Server`][server]: name the socket

[`Server`][server] describes a tmux endpoint without contacting it. Give it
exactly one of `socket_name` or `socket_path`. [`from_env`][from_env] reads
`TMUX`, and selects the `default` socket outside tmux:

```jldoctest
julia> using LibTmux

julia> Server(socket_name="work")
Server(socket_name="work", tmux="tmux")

julia> from_env(env=Dict("TMUX" => "/tmp/tmux-1000/default,1234,0"))
Server(socket_path="/tmp/tmux-1000/default", tmux="tmux")
```

A `Server` is an immutable value with nothing to close. It borrows the daemon
it names. [`open_server`][open_server] starts a private daemon that you close.

## Type into a pane and read what it prints

### [`send_keys`][send_keys]: type into a pane

[`send_keys`][send_keys] types into a pane and adds no Enter.
[`observe_output`][observe_output] streams the bytes a pane prints from then
on, over a control connection:

```julia
using LibTmux

echoed = with_server() do server
    created = new_session(server; name="echo", command=["/bin/cat"])
    pane = only(panes(snapshot(server))).ref
    open_control(server, created) do connection
        observe_output(connection, pane) do stream
            send_keys(server, pane, "hello from Julia"; literal=true)
            bytes = UInt8[]
            while length(bytes) < ncodeunits("hello from Julia")
                append!(bytes, take!(stream; timeout=5).bytes)
            end
            decode_text(bytes)
        end
    end
end

println(echoed)
```

```text
hello from Julia
```

The terminal echoes every key, so the stream carries the text you typed.
[`decode_text`][decode_text] turns the bytes into a `String`, and
[`capture_baseline`][capture_baseline] records the screen at a reset point.

Runnable: [`examples/output_stream.jl`][repo-examples-output_stream-jl]. It also
reads the cursor with [`observation_cursor`][observation_cursor].

### [`wait_for_text`][wait_for_text]: wait for text on the screen

[`wait_for_text`][wait_for_text] polls the visible screen on every supported
tmux release, joins wrapped rows and needs no control connection.
[`watch_screen`][watch_screen] takes the entry read first, so keys sent inside
its block are not counted as already on the screen:

```julia
using LibTmux

with_server() do server
    new_session(server; name="shell")
    pane = only(panes(snapshot(server))).ref
    watch_screen(server, pane) do screen
        send_keys(server, pane, "printf 'ready-%s\\n' now", "Enter")
        wait_for_text(screen, "ready-now").text
    end
end
```

A pane or server that ends first raises [`ScreenWaitEnded`][ScreenWaitEnded]
with the last screen read. Text that scrolled off is not seen, and typed echo
counts, so match on what a command prints.

## Reuse a control connection

Control connections need tmux 3.7 or newer; older releases raise
[`UnsupportedCapability`][UnsupportedCapability].
[Compatibility][repo-docs-src-compatibility-md] lists every optional feature
and its release.

### [`open_control`][open_control]: persistent clients for repeated commands

A plain server starts a tmux client process for each command.
[`open_control`][open_control] keeps two clients open for repeated operations
and cleanup.
Both yield during I/O, so `Threads.@spawn` and `fetch` overlap calls:

```julia
using LibTmux

screens = with_server() do server
    session = new_session(server; name="tasks", command=["/bin/cat"])
    new_window(server, session; name="logs", command=["/bin/cat"])
    open_control(server, session) do connection
        jobs = map(panes(snapshot(connection))) do pane
            Threads.@spawn capture_pane(connection, pane.ref)
        end
        fetch.(jobs)
    end
end
```

`screens` holds both pane captures. The inner block closes both clients, and the
outer block closes the server.

A control client counts as attached in tmux. Connection loss is terminal, and
cancelling a sent operation does not undo it.
[Ownership and cancellation][repo-docs-src-ownership-md] and
[output streams][repo-docs-src-observations-md] cover deadlines and cleanup.

## Run the example programs

Each program creates and cleans up its own tmux server:

| Task | Program |
| --- | --- |
| Create a session and capture its screen | [owned_capture.jl](https://github.com/libtmux/libtmux-julia/blob/master/examples/owned_capture.jl) |
| Query shared windows and their panes | [shared_windows.jl](https://github.com/libtmux/libtmux-julia/blob/master/examples/shared_windows.jl) |
| Cancel a waiting control operation | [control_cancel.jl](https://github.com/libtmux/libtmux-julia/blob/master/examples/control_cancel.jl) |
| Send text and subscribe to pane output | [output_stream.jl](https://github.com/libtmux/libtmux-julia/blob/master/examples/output_stream.jl) |
| Wait for an explicit command completion marker | [command_completion.jl](https://github.com/libtmux/libtmux-julia/blob/master/examples/command_completion.jl) |

To run the programs, clone the source:

```console
$ git clone \
    https://github.com/libtmux/libtmux-julia.git
```

```console
$ cd libtmux-julia
```

```console
$ git checkout v0.1.1-alpha.2
```

```console
$ julia \
    --project=. \
    examples/shared_windows.jl
```

The [MCP guide][repo-packages-libtmuxmcp] and
[workspace guide][repo-packages-libtmuxworkspace] include their own installation
and launcher commands. The
[workspace example][ws-examples-owned_load-jl] loads a
configuration and checks its layout, focus and cleanup.

## Packages

Each heading links to the package's directory on GitHub. None is in the
General registry yet, so install from the same source revision, as the
[quick start](#quick-start) does.

### [`LibTmux`](https://github.com/libtmux/libtmux-julia/tree/master/src): the core library

Sessions, windows, panes, snapshots and control connections, using only Julia
standard libraries.

[API reference](https://libtmux.org/en/julia/latest/reference/) ·
[Guides](https://libtmux.org/en/julia/latest/guides/) ·
[Examples](https://libtmux.org/en/julia/latest/examples/)

A [`PaneWhere`][panewhere] criterion is also plain data.
[`encode_where`][encode_where] converts one to a document without contacting
tmux:

```jldoctest
julia> using LibTmux

julia> import LibTmux.Filters as F

julia> wide = PaneWhere(active=true, width=F.AtLeast(80));

julia> encode_where(wide)["entity"]
"pane"
```

### [JSON and Tables extensions](https://github.com/libtmux/libtmux-julia/tree/master/ext): optional integrations

Load JSON 1.9+ to move criteria through JSON text, or Tables 1.14+ to read
projected rows as a table. The core imports neither.

[Portable criteria][repo-docs-criteria-wire-md] ·
[Tables projections][repo-docs-projections-md]

With JSON loaded, [`write_where_json`][write_where_json] and
[`read_where_json`][read_where_json] round trip a criterion:

```jldoctest
julia> using LibTmux, JSON

julia> text = write_where_json(PaneWhere(active=true));

julia> encode_where(read_where_json(text)) == encode_where(PaneWhere(active=true))
true
```

Continue with `snap` from the quick start. With Tables loaded,
[`project_rows`][project_rows] selects the columns of a table:

```julia
using Tables

rows = project_rows(panes(snap); columns=(:id, :current_command))
columns = Tables.columntable(rows)
println(join(columns.current_command, ", "))
```

```text
cat, cat
```

### [`LibTmuxWorkspace`](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxWorkspace): tmuxp-style workspaces

Read a YAML or JSON workspace, plan it without contacting tmux, apply it to a
server and freeze a running session back into a file.

[API reference](https://libtmux.org/en/julia/latest/workspace/reference/) ·
[Guide](https://libtmux.org/en/julia/latest/workspace/source-guide/) ·
[Package README][repo-packages-libtmuxworkspace]

From a checkout, after [`install_cli`][workspace_install_cli] creates
`bin/libtmux-workspace`, [`validate`][workspace_validate] checks the shipped
configuration without contacting tmux:

```console
$ bin/libtmux-workspace validate packages/LibTmuxWorkspace/examples/workspace.yaml
```

```text
valid
```

### [`LibTmuxMCP`](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxMCP): a tmux server for agents

A local stdio MCP server for one tmux server that you name. Its default tools
list panes, capture a pane and send keys.

[API reference](https://libtmux.org/en/julia/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/julia/latest/mcp/tools/) ·
[Guide](https://libtmux.org/en/julia/latest/mcp/source-guide/) ·
[Package README][repo-packages-libtmuxmcp]

The server borrows a tmux server that is already running. Start one on its
own socket:

```console
$ tmux -L agent new-session -d -s work
```

After [`install_cli`][mcp_install_cli] creates `bin/libtmux-mcp`, add it to
Claude Code. Until you enable more tools, the client sees
[`list_panes`][tool_list_panes], [`capture_pane`][tool_capture_pane] and
[`send_keys`][tool_send_keys]:

```console
$ claude mcp add tmux -- "$PWD/bin/libtmux-mcp" --socket-name agent
```

The [MCP README][repo-packages-libtmuxmcp] covers other clients and every tool.

## What it leaves out

- **Live objects.** A [`snapshot`][snapshot] records what tmux reported when
  it was read. Take a new one, or [observe output][observe_output], to see a
  change.
- **A terminal emulator.** A pane capture returns the screen tmux drew, and
  [`observe_output`][observe_output] returns the raw bytes a program wrote.
  Nothing here interprets those bytes.
- **Your tmux configuration.** [`open_server`][open_server] starts a daemon
  with an empty configuration, and nothing edits `~/.tmux.conf`.
- **Remote and native Windows tmux.** The core drives a local POSIX tmux. SSH
  and native Windows tmux are [excluded][repo-docs-src-compatibility-md].

## Support and status

- **Initial release.** The packages are unregistered and their APIs may change. Pkg
  records the requested revision and package tree in your `Manifest.toml`.
- **Standard library only.** The core imports only Julia standard libraries.
  The JSON and Tables integrations are optional extensions.
- **Julia 1.13.1 or newer and tmux 3.3a or newer.** Operations refuse an older
  or unreadable tmux release before they have any effect.
  [Compatibility][repo-docs-src-compatibility-md] lists features that need a
  newer one.
- **Linux, including WSL.** CI runs Linux only. macOS and psmux are excluded
  from CI; native Windows tmux is outside scope.
- **Evidence.** The capability manifest is
  [`capabilities.json`][repo-capabilities-json]; the
  [CI results](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
  record what is verified.

## Documentation

| | |
| --- | --- |
| [Reference](https://libtmux.org/en/julia/latest/reference/) | Every public binding, one page each |
| [Installation guide](https://github.com/libtmux/libtmux-julia/blob/master/docs/src/installation.md) | Add the MCP or workspace companion with the matching core |
| [Contributing and checks](https://github.com/libtmux/libtmux-julia/blob/master/CONTRIBUTING.md) | The checks a change must pass |
| [Troubleshooting](https://github.com/libtmux/libtmux-julia/blob/master/docs/src/troubleshooting.md) | Symptoms and next steps |
| [Benchmarks](https://github.com/libtmux/libtmux-julia/blob/master/benchmark/README.md) | What each execution mode costs |
| [Changelog](https://github.com/libtmux/libtmux-julia/blob/master/CHANGELOG.md) | What each release changed |

## Attribution

Developed out of curiosity and a desire to learn and master Julia by the
maintainer of Python libtmux, with AI assistance for code, tests, and
documentation. Python libtmux is the behavioural reference.

Please use the following BibTeX template to cite libtmux-julia in scientific discourse:

```bibtex
@misc{libtmux-julia,
   author = {Tony Narlock},
   year = {2026},
   note = {https://libtmux.org},
   title = {libtmux-julia: Julia wrapper for tmux}
}
```

## License

Core, MCP and workspace packages use the [MIT license][repo-license].

[with_server]: https://libtmux.org/en/julia/latest/reference/libtmux-with_server/
[new_session]: https://libtmux.org/en/julia/latest/reference/libtmux-new_session/
[split_window]: https://libtmux.org/en/julia/latest/reference/libtmux-split_window/
[snapshot]: https://libtmux.org/en/julia/latest/reference/libtmux-snapshot-1gv6/
[capture_pane]: https://libtmux.org/en/julia/latest/reference/libtmux-capture_pane/
[capture_bytes]: https://libtmux.org/en/julia/latest/reference/libtmux-capture_bytes/
[sessions]: https://libtmux.org/en/julia/latest/reference/libtmux-sessions/
[server]: https://libtmux.org/en/julia/latest/reference/libtmux-server/
[from_env]: https://libtmux.org/en/julia/latest/reference/libtmux-from_env/
[open_server]: https://libtmux.org/en/julia/latest/reference/libtmux-open_server/
[panewhere]: https://libtmux.org/en/julia/latest/reference/libtmux-panewhere/
[panes]: https://libtmux.org/en/julia/latest/reference/libtmux-panes/
[selection]: https://libtmux.org/en/julia/latest/reference/libtmux-selection/
[windows]: https://libtmux.org/en/julia/latest/reference/libtmux-windows/
[windowlinks]: https://libtmux.org/en/julia/latest/reference/libtmux-windowlinks/
[paneoccurrences]: https://libtmux.org/en/julia/latest/reference/libtmux-paneoccurrences/
[send_keys]: https://libtmux.org/en/julia/latest/reference/libtmux-send_keys/
[observe_output]: https://libtmux.org/en/julia/latest/reference/libtmux-observe_output/
[observation_cursor]: https://libtmux.org/en/julia/latest/reference/libtmux-observation_cursor/
[decode_text]: https://libtmux.org/en/julia/latest/reference/libtmux-decode_text/
[capture_baseline]: https://libtmux.org/en/julia/latest/reference/libtmux-capture_baseline/
[open_control]: https://libtmux.org/en/julia/latest/reference/libtmux-open_control/
[wait_for_text]: https://libtmux.org/en/julia/latest/reference/libtmux-wait_for_text/
[watch_screen]: https://libtmux.org/en/julia/latest/reference/libtmux-watch_screen/
[ScreenWaitEnded]: https://libtmux.org/en/julia/latest/reference/libtmux-screenwaitended/
[UnsupportedCapability]: https://libtmux.org/en/julia/latest/reference/libtmux-unsupportedcapability/
[filters]: https://libtmux.org/en/julia/latest/reference/libtmux-filters/
[encode_where]: https://libtmux.org/en/julia/latest/reference/libtmux-encode_where/
[write_where_json]: https://libtmux.org/en/julia/latest/reference/libtmux-write_where_json/
[read_where_json]: https://libtmux.org/en/julia/latest/reference/libtmux-read_where_json/
[project_rows]: https://libtmux.org/en/julia/latest/reference/libtmux-project_rows/
[workspace_install_cli]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-install_cli/
[workspace_validate]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-validate/
[mcp_install_cli]: https://libtmux.org/en/julia/latest/mcp/reference/libtmuxmcp-install_cli/
[tool_list_panes]: https://libtmux.org/en/julia/latest/mcp/tools/list_panes/
[tool_capture_pane]: https://libtmux.org/en/julia/latest/mcp/tools/capture_pane/
[tool_send_keys]: https://libtmux.org/en/julia/latest/mcp/tools/send_keys/
[repo-capabilities-json]: https://github.com/libtmux/libtmux-julia/blob/master/capabilities.json
[repo-docs-criteria-wire-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/criteria-wire.md
[repo-docs-generated-criteria-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/generated/criteria.md
[repo-docs-projections-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/projections.md
[repo-docs-src-compatibility-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/src/compatibility.md
[repo-docs-src-observations-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/src/observations.md
[repo-docs-src-ownership-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/src/ownership.md
[repo-docs-src-queries-md]: https://github.com/libtmux/libtmux-julia/blob/master/docs/src/queries.md
[repo-examples-output_stream-jl]: https://github.com/libtmux/libtmux-julia/blob/master/examples/output_stream.jl
[repo-examples-owned_capture-jl]: https://github.com/libtmux/libtmux-julia/blob/master/examples/owned_capture.jl
[repo-examples-shared_windows-jl]: https://github.com/libtmux/libtmux-julia/blob/master/examples/shared_windows.jl
[repo-license]: https://github.com/libtmux/libtmux-julia/blob/master/LICENSE
[repo-packages-libtmuxmcp]: https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxMCP
[repo-packages-libtmuxworkspace]: https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxWorkspace
[ws-examples-owned_load-jl]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/examples/owned_load.jl

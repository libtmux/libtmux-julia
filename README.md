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

Create tmux sessions, split panes, send input and capture terminal output from
Julia. Read server state into a snapshot, then query it with `filter`, `count`
and other Julia collection functions.

</div>

[Install](#install) · [Quick start](#create-a-session-and-capture-a-pane) ·
[Queries](#filter-with-ordinary-julia) · [Control](#reuse-a-control-connection) ·
[Examples](#examples) · [Packages](#packages) ·
[API reference](https://libtmux.org/en/julia/latest/reference/) ·
[Field reference](docs/generated/criteria.md)

The core uses only Julia standard libraries. Add an experimental companion
for MCP or workspace configuration:

| Package | Use it for |
| --- | --- |
| [**LibTmux**](#libtmux-the-core-library) | Sessions, windows, panes, snapshots and control connections |
| [LibTmuxMCP](packages/LibTmuxMCP) | MCP tools to inspect panes, send keys and wait for output |
| [LibTmuxWorkspace](packages/LibTmuxWorkspace) | Load and freeze tmuxp-style YAML or JSON workspaces |

## Install

The package is unregistered. From your Julia project's directory, add the
core from this tested public source revision:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision="e48057e583ac918c042c58021fac52137bbe05b3"; Pkg.add(Pkg.PackageSpec(url=repo, rev=revision))'
```

Have `tmux` on your `PATH`. Julia 1.10+ and tmux 3.3a+ are the compatibility
targets. Operations refuse an older or unreadable tmux release before they
have any effect; see
[tested platforms and limits](docs/src/compatibility.md). APIs may change
during alpha development. Pkg records the requested revision and package tree
in your project's `Manifest.toml`.

Install the MCP or workspace companion with the matching core revision:
[installation guide](docs/src/installation.md). The packages are not in General.

Open Julia in that project to run the examples below:

```console
$ julia --project=.
```

## Create a session and capture a pane

Create a private server and split its first window. [`with_server`][with_server]
closes the server when the block returns or throws; the snapshot remains
readable. The block also calls [`new_session`][new_session],
[`split_window`][split_window], [`snapshot`][snapshot] and
[`capture_pane`][capture_pane].

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

`screen` contains the pane's UTF-8 text. These panes run `cat`, so their
initial screens are blank. Use [`capture_bytes`][capture_bytes] for the
original bytes, or follow the
[send-and-observe example](examples/output_stream.jl) to read output as it
arrives. The [capture program](examples/owned_capture.jl) also verifies server
cleanup.

To use an existing server, select it with [`Server(socket_name="work")`][server]
or `Server(socket_path=...)`. Inside tmux, [`from_env()`][from_env] selects the
server from your environment. These descriptions borrow the server; they do
not own it.

## Filter with ordinary Julia

Continue with `snap` above. A closure or a reusable criterion such as
[`PaneWhere`][panewhere] filters the captured data without contacting tmux:

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
ordered, read-only [`Selection <: AbstractVector`][selection]; `collect` gives
you a vector. Use
`only` when you require exactly one result. Call `snapshot(server)` again
while the server is open to read fresh state.

A window can belong to several sessions. [`windows(snap)`][windows] and
`panes(snap)` contain physical objects; [`windowlinks(snap)`][windowlinks] and
[`paneoccurrences(snap)`][paneoccurrences] preserve each session's context.
The [shared-window example](examples/shared_windows.jl) shows two windows,
three links and five pane occurrences, plus relation queries.

[Queries and relations](docs/src/queries.md) ·
[Filterable fields](docs/generated/criteria.md) ·
[JSON criteria](docs/criteria-wire.md) · [Tables projections](docs/projections.md).
JSON and Tables integrations are optional. At the Julia prompt, `?PaneWhere`
and `?capture_pane` show API help.

## Reuse a control connection

A plain server starts a tmux client process for each command. A control
connection from [`open_control`][open_control] keeps one client open for
repeated operations. Both yield during I/O; use `Threads.@spawn` and `fetch`
to overlap calls with Julia Tasks:

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

`screens` contains both pane captures. The inner block closes the client;
the outer block closes the server. A control client counts as attached in
tmux. Connection loss is terminal, and cancelling a sent operation does not
undo its effects. See [ownership and cancellation](docs/src/ownership.md)
and [output streams](docs/src/observations.md) for deadlines and cleanup.

## Examples

Each program creates and cleans up its own tmux server:

| Task | Program |
| --- | --- |
| Create a session and capture its screen | [owned_capture.jl](examples/owned_capture.jl) |
| Query shared windows and their panes | [shared_windows.jl](examples/shared_windows.jl) |
| Cancel a waiting control operation | [control_cancel.jl](examples/control_cancel.jl) |
| Send text and subscribe to pane output | [output_stream.jl](examples/output_stream.jl) |
| Read an authored command's completion marker and exit status | [command_completion.jl](examples/command_completion.jl) |

To run the programs, clone the source:

```console
$ git clone \
    https://github.com/libtmux/libtmux-julia.git
```

```console
$ cd libtmux-julia
```

```console
$ git checkout e48057e583ac918c042c58021fac52137bbe05b3
```

```console
$ julia \
    --project=. \
    examples/shared_windows.jl
```

The [MCP guide](packages/LibTmuxMCP) and
[workspace guide](packages/LibTmuxWorkspace) include their own installation
and launcher commands. The [workspace example](packages/LibTmuxWorkspace/examples/owned_load.jl)
loads a configuration and checks its layout, focus and cleanup.

## Packages

This repository holds three Julia packages. Each heading links to the
package's directory on GitHub. None is in the General registry yet, so no
registry page exists; [Install](#install) uses a public source revision.

### [LibTmux](https://github.com/libtmux/libtmux-julia/tree/master/src): the core library

Sessions, windows, panes, snapshots and control connections, using only Julia
standard libraries.

[API reference](https://libtmux.org/en/julia/latest/reference/) ·
[Guides](https://libtmux.org/en/julia/latest/guides/) ·
[Examples](https://libtmux.org/en/julia/latest/examples/)

The [quick start](#create-a-session-and-capture-a-pane),
[queries](#filter-with-ordinary-julia) and
[control connection](#reuse-a-control-connection) programs above run against
this package. A [`PaneWhere`][panewhere] criterion is also plain data: the
[`Filters`][filters] module supplies its comparisons, and
[`encode_where`][encode_where] converts it to a document without contacting
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

[Portable criteria](docs/criteria-wire.md) ·
[Tables projections](docs/projections.md)

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

### [LibTmuxWorkspace](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxWorkspace): tmuxp-style workspaces

Read a YAML or JSON workspace, plan it without contacting tmux, apply it to a
server and freeze a running session back into a file.

[API reference](https://libtmux.org/en/julia/latest/workspace/reference/) ·
[Guide](https://libtmux.org/en/julia/latest/workspace/source-guide/) ·
[Package README](packages/LibTmuxWorkspace)

From a checkout, after [`install_cli`][workspace_install_cli] creates
`bin/libtmux-workspace`, [`validate`][workspace_validate] checks the shipped
configuration without contacting tmux:

```console
$ bin/libtmux-workspace validate packages/LibTmuxWorkspace/examples/workspace.yaml
```

```text
valid
```

### [LibTmuxMCP](https://github.com/libtmux/libtmux-julia/tree/master/packages/LibTmuxMCP): a tmux server for agents

A local stdio MCP server for one tmux server that you name. Its default tools
list panes, capture a pane and send keys.

[API reference](https://libtmux.org/en/julia/latest/mcp/reference/) ·
[Tools](https://libtmux.org/en/julia/latest/mcp/tools/) ·
[Guide](https://libtmux.org/en/julia/latest/mcp/source-guide/) ·
[Package README](packages/LibTmuxMCP)

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

The [MCP README](packages/LibTmuxMCP) covers other clients and every tool.

## Status and development

[Compatibility](docs/src/compatibility.md) separates baseline correctness from
current development gates. Complete loop budgets, final installed workflows,
benchmark limits and independent adoption review remain open. Check the
[capability manifest](docs/capabilities.toml) and
[CI results](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
for current evidence. WSL is a Linux host; native Windows tmux is outside scope.

[Contributing and checks](CONTRIBUTING.md) ·
[Troubleshooting](docs/src/troubleshooting.md) ·
[Benchmarks](benchmark/README.md) · [Changelog](CHANGELOG.md).

Core, MCP and workspace packages use the [MIT license](LICENSE).

## Attribution

Please use the following BibTeX template to cite libtmux-julia in scientific discourse:

```bibtex
@misc{libtmux-julia,
   author = {Tony Narlock},
   year = {2026},
   note = {https://libtmux.org},
   title = {libtmux-julia: Julia wrapper for tmux}
}
```

[with_server]: https://libtmux.org/en/julia/latest/reference/libtmux-with_server/
[new_session]: https://libtmux.org/en/julia/latest/reference/libtmux-new_session/
[split_window]: https://libtmux.org/en/julia/latest/reference/libtmux-split_window/
[snapshot]: https://libtmux.org/en/julia/latest/reference/libtmux-snapshot-1gv6/
[capture_pane]: https://libtmux.org/en/julia/latest/reference/libtmux-capture_pane/
[capture_bytes]: https://libtmux.org/en/julia/latest/reference/libtmux-capture_bytes/
[server]: https://libtmux.org/en/julia/latest/reference/libtmux-server/
[from_env]: https://libtmux.org/en/julia/latest/reference/libtmux-from_env/
[panewhere]: https://libtmux.org/en/julia/latest/reference/libtmux-panewhere/
[panes]: https://libtmux.org/en/julia/latest/reference/libtmux-panes/
[selection]: https://libtmux.org/en/julia/latest/reference/libtmux-selection/
[windows]: https://libtmux.org/en/julia/latest/reference/libtmux-windows/
[windowlinks]: https://libtmux.org/en/julia/latest/reference/libtmux-windowlinks/
[paneoccurrences]: https://libtmux.org/en/julia/latest/reference/libtmux-paneoccurrences/
[open_control]: https://libtmux.org/en/julia/latest/reference/libtmux-open_control/
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

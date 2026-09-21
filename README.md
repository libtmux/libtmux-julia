# LibTmux.jl

Create tmux sessions, split panes, send input and capture terminal output from
Julia. Read server state into a snapshot, then query it with `filter`, `count`
and other Julia collection functions.

[Install](#install) · [Quick start](#create-a-session-and-capture-a-pane) ·
[Queries](#filter-with-ordinary-julia) · [Control](#reuse-a-control-connection) ·
[Examples](#examples) · [Field reference](docs/generated/criteria.md)

The core uses only Julia standard libraries. Add a companion for MCP or
workspace configuration:

| Package | Use it for |
| --- | --- |
| **LibTmux** | Sessions, windows, panes, snapshots and control connections |
| [LibTmuxMCP](packages/LibTmuxMCP) | MCP tools to inspect panes, send keys and wait for output |
| [LibTmuxWorkspace](packages/LibTmuxWorkspace) | Load and freeze tmuxp-style YAML or JSON workspaces |

## Install

`v0.1.0-alpha.1` is an unregistered source release. From your Julia project's
directory, add the core from its public Git tag:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); Pkg.add(Pkg.PackageSpec(url="https://github.com/libtmux/libtmux-julia.git", rev="v0.1.0-alpha.1"))'
```

Have `tmux` on your `PATH`. Julia 1.10+ and tmux 3.2a+ are the compatibility
targets; see [tested platforms and limits](docs/src/compatibility.md). APIs
may change during alpha development. Pkg records the requested revision and
package tree in your project's `Manifest.toml`.

Install the MCP or workspace companion with the matching core specification:
[installation guide](docs/src/installation.md). The alpha is not in General.

Open Julia in that project to run the examples below:

```console
$ julia --project=.
```

## Create a session and capture a pane

Create a private server and split its first window. `with_server` closes the
server when the block returns or throws; the snapshot remains readable.

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
initial screens are blank. Use `capture_bytes` for the original bytes, or
follow the [send-and-observe example](examples/output_stream.jl) to read output
as it arrives. The [capture program](examples/owned_capture.jl) also verifies
server cleanup.

To use an existing server, select it with `Server(socket_name="work")` or
`Server(socket_path=...)`. Inside tmux, `from_env()` selects the server from
your environment. These descriptions borrow the server; they do not own it.

## Filter with ordinary Julia

Continue with `snap` above. A closure or a reusable criterion filters the
captured data without contacting tmux:

```julia
filter(pane -> pane.active, panes(snap))

import LibTmux.Filters as F
wide = PaneWhere(active=true, width=F.AtLeast(80))

filter(wide, panes(snap))
count(wide, panes(snap))
any(wide, panes(snap))
[pane.id for pane in Iterators.filter(wide, panes(snap))]
```

Criteria are callable values. Filtering `panes(snap)` returns an ordered,
read-only `Selection <: AbstractVector`; `collect` gives you a vector. Use
`only` when you require exactly one result. Call `snapshot(server)` again
while the server is open to read fresh state.

A window can belong to several sessions. `windows(snap)` and `panes(snap)`
contain physical objects; `windowlinks(snap)` and `paneoccurrences(snap)`
preserve each session's context. The [shared-window example](examples/shared_windows.jl)
shows two windows, three links and five pane occurrences, plus relation queries.

[Queries and relations](docs/src/queries.md) ·
[Filterable fields](docs/generated/criteria.md) ·
[JSON criteria](docs/criteria-wire.md) · [Tables projections](docs/projections.md).
JSON and Tables integrations are optional. At the Julia prompt, `?PaneWhere`
and `?capture_pane` show API help.

## Reuse a control connection

A plain server starts a tmux client process for each command. A control
connection keeps one client open for repeated operations. Both yield during
I/O; use `Threads.@spawn` and `fetch` to overlap calls with Julia Tasks:

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

To run the programs, clone the source:

```console
$ git clone \
    --branch v0.1.0-alpha.1 \
    --depth 1 \
    https://github.com/libtmux/libtmux-julia.git
```

```console
$ cd libtmux-julia
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

## Status and development

The four CI cells in [Compatibility](docs/src/compatibility.md) passed the
complete package suite. Benchmark baselines and an independent guide walkthrough
remain open. Check the
[capability manifest](docs/capabilities.toml) and
[CI results](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
for current evidence. WSL is a Linux host; native Windows tmux is outside scope.

[Contributing and checks](CONTRIBUTING.md) ·
[Troubleshooting](docs/src/troubleshooting.md) ·
[Benchmarks](benchmark/README.md) · [Changelog](CHANGELOG.md).

Core, MCP and workspace packages use the [MIT license](LICENSE).

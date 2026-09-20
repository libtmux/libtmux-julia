# LibTmux.jl

Create sessions, split panes, capture terminal output and query tmux from Julia.
The core uses only Julia standard libraries. MCP and workspace tools are
separate packages.

[Quick start](#create-a-session-and-capture-a-pane) ·
[Query reference](docs/generated/criteria.md) ·
[Examples](#examples) · [MCP](packages/LibTmuxMCP) ·
[Workspaces](packages/LibTmuxWorkspace)

## Install

Development packages, not yet registered. Julia 1.10+ and tmux 3.2a+ are the
compatibility targets; see [tested platforms and limits](docs/src/compatibility.md).
Install Julia and tmux, then check out the implementation branch:

```console
$ git clone \
    --branch initial-pr \
    https://github.com/libtmux/libtmux-julia.git
```

```console
$ cd libtmux-julia
```

```console
$ julia \
    --project=. \
    -e 'using Pkg; Pkg.instantiate()'
```

Open Julia in this project to try the examples below:

```console
$ julia --project=.
```

## Create a session and capture a pane

This example starts a private tmux server with one pane. `with_server` closes
its daemon when the block returns or throws. The captured data remains usable.

```julia
using LibTmux

snap, screen = with_server() do server
    new_session(server; name="demo", command=["/bin/cat"])
    snap = snapshot(server)
    pane = only(panes(snap))
    snap, capture_pane(server, pane.ref)
end

only(sessions(snap)).name
length(panes(snap))
```

The snapshot contains session `"demo"` and one pane. The pane runs `cat`, so
its initial screen is blank. `capture_pane` returns UTF-8 text; use
`capture_bytes` when you need the original bytes.
The [complete program](examples/owned_capture.jl) also checks cleanup.

To use an existing server, select it with `Server(socket_name="work")` or
`Server(socket_path=...)`. Inside tmux, `from_env()` selects the server from
your environment. These descriptions borrow the server; they do not own it.

## Filter with ordinary Julia

Use the `snap` captured above. These expressions read local data and make no
tmux calls:

```julia
filter(pane -> pane.active, panes(snap))

import LibTmux.Filters as F
wide = PaneWhere(active=true, width=F.AtLeast(80))

filter(wide, panes(snap))
count(wide, panes(snap))
any(wide, panes(snap))
[pane.id for pane in Iterators.filter(wide, panes(snap))]
```

Criteria are callable values. `filter` returns an ordered, read-only
`Selection <: AbstractVector`; `collect` gives you an ordinary vector.
Use `only` when you require exactly one result. Reacquire with
`snapshot(server)` when you want fresh state.

A window can belong to several sessions. `windows(snap)` and `panes(snap)`
contain physical objects; `windowlinks(snap)` and `paneoccurrences(snap)`
preserve each session's context. The [shared-window example](examples/shared_windows.jl)
shows two windows, three links and five pane occurrences, plus relation queries.

Read more: [Queries and relations](docs/src/queries.md) ·
[Filterable fields](docs/generated/criteria.md) ·
[JSON criteria](docs/criteria-wire.md) · [Tables projections](docs/projections.md).
JSON and Tables integrations are optional.
At the Julia prompt, `?PaneWhere` and `?capture_pane` show API help.

## Reuse a control connection

A control connection keeps one tmux client open for repeated operations.
Remote calls yield during I/O; use `Threads.@spawn` and `fetch` to overlap
work with ordinary Julia Tasks. This example captures both panes through
one connection.

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

The inner block closes the client; the outer block closes the owned server.
A control client counts as attached in tmux. Connection loss is terminal,
and cancelling a sent operation does not undo its effects. See
[ownership and cancellation](docs/src/ownership.md) and
[output streams](docs/src/observations.md) for deadlines, bounds and cleanup.

## Examples

Each program creates and cleans up its own tmux server:

| Task | Program |
| --- | --- |
| Create a session and capture its screen | [owned_capture.jl](examples/owned_capture.jl) |
| Query shared windows and their panes | [shared_windows.jl](examples/shared_windows.jl) |
| Cancel a waiting control operation | [control_cancel.jl](examples/control_cancel.jl) |
| Subscribe to pane output | [output_stream.jl](examples/output_stream.jl) |

Run one from the checkout:

```console
$ julia \
    --project=. \
    examples/shared_windows.jl
```

## MCP and workspaces

Install the consumer you need alongside the core:

| Package | Use it to |
| --- | --- |
| [LibTmuxMCP](packages/LibTmuxMCP) | Give an MCP client tools to list panes, capture output, send keys and wait for text |
| [LibTmuxWorkspace](packages/LibTmuxWorkspace) | Validate, plan, load and freeze tmuxp-style YAML or JSON workspaces |

Both guides include installation and launcher commands. The
[workspace example](packages/LibTmuxWorkspace/examples/owned_load.jl) loads
an isolated workspace and checks its layout, focus and cleanup.

## Status and development

The API is under development. Full platform admission, benchmark baselines
and an independent guide walkthrough remain open. Check the
[capability manifest](docs/capabilities.toml) and
[CI results](https://github.com/libtmux/libtmux-julia/actions/workflows/julia.yml)
for current evidence. WSL is a Linux host; native Windows tmux is outside scope.

[Contributing and checks](CONTRIBUTING.md) ·
[Troubleshooting](docs/src/troubleshooting.md) ·
[Benchmarks](benchmark/README.md) · [Changelog](CHANGELOG.md).

Core, MCP and workspace packages use the [MIT license](LICENSE).

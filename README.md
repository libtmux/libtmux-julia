# LibTmux.jl

Control tmux from Julia with explicit server selection, captured object
graphs, ordinary predicates and owned process cleanup. Remote operations
yield during I/O; use Julia Tasks for concurrency.

The package suite is under development. Core operations and criteria have
real-tmux verification; control, MCP and workspace products are still being
completed. The [capability manifest](docs/capabilities.toml) records what has
been implemented and what remains unverified. No registry release is claimed.

## Start with an owned server

Prepare the checkout with Julia and tmux available:

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using Pkg; Pkg.instantiate()'
```

Run the [create, capture and cleanup example](examples/owned_capture.jl):

```console
$ julia \
    --startup-file=no \
    --project=. \
    examples/owned_capture.jl
```

`with_server` starts a private daemon, calls your function with its endpoint,
and closes the daemon before returning, including when the function fails.
For an existing server, construct `Server(socket_path=...)` or
`Server(socket_name=...)`. Ambient selection requires an explicit `from_env()`
call. Ordinary server descriptions do not own or destroy borrowed sessions.

## Work with captured data

Acquire a graph with `snapshot(server)`, then use `panes`, `windows`,
`sessions` and Julia's `filter`, `count`, `only` and `Iterators.filter`.
`PaneWhere`, `WindowWhere` and related constructors are callable criteria.
Filtering captured data performs no tmux I/O. Missing coverage raises an
error instead of behaving like an empty relation.

Physical windows are distinct from their session links. The
[shared-window example](examples/shared_windows.jl) creates two windows,
three links, three physical panes and five pane occurrences. It queries the
captured graph after its owned daemon has stopped.

## Choose explicit effects and ownership

Use references returned by creation or snapshot operations when sending
keys, capturing panes or changing topology. `send_keys` never adds Enter.
`capture_bytes` preserves bytes; `capture_pane` validates UTF-8.
`RawFormat` explicitly permits executable tmux format expressions.

Subprocess generation checks are best effort. Cancelling a sent operation
does not undo its remote effects. Control connection loss is terminal;
operations are never replayed or moved silently to another transport. See
the [control cancellation example](examples/control_cancel.jl).

## Packages and reference

| Package | Responsibility |
| --- | --- |
| `LibTmux` | Core operations, snapshots, criteria and transports |
| [LibTmuxMCP](packages/LibTmuxMCP) | MCP application using public core APIs |
| [LibTmuxWorkspace](packages/LibTmuxWorkspace) | Workspace plans and tmuxp-style loading |

JSON and Tables support are optional extensions. See the
[criteria wire contract](docs/criteria-wire.md),
[row projections](docs/projections.md),
[generated criterion fields](docs/generated/criteria.md) and
[development checks](CONTRIBUTING.md).

Julia 1.10 and tmux 3.2a are proposed floors with focused verification.
The full product and platform matrix remains open; WSL checks count as
Linux, and no macOS result is implied.

## License

Core, MCP, and workspace packages use the [MIT license](LICENSE).

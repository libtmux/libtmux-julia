# bench-mcp-client

An independent stdio client for the installed MCP launcher. It measures one
workflow sample and one stopped-reader sample per run.
[`benchmark/mcp.jl`](../../benchmark/mcp.jl) starts it for every launcher
profile it compares.

The client owns the launcher's pipes and speaks newline-delimited JSON to it.
It does not use the package's own transport. One `poll` waits for output,
stderr, the launcher's exit and room to write, and the client never polls for
readiness. The workflow sample lists and captures panes, creates a session,
cancels a wait and closes stdin. The stopped-reader sample shrinks the stdout
pipe, stops reading with a reply pending, cancels, closes stdin and requires
the launcher to exit. Where the system reports no pipe capacity, the sample
says so instead of claiming a result.

Before it starts the launcher, the client runs its own code against `cat`, so
no measured interval includes compilation. `child_max_rss_bytes` comes from
`wait4` and cannot fall below the client's own peak, which the report names as
`spawner_max_rss_bytes`.

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    scripts/bench-mcp-client/bench-mcp-client.jl \
    --launcher "$launcher" \
    --socket "$socket" \
    --tmux tmux \
    --pane '%0' \
    --output benchmark/results/client.json
```

The tests run the client against a stand-in launcher that needs no tmux, and
check the protocol walk, the byte bounds, the deadline and the clean exit.
They also fail a sample on a changed fixture and on an unclean exit. They need
only `JSON`:

```console
$ julia \
    --startup-file=no \
    --project=scripts/bench-mcp-client \
    scripts/bench-mcp-client/tests/runtests.jl
```

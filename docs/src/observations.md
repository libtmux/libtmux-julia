# Observe pane output

Use [`observe_output`](@ref) for raw future terminal bytes. A screen capture
is a separate observation: [`capture_baseline`](@ref) returns captured bytes
and an explicit `:reset` boundary. Its before/after cursors do not establish
an atomic relationship between the screen and the stream.

This program checks the exact bytes of terminal echo. Echo does not prove
that a command started, finished or succeeded.

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "examples", "output_stream.jl"), String) * "\n```")
```

Each stream has one consumer and independent item/byte limits. A slow
consumer loses its own stream with [`ObservationLost`](@ref); it cannot block
the shared control reader. `take!` accepts `timeout` and `cancel`. Always use
the callback form or close explicitly, including after an iteration error.
An unreachable stream is eventually retired, but GC does not provide a cleanup
deadline.

[`observation_cursor`](@ref) identifies the last consumed event. Replay with
`after=cursor` is limited to the same connection and retained history:
256 records or 4 MiB, shared across event types. Foreign, expired or
topology-invalidated cursors require a new stream and baseline. Retaining a
cursor does not retain history. Closing the connection invalidates replay.

[`notifications`](@ref) observes tmux notifications. [`subscribe_format`](@ref)
observes sampled field changes and preserves window-link context. tmux's
roughly one-second subscription cadence cannot establish prompt readiness
or output quiescence. Pane movement or removal requires a new subscription.
Use [`format_value`](@ref) to decode a format update's escaped bytes locally;
literal tabs, newlines and backslashes are preserved.

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

## Wait for text or inactivity

[`wait_for_text`](@ref) matches a literal string in future raw output.
[`wait_for`](@ref) accepts a predicate over [`OutputWaitResult`](@ref), including
its bounded UTF-8 text, source, cursor and omitted-byte counters. Both share one
total deadline across capture, predicate calls and stream reads. Predicates run
outside the reader lock and must return promptly; synchronous Julia code cannot
be forcibly interrupted. Cancellation and the deadline are checked again before
accepting a result. The caller keeps ownership of the stream and connection.

By default waits consider only output consumed by that call. Register a new
stream before sending input when freshness matters. `baseline=true` separately
tests an initial screen capture and returns `source == :baseline` with `:reset`
continuity if it matches. A rejected screen is never joined to raw bytes.
An oversized baseline raises `OutputLimitExceeded`; a streamed tail instead
omits older decoded bytes and reports `dropped_bytes`. An actual output gap,
overflow or topology change raises `ObservationLost` and requires a new stream.

Literal matching searches each decoded event before retaining text. A marker
in the middle of a large event remains eligible; returned text ends at that
match. Later bytes in the event are received but omitted from the result.
The result cursor covers that entire consumed event; it cannot resume inside
the event to recover omitted bytes.
Generic predicates inspect the latest bounded tail and must account for omitted
history. UTF-8 spans event boundaries; strict decoding rejects malformed input.
The retained decoder suffix is at most three bytes. Terminal escape sequences
remain data. Streaming `mode=:rendered` is unsupported; use explicit screen
captures for rendered observations.

Successive waits on the same consumer task retain incomplete UTF-8, including
after cancellation or a predicate exception. The stream permits one active
helper and refuses raw reads during it. Raw reads between helpers advance the
cursor without updating the decoder, so later text waits require a new stream.
Changing `invalid` requires an empty decoder suffix. A strict decoding error
closes the decoder; acquire a new stream before another text wait.

[`wait_for_quiet`](@ref) reports only that this client received no output event
for the requested inactivity interval. It never reports quiet when its total
deadline expires, and it never establishes process success. Queued output,
cancellation and stream loss remain observable. Matching text can also come
from terminal echo or another writer.
Quiet acceptance checks the queue, stream health and last-consumed cursor
together under the connection lock; this boundary is local to the client.

## Observe an authored command's exit status

This program registers output before submitting a command. Its authored shell
wrapper prints a fresh marker and the child's exit status after the child
finishes. The marker is absent from submitted input, so terminal echo cannot
satisfy the wait. The command deliberately exits with status 1; the program
checks that failure rather than interpreting payload text or silence as success.
All processes and control clients belong to the example's owned server.

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "examples", "command_completion.jl"), String) * "\n```")
```

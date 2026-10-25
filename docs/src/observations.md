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

A wait whose pane exited, or whose tmux server stopped, raises
[`OutputWaitEnded`](@ref) instead. Its `reason` is `:pane_exited` or
`:server_exited` and its `text` is the output the wait had seen, so the caller
can report a failed wait with that output; nothing is left to observe and a new
baseline cannot help. A live pane whose stream dropped still raises
`ObservationLost`. The wait asks tmux only when its stream ends, and a probe
that fails for any other reason leaves the original error in place.

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

## Wait for text on the screen

[`wait_for_text`](@ref)`(server, pane, text)` polls `capture-pane` on every
supported tmux release and opens no control client. It reads the visible screen
only, joins wrapped rows, and returns a [`ScreenWaitResult`](@ref). Use it
below tmux 3.7, or wherever a screen is the evidence you want; the stream
method above reads raw output and needs a control connection. Every read starts
its own tmux client process, so an open control connection never carries one.

```julia
using LibTmux

with_server() do server
    new_session(server; name="shell")
    pane = only(panes(snapshot(server))).ref
    watch_screen(server, pane) do screen
        send_keys(server, pane, "printf 'ready-%s\\n' now", "Enter")
        wait_for_text(screen, "ready-now")
    end
end
```

[`watch_screen`](@ref) takes the entry read when it opens, so keys sent inside
the block cannot be counted as already on the screen. The server form is
`watch_screen` plus one wait. Its `timeout` is one deadline from the entry read.

By default only text that appears after the entry read counts. The entry read
sets a bar equal to the number of occurrences on the screen, and a later read
matches when its count exceeds the bar. The bar is never lowered, so text that
scrolls off or is repainted cannot invent a match. `baseline=true` lets text
already on the entry screen match at once, with `matched_at_entry` set and
`source == :baseline`.

Each read is one tmux invocation: `capture-pane -p -J` followed by a hook-free
`run-shell -C` marker that reports the pane id, whether the pane is dead,
whether the pane shows the alternate screen and which server generation
answered. A pane from another server, or from an earlier generation of this
one, raises `CrossServerReference` or `StaleReference` instead of reading
another pane. The capture runs the owner's `after-capture-pane` hook, and a
hook that prints adds its output to the captured text. A read on the alternate
screen, where a full-screen program such as `less` or `vim` is up, is not
compared. A pane that is dead, a pane tmux no longer knows and a server that is
gone raise [`ScreenWaitEnded`](@ref) with the last screen read; cancellation
raises `RequestCancelled` and an expired deadline raises `DeadlineExceeded`, as
for every other operation. Every wait in a [`watch_screen`](@ref) block counts
against the entry read taken when the block opened. When `max_bytes` cuts the
screen, the match can lie in the dropped head of `text`.

The limits follow from reading a screen. Text that scrolled off is not seen. A
repaint shows only its final state, where the control stream shows every state.
If an old occurrence scrolls off and a new one arrives between two reads, the
count does not rise. Typed echo that contains the text counts as an occurrence,
so match on what a command prints, not on the command.

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

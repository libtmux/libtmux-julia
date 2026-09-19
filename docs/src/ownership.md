# Ownership and I/O

| Resource | Owner | Retirement |
| --- | --- | --- |
| Private daemon | [`OwnedServer`](@ref) | `close` or [`with_server`](@ref) |
| Borrowed endpoint | Caller | LibTmux never destroys it implicitly |
| Control clients | [`ControlConnection`](@ref) | `close` or `open_control` callback |
| Cancellation callback | [`CancellationSubscription`](@ref) | `close` |
| Capture spool/buffer | Capture operation | Success/failure cleanup |
| Snapshot/selection | Caller references | Ordinary Julia lifetime |

Remote functions return normal results. For concurrency, call them from
`Threads.@spawn` and fetch their results. Cancellation wakes owned work
through [`CancellationToken`](@ref); it does not undo commands already sent.
Before submission, a cancelled request sends nothing. After submission, its
effects can be uncertain and a control ledger slot remains occupied until
the backend reply is retired.

Typed `Server` operations share these keyword controls in addition to their
operation-specific arguments:

| Keyword | Default | Contract |
| --- | --- | --- |
| `timeout` | `5.0` seconds | One finite budget for validation, acquisition and command I/O |
| `cancel` | `nothing` | Optional `CancellationToken`; cancellation does not roll back effects |
| `strict` | `false` | `true` refuses subprocess generation semantics before execution |

Screen capture also accepts `max_bytes` (8 MiB by default); text capture
rejects invalid UTF-8 unless replacement is explicit. `load_buffer` chooses
an owned random name and returns its `BufferRef`; it has no `name` keyword.
Inspect each method's signature for specialized transport, acquisition and
lifecycle controls. Construction, filtering, iteration and display have no
remote timeout because they perform no tmux I/O.

Subprocess generation checks compare observed daemon identity before acting;
the check/use interval remains best effort. `strict=true` refuses unsupported
subprocess operations. A control connection stays bound to its daemon and
becomes terminal on connection loss. There is no reconnect or mutation replay.

Control ownership uses two attached clients, including an auxiliary client
for retiring library-owned waits. Attach/detach hooks, attached-client counts,
size policies and last-client settings remain observable tmux behavior.
Configured aliases and hooks are trusted and must preserve admitted command
semantics. Arbitrary raw commands are available through the subprocess
escape hatch; the control allowlist is narrower because raw payloads can
resemble protocol guards.

Choose the transport explicitly. Unsupported routes have no implicit fallback.

| Operation | `Server` | `ControlConnection` |
| --- | --- | --- |
| Snapshots and captured local queries | Yes | Yes |
| Binary/text screen capture | Yes | Yes, through an owned buffer/spool |
| New windows, split panes and key input | Yes | Yes, with exact typed targets |
| Session creation, topology and configuration | Yes | Typed methods pending |
| Typed format reads | Yes | Yes, with escaped reply rows |
| Raw format rendering and discovery hints | Yes | Not admitted to the control reply grammar |
| Raw future output, notifications and sampled format subscriptions | No | Yes |
| Arbitrary raw tmux argv | Yes | Restricted audited command grammar |
| Independent batches | Yes | Audited commands only |
| Explicit semicolon groups | Aggregate evidence; per-item attribution unknown | Audited commands with per-item evidence |

[`run_batch`](@ref) continues independent commands after an error. Results
preserve input order; concurrent execution order is unspecified.
[`run_group`](@ref) submits an explicit semicolon group. It can skip a suffix
after an error and never rolls back successful earlier effects. Inspect each
item's completed, failed, skipped or unknown status before deciding what to do
next. A group is not a transaction.

[`capture_bytes`](@ref) over control uses an owned buffer and private local
file. A same-queue fence confirms file completion; `%end` alone does not.
The daemon must share the local filesystem. Its file write can block the
tmux event loop even while Julia's caller yields.

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "examples", "control_cancel.jl"), String) * "\n```")
```

Close failure remains an error. A dead primary control client can prevent
proof of remote retirement even after local clients and tasks have stopped.
When a callback and cleanup both fail, inspect both entries in the resulting
`CompositeException`.

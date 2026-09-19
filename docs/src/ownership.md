# Ownership and I/O

| Resource | Owner | Retirement |
| --- | --- | --- |
| Private daemon | [`OwnedServer`](@ref) | `close` or [`with_server`](@ref) |
| Borrowed endpoint | Caller | LibTmux never destroys it implicitly |
| Control clients | [`ControlConnection`](@ref) | `close` or `open_control` callback |
| Cancellation callback | [`CancellationSubscription`](@ref) | `close` |
| Capture/paste spool and temporary buffer | I/O operation | Success/failure cleanup |
| Buffer returned by `load_buffer` | Caller | Explicit `delete_buffer` |
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
| Session creation, topology and layouts | Yes | Yes, with explicit references and links |
| Client switch/detach | Yes | Yes, with an observed client incarnation check |
| Paste and buffer load/save/delete | Yes | Yes, through an owned local spool |
| Environment set/unset/remove | Yes | Yes |
| Environment reads | Yes | Refused: encoded presence/hidden/removal metadata is unavailable |
| Options and sparse hooks | Yes | Exact names/scopes; hook storage uses a restricted grammar |
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

Control paste and buffer load/save use the same local-filesystem boundary.
`paste_bytes` preserves input bytes without adding Enter or converting LF to
CR; the terminal application may still transform input. Capture and paste
retire their temporary buffers. `load_buffer` transfers buffer ownership to
the caller. Failed cleanup retains the buffer reference in
`ControlBufferCleanupError`, alongside any primary error.

Control client methods verify the captured name and PID/creation-time pair.
That check cannot reserve the client against concurrent replacement. Client
names containing spaces or control bytes are refused because tmux emits them
as unescaped notification fields. Buffer methods permit spaces but refuse
control bytes. Detaching the connection's own client may close it before the
completion fence and leave the effect uncertain.

Control configuration reads request one exact option or hook name. They never
read a broad option listing, whose user-defined names can contain raw newlines.
`inherit=true` follows explicit parents only when the local option is absent.
An empty string or empty array masks inheritance; a missing sparse index stays
missing. Hook reads preserve tmux's canonical command bodies and numeric indices.

The generated option catalog pins metadata from tmux 3.2a through 3.7c.
Most entries have stable types and scopes. Seven require an exact pinned
version: `allow-passthrough`, `destroy-unattached`, `pane-border-format`,
`pane-border-style`, `pane-active-border-style`, `window-linked` and
`window-unlinked`. Those seven are refused on an unpinned version such as
3.7d; other catalog entries still use named commands to check availability.
Unknown names and incompatible scopes are rejected. Unavailable built-ins and
target errors retain their `ControlResult` instead of becoming absent values.

Unrestricted string option values retain literal tabs and newlines. Values
that tmux may echo in validation errors must be printable UTF-8. Scalar
command options and `set_hook` accept literal command names, quoted arguments,
punctuation escapes and semicolon-separated commands. Expansion, comments,
command blocks and escapes that decode into control bytes are refused. This
validates storage; executing a hook must still respect the trusted hook
contract above. A failed whole-array assignment may already have cleared it.

`get_environment(connection, ...)` raises `UnsupportedCapability`: the
researched control dialects cannot encode the complete `EnvironmentValue`
contract. Raw environment output can contain newlines, while format lookup
loses absence, hidden/removal flags and local/global origin. Use an explicit
`Server` read when its best-effort identity semantics meet the caller's needs.
Environment writes remain available through the control connection.

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "examples", "control_cancel.jl"), String) * "\n```")
```

Close failure remains an error. A dead primary control client can prevent
proof of remote retirement even after local clients and tasks have stopped.
When a callback and cleanup both fail, inspect both entries in the resulting
`CompositeException`.

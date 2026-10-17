# Servers and commands

Connect to a tmux server through subprocess commands or a control connection.
The [ownership guide](ownership.md) explains command budgets, cancellation,
and resource cleanup.

## Servers and control connections

```@autodocs
Modules = [LibTmux]
Pages = ["src/server.jl", "src/control.jl"]
Private = false
Order = [:module, :type, :function]
```

## Commands and batches

### Cancellation and failures

Create a [`CancellationToken`](@ref), pass it as `cancel=token`, then call
`cancel!(token)` to request cancellation. The call is idempotent and runs
registered callbacks on its calling task, outside the token lock. Callback
failures are raised together after all callbacks run. See [`on_cancel`](@ref)
for callback ownership and [`run_command`](@ref) for client retirement.

A token does not establish a deadline; use the operation's `timeout` for that.
Cancellation retires local work and does not undo submitted tmux commands or
stop remote pane jobs. Typed operation budgets include validation and I/O;
raw `run_command` accepts `timeout=nothing` and performs no generation check.

| Failure | Meaning |
| --- | --- |
| `LibTmuxError` | Base type for library errors; do not treat all subclasses as retryable. |
| `TmuxNotFound`, `ProcessSpawnError` | The tmux executable or local client could not be started; `cause` retains the local failure. |
| `CommandError` | A completed client exited unsuccessfully with `check=true`; `result` retains output and exit evidence. |
| `RequestCancelled`, `DeadlineExceeded` | Cancellation or timeout won. `sent` distinguishes pre-submission refusal from possible remote effects; `result` retains available client evidence. |
| `OutputLimitExceeded`, `ProcessIOError` | Bounded output overflow or pipe I/O failure; `result` retains available client evidence. `check=false` does not suppress these failures. |
| `CrossServerReference` | A reference belongs to a different endpoint. |
| `StaleReference` | A reference's observed daemon generation differs from the target or captured graph. |
| [`SnapshotCoverageError`](@ref) | A requested field or membership is uncaptured; it is not a no-match result. |
| `InconsistentSnapshot` | Captured records or edges cannot form a consistent graph. |
| `UnsupportedCapability` | The requested operation, transport, or format contract is not admitted; `operation` and `detail` explain the refusal. |

The [ownership guide](ownership.md) explains uncertainty after submission and
transport-specific guarantees. Cleanup can raise `CompositeException` with
both the primary failure and retirement failures.

```@raw html
<p>Included source: <a href="../source/src/process.jl.html#L1">client failures</a>,
<a href="../source/src/process.jl.html#L112">cancellation</a>,
<a href="../source/src/operations.jl.html#L1">target failures</a>,
<a href="../source/src/model.jl.html#L87">coverage and consistency</a>, and
<a href="../source/src/acquisition.jl.html#L45">capability refusal</a>.</p>
```

```@autodocs
Modules = [LibTmux]
Pages = ["src/process.jl", "src/batches.jl"]
Private = false
Order = [:module, :type, :function]
```

## Owned servers

```@autodocs
Modules = [LibTmux]
Pages = ["src/lifecycle.jl"]
Private = false
Order = [:module, :type, :function]
```

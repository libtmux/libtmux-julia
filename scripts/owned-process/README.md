# owned-process

Starts a child process and watches it through POSIX calls, for the benchmark
drivers. `Base.run` hides three things they need: the child's own process
group, its exit observed before it is reaped, and `wait4` accounting for its
CPU time and peak resident set.

[`bench-startup`](../bench-startup/README.md) and
[`bench-mcp-client`](../bench-mcp-client/README.md) include
`owned-process.jl`. A maintainer does not run it.

The module spawns with `posix_spawn`, gives the parent non-blocking pipe ends
and runs one blocking `waitid` or `wait4` on a libuv pool thread. That thread
writes a byte to a pipe when the child exits, so a caller waits for output and
exit in one `poll` and never polls for readiness. The child starts with
default signal dispositions and an empty signal mask, not Julia's.

The blocking calls go through `@blocking_ccall`, a copy of `@threadcall` that
marks the call safe for the garbage collector. `@threadcall` leaves its thread
unsafe for the whole call, so a collection on the main thread waited for the
child to exit.

On Linux and macOS a child inherits its spawner's resident set into
`ru_maxrss`, so `wait4` cannot report a peak below the spawner's. The drivers
record the spawner's own peak beside the child's.

The module needs only the standard library. Run its tests, which start real
processes:

```console
$ julia \
    --startup-file=no \
    scripts/owned-process/tests/runtests.jl
```

# bench-startup

Measures a fresh Julia process loading `LibTmux`, starting an owned tmux
server and using it once. The [benchmark guide](../../benchmark/README.md)
shows how to run it.

It runs `benchmark/startup.jl`, and a bare Julia baseline, in fresh processes
in a seeded random order. Each process leads its own group. The driver
observes the exit before it reaps the process, retires the group, and then
reads the output and `wait4` accounting. The report keeps every sample,
including failures and the raw output, and refuses to replace an existing
file. Each phase's own peak resident set comes from the child, which reads
`VmHWM` on Linux. `wait4` reports the child's peak, but it cannot fall below the
driver's own, so the report also names `spawner_max_rss_bytes`.

Prepare the benchmark project first, as the guide describes. The driver needs
no network and sets `JULIA_PKG_OFFLINE`:

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    scripts/bench-startup/bench-startup.jl \
    --samples 3 \
    --profiles normal \
    --threads 1 \
    --output benchmark/results/startup.json
```

The tests run the driver against stand-in `julia` and `tmux` programs, and
check the process observation, the report and its refusal to overwrite. They
start no tmux and need only `JSON`:

```console
$ julia \
    --startup-file=no \
    --project=scripts/bench-startup \
    scripts/bench-startup/tests/runtests.jl
```

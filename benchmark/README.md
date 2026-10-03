# Measure complete workflows

Benchmarks form a separate tier. Prepare dependencies before measuring, keep
each run under ten minutes, and keep an entire sweep under one hour. Use an
otherwise idle host, record compiler flags and retain every raw result,
including failures. A minimal-compilation smoke check is not performance
evidence for the normal Julia compiler.

From the repository root:

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    -e 'using Pkg; Pkg.develop([PackageSpec(path="."), PackageSpec(path="packages/LibTmuxMCP"), PackageSpec(path="packages/LibTmuxWorkspace")]); Pkg.instantiate()'
```

Set `LIBTMUX_TEST_TMUX` to select a different tmux executable. Every driver
that needs tmux uses a private owned server. None measures against the default
server.
Choose a fresh output file for every run; existing measurements are preserved.

## Fresh process and first use

```console
$ python3 benchmark/startup.py \
    --project benchmark \
    --samples 3 \
    --profiles normal \
    --threads 1 \
    --output benchmark/results/startup.json
```

The Python driver randomizes fresh Julia baseline and core samples. It records
package import, first owned server, first subprocess/control operations and
cleanup separately, using the library's default deadlines. JSON remains
unloaded; report serialization happens after the core sample. Dependencies
and compiled caches must already exist. OS and dependency caches are not
flushed. `--profiles normal,o0,minimal` compares compiler settings without
changing launcher defaults. Failed samples retain their output and timings.

## Queries and execution modes

### Pure captured graph scaling

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    --threads=1 \
    benchmark/graph_scaling.jl \
    sizes=16,64,256,1024,4096 \
    samples=20 \
    output=benchmark/results/graph-scaling-1
```

This driver performs no tmux I/O. It builds inert captured graphs through the
private fixture builder, then measures public collection, scalar, lookup,
relationship, filter, and projection calls. Each size contains two sessions,
the requested number of physical windows and panes, and shared links with
duplicate contextual occurrences. Fixture row generation and snapshot/index
construction are separate operations.

The fresh output directory contains flushed raw samples and a final report.
Existing results are never replaced; failures and source changes retain their
evidence and exit unsuccessfully. The report hashes all core and extension
source files, the driver, project files, and field schema before core import
and after measurement. It also binds the active prepared project and manifest.
Use the normal compiler with its default optimization level; other profiles
are refused.

First calls use `invokelatest` before semantic validation to include action
compilation, dispatch, and return boxing. Warm samples use a direct function
barrier; a no-op control records instrumentation cost without subtraction.
The first native warm wrapper can compile before its action timer;
`caller_elapsed_ns`, available compiler counters, and every first warm trial
remain in the raw evidence. Later sizes reuse compiler caches
from earlier sizes, so these are first invocations within the process, not
independent cold processes. Twenty or more randomized warm samples record
time, allocated bytes, allocation counts, and GC time with nearest-rank p50
and p95. Validation runs outside each measured call but within whole-script
time. Retained sizes distinguish a graph, one view, a one-row selection and
projection that pin the graph, and collected scalar rows.
RSS observations record process lifetime high-water memory after calls; they
do not attribute retained memory or memory growth to individual operations.

The pre-report script and package-import timings exclude process startup and
final report serialization; use
`startup.py` for that boundary. `sizes=16` is a bounded smoke measurement.
No regression thresholds are inferred from one run. Driver-only semantic
checks use `--compile=min -O0` with `benchmark/graph_scaling.jl --self-test`,
following the contribution loops. They verify allocation counters, source
hash/set changes, sample bounds, percentiles, and result/failure preservation.
The 480-second default budget is checked between operations. Use an external
process deadline to bound a single nonreturning operation and include startup.

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    --threads=4 \
    benchmark/workflows.jl \
    samples=5 \
    operations=8 \
    sessions=2 \
    windows=2 \
    panes=2 \
    links=1 \
    bytes=256 \
    output=benchmark/results/workflows.json
```

The same buffer-deletion workload, captured pane query and screen result run
through six modes: serial/concurrent subprocess, serial/pipelined control,
and each transport's semicolon group. Grouping applies to the deletion
commands; snapshot acquisition and capture follow it. Independent batches
preserve input-indexed results but need not execute in order. Opaque
subprocess groups cannot attribute success to individual steps.
Each sample records mutation, snapshot, local-query and capture time separately.
Mutation throughput counts the deletion commands only.

BenchmarkTools separately measures closure/vector, criterion/vector,
criterion/Selection, lazy, decoded and nested-relation queries. Local queries
perform no tmux I/O. Fixture construction is separate from workflow timing.
The first call for each mode occurs after fixture and query setup; it is not
a cold process/package measurement. Subsequent samples randomize mode order.

Vary `sessions`, `windows`, panes per window (`panes`), extra shared links
(`links`) and input bytes (`bytes`) independently while holding other inputs
fixed. The number of windows must be at least the number of sessions.
Record actual entity and occurrence counts from the result, not just input
dimensions. RSS is the process lifetime high-water mark; Julia allocations
refer to the measured workflow. An after-operation backlog of zero does not
establish a zero peak backlog.

For a multi-megabyte capture, run the same workload with a larger input:

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    --threads=4 \
    benchmark/workflows.jl \
    samples=20 \
    bytes=2097152 \
    output=benchmark/results/capture-2mib.json
```

`bytes` accepts up to 4 MiB of seeded text. The owned fixture increases history
capacity and checks that every seeded character survives capture before timing
begins. Captured output also includes screen line breaks; the report records its
actual byte count and hash. Every mode must return the same bytes and identities.
Retain failed runs, including fixture truncation and cleanup failures.

## Observations and pressure

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    --threads=4 \
    benchmark/observations.jl \
    samples=3 \
    bytes=4096 \
    capacity=4 \
    budget=480 \
    output=benchmark/results/observations.json
```

A controlled raw terminal producer verifies exact bytes and increasing
cursors. Pressure cases cover slow-subscriber overflow, cancellation,
unrelated request progress and bounded admission. The polling/event
comparison requires the same marker to become visible in a captured screen.
The capacity case fills the pending queue with submitted waits, cancels them
together, and measures caller wakeup separately from backend retirement.
It requires an empty queue and confirmed signal cleanup before testing reuse.
Raw events wake the event strategy; raw bytes are not treated as a screen
image. Private queue introspection is measurement instrumentation, not a
supported application API.

## Installed MCP and workspace commands

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    --threads=4 \
    benchmark/mcp.jl \
    samples=3 \
    warm=5 \
    profiles=normal,o0,minimal \
    threads=4 \
    budget=480 \
    output=benchmark/results/mcp.json
```

The external protocol client measures fresh-process discovery, first/warm
tools, concurrent requests during a wait, cancellation/EOF and a stopped
reader. Cancellation-to-exit is an upper bound on retirement, not a fabricated
cancellation acknowledgement. Unsupported pipe-capacity instrumentation is
reported separately from a successful backpressure measurement.

Compare workspace launcher compiler profiles with repeated randomized order:

```console
$ julia \
    --startup-file=no \
    --project=benchmark \
    packages/LibTmuxWorkspace/dev/cli_latency.jl benchmark/results/workspace.json all 3
```

Every load/freeze invocation starts a fresh Julia process against prepared
dependencies. The driver checks equal configuration results and cleanup.
Use `LIBTMUX_BENCH_THREADS=1` or `4` for workspace children. Small-sample
median/tail values are descriptive; they do not establish regression limits.
Choose limits only after repeated normal-compiler baseline measurements on
the admitted platforms. No universal performance claim is made by these
drivers.

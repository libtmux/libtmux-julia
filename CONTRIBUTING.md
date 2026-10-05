# Contributing

This repository contains the Julia core, captured queries, typed operations,
optional data adapters, and isolated tmux tests. MCP protocol/tool integration
and workspace application behavior are being verified in separate packages.

Read [AGENTS.md](AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Setup

The Julia development version is pinned in [.tool-versions](.tool-versions).
With mise installed, install that version from the repository root:

```console
$ mise install
```

Make the pinned version available as `julia` in your shell. The development
pin and package compatibility declarations do not prove a supported version
matrix. Track support separately in [the capability manifest](docs/capabilities.toml).

Core runtime and direct tests use Julia standard libraries. Optional JSON
and Tables integrations have separate prepared test environments. Unit
tests also require POSIX utilities such as `sh`, `cat`, and `yes`. Integration
tests require tmux on `PATH`; `LIBTMUX_TEST_TMUX` selects another executable.
Keep temporary paths short enough for a Unix socket. Fixtures clear inherited
tmux variables, own a unique socket, and never use the default server.

Prepare toolchains and package dependencies before timed test loops. Report
preparation separately; include process startup and fixture setup/cleanup in
each check's whole-command time.

## Checks

Run unit tests without starting tmux:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl unit
```

Run the owned-tmux fixture and core operation integration tests:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl integration
```

Run both suites before handoff, and repeat with `--threads=4` when changing
process ownership, cancellation, or concurrent I/O:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl all
```

Use `--compile=min -O0` for the inner and mid semantic loops, including all
unit tests. Normal compilation belongs in the outer loop because it includes
Julia compilation across every public feature. Minimal compilation does not
replace those normal checks or establish performance. The runner accepts
`unit`, `integration`, `all`, or one test file stem. Omitting the argument
selects `all`. For a focused parser check:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    --project=. \
    --threads=1 \
    test/runtests.jl control_protocol
```

The forced-cleanup case belongs to the outer loop because it deliberately
stops its owned daemon and waits for the 900 ms shutdown deadline:

```console
$ /usr/bin/time -p env LIBTMUX_TEST_FIXTURE_ESCALATION=1 julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl integration
```

Check generated criteria constructors, field identities and reference tables:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --project=. \
    dev/generate-criteria.jl --check
```

Check the pinned tmux option scope/type catalog without an upstream checkout:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/generate-options.jl --check
```

The catalog records release commits and source hashes. When updating it, use
`dev/generate-options.jl --check-upstream CHECKOUT` to compare the recorded
metadata with those exact tmux sources. Runtime named requests still check
option availability on the connected daemon.

Optional JSON/Tables checks use a separate project prepared with this checkout
and admitted dependency versions. The matrix preparation command below creates
that environment; its `extensions` phase runs the captured-data fixtures with
both optional packages loaded. The plain core suite and external core import
run without those packages loaded. Package resolution stays outside checks.

For documentation and configuration changes, review links and commands.
Check whitespace before handoff:

```console
$ git diff --check
```

Check the staged diff before committing:

```console
$ git diff --cached --check
```

## Manual and examples

Prepare the manual environment outside timed checks:

```console
$ julia \
    --startup-file=no \
    --project=docs \
    -e 'using Pkg; Pkg.develop([PackageSpec(path="."), PackageSpec(path="packages/LibTmuxMCP"), PackageSpec(path="packages/LibTmuxWorkspace")]); Pkg.instantiate()'
```

Build the Documenter manual with normal compilation:

```console
$ julia \
    --startup-file=no \
    --project=docs \
    docs/make.jl
```

Executable core programs live in `examples/`. Manual snippets are included
from those files rather than maintained as independent copies. Run each
program with `--project=.`; external-consumer execution remains a separate
required check. The docs manifest is local setup state, not a library pin.

Check discovery and drift for every shipped Julia fence and example:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/check-doc-examples.jl check
```

The [example inventory](docs/example-inventory.md) distinguishes exact pure
doctests, snippets derived from executable programs, and contextual examples.
After the matrix preparation below, run the contextual examples with its
resolved project and depot. The runner supplies an owned server, captured rows
and private files, then checks the results and cleanup:

```console
$ env JULIA_DEPOT_PATH="$matrix_stage/depot" julia \
    --startup-file=no \
    --project="$matrix_stage/environment" \
    dev/check-doc-examples.jl contextual
```

The matrix runs separate doctest, contextual and external-example gates.
A successful inventory check alone does not establish runtime correctness.

## External package imports

The consumer checker exports read-only source copies into a directory outside
the checkout. Each package gets an isolated project, manifest, and depot.
Preparation downloads dependencies into the isolated depot and warms normal
imports. The subsequent check runs offline.
Dependency acquisition uses normal compilation. Matrix setup copies the
prepared registry and completed stdlib caches into the consumer depot. The
selected Julia executable supplies the stdlib module names and cache version;
product caches are excluded. Every copied file has verified SHA-256 bytes
and independent storage. Consumer projects retain one owned depot and resolve
library source only from their immutable exports. Julia still validates cache
compatibility and compiles each exported product normally.
It is setup, not an inner or mid check. These commands share one shell:

```console
$ consumer_stage=$(mktemp -d "${TMPDIR:-/tmp}/ltj-consumer.XXXXXX")
```

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/check-consumers.jl prepare "$consumer_stage"
```

Run the import-only check after preparation:

```console
$ /usr/bin/time -p julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/check-consumers.jl check "$consumer_stage"
```

The driver uses minimal compilation; its package imports explicitly use
normal compilation. The check validates source hashes, package identities,
load paths, and the public core boundary. It rejects stale exports after
source changes; prepare a fresh stage. It does not prove registry publication.

Discover and run every exported Julia example against owned tmux servers:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/check-consumers.jl examples "$consumer_stage"
```

This outer check also requires Python 3.12+ and `ps`. It runs the exported
programs unchanged through an audited tmux executable. Each owned example
runs successfully and with a command failure injected after session creation.
The checker independently verifies daemon/client retirement and socket-directory
removal. A deliberate missing-close case proves that the audit detects leaks.
The pure workspace planning example is explicitly exempt from tmux acquisition.
These checks exercise command failure, not arbitrary process termination.

Check installed launchers from the exported packages, including real MCP
clients and workspace load/freeze/cancellation:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    dev/check-consumers.jl launchers "$consumer_stage"
```

Those two commands are outer checks. Children use normal optimized
compilation and one thread; the matrix's direct library suites separately
cover one and four threads.

The workspace launcher harness has a separate test project with JSON for
reading protocol responses. Its installed launcher uses the production
consumer project. Import checks and examples use only the production projects.

Remove only the stage created above when finished:

```console
$ rm -rf -- "$consumer_stage"
```

## Quality and compatibility

The matrix driver requires Python 3.12+ on Linux and Python 3.13+ on macOS.
It uses `waitid` with `WNOWAIT` to reserve child process identities until
signalling and final reap finish. CI selects Python 3.13 on both platforms.
The driver prepares exact tooling versions, exports immutable consumer
packages, and records commands, whole-command times and failure states.
Preparation can access the network; subsequent checks are offline. Source
changes invalidate the prepared export.

The isolated tooling project disables JuliaFormatter's optional package-wide
precompile workload through its supported preference. During preparation,
the private [compiler helper](dev/LibTmuxCheckCompiler/src/LibTmuxCheckCompiler.jl)
formats inert syntax samples with the check's settings to cache compiler work.
The timed formatter gate uses normal compilation, checks every owned source
file, and includes the complete corpus work in the mid budget. Prepared
metadata records the preference, and the runner rejects preference changes
before checking the cell.

```console
$ matrix_stage=$(mktemp -d "${TMPDIR:-/tmp}/ltj-matrix.XXXXXX")
```

```console
$ python3 dev/check-matrix.py prepare "$matrix_stage" \
    --threads 4
```

Run the prepared unit and quality tiers separately while developing:

```console
$ python3 dev/check-matrix.py run "$matrix_stage" \
    --threads 4 \
    --tier unit
```

```console
$ python3 dev/check-matrix.py run "$matrix_stage" \
    --threads 4 \
    --tier quality
```

Run the complete prepared cell with an explicit executable and thread count:

```console
$ python3 dev/check-matrix.py run "$matrix_stage" \
    --tmux tmux \
    --threads 4
```

The quality tier checks Aqua, cross-package/extension ambiguities, generated
criteria freshness and JuliaFormatter. Formatting is read-only: it reports
files without rewriting them. Generated criteria have their own checker.
The outer tier includes normal library tests, installed launchers, optional
extensions, the manual, external imports and discovered examples.
Its stopped-reader checks exercise actual launcher stdio and require owned
writers to retire when their readers stop consuming output.

The matrix runner can split a platform cell into `runtime` and `delivery`
suites. Runtime covers units, quality and library/application tests. Delivery
covers extensions, documentation, external imports, examples and launchers.
Both must pass at the same source revision to complete a split cell. Use
`--suite runtime` or `--suite delivery` to run one partition locally; omitting
the option runs both.

Pull requests require four complete Linux cells: floor and current Julia/tmux
versions, each at one and four threads. Current macOS cells on each architecture
are supplementary and may fail independently; their failures do not excuse a
Linux failure.
Intermediate releases and macOS floor evidence remain explicit compatibility
work; an unrun release is not support.

The driver saves structured results before and after each phase. Interrupted
runs retain completed failures and identify the unfinished phase; they never
establish a passing cell.

Print the exact planned version/platform cells:

```console
$ python3 dev/check-matrix.py matrix
```

Planned cells begin as `NOT RUN`. Only recorded successful checks against
unchanged sources establish a passed cell. WSL counts as Linux; no local
Linux run establishes macOS support. The workflow is prepared in
`.github/workflows/julia.yml`; remote CI results require an actual run.

Run performance work separately using [the benchmark guide](benchmark/README.md).
It covers execution modes, local criteria, output pressure and installed
MCP/workspace processes. Keep raw results and compiler flags with any claim.

## Verification budgets and remaining gates

Measure the whole command. Libraries should aim for the stretch budget.

| Loop | Whole-command budget | Scope |
| --- | --- | --- |
| Inner | Under 1 second | Focused tests after each edit |
| Mid | Under 10 seconds | All unit suites, quality, formatting and generated-file checks |
| Outer | Under 200 seconds temporarily | Complete prepared cell, including normal compilation, integration, documentation and installed consumers |

The outer allowance is temporary. Track reductions in CI runtime and wait
latency in [the follow-up issue](https://github.com/libtmux/libtmux-julia/issues/9).
The long-term whole-command outer target remains under 60 seconds; inner and
mid targets are unchanged.

The matrix runner records aggregate mid and outer durations. A soft overrun
fails the check while work continues. A completed failing mid worker still
runs the outer checks; an interrupted, incomplete or stale worker stops them.
Use `--tier mid` for the complete mid scope. The default complete outer
includes the preceding mid checks.
Individual unit/quality and runtime/delivery partitions record incomplete
scope; they cannot establish a passing complete loop. Retain external
whole-process timing as well as the runner's orchestration measurements.
The aggregate clock starts after Python imports and argument parsing and
ends before the supervisor's final receipt write and process exit.

Hard limits stop work after 30 seconds for mid or 240 seconds for the complete
outer command, including mid. Every admitted phase shares its worker's
absolute deadline. Expired deadlines admit no new work. These diagnostic
allowances do not change the soft acceptance limits above.
Version probes use the same deadline and owned process retirement as test
commands. Receipts must explicitly describe their active, pending and planned
phases; malformed progress blocks further work while retaining known failures.

Exit observation and timer joins share a separate two-second allowance. The
runner records direct-child reap and retained identities when observation
cannot finish. File writes, ownership locks and worker-pool shutdown are not
covered by that wait bound. Escaped descendants and tmux fixtures still need
their own cleanup evidence. The supervisor and CI job remain the external
stop guards; CI preserves logs and receipts after a failed check.

Complete timing gates remain open while the existing normal suites and
installed launcher checks exceed these limits. Passing correctness checks
do not waive the timing requirement.

The current runnable tiers include unit checks, owned-tmux integration,
forced-cleanup cases, generated criteria and external imports. Four CI product
cells cover quality, example discovery and compatibility at their listed
checkpoints. Benchmark baselines and an independent guide walkthrough remain
open. Focused passing checks do not establish support outside recorded cells.

Keep network access, installs, production builds, browsers, sleeps, and broad
corpus scans out of the inner and mid loops. Replace polling delays with
events or subscriptions. Investigate waits over one second and remove their
cause. Tag slow tests with a one-line reason and run them in the outer loop.
Fix an over-budget loop before adding tests; do not raise its budget.

Benchmarks are separate: keep each run under ten minutes and a full sweep
under one hour. Reduce sizes when necessary.

## Review

Keep each commit and pull request focused on one topic. Inspect the staged
diff and include only the intended files. Keep changelog updates separate
from implementation changes.

Describe the concrete problem, resulting behavior, and relevant verification.
Report failures and skipped checks explicitly. For behavior changes, add
focused regression coverage and prove it fails for the intended reason.

## Repository metadata

[.github/repository.json](.github/repository.json) records the description,
visibility, default branch, topics, and labels for the upstream GitHub
repository. Apply changes to those settings manually; Git does not synchronize
them. Manage fork settings separately.

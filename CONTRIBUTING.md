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

Assert that a release below the 3.3a floor is refused without effect by
pointing the tmux selector at that release. `LIBTMUX_TEST_CLIENT_TMUX`
optionally adds a newer client that must not qualify the older daemon:

```console
$ LIBTMUX_TEST_TMUX=/path/to/tmux-3.2a julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl rejection
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

## Documentation API export

The documentation environment also exports the API for the shared website.
Prepare it with the manual setup command below, then run:

```console
$ julia \
    --startup-file=no \
    --project=docs \
    docs/export-api.jl
```

The artifact at `docs/build/api.json` records public and qualified bindings,
constructors, fields, methods, keyword defaults, type parameters, docstrings
and source locations. It combines Julia syntax with native method and
documentation metadata, including declarations generated through `@eval`.
Methods extending Base and dependency APIs remain separate from package
bindings. The exporter captures the base inventory before loading optional
JSON and Tables extensions and identifies their added methods.

The selected environment determines the LibTmux checkout. The artifact
records that checkout's revision and source hashes independently of the
exporter's hash and tool versions. Uncommitted API sources or source changes
during extraction fail the export. An optional positional argument selects
another output path.

Check the artifact against native inventories and the generated-method,
keyword-default, source and optional-extension regressions:

```console
$ julia \
    --startup-file=no \
    --project=docs \
    docs/test-export-api.jl
```

These checks verify extraction. They do not execute the documented programs
or establish website rendering or publication.

The Linux Julia 1.13 matrix jobs run both commands with their prepared tool
environments, offline, and save a `julia-docs-api-<job-label>` artifact for
each job. They reuse the existing dependency preparation. Website previews
and publication use the shared documentation workflow and record their own
source and tooling provenance.

## Website publication

The [docs workflow](.github/workflows/docs.yml) builds the selected source with the
shared libtmux.org workflow. Keep its build and publisher references pinned
to the same full commit in `libtmux/docs`. The native exporter comes from the
calling workflow's tested commit; its provenance stays separate from the
selected source revision.

A `master` push publishes `/en/julia/latest/`. A `v*` release tag
publishes its version plus `next` for prereleases or `stable` for releases.
Same-repository pull requests publish `/en/julia/pr-N/` from the tested
merge commit. Before publishing, the workflow checks that the PR is still
open in this repository and its current head and merge match the tested
revision. Fork pull requests build without publishing. Closing a pull
request deletes only its preview prefix, after confirming it is still
closed. Cleanup shares the build and publication queue; rerunning an old
closed event cannot delete a reopened PR's preview.

To rebuild an existing revision, dispatch `docs.yml` from `master`. Set
`source-ref`, `version`, `version-kind`, `is-default`, `resolves-to`, and
`publish`. Use `resolves-to` only for an alias. Leave `publish` false for a
build-only check. An immutable version must still identify its original
source and package version. Inspect the build provenance and hosted page
after publishing; a successful native export alone is not publication proof.

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

Check the root and package READMEs. The static mode checks that package
headings link their directories, every link and anchor resolves, API links
name public bindings, public names mentioned in prose are linked, MCP tool
names link their tool pages, and every `--option` exists in the launcher's
`--help`. It also runs planted failures with clean controls. It needs the
prepared quality project and no tmux:

```console
$ env JULIA_DEPOT_PATH="$matrix_stage/depot" julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    --project="$matrix_stage/environment" \
    dev/check-readme-commands.jl static
```

The commands mode installs both launchers into a private directory and runs
the README console commands in order against a private tmux server. It starts
each `claude mcp add` launcher and the `mcpServers` configuration as a client
would, then compares the served tools with the documented ones. A command
with a `text` block after it must print exactly that text. A command that is
neither run nor accounted for fails. `<!-- file: NAME -->` before a code
block writes that block to `NAME` first:

```console
$ env JULIA_DEPOT_PATH="$matrix_stage/depot" julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    --project="$matrix_stage/environment" \
    dev/check-readme-commands.jl commands
```

Neither mode fetches a URL. After editing links, run the `links` mode. It
needs the network and is not part of the matrix. It requires a 200 response
without a redirect for each URL and first checks that a page the site does not
publish does not return 200:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    --project="$matrix_stage/environment" \
    dev/check-readme-commands.jl links
```

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

Pull requests require four complete Linux boundary cells: floor (tmux 3.3a)
and current Julia/tmux versions, each at one and four threads. An additional
Linux cell runs tmux 3.8. Current macOS cells on each architecture are
supplementary and may fail independently; their failures do not excuse a
Linux failure. Rejection cells run tmux 3.0a, 3.1c, 3.2a and unpatched 3.3
outside the supported matrix. The 3.2a and 3.3 cells run
`test/runtests.jl rejection` with the release itself and with a 3.3a client;
the 3.0a and 3.1c cells run
`test/runtests.jl old-daemon` behind a 3.3a client. Both suites assert refusal
without effects. Every rejection cell also runs the workspace CLI against a
real daemon of the rejected release, and the 3.0a and 3.1c cells run the MCP
tools against a daemon that replaces a checked one. Both package suites use
`runtests.jl old-daemon` and fail instead of skipping when builds are absent.
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

Preparation develops the private test observer in the tooling project and
queries the core, workspace and MCP runners for their unit and complete file
inventories. These offline queries stop before test execution. The prepared
metadata binds each file to its source hash. Product dependencies are unchanged.
Admitted commands receive a directory scoped to their invocation and phase;
native test processes write separate files identified by a process token and
PID. Schema 4 receipts retain the independently admitted direct-process IDs
and expected files. Child admission is still unproved, so complete test
coverage remains partial even when every observed file and testset finishes.
Commands outside those three runners retain process receipts without native
test inventories.

The matrix enables flushed `LIBTMUX_TEST_PROGRESS` JSON records for admitted
native runners. Records identify the invocation, process, file and nested
testset, with outcomes and assertion/error details. The observer's console
output defaults off; the matrix explicitly enables it for native suites.
Consumer observers and the private child bootstrap keep console markers off
to preserve installed stdout and stderr.

The phase output observer saves combined stdout/stderr bytes in the owned log
and forwards validated, sanitized progress records through a bounded
asynchronous console queue. Queue admission does not prove delivery. Dropped
records, write faults and incomplete delivery fail diagnostic receipts; the
native journal and checkpoint notifications remain available when console
output stalls. A blocked console writer retains its descriptor until it
retires, with an explicit `UNRETIRED` receipt if bounded finalization expires.

Each admitted phase publishes a sanitized summary, ranked timing CSV, JUnit,
partial progress, original log snapshot and hash manifest. Native suites retain
their own assertion counts; the job index links phase bundles without adding
unit and complete-suite counts together. The final job report retains aggregate
timing failures even when every test command passes. Missing completion records
remain partial evidence.

Admitted native phases also publish immutable `LIVE_PREFIX` bundles while
work runs. Process-start, assertion-problem and enabled profile-checkpoint
notifications select a flushed prefix from the independently admitted direct
process. Each snapshot binds its invocation, source, process birth, sequence
and retained bytes. The publisher coalesces notifications within the worker's
hard deadline.
Snapshot coverage stays `PARTIAL`. Test/check status stays `UNKNOWN` until
observed assertion failures or errors establish `FAIL`, with their original
details retained. A published prefix establishes neither command completion
nor a passing check. The CI upload step includes these sanitized snapshots
with final bundles after work stops.

Phase bundles capture the command before their own artifact finalizer. The
final supervisor receipt includes that finalization time. A separate CI step
publishes the job index after work stops, using a two-second owned exporter and
separate cleanup allowance. Its workflow ceiling is one minute; upload has a
separate two-minute ceiling. Exporter retirement has its own sanitized receipt.
Failed setup produces explicitly unverified setup snapshots. CI uploads public
bundles after their privacy checks, with missing artifacts reported as errors.

The CI offline step requests CPU sampling with deferred symbol lookup for
complete native suites and supported consumer phases. Unit and quality phases
keep sampling off. Local sampling defaults off; set `LIBTMUX_CI_PROFILE=cpu`
or `wall` to request it. The private observer supports CPU sampling on Julia
1.10 and 1.13, and separate wall-time sampling on Julia 1.13. CI wall-time
scheduling remains open.

Each admitted phase records its sampler request. A required native sampler
must retain one matching start and at least one bound raw checkpoint. Missing,
unsupported or contradictory sampling evidence fails diagnostics without
changing original assertion counts or process exits. An empty checkpoint
remains partial evidence. Checkpoints retain process/source identity,
unresolved symbols and export overhead. Cumulative checkpoints and inclusive
frames overlap. Copying every checkpoint does not establish complete sampling
coverage or symbol lookup.

Saved profiles require the matching Julia version for native decoding. The CI
exporter preserves raw checkpoints and labels native decoding unverified.
With matrix diagnostic bindings, the consumer checker can profile its direct
Julia children through a private source bootstrap. It records their actual
process IDs before waiting, distinct birth tokens, observed exits and wait
returns. It preserves command flags, inherited stdio and consumer projects.
A returned Julia wait does not measure the kernel's earlier reap time or prove
descendant retirement.

Consumer profiles default to deferred symbol lookup to preserve application
stderr. Raw samples retain unresolved addresses; decoding after exit cannot
recover every process-local JIT label. First-output-byte timing remains
unavailable for consumer children with inherited stdio; their application
readiness remains unproved. Embedded examples and installed launcher
descendants need their own independent admission and profiling evidence.

Consumer sampling requests retain an unverified capture contract until child
admission is complete. Bounded native decoding, first-byte readiness and
complete child admission remain verification work.
The private sampling controls belong to the outer loop. Use `profiles wall`
instead of `profiles` to check wall-time sampling separately on Julia 1.13:

```console
$ julia \
    --startup-file=no \
    --project=dev/LibTmuxTestDiagnostics \
    --threads=4 \
    dev/LibTmuxTestDiagnostics/test/runtests.jl profiles
```

Check direct-child identity, CPU checkpoints, binary stdout, stderr, randomness
and nonzero/ignored exits with the separate outer control:

```console
$ python3 \
    dev/LibTmuxTestDiagnostics/test/children.py \
    julia \
    --threads 4
```

The runner records process launch, positive exit observation and reap times.
The phase output observer timestamps its first read of combined stdout,
stderr and diagnostic records. `OBSERVED` means a parent read occurred;
it identifies neither the first application byte nor application readiness.
When no byte is observed, the receipt records `UNAVAILABLE` and distinguishes
empty output from incomplete observation.

Native event decoding and phase publication run in a separate owned process
with a diagnostic limit of two seconds and another two seconds for cleanup.
Finalization time counts in the aggregate loops and is recorded separately.
Decoder failure preserves the original test result. The supervisor reserves
up to six seconds for worker retirement across test cleanup and diagnostic
finalization, including on interruption. These reserves admit no additional
tests after the work deadline.

Test-phase exit observation and timer joins share a separate two-second
allowance. Output observers, checkpoint publishers and console finalization
record bounded retirement separately. The runner records direct-child reap
and retained identities when observation cannot finish. File writes,
ownership locks and worker-pool shutdown are not covered by that wait bound.
Escaped descendants and tmux fixtures still need their own cleanup evidence.
The supervisor and CI job remain the external stop guards; CI preserves logs
and receipts after a failed check.

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

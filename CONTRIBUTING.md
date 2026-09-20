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
replace those normal checks or establish performance. The runner accepts only
`unit`, `integration`, and `all`; omitting the argument selects `all`.

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

The Python 3.12+ matrix driver prepares exact tooling versions, exports
immutable consumer packages, and records commands, whole-command times and
failure states. Preparation can access the network; subsequent checks are
offline. Source changes invalidate the prepared export.

The isolated tooling project disables JuliaFormatter's optional package-wide
precompile workload through its supported preference. The formatter check
still uses normal compilation and inspects every owned source file. Product
precompilation is unchanged. Prepared metadata records the preference, and
the runner rejects preference changes before checking the cell.

```console
$ matrix_stage=$(mktemp -d "${TMPDIR:-/tmp}/ltj-matrix.XXXXXX")
```

```console
$ python3 dev/check-matrix.py prepare "$matrix_stage"
```

Run the prepared unit and quality tiers separately while developing:

```console
$ python3 dev/check-matrix.py run "$matrix_stage" \
    --tier unit
```

```console
$ python3 dev/check-matrix.py run "$matrix_stage" \
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

CI splits each platform cell into `runtime` and `delivery` suites to keep
preparation and checks within the job budget. Runtime covers units, quality
and library/application tests. Delivery covers extensions, documentation,
external imports, examples and launchers. Both must pass at the same source
revision to complete a cell. Use `--suite runtime` or `--suite delivery` to
run one partition locally; omitting the option runs both.

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

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Focused tests after each edit |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, and generated-file checks before handoff |
| Outer | Under 5 minutes | Under 60 seconds | Types, builds, integration tests, and compatibility checks before commit or PR |

The current runnable tiers include unit checks, owned-tmux integration,
forced-cleanup cases, generated criteria and external imports. Product-wide
quality, example discovery, compatibility and benchmark gates remain open.
Focused passing checks do not establish complete product support.

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

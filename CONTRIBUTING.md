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

Assert that a release below the 3.7c floor is refused without effect by
pointing the tmux selector at that release. `LIBTMUX_TEST_CLIENT_TMUX`
optionally adds a newer client that must not qualify the older daemon:

```console
$ LIBTMUX_TEST_TMUX=/path/to/tmux-3.6b julia \
    --startup-file=no \
    --project=. \
    --threads=1 \
    test/runtests.jl rejection
```

The global tmux floor is 3.7c. Rejection tests verify that older daemons cannot
receive effectful operations, including after replacing a previously checked
daemon. A skipped check is not a passing check.

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
replace those normal checks or establish performance. The runner accepts `unit`, `integration`, `all`, or a test-file stem;
omitting the argument selects `all`.

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

The Linux Julia 1.13 matrix job runs both commands with its prepared tool
environment, offline, and saves the `julia-docs-api` CI artifact. It reuses
the existing dependency preparation. Website previews and publication use
the shared documentation workflow and record their own source and tooling
provenance.

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
and private files, then checks the results and cleanup. A `text` block right
after a contextual fence must equal what the fence prints:

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
`--help`. It also requires Quick start as the first section, a "What it leaves
out" and a "Support and status" section, and prose blocks of at most 240
characters. A README is read outside GitHub too, so a link to a file of this
repository must be an absolute GitHub `blob` or `tree` URL for a path that
exists, never a relative link. It runs planted failures with clean controls. It
needs the prepared quality project and no tmux:

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
publish does not return 200. A link to a file that a pull request adds returns
404 until the pull request merges:

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

The Python 3.12+ matrix driver prepares exact tooling versions, exports
immutable consumer packages, and records commands, whole-command times and
failure states. Preparation can access the network; subsequent checks are
offline. Source changes invalidate the prepared export.

The isolated tooling project disables JuliaFormatter's optional package-wide
precompile workload through its supported preference. The formatter check
still uses normal compilation and inspects every owned source file. Product
precompilation is unchanged. Prepared metadata records the preference, and
the runner rejects preference changes before checking the cell.
Preparation runs the same read-only formatter check at the selected thread
count. Its cost is included in preparation, independently of check timings.

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

Pull requests run Linux checks on Julia 1.13.1 with tmux 3.7c at one and four
threads and tmux 3.8 at one thread. Each configuration runs required runtime and
delivery jobs, with independent preparation and unchanged hard limits. Both
partitions must pass; their union runs every verification phase once. This repeats
dependency setup to keep cold preparation from exhausting the final checks'
allowance.

macOS and psmux are excluded from CI. Rejection jobs use tmux 3.0a, 3.1c, 3.3a
and 3.6b with a current client; these versions
must be refused without effect. The oldest two also exercise protocol-mismatch
replies from real old daemons in the core and MCP packages.

Set `JULIA_TEST_VERBOSE=true` for native nested testset start/finish messages.
The file wrapper preserves assertion details and continues later files after a
failure. A native testset finish message can be printed during interruption;
only a matching final receipt and successful process exit establish completion.

The runner streams original logs, saves partial results between phases and
reports diagnostic timing overruns. A fifteen-minute work limit stops admission
and interrupts owned processes, escalating when necessary. Cleanup is separately
bounded. Linux adopts and reaps escaped descendants; artifacts record survivors
and cleanup failures. CI reserves time within its twenty-minute job for cleanup
and sanitized artifact upload. Profiling is optional troubleshooting, using
Julia's standard `Profile` tools.

Each artifact contains a readable summary, ranked timing CSV, original failure
logs with local paths and known credentials removed, completion receipts and
partial result records. File times overlap command times; do not add both.

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

## Diagnostic timing targets

Time whole commands, including startup, setup and cleanup. Aim for roughly
five seconds for focused checks, thirty seconds for unit/quality checks and
five minutes for complete outer checks. These targets are diagnostic, not
pass/fail thresholds. Investigate substantial regressions without adding blind
retries or sleeps. Product deadlines, cancellation and cleanup remain correctness
requirements.

Keep network access, installs, production builds, browsers, sleeps and broad
corpus scans out of inner and mid loops. Prepare dependencies before checking
and report preparation separately. Normal compilation and installed consumers
belong in the outer loop. Compiler caches do not replace correctness checks.

Benchmark work is separate from merge readiness. Keep each run under ten
minutes and a full sweep under one hour; reduce sizes when necessary.

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

# Contributing

This repository is a scaffold for the Julia port of libtmux. It contains
repository configuration and contribution guides. The library implementation,
package manifest, and automated test suite have not been added.

Read [AGENTS.md](AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Setup

The Julia development version is pinned in [.tool-versions](.tool-versions).
With mise installed, install that version from the repository root:

```console
$ mise install
```

The development pin does not establish a minimum supported Julia version.

## Checks

For documentation and configuration changes, review links, commands, and the
diff. Check whitespace in unstaged changes:

```console
$ git diff --check
```

Check the staged diff before committing:

```console
$ git diff --cached --check
```

Use the following budgets when development checks are introduced. Measure the
whole command, including startup and setup. Libraries should aim for the
stretch budget.

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Focused tests after each edit |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, and generated-file checks before handoff |
| Outer | Under 5 minutes | Under 60 seconds | Types, builds, integration tests, and compatibility checks before commit or PR |

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
visibility, default branch, topics, and labels for both GitHub repositories.
Apply changes to those settings manually on each repository; Git does not
synchronize them.

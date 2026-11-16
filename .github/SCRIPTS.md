# Scripts

This policy covers the support scripts in this repository: files under
`scripts/`, CI helpers, generators and checkers. It applies the libtmux
decision in [libtmux/docs#323](https://github.com/libtmux/docs/pull/323).

## Keep a script only for a current use

A script stays when this project runs it today: a CI job, a release step, a
code generator, a documentation check, or a maintainer task named in
[CONTRIBUTING.md](../CONTRIBUTING.md).

- Parity with Python libtmux or tmuxp is not a use. Delete comparison
  harnesses, oracles, ledgers and generated fixtures, and the CI steps that
  install them.
- A shell step that creates, prepares or stops tmux for an example or test
  means the library lacks an operation. File an issue for the operation and
  remove the step when it lands.
- Delete scripts nothing calls.
- Tooling several ports share lives once, as a shared workflow or action, not
  as a vendored copy.

## Language

Scripts are Julia, run with `julia --project`, the same interpreter CI uses
for the library. Do not add shell or Python script files.

## Layout and checks

- A script with tests lives in `scripts/<name>/`, with a `README.md` (what it
  does, who runs it, how) and `tests/`. A short single-purpose script may be
  one file with a usage header.
- Scripts pass the same formatter, linter, type checker and test runner as the
  library, in CI.
- Use current language and tool idioms; no shims below the project's floor.
- Before a new or rewritten script merges, a reviewer who did not write it
  checks it against [WRITING.md](../WRITING.md) and
  [no-ai-slop](https://github.com/petergyang/no-ai-slop).

## What stays

- GitHub Actions `run:` lines that call one command.
- A capability Julia lacks comes from a test-only Julia dependency, not from a
  second language.
- Test data that is not a comparison, such as workspace files a loader reads.

## Exceptions

A shell program stays only when this section names it and records what the
Julia alternative costs, with the command that measured it. Delete the entry
when the numbers stop holding.

### check-example-cleanup: the audited tmux wrapper

`scripts/check-example-cleanup/check-example-cleanup.jl` writes a POSIX shell
script into its temporary directory at run time and gives it to an example as
`LIBTMUX_TEST_TMUX`. Every tmux call the example makes starts the wrapper first.
It records its process, refuses a socket outside the checker's directory and
then runs `exec` on the real tmux. `open_server` allows its version probe 900 ms
(`timeout=0.9`), and one run of `examples/owned_capture.jl` makes 101 client
calls and starts one daemon.

A Julia wrapper with the same steps (a shebang through `env -S`, a read of
`/proc/self/stat`, one TOML record, `execv`) took far longer to run `tmux -V`
than the shell wrapper. The runs were 30 to 40 each with `hyperfine -N` on a
12-CPU WSL2 Linux machine with Julia 1.13.1 and tmux 3.8a. The first row ran
beside other jobs, at a load average near 11. The other rows pinned the wrapper
and 0, 1 or 3 added busy loops to one CPU with `taskset`. Each cell gives the
median and the maximum:

| Condition | Shell | Julia `--compile=min -O0` | Julia default flags |
| --- | --- | --- | --- |
| all CPUs available, shared host | 4 / 7 ms | 342 / 465 ms | 485 / 1137 ms |
| one CPU, no added load | 6 / 11 ms | 632 / 1015 ms | 999 / 1246 ms |
| one CPU, 1 busy loop | 15 / 28 ms | 643 / 1038 ms | 844 / 1238 ms |
| one CPU, 3 busy loops | 20 / 43 ms | 1271 / 1532 ms | 1810 / 2103 ms |

With `--compile=min -O0` the Julia wrapper stays under the 900 ms probe only
when all CPUs are available. At 342 ms per call it adds about 35 seconds of
process starts to one example run, against 0.4 seconds for the shell wrapper.
Julia's own start is the floor, measured with one command:

```console
$ hyperfine \
    -N \
    --warmup 3 \
    --runs 40 \
    'julia --startup-file=no --history-file=no --compile=min -O0 -e 0'
```

It took a median of 391 ms, from 236 to 628 ms, on the shared host.

# check-matrix

Prepares isolated Julia tooling for one cell of the `Julia` workflow, runs its
checks offline, and writes sanitized evidence.

The workflow's `check` job runs three commands in order. `prepare` resolves the
pinned tool versions, exports the immutable consumer packages and warms the
formatter, and is the only step that may use the network. `run` records every
phase of the cell's suite and tier in its own tmux sandbox, with a fifteen-minute
work limit, a separately bounded cleanup, and a receipt each native test suite
must write. It fails a cell that leaves a socket or a process behind. `artifacts`
removes local paths and known credentials from the logs and results and writes
`summary.txt` and `timings.csv`. The stage is a directory outside the checkout.

```console
$ julia \
    --startup-file=no \
    --project=. \
    scripts/check-matrix/check-matrix.jl prepare "$stage" \
    --threads 4
```

```console
$ julia \
    --startup-file=no \
    --project=. \
    scripts/check-matrix/check-matrix.jl run "$stage" \
    --tmux tmux \
    --threads 4
```

`scripts/plan-matrix` decides which cells exist, and the shared `build-tmux` action
builds the tmux each cell tests. The tests check preparation, the cache copies,
the phase runner's bounds and audits, the sandbox, the cell plan and the evidence
sanitizer. They start no tmux and need only the standard library:

```console
$ julia \
    --startup-file=no \
    --project=. \
    scripts/check-matrix/tests/runtests.jl
```

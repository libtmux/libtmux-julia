# plan-matrix

Decides which tmux releases and jobs a `Julia` workflow run covers, and gates the
aggregate job on them.

The workflow lists no tmux version. `.github/workflows/julia.yml` runs `plan` in
its planning job and builds its job matrix from the output; the table of supported
and refused releases lives in this script. A push and a pull request cover the
oldest and the newest release, a `v*` tag and a dispatch with `scope=full` cover
the whole table and the refusal lanes, and `scope=custom` covers the tmux
versions, tags, branches and commits the dispatch names. `gate` runs in the
`required` job and passes only when the planning job and every planned job passed
and a lane the plan left out stayed skipped.

Each runtime configuration runs one `unit-quality` job and one `outer` job.
Delivery runs its whole suite in one job. Each job prepares its own stage
and has a separate work window. Together the jobs run every applicable check.
An explicit debug dispatch keeps the combined runtime suite in one job.

Print the plan for an event, as the workflow does:

```console
$ julia \
    --startup-file=no \
    --project=. \
    scripts/plan-matrix/plan-matrix.jl plan \
    --event push
```

The tests check every rule of the plan, then replace each rule with its absence
and require its check to fail. They also read `julia.yml` as text and require that
the cells and refusal lanes come from the plan, that the aggregate job gates on
the planning job, the lanes and the checks, that no tmux version appears in the
workflow, and that a debugging session stays pinned, limited to the actor and bound
to the job the plan chose. The script needs only the standard library:

```console
$ julia \
    --startup-file=no \
    --project=. \
    scripts/plan-matrix/tests/runtests.jl
```

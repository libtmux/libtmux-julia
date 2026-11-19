# check-example-cleanup

Runs an example program behind an audited tmux executable and proves it leaves no
server, client or socket directory behind.

`dev/check-consumers.jl examples` runs every exported example through it, and
`test/sandbox_client.jl` uses it to check that an example sees none of the caller's
tmux selectors. The checker puts a private tmux wrapper first on the example's
`PATH`, where the library's default `tmux` finds it. The wrapper records each
tmux process the example starts, refuses a socket outside the directory the
checker owns and a client that names no socket, and then runs the real tmux. Once the example exits, the checker
verifies from the records that every process is gone and that no daemon left its
socket directory. A second run fails the first command after a session exists, and
the example must propagate that failure and still clean up.

```console
$ julia \
    --startup-file=no \
    scripts/check-example-cleanup/check-example-cleanup.jl \
    --tmux tmux \
    --cwd . \
    -- julia --startup-file=no --project=. examples/owned_capture.jl
```

Pass `--pure` for an example that must start no tmux. `--negative-control` runs a
program that opens a server and never closes it, and fails unless the audit
catches it. `--identity-self-test` checks the process identity lookup.

The wrapper is a POSIX shell script that the checker writes into its temporary
directory, not a file of this repository. A Julia wrapper starts too slowly for
the library's 900 ms version probe; the measurement is in the
[exceptions](../../.github/SCRIPTS.md#exceptions) section of the script policy.

The checker needs only the standard library. Run its tests with a tmux selected
by `LIBTMUX_TEST_TMUX`; they start real servers:

```console
$ julia \
    --startup-file=no \
    scripts/check-example-cleanup/tests/runtests.jl
```

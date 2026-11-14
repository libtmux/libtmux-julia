# Executable examples

Run these programs from an environment with LibTmux and a local tmux. Each
starts a private server and removes it. None touches your default server.
`LIBTMUX_TEST_TMUX` selects another tmux executable.

`control_cancel.jl`, `output_stream.jl` and `command_completion.jl` need
tmux 3.7 or newer. The others run on the core's tmux 3.3a floor.

| Program | Demonstrates |
| --- | --- |
| [owned_capture.jl](owned_capture.jl) | Owned setup, borrowed named targeting and ambiguity refusal |
| [shared_windows.jl](shared_windows.jl) | Entities, shared links and local criteria |
| [control_cancel.jl](control_cancel.jl) | Task cancellation and control ownership |
| [output_stream.jl](output_stream.jl) | Bounded raw output and an explicit screen reset |
| [command_completion.jl](command_completion.jl) | Authored completion marker and child exit status |

From the prepared checkout:

```console
$ julia \
    --startup-file=no \
    --project=. \
    examples/owned_capture.jl
```

Use any other program path from the table.

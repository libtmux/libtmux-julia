# Executable examples

Run these programs from an environment containing LibTmux and a local tmux
binary. Each creates a private server and verifies cleanup. They never use
the default server. `LIBTMUX_TEST_TMUX` can select a specific tmux executable.

| Program | Demonstrates |
| --- | --- |
| [owned_capture.jl](owned_capture.jl) | Create, capture and close an owned server |
| [shared_windows.jl](shared_windows.jl) | Entities, shared links and local criteria |
| [control_cancel.jl](control_cancel.jl) | Task cancellation and control ownership |
| [output_stream.jl](output_stream.jl) | Bounded raw output and an explicit screen reset |

From the prepared checkout:

```console
$ julia \
    --startup-file=no \
    --project=. \
    examples/owned_capture.jl
```

The same command accepts the other program paths. Normal compilation is
part of the outer example check; dependency preparation happens separately.

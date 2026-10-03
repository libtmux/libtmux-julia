# Load a workspace

LibTmuxWorkspace reads a documented tmuxp-style YAML/JSON subset. Validation,
expansion and planning are pure. Applying a plan creates tmux resources and
can execute shell input. Keep those stages explicit when reviewing an
untrusted configuration.

Prepare a consumer project with the core and workspace packages from the same
revision using [Install](installation.md#workspace-loader).

The following executable source example needs a checkout and its own consumer
environment. Clone the tested public source, then enter the checkout:

```console
$ git clone \
    https://github.com/libtmux/libtmux-julia.git
```

```console
$ cd libtmux-julia
```

```console
$ git checkout 9e3776d07798174a3590a728d28029efcbb52780
```

Create a local environment for the example:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate(".workspace-env"); Pkg.develop([Pkg.PackageSpec(path="."), Pkg.PackageSpec(path="packages/LibTmuxWorkspace")]); Pkg.instantiate()'
```

It loads two panes, checks their layout and focus, freezes the supported
reconstruction subset, and closes the private daemon:

```console
$ julia \
    --startup-file=no \
    --project=.workspace-env \
    packages/LibTmuxWorkspace/examples/owned_load.jl
```

The code below is included from that executable program:

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "packages", "LibTmuxWorkspace", "examples", "owned_load.jl"), String) * "\n```")
```

## Install the command

The launcher binds to that environment and performs no package resolution at
startup:

```console
$ julia \
    --startup-file=no \
    --project=.workspace-env \
    -e 'using LibTmuxWorkspace; println(LibTmuxWorkspace.install_cli("bin"))'
```

Inspect the shipped configuration without contacting tmux:

```console
$ bin/libtmux-workspace plan packages/LibTmuxWorkspace/examples/workspace.yaml \
    --env PROJECT=example \
    --output json
```

`validate FILE` checks syntax and schema. `plan FILE` expands only explicitly
supplied environment/home values and produces inert ordered steps.
`load FILE` and `freeze SESSION` require exactly one explicit `--socket` or
`--socket-name`. Loading is detached by default; an existing session name
fails unless reuse is explicit. Interactive `--attach` requires a terminal
and remains outside automated attachment evidence.

Human progress goes to stderr. `--output json` writes one final result;
`--output ndjson` writes ordered progress and one terminal record. Nonzero
exit codes distinguish usage, backend failure, partial effects, cancellation
and deadline. A requested rollback removes only provably created resources.
Shell input, scripts and changes to borrowed resources cannot be rolled back.

The default POSIX shell readiness handshake uses directory notifications
and an exact owned marker. It does not poll cursor position or infer that
later commands finished. Custom interactive launchers require the explicit
readiness opt-out and caller-provided coordination.

Freeze preserves names, layouts, pane directories and focus. It cannot
reconstruct commands, history, environment or options. Reloading shared
windows creates independent windows. Snapshot acquisition is not atomic.

## Library reference

```@autodocs
Modules = [LibTmuxWorkspace]
Private = false
Order = [:module, :type, :function]
```

<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Julia workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# LibTmuxWorkspace

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/julia/latest/workspace/)

Load tmuxp-style YAML or JSON workspaces into tmux, and freeze a running
session back into a file.

</div>

[`read_config`][read_config], [`validate`][validate], [`expand`][expand] and
[`plan`][plan] run no configuration commands, so you can check a file before
[`apply`][apply] touches tmux. The `libtmux-workspace` command and the library
share the same operations.

**Contents** — [Quick start](#quick-start) ·
[Write a file](#write-a-workspace-file) ·
[Check a file](#check-a-file-before-it-touches-tmux) ·
[Load](#load-a-workspace-into-tmux) ·
[Freeze](#save-a-session-as-a-workspace) ·
[Command line](#use-the-command-line) ·
[Errors](#handle-errors-and-limits) · [Leaves out](#what-it-leaves-out) ·
[Support](#support-and-status) · [Documentation](#documentation) ·
[API reference](https://libtmux.org/en/julia/latest/workspace/reference/) ·
[Guide](https://libtmux.org/en/julia/latest/workspace/source-guide/)

## Quick start

The packages are unregistered. From a consumer project
directory, add the core and workspace package from the same revision:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision = "v0.1.1-alpha.2"; Pkg.add([Pkg.PackageSpec(url=repo, rev=revision), Pkg.PackageSpec(url=repo, rev=revision, subdir="packages/LibTmuxWorkspace")])'
```

Install a launcher bound to that environment with
[`install_cli`][install_cli]:

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using LibTmuxWorkspace; println(install_cli("bin"))'
```

```console
$ bin/libtmux-workspace --help
```

The commands `validate`, `plan`, `load` and `freeze` run [`validate`][validate],
[`plan`][plan], [`apply`][apply] and [`freeze`][freeze]. Have tmux 3.3a or
newer on your `PATH`.

Save this workspace as `workspace.yaml`. `${PROJECT}` expands from a value you
pass, and `default-shell: /bin/sh` gives each pane the POSIX shell that the
readiness handshake requires:

<!-- file: workspace.yaml -->

```yaml
session_name: ${PROJECT}
options:
  default-shell: /bin/sh
windows:
  - window_name: editor
    layout: even-horizontal
    panes:
      - shell_command: printf 'editor ready\n'
      - null
```

Check its syntax and schema. This command never contacts tmux:

```console
$ bin/libtmux-workspace validate workspace.yaml
```

```text
valid
```

`load` and `freeze` choose a tmux server the way [`Server`][server] does:
`--socket` or `--socket-name`, else `LIBTMUX_SOCKET_PATH`, else `LIBTMUX_SOCKET`,
else tmux's own choice.

A `LIBTMUX_SOCKET` that holds a slash is refused with exit status 2, so put a
path in `LIBTMUX_SOCKET_PATH`. A relative path resolves against the working
directory.

For this demonstration, name an unused socket so that nothing reaches your own
server. The commands use `work`; use another name throughout if a daemon already
has that name. Start the example's server:

```console
$ tmux -L work new-session -d -s scratch
```

Load the workspace into it. Progress goes to stderr, and a successful load
prints one line:

```console
$ bin/libtmux-workspace load workspace.yaml \
    --socket-name work \
    --env PROJECT=demo \
    --rollback-created
```

```text
loaded
```

`--rollback-created` removes what `load` created if it fails partway. Check
the result with tmux:

```console
$ tmux -L work list-windows -t demo -F '#{window_name}: #{window_panes} panes'
```

```text
editor: 2 panes
```

Freeze the session back into a workspace file:

```console
$ bin/libtmux-workspace freeze demo --socket-name work > frozen.yaml
```

Stop only the server created for this demonstration:

```console
$ tmux -L work kill-server
```

## Write a workspace file

A workspace file names a session, its windows and the panes in each. It is
the format [tmuxp](https://tmuxp.git-pull.com/) reads, in a documented subset.

| Scope | Accepted keys |
| --- | --- |
| Session | `schema_version`, `session_name`, `windows`, `start_directory`, `before_script`, `shell_command_before`, `environment`, `options`, `global_options`, `suppress_history` |
| Window | `window_name`, `window_index`, `panes`, `start_directory`, `shell_command_before`, `environment`, `options`, `options_after`, `layout`, `window_shell`, `suppress_history`, `focus` |
| Pane | `shell_command`, `shell_command_before`, `start_directory`, `environment`, `shell`, `enter`, `suppress_history`, `focus` |
| Command object | `cmd`, `enter` |

- **Required.** `session_name`, a nonempty `windows` list and each
  `window_name`.
- **Panes.** A pane is a mapping, a command string, a command list or `null`.
  `null` means no commands.
- **Order.** A pane runs the session, window and pane `shell_command_before`
  commands, then its own.
- **Unknown keys.** They fail with their document path and are never ignored.
- **Unsupported.** Python plugins, file imports, `sleep` keys and hooks produce
  `:unsupported` diagnostics.

[Every rule][ws-docs-contracts-md-version-1-configuration] covers pane
shorthand, `enter`, history suppression, options and window indices.

## Check a file before it touches tmux

### [`read_config`][read_config]: from a file to a plan

[`read_config`][read_config] reads the file, [`validate`][validate] checks it,
[`expand`][expand] supplies values and [`plan`][plan] lists the steps. In a
checkout, from this package directory, with the shipped configuration:

```jldoctest
julia> using LibTmuxWorkspace

julia> config = validate(read_config("examples/workspace.yaml"));

julia> workspace = expand(config; env=Dict("PROJECT" => "example"));

julia> result = plan(workspace);

julia> isempty(result.steps)
false
```

[`examples/workspace.yaml`][ws-examples-workspace-yaml] covers command ordering,
blank panes, layout, focus and a command without Enter. `read_config` is the
only call that reads a file.

### [`parse_config`][parse_config]: from text you already hold

[`parse_config`][parse_config] takes YAML or JSON text. Text has no file to
resolve paths against, so [`expand`][expand] needs a `base_directory`:

```jldoctest
julia> using LibTmuxWorkspace

julia> text = """
       session_name: demo
       windows:
         - window_name: editor
           panes:
             - shell_command: echo hi
             - null
       """;

julia> config = validate(parse_config(text; format=:yaml));

julia> workspace = expand(config; base_directory="/work");

julia> [step.action for step in plan(workspace).steps]
4-element Vector{Symbol}:
 :create_session
 :create_window
 :send_command
 :split_pane
```

[`expand`][expand] reads no environment, directory or home that you did not
pass. `$NAME` and `${NAME}` use only `env`, and unknown names stay literal
unless you pass `unknown_variables=:error`.

### [`plan`][plan]: the steps, and nothing runs

[`plan`][plan] starts no process and contacts no tmux. The command prints one
JSON step per line, with `PROJECT` supplied:

```console
$ bin/libtmux-workspace plan workspace.yaml --env PROJECT=demo
```

Each [`PlanStep`][planstep] has an `action`, optional `window` and `pane`
positions, and named `arguments`. Positions count from 1, whatever the tmux
indices are.

## Load a workspace into tmux

### [`apply`][apply]: build the session

[`apply`][apply] creates the session, its windows and panes, sends the
commands, applies the layout and selects the focus. The `load` command runs
it. With a `server` you name and `workspace.yaml` in the current directory:

```julia
using LibTmux, LibTmuxWorkspace

prepared = plan(expand(validate(read_config("workspace.yaml"));
                       env=Dict("PROJECT" => "example")))
result = apply(server, prepared; rollback=:created)
println(result.session)
```

- A name that already exists fails. `reuse=` borrows one session instead.
- Only newly created panes receive commands.
- The default pane shell must be POSIX-compatible, because readiness runs a
  marker command in it.
- Sent commands cannot be rolled back.

[Readiness, cancellation and events][ws-docs-contracts-md-applying-a-plan] cover
the deadline, `before_script` and the handshake.
[`run_before_script`][run_before_script] runs one script on its own.

### [`WorkspaceApplyError`][applyerror]: what a failed load leaves

A failure throws [`WorkspaceApplyError`][applyerror] with a `cause` and a
`result`. Applying `prepared` a second time fails, because the session already
exists:

```julia
try
    apply(server, prepared)
catch error
    error isa WorkspaceApplyError || rethrow()
    println(error.result.status)
end
```

```text
failed
```

`result.status` is `failed`, `partial` or `cancelled`. `created` lists what
the load established, and `unknown_effects` lists shell input and scripts that
may have run. `rollback=:created` removes only what the load provably created.

## Save a session as a workspace

### [`freeze`][freeze]: a running session back into a file

[`freeze`][freeze] reads a session into a [`WorkspaceDocument`][document]:
names, window indices and layouts, pane directories and focus. The `freeze`
command writes one as YAML. In Julia, after [`apply`][apply]:

```julia
document = freeze(server, result.session)
println(document.data["session_name"], ": ",
        join((window["window_name"] for window in document.data["windows"]), ", "))
```

```text
example: editor
```

Write `document.data` with your JSON or YAML encoder. Commands, options,
environment and history are not captured, and shared windows become
independent windows when reloaded.

The file that the quick start froze validates:

```console
$ bin/libtmux-workspace validate frozen.yaml
```

```text
valid
```

## Use the command line

### [`install_cli`][install_cli]: put the launcher on disk

[`install_cli`][install_cli] installs a launcher bound to your resolved
project. It installs no dependencies and keeps an existing launcher unless
`force=true`. Set `bin_directory` to your chosen directory first:

```julia
using LibTmuxWorkspace
install_cli(bin_directory)
```

Each command runs the operation of the same name: [`validate`][validate],
[`plan`][plan], [`apply`][apply] for `load`, and [`freeze`][freeze].

| Command | Result |
| --- | --- |
| `validate FILE` | Strict syntax/schema check; no tmux connection |
| `plan FILE` | Explicit expansion and inert ordered plan |
| `load FILE` | Detached application; `--reuse` explicitly borrows the named session |
| `freeze SESSION` | Supported reconstruction document for the exact named session |

- `load` and `freeze` take at most one of `--socket` or `--socket-name`. With
  neither, they read `LIBTMUX_SOCKET_PATH`, then `LIBTMUX_SOCKET`, and
  otherwise tmux picks the server: the one `TMUX` names inside tmux, and the
  default socket elsewhere.
- Progress goes to stderr. `--output json` writes one final document, and
  `--output ndjson` writes progress records and one result.
- `--no-readiness` skips the shell handshake. `--attach` attaches after a load
  and needs a terminal.

This load uses an already-running server at an explicit socket:

```console
$ libtmux-workspace load workspace.yaml \
    --socket /tmp/my-tmux/socket \
    --env PROJECT=example \
    --rollback-created \
    --output ndjson
```

| Exit | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Configuration or usage error |
| 3 | Backend or output failure |
| 4 | Partial application |
| 5 | Cancellation |
| 6 | Deadline |

### [`main`][main]: the same commands from Julia

[`main`][main] runs the commands and returns the exit code. It borrows the
streams you pass and leaves your signal handlers alone:

```jldoctest
julia> using LibTmuxWorkspace

julia> main(["--help"]; out=IOBuffer(), err=IOBuffer())
0

julia> main(["bogus"]; out=IOBuffer(), err=IOBuffer())
2
```

[Output bounds, Ctrl-C and cleanup][ws-docs-contracts-md-the-command-line]
describe the installed launcher.

## Run the programs in this checkout

The two programs need a checkout. From the repository root, enter this package
directory and use the same shell for setup and examples:

```console
$ cd packages/LibTmuxWorkspace
```

Create an external consumer project. Dependency resolution and precompilation
are setup, outside timed checks:

```console
$ workspace_stage=$(mktemp -d "${TMPDIR:-/tmp}/ltj-workspace.XXXXXX")
```

```console
$ julia \
    --startup-file=no \
    --project="$workspace_stage" \
    -e 'using Pkg; Pkg.develop([PackageSpec(path="../.."), PackageSpec(path=".")]); Pkg.precompile()'
```

The [dry-plan program][ws-examples-plan-jl] plans the shipped configuration:

```console
$ julia \
    --startup-file=no \
    --project="$workspace_stage" \
    examples/plan.jl
```

[`examples/owned_load.jl`][ws-examples-owned_load-jl] creates an isolated
server, loads two panes, freezes the supported subset, then removes its owned
server. It uses only public core and workspace APIs:

```console
$ julia \
    --startup-file=no \
    --project="$workspace_stage" \
    examples/owned_load.jl
```

The package tests, and the checks they run, are in
[Working in this checkout][ws-docs-contracts-md-working-in-this-checkout].

## Handle errors and limits

### [`WorkspaceConfigError`][configerror]: where the file is wrong

A bad file throws [`WorkspaceConfigError`][configerror] with a `code`, a `path`
into the document and a `message`. The message never repeats configuration
values, which can hold secrets:

```jldoctest
julia> using LibTmuxWorkspace

julia> try
           validate(parse_config("windows: []"))
       catch error
           (error.code, error.path)
       end
(:required, "\$.session_name")
```

Codes include `:required`, `:unknown_key`, `:unsupported`, `:type`, `:value`
and `:limit`. Syntax errors name the document root and give no line.

### [`ConfigLimits`][configlimits]: bounds on untrusted input

[`ConfigLimits`][configlimits] bounds document size, nesting and value count.
[`read_config`][read_config], [`parse_config`][parse_config],
[`validate`][validate] and [`expand`][expand] take it as `limits`. Parsers
reject duplicate keys before a key can overwrite another.

[Ownership, limits and errors][ws-docs-contracts-md-ownership-limits-and-errors]
lists the defaults and what `validate` copies.

## What it leaves out

- **Python plugins and builders.** They produce `:unsupported` diagnostics, as
  do file imports, `sleep` keys and arbitrary hooks.
  [The subset][ws-docs-contracts-md-version-1-configuration] also rejects YAML
  aliases, anchors and merge keys.
- **Full tmuxp compatibility.** The package imports a subset with stricter
  duplicate, type, version and focus checks.
  [Relation to tmuxp][ws-docs-contracts-md-relation-to-tmuxp] names the sources.
- **Undoing shell effects.** Sent commands and scripts stay done. Rollback
  removes only [resources it proved it created][ws-docs-contracts-md-rollback].
- **An exact freeze.** [`freeze`][freeze] keeps names, indices, layouts,
  directories and focus.
  [Everything else][ws-docs-contracts-md-freezing-a-session] is omitted.

## Support and status

- **Experimental.** The packages are unregistered and their APIs may change.
- **Dependencies.** The package depends on the public
  [`LibTmux`][libtmux] package, JSON 1.9, YAML 0.4.17 and PrecompileTools. The
  core does not depend on this package.
- **Precompilation.** It covers inert configuration and CLI reporting. It never
  starts a process or contacts tmux.
- **Julia 1.13.1 or newer and tmux 3.3a or newer.**
- **Linux, including WSL.** CI runs Linux only. macOS and psmux are excluded
  from CI.
- **Attach.** The automated consumer tests have not exercised `--attach`.

## Documentation

| | |
| --- | --- |
| [Contracts](https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md) | Every rule behind the file format, loading, freezing and the launcher |
| [API reference](https://libtmux.org/en/julia/latest/workspace/reference/) | Every public binding, one page each |
| [Guide](https://libtmux.org/en/julia/latest/workspace/source-guide/) | Load a workspace, step by step |
| [Root README](https://github.com/libtmux/libtmux-julia/blob/master/README.md) | The core library and the other packages |
| [Changelog](https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/CHANGELOG.md) | What each release changed |

## License

[MIT][ws-license].

[libtmux]: https://libtmux.org/en/julia/latest/reference/libtmux/
[server]: https://libtmux.org/en/julia/latest/reference/libtmux-server/
[validate]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-validate/
[plan]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-plan/
[apply]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-apply/
[freeze]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-freeze/
[read_config]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-read_config/
[expand]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-expand/
[parse_config]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-parse_config/
[applyerror]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspaceapplyerror/
[document]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspacedocument/
[run_before_script]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-run_before_script/
[install_cli]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-install_cli/
[main]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-main/
[configlimits]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-configlimits/
[configerror]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspaceconfigerror/
[planstep]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-planstep/
[ws-docs-contracts-md-applying-a-plan]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#applying-a-plan
[ws-docs-contracts-md-freezing-a-session]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#freezing-a-session
[ws-docs-contracts-md-ownership-limits-and-errors]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#ownership-limits-and-errors
[ws-docs-contracts-md-relation-to-tmuxp]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#relation-to-tmuxp
[ws-docs-contracts-md-rollback]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#rollback
[ws-docs-contracts-md-the-command-line]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#the-command-line
[ws-docs-contracts-md-version-1-configuration]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#version-1-configuration
[ws-docs-contracts-md-working-in-this-checkout]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/docs/contracts.md#working-in-this-checkout
[ws-examples-owned_load-jl]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/examples/owned_load.jl
[ws-examples-plan-jl]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/examples/plan.jl
[ws-examples-workspace-yaml]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/examples/workspace.yaml
[ws-license]: https://github.com/libtmux/libtmux-julia/blob/master/packages/LibTmuxWorkspace/LICENSE

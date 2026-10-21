# LibTmuxWorkspace contracts

The [README](../README.md) shows how to load, check and freeze a workspace. This
page holds the rules behind those operations: what the file accepts, how values
expand, what [`apply`][apply] guarantees, how the launcher reports results, and
how the package is tested.

## Version 1 configuration

An omitted `schema_version` imports the tmuxp subset as version 1. An explicit
version must be integer `1`. Unknown keys fail with their document path; they
are never silently ignored.

| Scope | Accepted keys |
| --- | --- |
| Session | `schema_version`, `session_name`, `windows`, `start_directory`, `before_script`, `shell_command_before`, `environment`, `options`, `global_options`, `suppress_history` |
| Window | `window_name`, `window_index`, `panes`, `start_directory`, `shell_command_before`, `environment`, `options`, `options_after`, `layout`, `window_shell`, `suppress_history`, `focus` |
| Pane | `shell_command`, `shell_command_before`, `start_directory`, `environment`, `shell`, `enter`, `suppress_history`, `focus` |
| Command object | `cmd`, `enter` |

`session_name`, a nonempty `windows` list and each `window_name` are required. A
missing `panes` list creates one blank pane; an explicitly empty list is an
error. A pane can be a mapping, command string, command list or `null`.

`blank`, `pane`, `null` and singleton command lists containing those values mean
no pane commands. An empty string is a command that submits an empty line when
Enter is enabled. Use a command object to send the literal word `blank` or
`pane`.

Command lists preserve order. Each pane receives session before commands, window
before commands, pane before commands, then its own commands. `enter` defaults
to `true` at pane scope. An explicit command override applies only to that
command; it does not change later commands.

`suppress_history` defaults to `true` and inherits session, then window, then
pane. The plan retains this instruction. Parsing does not modify command text to
suppress history.

Environment values must be strings. Quote YAML values such as `"on"`, `"yes"` or
`"8009"` when text is intended. Option values accept strings, booleans and
signed 64-bit integers. Option names and layouts are passed through as data;
planning does not establish backend support for them. `global_options` means
global **session** options, matching tmuxp's builder.

Window indices are integers from 0 through 2147483647, and explicit indices must
be distinct. At most one window may request focus and at most one pane per
window may request focus. Plan positions are always 1-based configuration
positions, independently of tmux indices.

Python plugins, custom workspace builders, file imports and inheritance,
`sleep_before`, `sleep_after`, `sleep` and arbitrary hooks produce
`:unsupported` diagnostics. YAML aliases, anchors, merge keys, multiple
documents and non-JSON tags are outside this subset. Session, window and pane
inheritance is supported; no files are implicitly imported.

## Explicit expansion

[`expand`][expand] never reads the process environment, current directory or
home. Pass `env`, `home` and an absolute `base_directory` explicitly when
needed. A document read from disk defaults its base to the configuration
directory.

Both `$NAME` and `${NAME}` use only the supplied environment. Unknown names
remain literal by default; `unknown_variables=:error` rejects them. Replacement
strings are not recursively expanded. Shell substitutions, globs, expressions
and commands are never evaluated. A leading `~` or `~/` requires the explicit
`home`; named-user lookup is unsupported.

Relative directories resolve lexically against the inherited parent:
configuration directory, then session, window and pane. No symlinks are resolved
and no path existence checks occur. Environment and string option values
starting with `.` resolve against the configuration directory, as in tmuxp.

Names, command text, environment values, options and `before_script` receive
variable expansion. `shell` and `window_shell` remain verbatim launch text.

A pane inherits session values and the window's environment overrides. Supplying
a pane `environment` map replaces the window overrides, including when that map
is empty, while retaining session values. This follows tmuxp's builder and does
not merge all three maps.

`before_script` remains an inert string in the plan, scheduled after session
creation and before options and windows. The plan also records its execution
directory and configuration base. Application parses POSIX shlex-style argv
without implicit shell evaluation and resolves a relative executable containing
`/` from the configuration base. Bare executable names use `PATH`.

Planning does not run the script or prove its existence. Use an explicit
`/bin/sh -c` only when shell evaluation is intended. Pane command text is
likewise inert until application.

## Parsing text you already hold

For text already held in memory, use
[`parse_config(text; format=:yaml)`][parse_config] or `format=:json`, then
[`validate`][validate]. Supply an absolute `source_path` when it is known, or
pass `base_directory` to [`expand`][expand]. Parsing does not read that path.
[`read_config`][read_config] is the explicit file I/O boundary and supplies its
source path.

## Applying a plan

[`apply`][apply] runs detached under one monotonic deadline (`timeout=30.0`). It
creates sessions, windows and panes, applies options and environment, sends
ordered commands, applies layout, then selects the requested pane and window.

Names that already exist fail. Supply `reuse=existing_session_ref` to borrow
exactly that session after checking its server generation and name. Only newly
created panes receive commands. Index collisions fail without replacing old
windows.

### Readiness

A default pane shell must be POSIX-compatible. Readiness executes an owned
marker command in that shell and consumes an operating-system directory
notification. The marker is published by atomic rename and checked exactly.

The five-second handshake uses no polling, sleeps or tmux waiter channels; cleanup
removes its private directory, including on cancellation. It proves the shell
executed the handshake. It does not prove that later jobs finished.

Explicit pane or window launchers with input require `readiness=:none`. That
opt-out gives the caller responsibility for readiness. Submitted command input
is an external effect and cannot be rolled back. `enter=false` leaves input
unsubmitted.

### Cancellation and events

`cancel=CancellationToken()` interrupts waits and prevents later steps.
`on_event(event)` receives ordered step events, script output and completion; it
must return promptly. Script output events contain owned byte chunks.

[`run_before_script`][run_before_script] also works separately with
`on_output(stream, bytes)`. It bounds each captured stream at 64 KiB by default
and never decodes output implicitly. An expired deadline refuses child
admission.

Every admitted direct child is reaped, and owned pipe workers and timer
callbacks are joined. Cancellation and deadlines kill the still-owned POSIX
process group. Escaped children and descendants surviving a successful script
exit are unproved external effects.

Script execution inherits the caller environment by default, except `TMUX` and
`TMUX_PANE`. Pass `script_env` to `apply`, or `env` to `run_before_script`, to
choose it explicitly. Expansion still uses only its separately supplied `env`.

### Failures

Failures raise [`WorkspaceApplyError`][workspaceapplyerror] with `cause` and a
`result` containing:

| Field | Meaning |
| --- | --- |
| `status` | `failed`, `partial` or `cancelled`; success returns `complete` |
| `session`, `created`, `borrowed` | Exact references established by completed replies |
| `completed` | Plan step indices whose operations completed |
| `unknown_effects` | Shell input, scripts, borrowed configuration and uncertain steps |
| `removed` | Bootstrap windows removed during successful application |
| `rollback` | Attempted cleanup outcomes, including unresolved known creations |

### Rollback

`rollback=:created` attempts uncancelled cleanup within five seconds. It removes the
new session or newly created window links in a borrowed session. It preserves
borrowed resources and other links to shared windows.

A returned window whose link could not be observed is reported as unresolved.
Cleanup does not restore borrowed options and environment, global settings or
shell effects, and it never guesses which resources an uncertain reply might
have created.

## Freezing a session

[`freeze(server, session_ref)`][freeze] returns a
[`WorkspaceDocument`][workspacedocument] containing names, window indices and
layouts, pane directories and focus. Write `document.data` with your JSON or
YAML encoder.

It cannot reconstruct commands, options, environment, history or shell side
effects. Shared windows become independent windows when reloaded. Acquisition is
not atomic, and normal expansion rules still apply to names and paths in the
resulting document.

## The command line

After preparing a consumer project, [`install_cli`][install_cli] installs a
launcher into a directory you choose. It binds to that resolved project and
performs no dependency installs. Existing launchers are preserved unless
`force=true` is explicit.

`load` and [`freeze`][freeze] require exactly one `--socket` or `--socket-name`;
there is no default-server fallback. Use `--tmux` to choose the executable.
`--env`, `--home` and `--base-directory` supply expansion inputs.
`--no-readiness` is an explicit opt-out.

`--attach` is load-only, runs after successful application, and requires
terminal stdin and stdout plus human output. The automated consumer tests have
not exercised interactive attachment.

Human progress and script output go to stderr. `--output json` writes one final
stdout document. `--output ndjson` writes ordered progress followed by one
terminal `result` or `error`, each with a sequence number; script bytes are
base64.

Ctrl-C returns cancellation evidence and applies requested cleanup. The
installed-launcher test verifies this with a blocked owned script. The installed
process owns Ctrl-C handling until exit. Calling library [`main`][main] leaves
the embedding application's signal handlers unchanged.

The installed launcher owns one bounded writer for stdout and stderr. Progress
callbacks enqueue at most 64 records and 8 MiB; one active record can retain
another 2 MiB. A write has a 500 ms deadline; final drainage has 900 ms.

Queue overflow, write failure or a stalled consumer cancels application work,
closes owned stdio and joins the writer. Requested rollback still applies.
Output failure returns exit code 3; a terminal record cannot be delivered to an
unavailable consumer. Library `main(...; out, err)` borrows its streams, leaves
them open, and requires their writes to return promptly.

| Exit | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Configuration or usage error |
| 3 | Backend or output failure |
| 4 | Partial application |
| 5 | Cancellation |
| 6 | Deadline |

## Ownership, limits and errors

[`validate`][validate] copies data into immutable records and tuples. Later
mutation of the caller's dictionaries, vectors or integer objects does not
change a validated configuration. [`WorkspaceDocument.data`][workspacedocument]
is parsed mutable data; validate it before handing it to other code. Expanded
records and plan steps contain owned values.

[`ConfigLimits()`][configlimits] defaults to 1 MiB of document and string data,
32 nesting levels and 20,000 values. JSON and YAML nesting are bounded before
recursive object construction. Both parsers reject duplicates before a key can
overwrite another. File reads request at most `max_bytes + 1` bytes. Expansion
bounds constructed strings before allocation with its own `limits` argument.

[`WorkspaceConfigError`][workspaceconfigerror] exposes `code`, `path` and
`message`. Examples include `:duplicate`, `:unknown_key`, `:unsupported`,
`:version`, `:type`, `:value`, `:limit`, `:variable` and `:home`. Parser errors
are normalized without including configuration values, which can contain
secrets. Syntax diagnostics identify the document root and give no parser line
or column.

Plans contain ordered [`PlanStep`][planstep] values with `action`, optional
`window` and `pane` positions, and named `arguments`. Creating a window includes
its first pane. The steps describe intended effects. They do not establish a
live server generation, target identity, readiness or rollback capability.

## Working in this checkout

The source examples need a checkout. From the repository root, enter this
package directory and use the same shell for setup and examples:

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

After preparation, run the pure inner suite:

```console
$ julia \
    --startup-file=no \
    --compile=min \
    -O0 \
    --project="$workspace_stage" \
    test/runtests.jl
```

The default `unit` suite covers parser admission, immutable values, expansion,
inert plans, owned script execution, readiness lifecycle and CLI formatting. For
a focused inner loop, run the corresponding file (`test/config.jl`,
`test/script.jl`, `test/readiness.jl` or `test/cli.jl`).

The `integration` suite runs owned real-tmux application, partial cleanup and
observation-failure checks. `cli` runs installed launchers for load, freeze and
SIGINT; its separate Julia processes make it an outer check. `all` runs every
suite.

Run normal compilation for the outer check, including startup and setup in its
timing:

```console
$ julia \
    --startup-file=no \
    --project="$workspace_stage" \
    test/runtests.jl all
```

Set `LIBTMUX_TEST_CLI_COMPILE=normal` to verify installed launchers with their
default optimized compilation. The standard CLI semantic fixture uses minimal
compilation explicitly and does not replace this normal check.

Set `LIBTMUX_TEST_TMUX` to select a tmux executable. Every live test owns its
socket and daemon; none uses the default server. Tests require no network or
package resolution after preparation. Consumer tests own their servers through
the public core [`with_server`][with_server] operation.

`dev/cli_latency.jl OUTPUT.json [normal|o0|minimal|all] [samples]` is a separate
benchmark tier, defaulting to `normal`. It compares fresh installed CLI load and
freeze processes under default optimization, `-O0` and `--compile=min -O0`,
using the same owned-server workload. Prepare packages first;
`LIBTMUX_BENCH_THREADS=1` or `4` chooses child threads.

Profiles run in randomized order for each repetition. The default is one sample
per mode, which compares modes for diagnosis and supports no statistical
performance claim. Repeated runs retain raw observations and descriptive median
and tail summaries.

## Relation to tmuxp

The imported behavior was checked against tmuxp's
[loader](https://github.com/tmux-python/tmuxp/blob/08918c73464136d16776d0b75afb9b2e1c15deb2/src/tmuxp/workspace/loader.py),
[validation](https://github.com/tmux-python/tmuxp/blob/08918c73464136d16776d0b75afb9b2e1c15deb2/src/tmuxp/workspace/validation.py)
and
[classic builder](https://github.com/tmux-python/tmuxp/blob/08918c73464136d16776d0b75afb9b2e1c15deb2/src/tmuxp/workspace/builder/classic.py).

The package implements a subset with stricter duplicate, type, version and focus
checks. It does not claim full tmuxp compatibility. Python plugins, arbitrary
builders and sleeping readiness strategies are unsupported.

[apply]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-apply/
[configlimits]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-configlimits/
[expand]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-expand/
[freeze]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-freeze/
[install_cli]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-install_cli/
[main]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-main/
[parse_config]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-parse_config/
[planstep]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-planstep/
[read_config]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-read_config/
[run_before_script]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-run_before_script/
[validate]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-validate/
[with_server]: https://libtmux.org/en/julia/latest/reference/libtmux-with_server/
[workspaceapplyerror]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspaceapplyerror/
[workspaceconfigerror]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspaceconfigerror/
[workspacedocument]: https://libtmux.org/en/julia/latest/workspace/reference/libtmuxworkspace-workspacedocument/

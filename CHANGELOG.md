# Changelog

## Unreleased

#### Restore the tmux 3.3a minimum

The minimum tmux release is 3.3a again; 0.1.0 required 3.7c. Control
connections still need tmux 3.7 and named-buffer deletion needs 3.4. On older
releases those operations raise `UnsupportedCapability` before any effect, and
everything else keeps working, including pasting, which deletes its own
staging buffer before 3.4. (#41)

#### Raw tmux command lines meet the release requirements

`run_command`, `run_batch` and `run_group` refuse a command before sending it
when the release mishandles it: `delete-buffer -b` and `set-buffer -n`
below tmux 3.4, `refresh-client -l` below tmux 3.6a (it stops a 3.3a server at
once, and a 3.4 to 3.6 server when the attached client leaves before its
terminal answers), a `select-layout` string that 3.3a would stop on, and a
`break-pane` without `-n` on tmux 3.7. Commands are resolved the way tmux
resolves them, including aliases, prefixes and `;` lists. Command strings that
tmux parses itself, such as `if-shell` bodies, are not inspected. (#41)

#### `break_pane` works on every supported release

`break_pane` reads the window back from the pane where tmux up to 3.5 prints
nothing for a window's last pane, instead of failing after the move. On
exactly tmux 3.7, which stops on a nameless `break-pane` and ignores `-n`, it
requires a name and renames the window afterwards. (#41)

#### MCP waits poll the screen below tmux 3.7

`wait_for_text` and `send_keys_and_wait` poll the screen, joining wrapped rows,
on servers without control support and report such a match with
`source: "screen"`. A wait whose pane exits or whose server stops fails with
code `pane_died` and an `output` field holding the text seen so far, on both
paths, also while a second client keeps the stopped server alive. (#41)

#### Waits report an ended pane or server

`wait_for`, `wait_for_text` and `wait_for_quiet` raise the new
`OutputWaitEnded` when the pane has exited or the tmux server has stopped,
with the `reason` (`:pane_exited` or `:server_exited`) and the `text` the wait
had seen. Before, both came back as `ObservationLost` with advice to acquire a
new baseline, which cannot help when nothing is left to observe. A live pane
whose stream dropped still raises `ObservationLost`; code that caught
`ObservationLost` to detect a dead pane should catch `OutputWaitEnded`. (#41)

#### Plan workspaces with fewer allocations

Repeated workspace inspection and planning allocate less while preserving
plan contents and ordering. Direct record construction requires the exported
configuration, expanded-workspace and plan-step records. (#39)

#### Release installation checks use normal Julia compilation

Verify installed packages with Julia's normal compiler and cache behavior.
Child imports and launcher checks receive only their isolated environment,
so inherited credentials stay out of failure diagnostics.

#### Accept annotated release tags

The release check binds a tag push to its public tag object and the commit
it names. Annotated and lightweight tags retain the same metadata and trunk
checks.

## 0.1.0 - 2026-10-20

#### CI no longer runs macOS

The Julia workflow runs its Linux configurations only. macOS and psmux are
excluded from CI and current support; earlier platform results remain
historical evidence. (#34, #32)

#### The release workflow checks a tag install again

The job that installs a pushed release tag into a fresh Julia environment
read fields Pkg does not provide and failed after a successful install. It
now checks each installed package's name, version, source, revision and
tree, and its self-test is built from Pkg's own package fields. (#34)

#### Require Julia 1.13.1 and tmux 3.7c

Require Julia 1.13.1 and tmux 3.7c across the core, MCP and workspace packages.
Unsupported or replaced daemons are refused before effects. JSON layouts
require tmux 3.8. (#32)

#### Query captured state and scoped relationships

Inspect operational pane state, look up captured entities by identity, and
filter related entities with native Julia collections. Scoped observations
preserve coverage, ordering and the distinction between shared windows and
their session links. (#32)

#### Wait for output within a shared deadline

Wait for text, a predicate or an inactivity interval with a shared deadline
and cancellation. Concurrent callers keep their own registration budgets;
a text match or quiet output does not prove command success. (#32)

#### Maintain panes and inspect configuration

Maintain panes and inspect bounded option, environment, hook and buffer
inventories. Pane operations preserve literal window names, and callers
retain cancellation causes and cleanup failures. (#32)

#### Follow task-first guides and installation examples

Use task-first guides, executable tmux examples and native API references.
MCP and workspace installation recipes show how to bind their launchers to
the selected consumer project. (#32)

#### Identify CI failures and retain partial results

Identify the active file and nested testset, retain original failures and
partial artifacts, and continue independent files after failures. Linux
checks cover isolated installs and installed workflows, with bounded cleanup
and portable Julia caches. (#32)

## 0.1.0-alpha.2 - 2026-10-18

#### Require tmux 3.3a

`LibTmux` requires tmux 3.3a or newer, judged by the running tmux server's
version rather than the `tmux` executable's. Commands, owned server startup,
control attachment and the `LibTmuxWorkspace` attach refuse a server below
3.3a, including 3.3 and anything before 3.2, and a version report that names
no release, with `UnsupportedTmuxVersion` before the command has any effect.
Upgrade tmux and restart the server, or pin the previous release.
`kill-server` on an absent endpoint does nothing. The first command to an
endpoint reads the release; later commands skip the read, and a replaced or
vanished server drops the remembered release. `UnsupportedTmuxVersion` and
`MINIMUM_TMUX_VERSION` are new exports. (#17)

#### The version check runs no user hooks

Reading the server's version no longer runs a user's `after-display-message`
hook, and a server replaced after the check is refused before any command
runs. A control attach compares the server's identity without a hook too.
(#17)

#### Commands return when an exited client's pipes stay silent

`run_command` returns the output read so far once a client has exited and its
pipes stay silent for 250 ms. A tmux 3.0a or 3.1c server that keeps the
client's stdout open no longer holds the call until its deadline. (#17)

#### The option catalog starts at tmux 3.3a

The catalog drops its 3.2a and 3.3 metadata. `allow-passthrough`,
`destroy-unattached`, `pane-active-border-style` and `pane-border-style` still
need an exact pinned release. `window-linked`, `window-unlinked` and
`pane-border-format` are stable entries with one scope, and the catalog refuses
releases below the floor. (#17)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial Julia package suite

Add `LibTmux`, a Julia-native tmux core with explicit server selection,
captured snapshots, callable criteria, and direct or control-mode operations.
Add `LibTmuxMCP` for local stdio tools and `LibTmuxWorkspace` for planning,
applying, and freezing the documented tmuxp-compatible YAML/JSON subset through
a CLI. The suite includes runnable examples, documentation, benchmarks,
and a selected Julia/tmux CI matrix. (#1)

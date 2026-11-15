# Expected structure of tmuxp's examples

Each `<name>.json` is the structure tmuxp's example `../<name>.yaml` means,
written by hand from what tmuxp documents for it. No tmuxp or Python runs to
produce or check them, and a structure is never generated from tmuxp's output.

## Source

Nine files are copies of the structures libtmux-ruby wrote at
[`fdc8bac`](https://github.com/libtmux/libtmux-ruby/tree/fdc8bac/test/fixtures/tmuxp/expected):
`2-pane-vertical`, `3-pane`, `4-pane`, `focus-window-and-panes`,
`main-pane-height`, `session-environment`, `shorthands`, `start-directory` and
`window-index`. That copy is the reference the ports share, so these stay
byte-identical to it. The other six, `2-pane-synchronized`, `blank-panes`,
`env-variables`, `main-pane-height-percentage`, `pane-shell` and
`suppress-history`, are files this loader accepts and libtmux-ruby refuses. They
follow the same shape.

## Shape

`session`, then `windows` in file order, then `panes` in file order, with each
key present. The values are what tmuxp means after it expands the file:

- A pane's `commands` are the session's, the window's and the pane's
  `shell_command_before`, then its own `shell_command`.
- A window's or pane's `start_directory` has its parent's joined on, and `null`
  means the file set none.
- `focus` and `index` are the ones in effect when the build ends: the last window
  or pane the file focuses, else the first, and the lowest index tmux has free.
- A pane's `environment` is the session's variables with the pane's, else its
  window's, on top.

A few keys exist only where a file needs them, and default to `{}` or `null`:
`options_after` on a window, `shell` on a pane and `before_script` on the
session.

`${HOME}` and `${WORKSPACE_DIR}` stand for the home directory and the directory
of the workspace file. `env-variables.json` shows expanded variables as the
placeholders `/@PWD@`, `/@MY_ENV_VAR@` and `@USER@`, which the tests give to the
loader as the values of `PWD`, `MY_ENV_VAR` and `USER`.

## Where this loader differs

`test/support/tmuxp_catalog.jl` lists each difference with its reason, applies it
to the expected structure and fails when the loader stops differing. They are an
undeclared `start_directory`, which is the workspace file's directory here,
`./` in a window directory, which resolves against the session's directory, and
the word `pane`, which libtmux-ruby's copy of `focus-window-and-panes` sends as a
command and tmuxp documents as a blank pane.

## Checks

`test/tmuxp_catalog.jl` compares the loaded model of every file with its
structure. `test/tmuxp_build.jl` builds each file on a private tmux server and
compares the session, window and pane tree with the same structure, reading only
what exists once the build returns. Pane contents, command output and timing are
not compared. `../syntax-support.json` records, for each tmuxp key and form,
whether the loader supports it, supports it with a difference, or refuses it
with its message, and `test/tmuxp_catalog.jl` checks every entry against the
loader.

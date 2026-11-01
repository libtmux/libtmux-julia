# Changelog

## Unreleased

## 0.1.1 - 2026-11-01

#### Take the server from a variable or tmux

`libtmux-mcp` no longer needs `--socket` or `--socket-name`. With neither, it
reads `LIBTMUX_SOCKET_PATH`, then `LIBTMUX_SOCKET`, and otherwise leaves the
choice to tmux: the server `TMUX` names inside tmux, and the default socket
elsewhere. A socket option leaves both variables unread, and the launcher still
refuses `--socket` together with `--socket-name`. A `LIBTMUX_SOCKET` that holds a
slash is refused with exit status 2. (#64)

## 0.1.1-alpha.1 - 2026-10-24

#### Require tmux 3.3a

The MCP application requires tmux 3.3a again. Its waiting tools poll the
screen below tmux 3.7, joining wrapped rows, and report `source: "screen"`; a
wait whose pane exits or whose server stops fails with code `pane_died` and an
`output` field holding the text seen so far, on both paths. (#41)

## 0.1.0 - 2026-10-20

#### Require Julia 1.13.1 and tmux 3.7c

Require Julia 1.13.1 and tmux 3.7c for the MCP application. Install MCP as a
separate package and bind its launcher to the selected consumer project.
(#32)

#### Scope, filter and page pane discovery

Discover panes within a session or window, filter and project captured
fields, and continue pages only while the observation remains unchanged.
Wait tools share core waits and accept shorter per-call budgets. (#32)

#### Preserve whole-call effects

Inspect effects from hooks, earlier batch items, cancellation and cleanup
when a tool fails. Effects describe the whole call, including work completed
before an error. (#32)

#### Report the installed package version

Keep the reported MCP server version aligned with installed package metadata
after upgrades and normal precompilation. (#32)

## 0.1.0-alpha.2 - 2026-10-18

#### Report refused tmux releases

A tool called against a tmux server below 3.3a, or one that reports no known
release, fails with the new error code `unsupported_tmux` and `effects:
none`, and `libtmux-mcp` exits at startup with the same remedy. `--help` names
the minimum release. (#17)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial stdio MCP application

Run a local stdio MCP application against an explicitly selected tmux endpoint.
It exposes discoverable tmux tools with policy-controlled targets, bounded
waits, cancellation, and owned-session teardown. (#1)

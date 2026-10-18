# Changelog

## Unreleased

#### Report refused tmux releases

`load` and `freeze` report a tmux server below 3.3a, or one that reports no
known release, as error code `tmux_unsupported` with exit status 3 in human,
JSON and NDJSON output. The message names the release and the remedy, and
`load` no longer wraps it in a generic apply failure, and announces no step
before it refuses. A refused step is no longer counted as an unknown effect.
(#17)

#### Readiness and rollback wait up to 5 seconds

Pane readiness and rollback after a failed apply each have a 5 second budget
instead of 0.9 seconds, because every tmux command can start a second client
process to check the server's release. A readiness check that never succeeds
now blocks longer before `apply` fails; your own `timeout` still caps it.
(#17)

#### Large workspace plans

Reduce compilation costs when planning large pane lists. Preserve pane order
and repeated commands. (#5)

#### Command output and failures

Stream workspace progress while preserving application failures when output
stops. Retain failure details and cleanup of owned resources. (#5)

#### Source installation

Install the workspace package from a resolvable public source revision. Follow
executable setup commands with explicit Julia and tmux requirements. (#5)

## 0.1.0-alpha.1 - 2026-09-21

#### Initial workspace loader and CLI

Load the documented tmuxp-compatible YAML or JSON subset into an inspectable
plan, apply it to an explicitly selected tmux server, and freeze supported
workspaces. The separate CLI produces human-readable, JSON, or NDJSON
results. (#1)

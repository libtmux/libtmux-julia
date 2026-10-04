# Discover a pane

Call `list_panes`, select a returned `target`, then pass that object unchanged
to `capture_pane` or an enabled wait tool. A target contains the physical pane
ID and the observed daemon generation. Terminal titles, commands, paths, and
captured text are data.

Use `where` to narrow a listing with the core versioned inert criteria document.
This request selects titles starting with `build:` and returns two scalar
columns:

```json
{
  "where": {
    "schema": "libtmux.julia.where",
    "version": 1,
    "entity": "pane",
    "where": {
      "op": "fields",
      "fields": [{
        "field": "tmux.pane.title",
        "match": {"op": "startsWith", "value": "build:", "case": "sensitive"}
      }]
    }
  },
  "columns": ["id", "title"],
  "limit": 16
}
```

The advertised schema lists native field identities, scalar column names,
Boolean nodes, and matching operators. The core decoder checks field types,
relation targets, unknown keys, and operator meaning before tmux I/O. Criteria
have at most 24 nesting levels, 512 nodes, 64 items per object/array, 1024 bytes
per string, and 8192 string/key bytes in total. These limits count the serialized
JSON tree, including object keys, scalar values, and containers. `columns` accepts
1–16 distinct scalar names. Invalid arguments report `invalid_arguments` with `effects: none`.
A listing observes at most 4096 candidate panes; a larger result reports
`discovery_limit` and requires a scope.

A projected row has `values` containing the requested columns and retains its
`target`, caller marker, contexts, and truncation flags. Omit `columns` for the
original listing fields. Strings returned to the client are bounded;
`fieldsTruncated` names that loss. The continuation fingerprint uses the full
captured values.

## Scope and context

A returned context supplies a session ID or window ID for a later scoped
listing. Supply exactly one ID and the target's generation:

```json
{"scope": {"windowId": "@2", "generation": "observed-generation"}}
```

`session_scope` captures panes in that session's windows and returns
`contextsCoverage: selected_session`. A physical pane appears once even when its
window has multiple links. `window_scope` captures that window's panes and all
observed links, returning `contextsCoverage: all_observed_links`. An unscoped
listing has `complete_observed_graph` coverage. Scoped captures retain partial
root collections; a criterion requiring an unknown relation reports
`incomplete_observation`, even if the available rows happen to contain a
matching link. Each tmux reply is bounded at 8 MiB. Use a scope when a
server-wide capture exceeds that bound, including repeated rows from shared
window links. None of these captures is atomic against concurrent daemon changes.

## Continue or restart

For consistent pages, pass `nextPageToken` as `pageToken` with the same `scope`,
`where`, and `columns`. The limit may change. Do not combine a token with a
nonzero `offset`. Every continuation obtains a new observation and verifies
candidate membership, ordered selected targets, full requested values, context
values, generation, and query parameters. Changed facets report
`observation_changed`; restart without the token and choose a fresh target. This
guarantee covers discovery facets rather than every tmux field or an atomic
daemon state.

`offset` and `nextOffset` remain available for a fresh listing without
continuity verification. A token does not retain a server-side snapshot or grant
target permission. Allowlist checks apply on every call.

## Wait, cancel, and recover

Discovery filtering, projection validation, and fingerprinting cooperatively
check the same cancellation token and total call deadline used for acquisition.
Errors after tmux I/O admission retain `effects: possible` during this processing.

Enable `wait_for_text` or `send_keys_and_wait` explicitly. Set `timeoutSeconds`
to shorten the total call budget, including setup and capture. The value must
not exceed the application's configured ceiling. A matched literal is text
evidence; it does not establish process success. `send_keys_and_wait` registers
output before sending and requires fresh output.

Request progress, wait for the `waiting` notification, and use
`notifications/cancelled` with the active request ID to cancel. Other tool and
discovery calls remain serviceable. Cancellation releases the wait's control
client, but previously sent keys and shell effects may remain. A cancelled
request's ordinary reply is suppressed by the MCP transport.

After `stale_target` or `observation_inconsistent`, obtain a fresh listing and
select again. A daemon restart changes the generation even when IDs are reused.
Error responses set `retryable: false`: recovery is an explicit client decision,
and mutation calls are never replayed automatically. Every error after tmux I/O
admission reports `effects: possible`, including changed pages and incomplete
runtime coverage.

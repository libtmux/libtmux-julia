# Criteria field reference

Generated from `schema/fields.toml`; regenerate with `dev/generate-criteria.jl`.

Criteria are local callable values. Omitted keywords impose no constraint.
`nothing` matches captured absence only for nullable fields; uncaptured
values raise `SnapshotCoverageError`. IDs require their typed constructors.

Import operators with `import LibTmux.Filters as F`. Scalar fields accept
bare equality, `F.EqualTo`, `F.NotEqualTo`, and `F.OneOf`. String fields also
accept `F.Contains`, `F.StartsWith`, and `F.EndsWith`; their `case` option is
`:sensitive` or `:ascii_insensitive`, without Unicode folding. Integer fields
accept `F.AtLeast`, `F.AtMost`, `F.GreaterThan`, and `F.LessThan` with finite
numeric thresholds; Boolean values are not numeric operands.

To-one relations accept a nested criterion; optional relations also accept
equality/inequality with `nothing`. To-many relations require `F.AnyRelated`,
`F.AllRelated`, or `F.NoRelated`. Empty membership gives false/true/true.
`F.AllOf`, `F.AnyOf`, and `F.Not` combine criteria for the same entity.
All branches and related members are checked for coverage before matching.

## ClientWhere

Matches `ClientSnapshot`. All listed fields use local evaluation; tmux
pushdown is not implemented. Availability depends on captured coverage.

| Keyword | Wire identity | Julia value | Nullable | tmux field/source | Contract |
| --- | --- | --- | --- | --- | --- |
| `id` | `tmux.client.id` | `ClientID` | false | `client_name/client_pid/client_created` | Exact name plus observed connection incarnation.  |
| `name` | `tmux.client.name` | `String` | false | `client_name` | Exact tmux client name.  |
| `pid` | `tmux.client.pid` | `Integer` | false | `client_pid` | Observed client process ID.  |
| `created` | `tmux.client.created` | `Integer` | false | `client_created` | Observed creation time; not a strict identity guard.  |
| `activity` | `tmux.client.activity` | `Integer` | false | `client_activity` | Observed client activity time in Unix seconds.  |
| `session` | `tmux.client.session` | `SessionWhere (one)` | true | `session_id` | Captured session or known absence; normal acquisition lists attached clients.  |

## PaneWhere

Matches `PaneSnapshot`. All listed fields use local evaluation; tmux
pushdown is not implemented. Availability depends on captured coverage.

| Keyword | Wire identity | Julia value | Nullable | tmux field/source | Contract |
| --- | --- | --- | --- | --- | --- |
| `id` | `tmux.pane.id` | `PaneID` | false | `pane_id` | Physical pane identity.  |
| `index` | `tmux.pane.index` | `Integer` | false | `pane_index` | Pane index within its window; not a Julia collection position.  |
| `active` | `tmux.pane.active` | `Bool` | false | `pane_active` | Active pane of its window; not client visibility.  |
| `dead` | `tmux.pane.dead` | `Bool` | false | `pane_dead` | Whether tmux retains an exited pane.  |
| `width` | `tmux.pane.width` | `Integer` | false | `pane_width` | Pane width in cells.  |
| `height` | `tmux.pane.height` | `Integer` | false | `pane_height` | Pane height in cells.  |
| `current_command` | `tmux.pane.current_command` | `String` | true | `pane_current_command` | Command name observed by tmux. May be uncaptured; nonempty dead-pane fallback is retained. |
| `current_path` | `tmux.pane.current_path` | `String` | true | `pane_current_path` | Path observed on the tmux host; text matching is lexical. May be uncaptured when tmux cannot resolve cwd. |
| `title` | `tmux.pane.title` | `String` | false | `pane_title` | Pane title, including literal format-like text.  |
| `pid` | `tmux.pane.pid` | `Integer` | false | `pane_pid` | Observed initial pane process ID; not an identity guard.  |
| `tty` | `tmux.pane.tty` | `String` | true | `pane_tty` | Pane PTY path, or captured absence for a pane without a PTY.  |
| `exit_status` | `tmux.pane.exit_status` | `Integer` | true | `pane_dead_status` | Normal-exit status retained by tmux; live or signal-terminated panes have captured absence.  |
| `history_size` | `tmux.pane.history_size` | `Integer` | false | `history_size` | Retained scrollback lines.  |
| `history_limit` | `tmux.pane.history_limit` | `Integer` | false | `history_limit` | Configured maximum scrollback lines.  |
| `cursor_x` | `tmux.pane.cursor_x` | `Integer` | false | `cursor_x` | Zero-based cursor column in the pane's base screen.  |
| `cursor_y` | `tmux.pane.cursor_y` | `Integer` | false | `cursor_y` | Zero-based cursor row in the pane's base screen.  |
| `window` | `tmux.pane.window` | `WindowWhere (one)` | false | `window_id` | Physical containing window.  |

## SessionWhere

Matches `SessionSnapshot`. All listed fields use local evaluation; tmux
pushdown is not implemented. Availability depends on captured coverage.

| Keyword | Wire identity | Julia value | Nullable | tmux field/source | Contract |
| --- | --- | --- | --- | --- | --- |
| `id` | `tmux.session.id` | `SessionID` | false | `session_id` | Session identity.  |
| `name` | `tmux.session.name` | `String` | false | `session_name` | Session name.  |
| `attached_clients` | `tmux.session.attached_clients` | `Integer` | false | `session_attached` | Attached client count observed by tmux.  |
| `created` | `tmux.session.created` | `Integer` | false | `session_created` | Session creation time in Unix seconds.  |
| `activity` | `tmux.session.activity` | `Integer` | false | `session_activity` | Observed session activity time in Unix seconds.  |
| `last_attached` | `tmux.session.last_attached` | `Integer` | true | `session_last_attached` | Last attachment time in Unix seconds, or captured absence when tmux has no recorded attachment.  |
| `windows` | `tmux.session.windows` | `WindowWhere (many)` | false | `window_id` | Unique windows reached through complete captured session links.  |
| `windowlinks` | `tmux.session.windowlinks` | `WindowLinkWhere (many)` | false | `window_index` | Complete captured links including session-specific indices.  |

## WindowWhere

Matches `WindowSnapshot`. All listed fields use local evaluation; tmux
pushdown is not implemented. Availability depends on captured coverage.

| Keyword | Wire identity | Julia value | Nullable | tmux field/source | Contract |
| --- | --- | --- | --- | --- | --- |
| `id` | `tmux.window.id` | `WindowID` | false | `window_id` | Physical window identity, independent of session links.  |
| `name` | `tmux.window.name` | `String` | false | `window_name` | Window name.  |
| `width` | `tmux.window.width` | `Integer` | false | `window_width` | Window width in cells.  |
| `height` | `tmux.window.height` | `Integer` | false | `window_height` | Window height in cells.  |
| `layout` | `tmux.window.layout` | `String` | false | `window_layout` | Full window layout, including saved layout while zoomed.  |
| `visible_layout` | `tmux.window.visible_layout` | `String` | false | `window_visible_layout` | Currently visible layout, including the zoomed pane.  |
| `zoomed` | `tmux.window.zoomed` | `Bool` | false | `window_zoomed_flag` | Whether the window is zoomed.  |
| `activity` | `tmux.window.activity` | `Integer` | false | `window_activity` | Observed window activity time in Unix seconds.  |
| `panes` | `tmux.window.panes` | `PaneWhere (many)` | false | `pane_id` | Complete captured physical pane membership.  |
| `windowlinks` | `tmux.window.windowlinks` | `WindowLinkWhere (many)` | false | `session_id/window_index` | Complete captured links to sessions.  |

## WindowLinkWhere

Matches `WindowLink`. All listed fields use local evaluation; tmux
pushdown is not implemented. Availability depends on captured coverage.

| Keyword | Wire identity | Julia value | Nullable | tmux field/source | Contract |
| --- | --- | --- | --- | --- | --- |
| `index` | `tmux.windowlink.index` | `Integer` | false | `window_index` | Window index in this session.  |
| `active` | `tmux.windowlink.active` | `Bool` | false | `window_active` | Selected window in this session.  |
| `session` | `tmux.windowlink.session` | `SessionWhere (one)` | false | `session_id` | Session containing this link.  |
| `window` | `tmux.windowlink.window` | `WindowWhere (one)` | false | `window_id` | Physical linked window.  |

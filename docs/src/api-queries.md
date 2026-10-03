# Captured data and criteria

Capture a graph of tmux entities, then use Julia collections, criteria, and
projections to inspect it. The [captured query guide](queries.md) explains
coverage, identity, linked windows, and wire compatibility.

## Captured entities and acquisition

### IDs, references, and views

| Public name | Use |
| --- | --- |
| `SessionID("\$0")`, `WindowID("@1")`, `PaneID("%2")` | Validate a numeric tmux ID and retain its entity kind. |
| `SessionRef(identity, id)`, `WindowRef(identity, id)`, `PaneRef(identity, id)`, `ClientRef(identity, id)` | Bind an ID to an observed [`ServerIdentity`](@ref). Prefer an acquired entity's `.ref`; a supplied identity does not establish current daemon liveness. |
| `SessionSnapshot`, `WindowSnapshot`, `PaneSnapshot`, `ClientSnapshot` | Read-only views returned by [`snapshot`](@ref) and captured collections. Access observed fields and `.ref`; acquire views rather than constructing their private storage. |
| `WindowLink` | One captured session/window slot, with `session_id`, `window_id`, `index`, `active`, `.session`, and `.window`. A shared physical window can have several links. |

```@raw html
<p>Included source: <a href="../source/src/model.jl.html#L21">typed IDs</a>,
<a href="../source/src/model.jl.html#L71">references</a>, and
<a href="../source/src/model.jl.html#L150">captured views</a>.</p>
```

### Collections and navigation

These calls use captured data only. A relation with unknown membership raises
[`SnapshotCoverageError`](@ref); an empty observed relation returns an empty
[`Selection`](@ref). Collections retain order and snapshot provenance.

| Call | Result |
| --- | --- |
| `sessions(snap)`, `windows(snap)`, `panes(snap)`, `clients(snap)` | Complete server-wide entity collections; windows and panes represent physical entities. |
| `windowlinks(snap)` | All captured session/window slots. |
| `paneoccurrences(snap)` | [`PaneOccurrence`](@ref) values for every pane through every link; shared panes can occur more than once. |
| `windows(session_view)` | Physical windows in the session, deduplicated by ID in first-link order. |
| `panes(window_view)` | Panes of that physical window. |
| `windowlinks(session_view)`, `windowlinks(window_view)` | Links belonging to the selected session or physical window. |
| `window(pane_view)`, `window(link)` | The captured physical window. |
| `session(link)`, `session(client_view)` | The captured session; a client with observed absent `session_id` returns `nothing`. |
| `snap[ref]`, `get(snap, ref, default)` | A captured entity with matching server identity. Proven absence raises `KeyError` or returns `default`; an unknown scoped miss raises `SnapshotCoverageError`. |
| `entitykey(entity_or_ref)` | Server identity and physical entity ID; a `WindowLink` uses its physical window's key. |
| `occurrencekey(occurrence)` | Server identity, session ID, window slot, and pane ID. |
| `hascoverage(snap, key)` | Whether membership was observed completely: root keys include `:panes`; parent keys include `(:window, window_id, :panes)` and `(:session, session_id, :windowlinks)`. This does not check scalar field availability or contact tmux. |

[`snapshotof`](@ref) returns the retained graph. Read the [captured query
guide](queries.md) before using server-wide collections on a scoped capture.

```@raw html
<p>Included source: <a href="../source/src/model.jl.html#L270">captured lookup</a>,
<a href="../source/src/model.jl.html#L327">identity and coverage keys</a>, and
<a href="../source/src/model.jl.html#L341">collection and relation calls</a>.</p>
```

```@autodocs
Modules = [LibTmux]
Pages = ["src/model.jl", "src/acquisition.jl"]
Private = false
Order = [:module, :type, :function]
```

## Criteria and operators

Import the qualified operators and combine native criteria:

```julia
using LibTmux
import LibTmux.Filters as F

active_wide = PaneWhere(active=true, width=F.AtLeast(80))
in_shell = PaneWhere(current_command=F.OneOf(["sh", "bash"]))
criterion = F.AllOf(active_wide, in_shell)
wire = encode_where(criterion)
```

| Constructor | Meaning and example |
| --- | --- |
| `F.EqualTo(value)`, `F.NotEqualTo(value)` | Equality or inequality, such as `PaneWhere(active=F.NotEqualTo(false))`. A bare scalar field value means `EqualTo`. |
| `F.OneOf(values)` | Membership in copied scalar operands, such as `PaneWhere(index=F.OneOf([0, 2]))`. An empty operand list matches nothing. |
| `F.Contains(text; case=:sensitive)` | Literal substring, such as `PaneWhere(title=F.Contains("build"))`. |
| `F.StartsWith(text; case=:sensitive)`, `F.EndsWith(text; case=:sensitive)` | Literal prefix or suffix, such as `WindowWhere(name=F.StartsWith("dev"))`. |
| `F.AtLeast(value)`, `F.AtMost(value)` | Inclusive numeric bounds, such as `PaneWhere(width=F.AtLeast(80))`. |
| `F.GreaterThan(value)`, `F.LessThan(value)` | Exclusive numeric bounds, such as `PaneWhere(history_size=F.GreaterThan(0))`. |
| `F.AllOf(criteria...)`, `F.AnyOf(criteria...)` | Conjunction or disjunction on one entity kind. Empty lists match everything or nothing, respectively. |
| `F.Not(criterion)` | Negation, such as `F.Not(PaneWhere(dead=true))`. |
| `F.AnyRelated(criterion)` | At least one matching related record, such as `SessionWhere(windows=F.AnyRelated(WindowWhere(name="dev")))`. |
| `F.AllRelated(criterion)`, `F.NoRelated(criterion)` | Every or no related record matches. Both match an observed empty relation. |

Text operators also accept `case=:ascii_insensitive`; they do not perform
Unicode case folding or interpret patterns. Numeric bounds accept finite real
thresholds and reject Boolean values. Equality operands must match the field's
type, and `nothing` is accepted only for nullable fields. A nested to-one
criterion, such as `PaneWhere(window=WindowWhere(name="dev"))`, concerns that
captured parent. To-many constraints require a related-record operator.

Native criteria validate field types and relation kinds when constructed, and
check all requested coverage before evaluating Boolean branches. Base also
accepts ordinary callbacks, such as `filter(p -> p.width >= 80, panes(snap))`;
those callbacks retain their own effects and cannot be encoded as criteria.
[`encode_where`](@ref) enforces its wire profile's numeric and size limits;
the named sibling adapters refuse meanings outside their supported profiles.

```@raw html
<p>Included source: <a href="../source/src/criteria.jl.html#L23">operator constructors</a>,
<a href="../source/src/criteria.jl.html#L120">field validation</a>, and
<a href="../source/src/criteria.jl.html#L205">matching semantics</a>.</p>
```

```@autodocs
Modules = [LibTmux, LibTmux.Filters]
Pages = ["src/criteria_generated.jl", "src/criteria.jl"]
Private = false
Order = [:module, :type, :function]
```

## Projections and criteria wire formats

```@autodocs
Modules = [LibTmux]
Pages = ["src/projection.jl", "src/wire.jl", "src/sibling_wire.jl"]
Private = false
Order = [:module, :type, :function]
```

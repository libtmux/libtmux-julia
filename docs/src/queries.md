# Captured queries

[`snapshot`](@ref) acquires finite observations. `panes(snap)` contains
unique physical panes; `paneoccurrences(snap)` follows each session/window
link and may contain the same pane more than once. Filtering preserves the
source's order and multiplicity.

To inspect one exact session or window, pass its reference to
`snapshot(server, ref)` or `snapshot(connection, ref)`. The returned captured
view supports local navigation, such as `panes(snapshot(server, window_ref))`.
A session capture includes its window links and panes. A window capture
includes its panes, all links to sessions, and those sessions' scalar fields.
Neither form acquires attached clients.

`snapshotof(view)` retains that partial graph. Its server-wide collections
raise [`SnapshotCoverageError`](@ref). A session capture cannot prove a shared
window's links to other sessions; a window capture cannot prove each linked
session's other windows. Criteria that need those uncaptured relations raise
the same error. Use a full `snapshot(server)` when the query needs them.

[`PaneWhere`](@ref), [`WindowWhere`](@ref), [`SessionWhere`](@ref),
[`WindowLinkWhere`](@ref) and [`ClientWhere`](@ref) are callable criteria.
Use them with Base `filter`, `count`, `any`, `all`, `findall` and
`Iterators.filter`. Ordinary closures and downstream callable values work
where Base accepts them. `findall` returns collection positions; those are
one-based Julia indices, independent of tmux's configured indices.

`filter` preserves a [`Selection`](@ref). `collect` and row projections give
ordinary Julia collections. A selection pins its snapshot; keeping one pane
can therefore retain the whole captured graph. Refreshing acquires a new
snapshot and never changes existing selections.

Use `snap[reference]` to look up a captured session, window, pane or client.
`get(snap, reference, nothing)` returns `nothing` for proven absence. Both
validate the reference against the captured server identity; they do not
contact the current daemon. Indexing a proven missing key raises `KeyError`.
A missing key in a partial graph raises `SnapshotCoverageError` because its
absence was not observed. Client references also retain their incarnation.

The complete shared-window example is included directly from its tested
source:

```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "examples", "shared_windows.jl"), String) * "\n```")
```

Fields in one criterion are conjoined. Nested relations preserve correlation:
conditions within one `AnyRelated(WindowWhere(...))` concern the same window.
Two separate `AnyRelated` clauses can match different windows. On a captured
empty relation, any/all/none evaluates to false/true/true. Uncaptured membership
raises [`SnapshotCoverageError`](@ref), including in short-circuited branches.

`only` keeps Base's zero/multiple-result errors. [`onlymatch`](@ref) adds
distinct [`NoMatchError`](@ref) and [`MultipleMatchesError`](@ref) diagnostics.

Portable criteria use [`encode_where`](@ref) and [`decode_where`](@ref).
Closures are local code and cannot be encoded. TypeScript and Rust adapters
are separately named and reject semantics outside their verified intersection.
JSON and Tables are optional extensions, not mandatory core dependencies.

Criterion construction and wire conversion are pure and can be checked without
a tmux executable:

```jldoctest
julia> using LibTmux

julia> criterion = PaneWhere(active=true);

julia> criterion isa Function
true

julia> encode_where(decode_where(encode_where(criterion))) == encode_where(criterion)
true
```

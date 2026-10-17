"""A captured endpoint and opaque daemon-generation observation, not a strict guard."""
struct ServerIdentity
    socket_path::String
    generation::String

    function ServerIdentity(; socket_path::AbstractString, generation::AbstractString)
        path, epoch = _argument(socket_path), _argument(generation)
        isempty(path) && throw(ArgumentError("socket_path cannot be empty"))
        isempty(epoch) && throw(ArgumentError("generation cannot be empty"))
        new(abspath(path), epoch)
    end
end

Base.:(==)(a::ServerIdentity, b::ServerIdentity) =
    a.socket_path == b.socket_path && a.generation == b.generation
Base.isequal(a::ServerIdentity, b::ServerIdentity) = a == b
Base.hash(x::ServerIdentity, h::UInt) = hash((x.socket_path, x.generation), h)

abstract type EntityID end

"""A validated tmux numeric ID whose type fixes its entity kind."""
struct TmuxID{Kind} <: EntityID
    value::String

    function TmuxID{Kind}(value::AbstractString) where {Kind}
        prefix =
            Kind === :session ? '\$' :
            Kind === :window ? '@' :
            Kind === :pane ? '%' : throw(ArgumentError("unknown entity kind"))
        text = String(value)
        valid =
            ncodeunits(text) >= 2 &&
            codeunit(text, 1) == UInt8(prefix) &&
            all(c -> UInt8('0') <= c <= UInt8('9'), codeunits(text)[2:end]) &&
            (ncodeunits(text) == 2 || codeunit(text, 2) != UInt8('0'))
        valid || throw(ArgumentError("invalid $(Kind) ID: $(repr(text))"))
        new{Kind}(text)
    end
end
TmuxID{K}(id::TmuxID{K}) where {K} = id
const SessionID = TmuxID{:session}
const WindowID = TmuxID{:window}
const PaneID = TmuxID{:pane}

"""An exact client name and observed connection incarnation; names may be reused."""
struct ClientID <: EntityID
    name::String
    incarnation::String

    function ClientID(name::AbstractString, incarnation::AbstractString)
        name, incarnation = _argument(name), _argument(incarnation)
        isempty(name) && throw(ArgumentError("client name cannot be empty"))
        isempty(incarnation) && throw(ArgumentError("client incarnation cannot be empty"))
        new(name, incarnation)
    end
end
ClientID(id::ClientID) = id
Base.string(id::TmuxID) = id.value
Base.string(id::ClientID) = id.name
Base.:(==)(a::TmuxID{K}, b::TmuxID{K}) where {K} = a.value == b.value
Base.:(==)(::TmuxID, ::TmuxID) = false
Base.:(==)(a::ClientID, b::ClientID) = a.name == b.name && a.incarnation == b.incarnation
Base.isequal(a::EntityID, b::EntityID) = a == b
Base.hash(id::TmuxID{K}, h::UInt) where {K} = hash((K, id.value), h)
Base.hash(id::ClientID, h::UInt) = hash((:client, id.name, id.incarnation), h)
Base.show(io::IO, id::TmuxID{K}) where {K} =
    print(io, "TmuxID{:", K, "}(", repr(id.value), ")")
Base.show(io::IO, id::ClientID) =
    print(io, "ClientID(", repr(id.name), ", ", repr(id.incarnation), ")")

"""A typed entity identity bound to a captured daemon generation."""
struct EntityRef{I<:EntityID}
    server::ServerIdentity
    id::I

    EntityRef{I}(server::ServerIdentity, id) where {I<:EntityID} = new{I}(server, I(id))
end

const SessionRef = EntityRef{SessionID}
@doc """
    SessionRef

Identify one tmux session on the daemon generation it was captured from.
[`new_session`](@ref) returns one, and a `SessionSnapshot` carries its own as
`.ref`. Operations check a reference against the running daemon before acting
and raise `StaleReference` or `CrossServerReference` when it no longer matches.
""" SessionRef

const WindowRef = EntityRef{WindowID}
@doc """
    WindowRef

Identify one physical window on the daemon generation it was captured from,
whichever sessions link it; [`WindowLinkRef`](@ref) names one session's link.
[`new_window`](@ref) returns one, and a `WindowSnapshot` carries its own as
`.ref`. Operations check a reference against the running daemon before acting
and raise `StaleReference` or `CrossServerReference` when it no longer matches.
""" WindowRef

const PaneRef = EntityRef{PaneID}
@doc """
    PaneRef

Identify one physical pane on the daemon generation it was captured from.
[`split_window`](@ref) returns one, and a `PaneSnapshot` carries its own as
`.ref`. Operations check a reference against the running daemon before acting
and raise `StaleReference` or `CrossServerReference` when it no longer matches.
""" PaneRef

const ClientRef = EntityRef{ClientID}
@doc """
    ClientRef

Identify one attached tmux client by its name and observed connection
incarnation, because tmux can reuse client names. A `ClientSnapshot` carries
its own as `.ref`, and [`switch_client`](@ref) and [`detach_client`](@ref) take
one. Operations check a reference against the running daemon before acting and
raise `StaleReference` or `CrossServerReference` when it no longer matches.
""" ClientRef

Base.:(==)(a::EntityRef, b::EntityRef) = a.server == b.server && a.id == b.id
Base.isequal(a::EntityRef, b::EntityRef) = a == b
Base.hash(ref::EntityRef, h::UInt) = hash((ref.server, ref.id), h)
entitykey(ref::EntityRef) = (ref.server, ref.id)

"Captured data cannot answer a requested field or relation; this is not a no-match result."
struct SnapshotCoverageError <: LibTmuxError
    entity::Symbol
    id::Union{Nothing,String}
    field::Symbol
end
function Base.showerror(io::IO, e::SnapshotCoverageError)
    print(io, "snapshot does not contain complete ", e.entity)
    e.id === nothing || print(io, " ", repr(e.id))
    print(io, ".", e.field, " coverage")
end

struct InconsistentSnapshot <: LibTmuxError
    detail::String
end
Base.showerror(io::IO, e::InconsistentSnapshot) =
    print(io, "inconsistent snapshot: ", e.detail)

struct _CapturedRecord
    fields::NamedTuple
end

"""
    Snapshot

Privately owned captured records and membership coverage. Acquiring a new
snapshot never refreshes an existing one. Its acquisition interval describes
process-relative monotonic seconds, not UTC or a tmux transaction. Obtain
collections with `panes`, `windows`, `sessions`, `clients`, `windowlinks`,
and `paneoccurrences`.
"""
struct Snapshot
    identity::ServerIdentity
    acquired::Tuple{Float64,Float64}
    _sessions::Vector{_CapturedRecord}
    _windows::Vector{_CapturedRecord}
    _panes::Vector{_CapturedRecord}
    _clients::Vector{_CapturedRecord}
    _windowlinks::Vector{_CapturedRecord}
    _complete::Set{Any}
end
Base.propertynames(::Snapshot, private::Bool=false) =
    private ? fieldnames(Snapshot) : (:identity, :acquired)
function Base.getproperty(snap::Snapshot, key::Symbol)
    key in (:identity, :acquired) && return getfield(snap, key)
    throw(ArgumentError("snapshot storage is private; use collection accessors"))
end
Base.show(io::IO, snap::Snapshot) = print(io, "Snapshot(acquired=", snap.acquired, ")")

abstract type EntitySnapshot end
for name in (:SessionSnapshot, :WindowSnapshot, :PaneSnapshot, :ClientSnapshot, :WindowLink)
    @eval struct $name <: EntitySnapshot
        _snapshot::Snapshot
        _index::Int
    end
end

"""A physical pane viewed through one captured session/window link."""
struct PaneOccurrence
    pane::PaneSnapshot
    link::WindowLink

    function PaneOccurrence(pane::PaneSnapshot, link::WindowLink)
        snapshotof(pane) === snapshotof(link) && pane.window_id == link.window_id || throw(
            ArgumentError("pane occurrence must use its own snapshot and window link"),
        )
        new(pane, link)
    end
end

"""
    Selection(items; snapshot=nothing)

Read-only, ordered membership copied from `items`. Filtering preserves its
element type, order, duplicates and snapshot provenance. A small selection
may retain its entire snapshot. `collect`, `map` and `similar` return ordinary
mutable arrays. Elements supplied by callers are not recursively frozen.
"""
struct Selection{T} <: AbstractVector{T}
    _items::Vector{T}
    _snapshot::Union{Nothing,Snapshot}

    function Selection{T}(
        items::AbstractVector{T},
        snapshot::Union{Nothing,Snapshot},
    ) where {T}
        for item in items
            if snapshot !== nothing && item isa Union{EntitySnapshot,PaneOccurrence}
                snapshotof(item) === snapshot ||
                    throw(ArgumentError("selection contains another snapshot"))
            end
        end
        new{T}(collect(items), snapshot)
    end
end
function Selection(
    items::AbstractVector{T};
    snapshot::Union{Nothing,Snapshot}=nothing,
) where {T}
    Selection{T}(items, snapshot)
end
Base.IndexStyle(::Type{<:Selection}) = IndexLinear()
Base.size(xs::Selection) = size(getfield(xs, :_items))
Base.getindex(xs::Selection, i::Int) = getfield(xs, :_items)[i]
Base.similar(::Selection, ::Type{T}, dims::Dims) where {T} = Array{T}(undef, dims)
function Base.filter(predicate, xs::Selection{T}) where {T}
    items = T[]
    for item in xs
        predicate(item) && push!(items, item)
    end
    Selection{T}(items, snapshotof(xs))
end

"""Return captured provenance without acquiring or refreshing data."""
snapshotof(xs::Selection) = getfield(xs, :_snapshot)
snapshotof(x::EntitySnapshot) = getfield(x, :_snapshot)
snapshotof(x::PaneOccurrence) = snapshotof(x.pane)

_kind(::SessionSnapshot) = :session
_kind(::WindowSnapshot) = :window
_kind(::PaneSnapshot) = :pane
_kind(::ClientSnapshot) = :client
_kind(::WindowLink) = :windowlink
_storage(snap::Snapshot, kind::Symbol) = getfield(snap, Symbol("_", kind, "s"))
_record(x::EntitySnapshot) = _storage(snapshotof(x), _kind(x))[getfield(x, :_index)]
_identifier(record::_CapturedRecord) = record.fields.id

function _captured(x::EntitySnapshot, key::Symbol)
    fields = _record(x).fields
    haskey(fields, key) && return getproperty(fields, key)
    id = haskey(fields, :id) ? string(fields.id) : nothing
    throw(SnapshotCoverageError(_kind(x), id, key))
end
function _lookup(snap::Snapshot, kind::Symbol, id, View)
    idx = findfirst(r -> _identifier(r) == id, _storage(snap, kind))
    idx === nothing && throw(InconsistentSnapshot("missing $(kind) $(repr(string(id)))"))
    View(snap, idx)
end

for (View, Ref) in (
    (SessionSnapshot, SessionRef),
    (WindowSnapshot, WindowRef),
    (PaneSnapshot, PaneRef),
    (ClientSnapshot, ClientRef),
)
    @eval function Base.getproperty(x::$View, key::Symbol)
        key === :ref && return $Ref(snapshotof(x).identity, _captured(x, :id))
        key === :window && x isa PaneSnapshot && return window(x)
        key === :session && x isa ClientSnapshot && return session(x)
        key === :panes && x isa WindowSnapshot && return panes(x)
        key === :windows && x isa SessionSnapshot && return windows(x)
        key === :windowlinks &&
            x isa Union{SessionSnapshot,WindowSnapshot} &&
            return windowlinks(x)
        _captured(x, key)
    end
end
function Base.getproperty(link::WindowLink, key::Symbol)
    key === :window && return window(link)
    key === :session && return session(link)
    _captured(link, key)
end
function Base.propertynames(x::EntitySnapshot, private::Bool=false)
    private && return fieldnames(typeof(x))
    fields = keys(_record(x).fields)
    relations =
        x isa PaneSnapshot ? (:ref, :window) :
        x isa ClientSnapshot ? (:ref, :session) :
        x isa WindowSnapshot ? (:ref, :panes, :windowlinks) :
        x isa SessionSnapshot ? (:ref, :windows, :windowlinks) : (:session, :window)
    (fields..., relations...)
end
function Base.show(io::IO, x::EntitySnapshot)
    print(io, nameof(typeof(x)), '(')
    fields = _record(x).fields
    if haskey(fields, :id)
        show(io, fields.id)
    else
        print(io, fields.session_id, ", ", fields.index, ", ", fields.window_id)
    end
    print(io, ')')
end
entitykey(x::EntitySnapshot) = entitykey(x.ref)
entitykey(x::WindowLink) = entitykey(window(x))
entitykey(x::PaneOccurrence) = entitykey(x.pane)
occurrencekey(x::PaneOccurrence) =
    (snapshotof(x).identity, x.link.session_id, x.link.index, x.pane.id)

hascoverage(snap::Snapshot, key) = key in getfield(snap, :_complete)
function _require_coverage(snap::Snapshot, key::Symbol)
    hascoverage(snap, key) || throw(SnapshotCoverageError(:snapshot, nothing, key))
end
function _require_coverage(snap::Snapshot, key::Tuple)
    hascoverage(snap, key) || throw(SnapshotCoverageError(key[1], string(key[2]), key[3]))
end

for (accessor, View) in (
    (:sessions, SessionSnapshot),
    (:windows, WindowSnapshot),
    (:panes, PaneSnapshot),
    (:clients, ClientSnapshot),
    (:windowlinks, WindowLink),
)
    @eval function $accessor(snap::Snapshot)
        _require_coverage(snap, $(QuoteNode(accessor)))
        rows = getfield(snap, $(QuoteNode(Symbol("_", accessor))))
        Selection{$View}([$View(snap, i) for i in eachindex(rows)], snap)
    end
end

"""
    sessions(snapshot::Snapshot)

Return the sessions in `snapshot` as a [`Selection`](@ref) of `SessionSnapshot`
values. This reads the capture and never contacts tmux. Raises
[`SnapshotCoverageError`](@ref) when the capture does not include sessions.
"""
sessions(snapshot::Snapshot)

"""
    windows(snapshot::Snapshot)

Return the physical windows in `snapshot` as a [`Selection`](@ref) of
`WindowSnapshot` values. A window linked into several sessions appears once;
[`windowlinks`](@ref) lists each link. This reads the capture and never
contacts tmux. Raises [`SnapshotCoverageError`](@ref) when the capture does not
include windows.
"""
windows(snapshot::Snapshot)

"""
    panes(snapshot::Snapshot)

Return the physical panes in `snapshot` as a [`Selection`](@ref) of
`PaneSnapshot` values. A pane in a window linked into several sessions appears
once; [`paneoccurrences`](@ref) lists each appearance. This reads the capture
and never contacts tmux. Raises [`SnapshotCoverageError`](@ref) when the
capture does not include panes.
"""
panes(snapshot::Snapshot)

"""
    clients(snapshot::Snapshot)

Return the attached clients in `snapshot` as a [`Selection`](@ref) of
`ClientSnapshot` values. Transient unattached command clients are not
captured. This reads the capture and never contacts tmux. Raises
[`SnapshotCoverageError`](@ref) when the capture does not include clients.
"""
clients(snapshot::Snapshot)

"""
    windowlinks(snapshot::Snapshot)

Return every session-to-window link in `snapshot` as a [`Selection`](@ref) of
`WindowLink` values, one for each window index in each session. This reads the
capture and never contacts tmux. Raises [`SnapshotCoverageError`](@ref) when
the capture does not include links.
"""
windowlinks(snapshot::Snapshot)

"""
    window(pane::PaneSnapshot)

Return the `WindowSnapshot` that holds `pane`. This reads the capture and never
contacts tmux. Raises [`SnapshotCoverageError`](@ref) when the capture does not
include the pane's window.
"""
function window(pane::PaneSnapshot)
    _lookup(snapshotof(pane), :window, _captured(pane, :window_id), WindowSnapshot)
end

"""
    window(link::WindowLink)

Return the `WindowSnapshot` that `link` points to. This reads the capture and
never contacts tmux.
"""
window(link::WindowLink) =
    _lookup(snapshotof(link), :window, link.window_id, WindowSnapshot)

"""
    session(link::WindowLink)

Return the `SessionSnapshot` that holds `link`. This reads the capture and
never contacts tmux.
"""
session(link::WindowLink) =
    _lookup(snapshotof(link), :session, link.session_id, SessionSnapshot)

"""
    session(client::ClientSnapshot)

Return the `SessionSnapshot` that `client` is attached to, or `nothing` when
the client reports no session. This reads the capture and never contacts tmux.
Raises [`SnapshotCoverageError`](@ref) when the capture does not include the
client's session.
"""
function session(client::ClientSnapshot)
    id = _captured(client, :session_id)
    id === nothing ? nothing : _lookup(snapshotof(client), :session, id, SessionSnapshot)
end

"""
    panes(window::WindowSnapshot)

Return the panes of `window` as a [`Selection`](@ref) of `PaneSnapshot`
values. This reads the capture and never contacts tmux. Raises
[`SnapshotCoverageError`](@ref) when the capture does not include the window's
panes.
"""
function panes(win::WindowSnapshot)
    snap = snapshotof(win)
    _require_coverage(snap, (:window, win.id, :panes))
    items = PaneSnapshot[]
    for (i, row) in enumerate(getfield(snap, :_panes))
        haskey(row.fields, :window_id) ||
            throw(SnapshotCoverageError(:pane, string(row.fields.id), :window_id))
        row.fields.window_id == win.id && push!(items, PaneSnapshot(snap, i))
    end
    Selection{PaneSnapshot}(items, snap)
end

"""
    windowlinks(session::SessionSnapshot)
    windowlinks(window::WindowSnapshot)

Return the window links of a session, or of a window, as a [`Selection`](@ref)
of `WindowLink` values. A session has one link for each window index it holds;
a window has one for each session that holds it. This reads the capture and
never contacts tmux. Raises [`SnapshotCoverageError`](@ref) when the capture
does not include those links.
"""
function windowlinks(parent::Union{SessionSnapshot,WindowSnapshot})
    snap = snapshotof(parent)
    _require_coverage(snap, (_kind(parent), parent.id, :windowlinks))
    key = parent isa SessionSnapshot ? :session_id : :window_id
    items = WindowLink[]
    for (i, row) in enumerate(getfield(snap, :_windowlinks))
        getproperty(row.fields, key) == parent.id && push!(items, WindowLink(snap, i))
    end
    Selection{WindowLink}(items, snap)
end

"""
    windows(session::SessionSnapshot)

Return the windows linked into `session` as a [`Selection`](@ref) of
`WindowSnapshot` values, each once. This reads the capture and never contacts
tmux. Raises [`SnapshotCoverageError`](@ref) when the capture does not include
the session's links.
"""
function windows(parent::SessionSnapshot)
    items, seen = WindowSnapshot[], Set{WindowID}()
    for link in windowlinks(parent)
        link.window_id in seen && continue
        push!(seen, link.window_id)
        push!(items, window(link))
    end
    Selection{WindowSnapshot}(items, snapshotof(parent))
end

"""
    paneoccurrences(snapshot::Snapshot)

Return a `PaneOccurrence` for each pane in each window link of `snapshot`, as a
[`Selection`](@ref). A pane in a window linked into several sessions appears
once for each link. This reads the capture and never contacts tmux. Raises
[`SnapshotCoverageError`](@ref) when the capture does not include occurrences.
"""
function paneoccurrences(snap::Snapshot)
    _require_coverage(snap, :paneoccurrences)
    items = PaneOccurrence[]
    for link in windowlinks(snap), pane in panes(window(link))
        push!(items, PaneOccurrence(pane, link))
    end
    Selection{PaneOccurrence}(items, snap)
end

_freeze_value(x::Union{Nothing,Symbol,TmuxID,ClientID}) = x
function _freeze_value(x::Union{Integer,AbstractFloat})
    isbitstype(typeof(x)) ||
        throw(ArgumentError("captured numbers must have immutable scalar storage"))
    x
end
_freeze_value(x::AbstractString) = String(x)
_freeze_value(x::Tuple) = map(_freeze_value, x)
_freeze_value(x::AbstractVector) = Tuple(_freeze_value(v) for v in x)
_freeze_value(x::NamedTuple) = map(_freeze_value, x)
_freeze_value(x) = throw(ArgumentError("unsupported captured value type $(typeof(x))"))

function _records(kind::Symbol, rows)
    records, seen = _CapturedRecord[], Dict{Any,NamedTuple}()
    Id =
        kind === :session ? SessionID :
        kind === :window ? WindowID :
        kind === :pane ? PaneID : kind === :client ? ClientID : nothing
    for row in rows
        row isa NamedTuple || throw(ArgumentError("snapshot rows must be named tuples"))
        fields = _freeze_value(row)
        try
            if Id !== nothing
                haskey(fields, :id) || throw(ArgumentError("$(kind) row needs an id"))
                fields = merge(fields, (id=Id(fields.id),))
            end
            if haskey(fields, :window_id)
                fields = merge(fields, (window_id=WindowID(fields.window_id),))
            end
            if haskey(fields, :session_id) && fields.session_id !== nothing
                fields = merge(fields, (session_id=SessionID(fields.session_id),))
            end
            if kind === :windowlink
                all(k -> haskey(fields, k), (:session_id, :window_id, :index)) || throw(
                    ArgumentError("window link needs session_id, window_id and index"),
                )
                fields.index isa Integer && !(fields.index isa Bool) && fields.index >= 0 ||
                    throw(ArgumentError("window link index must be a nonnegative integer"))
            end
        catch e
            e isa ArgumentError || e isa MethodError || rethrow()
            throw(ArgumentError("invalid $(kind) row: $(sprint(showerror, e))"))
        end
        key = Id === nothing ? (fields.session_id, fields.index) : fields.id
        if haskey(seen, key)
            kind !== :windowlink && isequal(seen[key], fields) && continue
            throw(InconsistentSnapshot("conflicting or duplicate $(kind) identity"))
        end
        seen[key] = fields
        push!(records, _CapturedRecord(fields))
    end
    records
end

const _SNAPSHOT_SOURCES =
    (:sessions, :windows, :panes, :clients, :windowlinks, :paneoccurrences)

"""
    _build_snapshot(identity; sessions=(), windows=(), panes=(), clients=(),
                    windowlinks=(), acquired, complete=())

Internal acquisition boundary. Copy named-tuple rows and validate captured
edges. Numeric `id`, `session_id` and `window_id` values are tmux ID strings
or typed IDs; client IDs include their observed incarnation. Missing fields
are uncaptured, while explicit `nothing` is captured absence.

Completeness keys are root symbols such as `:panes`, or parent keys such as
`(:window, WindowID("@1"), :panes)` and
`(:session, SessionID("\$0"), :windowlinks)`. Root completeness does not imply
parent completeness. `complete=true` asserts all roots and captured parent
memberships are complete. `acquired` contains process-relative monotonic
seconds. No transport is retained and no I/O is performed.
"""
function _build_snapshot(
    identity::ServerIdentity;
    sessions=(),
    windows=(),
    panes=(),
    clients=(),
    windowlinks=(),
    acquired,
    complete=(),
)
    length(acquired) == 2 || throw(ArgumentError("acquired must contain start and end"))
    start, stop = Float64.(acquired)
    isfinite(start) && isfinite(stop) && start <= stop ||
        throw(ArgumentError("acquisition interval must be finite and ordered"))
    ss, ws, ps, cs, ls = _records(:session, sessions),
    _records(:window, windows),
    _records(:pane, panes),
    _records(:client, clients),
    _records(:windowlink, windowlinks)
    session_ids, window_ids =
        Set(_identifier(r) for r in ss), Set(_identifier(r) for r in ws)
    for row in vcat(ps, ls)
        haskey(row.fields, :window_id) || continue
        row.fields.window_id in window_ids ||
            throw(InconsistentSnapshot("captured window edge has no record"))
    end
    for row in vcat(cs, ls)
        haskey(row.fields, :session_id) || continue
        id = row.fields.session_id
        id === nothing && row in cs && continue
        id in session_ids ||
            throw(InconsistentSnapshot("captured session edge has no record"))
    end
    coverage = Set{Any}()
    if complete === true
        union!(coverage, _SNAPSHOT_SOURCES)
        for id in session_ids
            push!(coverage, (:session, id, :windowlinks))
        end
        for id in window_ids
            push!(coverage, (:window, id, :panes), (:window, id, :windowlinks))
        end
    else
        for key in complete
            valid =
                key isa Symbol ? key in _SNAPSHOT_SOURCES :
                key isa Tuple &&
                length(key) == 3 &&
                (
                    (
                        key[1] === :session &&
                        key[2] in session_ids &&
                        key[3] === :windowlinks
                    ) || (
                        key[1] === :window &&
                        key[2] in window_ids &&
                        key[3] in (:panes, :windowlinks)
                    )
                )
            valid || throw(ArgumentError("invalid snapshot completeness key $(repr(key))"))
            push!(coverage, key)
        end
    end
    Snapshot(identity, (start, stop), ss, ws, ps, cs, ls, coverage)
end

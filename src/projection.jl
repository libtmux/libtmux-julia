"""
Read-only scalar rows over one captured selection. Construct with
`project_rows`. Column names and types survive empty selections. Retaining
this projection retains its source snapshot. No operation refreshes data.
"""
struct RowProjection{R<:NamedTuple,S<:Selection} <: AbstractVector{R}
    _selection::S
end
Base.size(rows::RowProjection) = size(getfield(rows, :_selection))
Base.IndexStyle(::Type{<:RowProjection}) = IndexLinear()
Base.similar(::RowProjection, ::Type{T}, dims::Dims) where {T} = Array{T}(undef, dims)
function Base.getindex(rows::RowProjection{R}, index::Int) where {R}
    item = getfield(rows, :_selection)[index]
    R(map(name -> getproperty(item, name), fieldnames(R)))
end
snapshotof(rows::RowProjection) = snapshotof(getfield(rows, :_selection))
Base.propertynames(::RowProjection, private::Bool=false) =
    private ? (:_selection,) : (:columns,)
function Base.getproperty(rows::RowProjection{R}, name::Symbol) where {R}
    name === :columns && return fieldnames(R)
    throw(ArgumentError("projection storage is private; index or iterate its rows"))
end

function _projection_type(spec)
    Type =
        spec.type === :String ? String :
        spec.type === :Bool ? Bool :
        spec.type === :Integer ? Integer :
        spec.type === :PaneID ? PaneID :
        spec.type === :WindowID ? WindowID : spec.type === :SessionID ? SessionID : ClientID
    spec.nullable ? Union{Nothing,Type} : Type
end

"""
    project_rows(selection; columns) -> RowProjection

Project explicit scalar catalog fields into ordinary named tuples, preserving
row order and multiplicity. All requested fields are checked for coverage
before returning. Relations require an explicit caller projection instead.
IDs retain their typed identity; integers are not narrowed. Captured absence
remains `nothing`. No Tables or DataFrames dependency is required.

After `using Tables`, the optional extension exposes this same projection as
a Tables.jl row source with its declared schema, including when it is empty.
"""
function project_rows(selection::Selection{T}; columns) where {T}
    names = Tuple(columns)
    isempty(names) && throw(ArgumentError("select at least one scalar column"))
    all(name -> name isa Symbol, names) ||
        throw(ArgumentError("column names must be Symbols"))
    length(unique(names)) == length(names) ||
        throw(ArgumentError("duplicate projection column"))
    entity = _observation_entity(T)
    specs = map(names) do name
        spec = get(_CRITERIA_FIELDS, (entity, name), nothing)
        spec !== nothing && spec.relation === :scalar ||
            throw(ArgumentError("column $name is not a scalar field for $entity"))
        spec
    end
    for item in selection
        for (name, spec) in zip(names, specs)
            _literal_valid(spec, getproperty(item, name)) ||
                throw(ArgumentError("captured $name has an invalid scalar type"))
        end
    end
    types = map(_projection_type, specs)
    Row = NamedTuple{names,Tuple{types...}}
    RowProjection{Row,typeof(selection)}(selection)
end

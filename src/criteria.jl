"""A validated local predicate; portable criteria never contain caller callbacks."""
abstract type Criterion <: Function end
struct _Unconstrained end
const _UNCONSTRAINED = _Unconstrained()

function _criterion_operand(value)
    value isa AbstractString && return String(value)
    value isa Union{Nothing,Bool,TmuxID,ClientID} && return value
    value isa Real && isbitstype(typeof(value)) && isfinite(value) && return value
    throw(
        ArgumentError(
            "filter operands must be immutable strings, IDs, finite numbers, Boolean or nothing",
        ),
    )
end
function _numeric_operand(value)
    value isa Real && !(value isa Bool) && isbitstype(typeof(value)) && isfinite(value) ||
        throw(ArgumentError("numeric filter operands must be finite numbers, not Boolean"))
    value
end

"""Named local filter operators. Import as `import LibTmux.Filters as F`."""
module Filters
import ..LibTmux: Criterion, _criterion_operand, _numeric_operand
import ..LibTmux

abstract type Operator end
for name in (:EqualTo, :NotEqualTo)
    @eval struct $name <: Operator
        value::Any
        $name(value) = new(_criterion_operand(value))
    end
end

"""Membership in a copied, immutable tuple of scalar operands."""
struct OneOf <: Operator
    values::Tuple
    OneOf(values) = new(Tuple(_criterion_operand(v) for v in values))
end

for name in (:Contains, :StartsWith, :EndsWith)
    @eval struct $name <: Operator
        value::String
        case::Symbol
        function $name(value::AbstractString; case::Symbol=:sensitive)
            case in (:sensitive, :ascii_insensitive) ||
                throw(ArgumentError("case must be :sensitive or :ascii_insensitive"))
            new(String(value), case)
        end
    end
end

for name in (:AtLeast, :AtMost, :GreaterThan, :LessThan)
    @eval struct $name <: Operator
        value::Real
        $name(value) = new(_numeric_operand(value))
    end
end

for name in (:AllOf, :AnyOf)
    @eval struct $name <: Criterion
        criteria::Tuple{Vararg{Criterion}}
        function $name(criteria::Criterion...)
            LibTmux._common_entity(criteria)
            new(criteria)
        end
    end
end

struct Not <: Criterion
    criterion::Criterion
end

abstract type Related <: Operator end
for name in (:AnyRelated, :AllRelated, :NoRelated)
    @eval struct $name <: Related
        criterion::Criterion
    end
end
end

struct _CriteriaField
    type::Symbol
    nullable::Bool
    relation::Symbol
    target::Symbol
end
struct _FieldClause
    field::Symbol
    constraint::Union{Filters.Operator,Criterion}
end

function _common_entity(criteria)
    selected = :any
    for criterion in criteria
        kind = _criterion_entity(criterion)
        kind === :any && continue
        selected in (:any, kind) ||
            throw(ArgumentError("cannot combine criteria for different entities"))
        selected = kind
    end
    selected
end
_criterion_entity(q::Union{Filters.AllOf,Filters.AnyOf}) = _common_entity(q.criteria)
_criterion_entity(q::Filters.Not) = _criterion_entity(q.criterion)
_observation_entity(::Type) = :unknown

function _literal_valid(spec::_CriteriaField, value)
    value === nothing && return spec.nullable
    spec.type === :String && return value isa String
    spec.type === :Bool && return value isa Bool
    spec.type === :Integer && return value isa Integer && !(value isa Bool)
    spec.type === :PaneID && return value isa PaneID
    spec.type === :WindowID && return value isa WindowID
    spec.type === :SessionID && return value isa SessionID
    spec.type === :ClientID && return value isa ClientID
    false
end

function _validate_constraint(entity, field, spec, op)
    valid = if spec.relation === :one
        if op isa Criterion
            _criterion_entity(op) in (:any, spec.target)
        else
            spec.nullable &&
                op isa Union{Filters.EqualTo,Filters.NotEqualTo} &&
                op.value === nothing
        end
    elseif spec.relation === :many
        op isa Filters.Related && _criterion_entity(op.criterion) in (:any, spec.target)
    elseif op isa Union{Filters.EqualTo,Filters.NotEqualTo}
        _literal_valid(spec, op.value)
    elseif op isa Filters.OneOf
        all(value -> _literal_valid(spec, value), op.values)
    elseif op isa Union{Filters.Contains,Filters.StartsWith,Filters.EndsWith}
        spec.type === :String
    elseif op isa Union{Filters.AtLeast,Filters.AtMost,Filters.GreaterThan,Filters.LessThan}
        spec.type === :Integer
    else
        false
    end
    valid || throw(
        ArgumentError(
            "$(entity).$(field) accepts $(spec.type) $(spec.relation) constraints; received $(typeof(op))",
        ),
    )
    op
end

function _where_clauses(entity, fields)
    clauses = _FieldClause[]
    for (field, value) in pairs(fields)
        value === _UNCONSTRAINED && continue
        spec = _CRITERIA_FIELDS[(entity, field)]
        op = value isa Union{Filters.Operator,Criterion} ? value : Filters.EqualTo(value)
        push!(clauses, _FieldClause(field, _validate_constraint(entity, field, spec, op)))
    end
    Tuple(clauses)
end

include("criteria_generated.jl")

function _check_entity(q::Criterion, Type)
    expected, observed = _criterion_entity(q), _observation_entity(Type)
    observed !== :unknown && expected in (:any, observed) ||
        throw(ArgumentError("criterion for $(expected) cannot evaluate $(Type)"))
end

function _preflight(q::Criterion, item)
    _check_entity(q, typeof(item))
    for clause in getfield(q, :_clauses)
        value = getproperty(item, clause.field)
        spec = _CRITERIA_FIELDS[(_criterion_entity(q), clause.field)]
        if spec.relation === :scalar
            _literal_valid(spec, value) || throw(
                ArgumentError(
                    "captured $(clause.field) has invalid $(typeof(value)) value",
                ),
            )
        elseif clause.constraint isa Filters.Related
            for related in value
                _preflight(clause.constraint.criterion, related)
            end
        elseif clause.constraint isa Criterion && value !== nothing
            _preflight(clause.constraint, value)
        end
    end
    nothing
end
function _preflight(q::Union{Filters.AllOf,Filters.AnyOf}, item)
    _check_entity(q, typeof(item))
    for child in q.criteria
        _preflight(child, item)
    end
    nothing
end
_preflight(q::Filters.Not, item) = _preflight(q.criterion, item)

function _ascii_fold(text::String)
    bytes = Vector{UInt8}(codeunits(text))
    for i in eachindex(bytes)
        UInt8('A') <= bytes[i] <= UInt8('Z') && (bytes[i] += 0x20)
    end
    String(bytes)
end
_matches(op::Filters.EqualTo, value) = value == op.value
_matches(op::Filters.NotEqualTo, value) = value != op.value
_matches(op::Filters.OneOf, value) = any(x -> value == x, op.values)
_matches(op::Filters.AtLeast, value) = value !== nothing && value >= op.value
_matches(op::Filters.AtMost, value) = value !== nothing && value <= op.value
_matches(op::Filters.GreaterThan, value) = value !== nothing && value > op.value
_matches(op::Filters.LessThan, value) = value !== nothing && value < op.value
function _matches(op::Union{Filters.Contains,Filters.StartsWith,Filters.EndsWith}, value)
    value === nothing && return false
    haystack, needle =
        op.case === :sensitive ? (value, op.value) :
        (_ascii_fold(value), _ascii_fold(op.value))
    op isa Filters.Contains && return occursin(needle, haystack)
    op isa Filters.StartsWith && return startswith(haystack, needle)
    endswith(haystack, needle)
end
_matches(q::Criterion, value) = value !== nothing && _evaluate(q, value)
_matches(q::Filters.AnyRelated, values) =
    any(value -> _evaluate(q.criterion, value), values)
_matches(q::Filters.AllRelated, values) =
    all(value -> _evaluate(q.criterion, value), values)
_matches(q::Filters.NoRelated, values) =
    !any(value -> _evaluate(q.criterion, value), values)
_evaluate(q::Criterion, item) = all(
    clause -> _matches(clause.constraint, getproperty(item, clause.field)),
    getfield(q, :_clauses),
)
_evaluate(q::Filters.AllOf, item) = all(child -> _evaluate(child, item), q.criteria)
_evaluate(q::Filters.AnyOf, item) = any(child -> _evaluate(child, item), q.criteria)
_evaluate(q::Filters.Not, item) = !_evaluate(q.criterion, item)

function (q::Criterion)(item)::Bool
    _preflight(q, item)
    _evaluate(q, item)
end

function Base.filter(q::Criterion, xs::Selection{T}) where {T}
    _check_entity(q, T)
    for item in xs
        _preflight(q, item)
    end
    items = T[]
    for item in xs
        _evaluate(q, item) && push!(items, item)
    end
    Selection{T}(items, snapshotof(xs))
end

"An exact-cardinality criterion matched no items in its source."
struct NoMatchError <: LibTmuxError
    entity::Symbol
end
"An exact-cardinality criterion matched at least two items; the remaining source may not be counted."
struct MultipleMatchesError <: LibTmuxError
    entity::Symbol
end
Base.showerror(io::IO, e::NoMatchError) =
    print(io, "expected one ", e.entity, " match; found none")
Base.showerror(io::IO, e::MultipleMatchesError) =
    print(io, "expected one ", e.entity, " match; found at least two")

"""
    onlymatch(q, items)

Return exactly one match, stopping after a second match. Selection criteria
preflight coverage first. This function does not acquire or refresh data;
ordinary caller predicates retain their own effects.
"""
function onlymatch(q, items)
    kind = q isa Criterion ? _criterion_entity(q) : :item
    if q isa Criterion && items isa Selection
        _check_entity(q, eltype(items))
        for item in items
            _preflight(q, item)
        end
    end
    matched, result = false, nothing
    for item in items
        matches = q isa Criterion && items isa Selection ? _evaluate(q, item) : q(item)
        matches || continue
        matched && throw(MultipleMatchesError(kind))
        matched, result = true, item
    end
    matched || throw(NoMatchError(kind))
    result
end

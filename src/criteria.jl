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

const _BuiltinCriterion = Union{
    ClientWhere,
    PaneWhere,
    SessionWhere,
    WindowWhere,
    WindowLinkWhere,
    Filters.AllOf,
    Filters.AnyOf,
    Filters.Not,
}
const _CriterionSnapshot =
    Union{SessionSnapshot,WindowSnapshot,PaneSnapshot,ClientSnapshot,WindowLink}
const _CriterionMemoKey = Tuple{Symbol,Int,Criterion}
const _CriterionPreflightMemo = IdDict{Snapshot,Dict{_CriterionMemoKey,Nothing}}
const _CriterionResultMemo = IdDict{Snapshot,Union{Nothing,Dict{_CriterionMemoKey,Bool}}}
mutable struct _CriterionTraversal{C}
    checkpoint::C
    visits::Int
    memo::Union{Nothing,_CriterionPreflightMemo}
    results::Union{Nothing,_CriterionResultMemo}
end

_criterion_checkpoint!(::Nothing; force::Bool=false) = nothing
function _criterion_checkpoint!(control::_CriterionTraversal; force::Bool=false)
    control.checkpoint === nothing && return nothing
    control.visits += 1
    if force || control.visits >= 128
        control.visits = 0
        yield()
        control.checkpoint()
    end
    nothing
end

function _criterion_has_relations(q::Criterion)
    for clause in getfield(q, :_clauses)
        _CRITERIA_FIELDS[(_criterion_entity(q), clause.field)].relation !== :scalar &&
            return true
    end
    false
end
_criterion_has_relations(q::Union{Filters.AllOf,Filters.AnyOf}) =
    any(_criterion_has_relations, q.criteria)
_criterion_has_relations(q::Filters.Not) = _criterion_has_relations(q.criterion)
_criterion_memo_safe(::Criterion) = false
function _criterion_memo_safe(
    q::Union{ClientWhere,PaneWhere,SessionWhere,WindowWhere,WindowLinkWhere},
)
    all(getfield(q, :_clauses)) do clause
        constraint = clause.constraint
        if constraint isa Filters.Related
            constraint isa Union{Filters.AnyRelated,Filters.AllRelated,Filters.NoRelated} ||
                return false
            return _criterion_memo_safe(constraint.criterion)
        end
        constraint isa Criterion && return _criterion_memo_safe(constraint)
        true
    end
end
_criterion_memo_safe(q::Union{Filters.AllOf,Filters.AnyOf}) =
    all(_criterion_memo_safe, q.criteria)
_criterion_memo_safe(q::Filters.Not) = _criterion_memo_safe(q.criterion)
function _criterion_memo(q, xs)
    eltype(xs) <: _CriterionSnapshot &&
    _criterion_memo_safe(q) &&
    _criterion_has_relations(q) ? _CriterionPreflightMemo() : nothing
end

_criterion_builtin_operand(value) =
    !(value isa Real) || value isa Union{Bool,Base.BitInteger,Float16,Float32,Float64}
_criterion_builtin_operator(
    op::Union{
        Filters.EqualTo,
        Filters.NotEqualTo,
        Filters.AtLeast,
        Filters.AtMost,
        Filters.GreaterThan,
        Filters.LessThan,
    },
) = _criterion_builtin_operand(op.value)
_criterion_builtin_operator(op::Filters.OneOf) = all(_criterion_builtin_operand, op.values)
_criterion_builtin_operator(::Union{Filters.Contains,Filters.StartsWith,Filters.EndsWith}) =
    true
_criterion_builtin_operator(::Filters.Operator) = false
function _criterion_builtin_operator(
    op::Union{Filters.AnyRelated,Filters.AllRelated,Filters.NoRelated},
)
    _criterion_results_safe(op.criterion)
end
_criterion_builtin_operator(q::Criterion) = _criterion_results_safe(q)
function _criterion_results_safe(
    q::Union{ClientWhere,PaneWhere,SessionWhere,WindowWhere,WindowLinkWhere},
)
    all(clause -> _criterion_builtin_operator(clause.constraint), getfield(q, :_clauses))
end
_criterion_results_safe(q::Union{Filters.AllOf,Filters.AnyOf}) =
    all(_criterion_results_safe, q.criteria)
_criterion_results_safe(q::Filters.Not) = _criterion_results_safe(q.criterion)
_criterion_results_safe(::Criterion) = false
function _criterion_builtin_numbers(::Type{Snapshot{SI,WI,PI,CI,LI}}) where {SI,WI,PI,CI,LI}
    for schema in (SI, WI, PI, CI, LI), index = 1:fieldcount(schema)
        fieldtype(schema, index) <: Base.BitInteger || return false
    end
    true
end
_criterion_results(q, memo) =
    memo === nothing || !_criterion_results_safe(q) ? nothing : _CriterionResultMemo()

_preflight(q::Criterion, item) = _preflight_body(q, item, nothing)
function _preflight(q::Criterion, item, control)
    _criterion_checkpoint!(control)
    q isa _BuiltinCriterion || return _preflight(q, item)
    if control !== nothing && control.memo !== nothing && item isa _CriterionSnapshot
        captured = snapshotof(item)
        known = get!(control.memo, captured) do
            Dict{Tuple{Symbol,Int,Criterion},Nothing}()
        end
        key = (_kind(item), getfield(item, :_index), q)
        haskey(known, key) && return nothing
        _preflight_body(q, item, control)
        known[key] = nothing
        return nothing
    end
    _preflight_body(q, item, control)
end

function _preflight_body(q::Criterion, item, control)
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
                _preflight(clause.constraint.criterion, related, control)
            end
        elseif clause.constraint isa Criterion && value !== nothing
            _preflight(clause.constraint, value, control)
        end
    end
    nothing
end
function _preflight_body(q::Union{Filters.AllOf,Filters.AnyOf}, item, control)
    _check_entity(q, typeof(item))
    for child in q.criteria
        _preflight(child, item, control)
    end
    nothing
end
_preflight_body(q::Filters.Not, item, control) = _preflight(q.criterion, item, control)

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
# Ordinary native queries retain their original matcher. The MCP checkpoint
# path bounds work on captured strings; wire operands are limited separately.
function _ascii_fold(text::String, control::_CriterionTraversal)
    bytes = Vector{UInt8}(codeunits(text))
    for start = 1:4096:length(bytes)
        for index = start:min(start+4095, length(bytes))
            UInt8('A') <= bytes[index] <= UInt8('Z') && (bytes[index] += 0x20)
        end
        _criterion_checkpoint!(control; force=true)
    end
    String(bytes)
end
function _contains_checkpointed(haystack::String, needle::String, control)
    # Base's String search differs from SubString search for malformed UTF-8.
    isvalid(needle) || return occursin(needle, haystack)
    isempty(needle) && return true
    length = ncodeunits(haystack)
    ncodeunits(needle) > length && return false
    start = firstindex(haystack)
    while start <= length
        edge = prevind(haystack, min(start + 32768, length + 1))
        next = nextind(haystack, edge)
        stop = prevind(haystack, min(next + ncodeunits(needle), length + 1))
        matched = occursin(needle, SubString(haystack, start, stop))
        _criterion_checkpoint!(control; force=true)
        matched && return true
        start = next
    end
    false
end
function _matches(
    op::Union{Filters.Contains,Filters.StartsWith,Filters.EndsWith},
    value,
    control,
)
    (control === nothing || control.checkpoint === nothing) && return _matches(op, value)
    value === nothing && return false
    value isa String || return _matches(op, value)
    haystack, needle =
        op.case === :sensitive ? (value, op.value) :
        (_ascii_fold(value, control), _ascii_fold(op.value, control))
    op isa Filters.Contains && return _contains_checkpointed(haystack, needle, control)
    matched =
        op isa Filters.StartsWith ? startswith(haystack, needle) :
        endswith(haystack, needle)
    _criterion_checkpoint!(control; force=true)
    matched
end
_matches(op::Filters.Operator, value, control) = _matches(op, value)
_matches(q::Criterion, value) = value !== nothing && _evaluate(q, value)
_matches(q::Filters.AnyRelated, values) =
    any(value -> _evaluate(q.criterion, value), values)
_matches(q::Filters.AllRelated, values) =
    all(value -> _evaluate(q.criterion, value), values)
_matches(q::Filters.NoRelated, values) =
    !any(value -> _evaluate(q.criterion, value), values)
_matches(q::Criterion, value, control) =
    q isa _BuiltinCriterion ? value !== nothing && _evaluate(q, value, control) :
    _matches(q, value)
_matches(q::Filters.AnyRelated, values, control) =
    any(value -> _evaluate(q.criterion, value, control), values)
_matches(q::Filters.AllRelated, values, control) =
    all(value -> _evaluate(q.criterion, value, control), values)
_matches(q::Filters.NoRelated, values, control) =
    !any(value -> _evaluate(q.criterion, value, control), values)
_evaluate(q::Criterion, item) = _evaluate_body(q, item, nothing)
function _evaluate(q::Criterion, item, control)
    _criterion_checkpoint!(control)
    q isa _BuiltinCriterion || return _evaluate(q, item)
    if control !== nothing && control.results !== nothing && item isa _CriterionSnapshot
        known = get!(control.results, snapshotof(item)) do
            _criterion_builtin_numbers(typeof(snapshotof(item))) ?
            Dict{_CriterionMemoKey,Bool}() : nothing
        end
        if known !== nothing
            key = (_kind(item), getfield(item, :_index), q)
            haskey(known, key) && return known[key]
            result = _evaluate_body(q, item, control)
            known[key] = result
            return result
        end
    end
    _evaluate_body(q, item, control)
end
function _evaluate_body(q::Criterion, item, control)
    all(
        clause -> _matches(clause.constraint, getproperty(item, clause.field), control),
        getfield(q, :_clauses),
    )
end
function _evaluate_body(q::Filters.AllOf, item, control)
    all(child -> _evaluate(child, item, control), q.criteria)
end
function _evaluate_body(q::Filters.AnyOf, item, control)
    any(child -> _evaluate(child, item, control), q.criteria)
end
function _evaluate_body(q::Filters.Not, item, control)
    !_evaluate(q.criterion, item, control)
end

function (q::Criterion)(item)::Bool
    _preflight(q, item)
    _evaluate(q, item)
end

function _filter_where(q::Criterion, xs::Selection{T}, control) where {T}
    _criterion_checkpoint!(control; force=true)
    _check_entity(q, T)
    for item in xs
        _preflight(q, item, control)
    end
    items = T[]
    for item in xs
        _evaluate(q, item, control) && push!(items, item)
    end
    _criterion_checkpoint!(control; force=true)
    Selection{T}(items, snapshotof(xs))
end
function Base.filter(q::Criterion, xs::Selection)
    memo = _criterion_memo(q, xs)
    control =
        memo === nothing ? nothing :
        _CriterionTraversal{Nothing}(nothing, 0, memo, _criterion_results(q, memo))
    _filter_where(q, xs, control)
end
function _filter_where(q::Criterion, xs::Selection, checkpoint::Function)
    memo = _criterion_memo(q, xs)
    _filter_where(
        q,
        xs,
        _CriterionTraversal{Function}(checkpoint, 0, memo, _criterion_results(q, memo)),
    )
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

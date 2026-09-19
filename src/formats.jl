"""
    FormatField(name, T=String)

Describe one literal tmux format identifier with a `String`, `Int` or `Bool`
decoder. Names match `[a-z][a-z0-9_]*`; any such name is accepted, including
variables outside the snapshot field catalog. Construction does not prove that
the connected tmux supports the variable or supplies it in a given context.
Expressions, option names and command substitutions require `RawFormat`.
"""
struct FormatField{T}
    name::String

    function FormatField(name::AbstractString, ::Type{T}) where {T}
        T in (String, Int, Bool) ||
            throw(ArgumentError("format type must be String, Int or Bool"))
        text = _argument(name)
        occursin(r"\A[a-z][a-z0-9_]*\z", text) ||
            throw(ArgumentError("format field must match [a-z][a-z0-9_]*"))
        new{T}(text)
    end
end
FormatField(name::AbstractString) = FormatField(name, String)

"""
One explicit format observation. `:present` means a nonempty expansion, not a
version-support guarantee. Empty expansions have `availability=:unverified`:
tmux cannot distinguish an empty value from an unknown or unavailable variable.
`raw` always retains the decoded text. Empty strings retain `value=""`; numeric
and Boolean observations use `value=nothing` until their value is verified.
"""
struct FormatObservation{T}
    field::FormatField{T}
    raw::String
    value::Union{Nothing,T}
    availability::Symbol
end

"""A nonempty format value failed its requested decoder; command bytes remain in `result`."""
struct FormatValueError{R} <: LibTmuxError
    field::String
    expected::DataType
    raw::String
    result::R
end
Base.showerror(io::IO, error::FormatValueError) = print(
    io,
    "format ",
    error.field,
    " did not contain a valid ",
    error.expected,
    ": ",
    repr(error.raw),
)

function _format_target(target)
    target isa SessionRef && return string(target.id) * ":"
    target isa Union{WindowRef,PaneRef} && return string(target.id)
    throw(ArgumentError("format target must be a SessionRef, WindowRef or PaneRef"))
end

function _target_format_command(context, target, template; kwargs...)
    key = _format_target(target)
    predicate = target isa PaneRef ? "#{==:#{pane_id},$(target.id)}" : "#{pane_active}"
    # list-panes resolves its target strictly and filters before expansion.
    # display-message permits target failure, even with an exact numeric ID.
    _operation_command(
        context,
        "list-panes",
        "-t",
        key,
        "-f",
        predicate,
        "-F",
        template;
        kwargs...,
    )
end

function _format_observation(field::FormatField{T}, raw::String, result) where {T}
    if isempty(raw)
        value = T === String ? "" : nothing
        return FormatObservation{T}(field, raw, value, :unverified)
    end
    value = if T === String
        raw
    elseif T === Bool
        raw == "1" ? true : raw == "0" ? false : nothing
    else
        occursin(r"\A[+-]?[0-9]+\z", raw) ? tryparse(Int, raw) : nothing
    end
    value === nothing && throw(FormatValueError(field.name, T, raw, result))
    FormatObservation{T}(field, raw, value, :present)
end

function _read_formats(server, target, fields; max_output_bytes::Int=8 * 1024^2, kwargs...)
    _format_target(target)
    1 <= length(fields) <= 256 ||
        throw(ArgumentError("read between 1 and 256 format fields"))
    max_output_bytes >= 0 || throw(ArgumentError("max_output_bytes cannot be negative"))
    fields = collect(fields)
    template = _format_template(String[field.name for field in fields])
    context = _target_context(server, target; kwargs...)
    result = _target_format_command(context, target, template; max_output_bytes)
    rows = _decode_format_rows(result.stdout, length(fields))
    length(rows) == 1 || throw(ArgumentError("expected one format observation row"))
    raw = only(rows)
    observed = FormatObservation[
        _format_observation(field, value, result) for (field, value) in zip(fields, raw)
    ]
    _snapshot_remaining(context.started, context.budget)
    observed
end

"""
    read_formats(server, target, fields::FormatField...; kwargs...)
    read_formats(server, target, fields::AbstractVector{<:FormatField}; kwargs...)

Read 1–256 fields with the lossless row codec, preserving field order and
duplicates. Tabs, newlines, backslashes and Unicode remain literal values.
Return `FormatObservation` values; empty expansions remain unverified.
Nonempty invalid numeric or Boolean values raise `FormatValueError`.

The target is mandatory. `PaneRef` selects the physical pane. `SessionRef`
selects its active window and pane; `WindowRef` selects its active pane and
tmux chooses a linked-session context. Use a session target for contextual
session fields; a physical window has no unique session. Client references
are not supported by this API. Identity checks are best effort; `strict=true`
refuses execution. Deadline and cancellation options follow `new_session`.

These descriptors use names from the snapshot catalog without limiting callers
to that catalog:

```julia
read_formats(server, pane_ref,
             FormatField("pane_width", Int), FormatField("pane_active", Bool),
             FormatField("version"))
```
"""
read_formats(server::Server, target, fields::FormatField...; kwargs...) =
    _read_formats(server, target, fields; kwargs...)
read_formats(server::Server, target, fields::AbstractVector{<:FormatField}; kwargs...) =
    _read_formats(server, target, fields; kwargs...)

"""
    RawFormat(expression)

An explicit executable tmux format expression. In particular, `#()` can start
shell commands on the tmux host. It is never inferred from a field name or
evaluated during construction. tmux controls expansion, job scheduling and
cached command-substitution results; rendering does not wait for those jobs.
"""
struct RawFormat
    expression::String
    RawFormat(expression::AbstractString) = new(_argument(expression))
end

"""
    render_format(server, target, expression::RawFormat; kwargs...)

Explicitly evaluate a raw expression and return its `CommandResult`, retaining
all stdout/stderr bytes and exit evidence. stdout includes tmux's final record
newline; no text decoding or whitespace trimming occurs. Target semantics,
deadline and best-effort identity checks follow `read_formats`.
"""
function render_format(
    server::Server,
    target,
    expression::RawFormat;
    max_output_bytes::Int=8 * 1024^2,
    kwargs...,
)
    _format_target(target)
    max_output_bytes >= 0 || throw(ArgumentError("max_output_bytes cannot be negative"))
    text = _literal_tmux_argument(expression.expression)
    context = _target_context(server, target; kwargs...)
    _target_format_command(context, target, text; max_output_bytes)
end

"""
Unverified candidate names from tmux's unescaped format listing. `result`
retains bounded raw command evidence. `availability` is `:unverified` and
`complete` is `false`; candidate names do not prove variable support.
"""
struct FormatHints
    candidate_names::Vector{String}
    result::CommandResult
    availability::Symbol
    complete::Bool
end

"""
    format_hints(server, target; max_output_bytes=1048576, kwargs...)

Return `FormatHints` from `display-message -a` in the explicit target context.
tmux prints unescaped `key=value` rows: multiline values can resemble extra
keys, and unavailable callbacks are omitted. The candidate list is therefore
unverified and incomplete. Read useful candidates with `FormatField`; even
then, an empty expansion does not prove absence or support. Raw bytes remain
in `result`, including invalid UTF-8 that is not part of a candidate name.
Strict list commands verify the target before and after the listing; these
are separate observations, with the same best-effort generation contract.
"""
function format_hints(server::Server, target; max_output_bytes::Int=1024^2, kwargs...)
    key = _format_target(target)
    max_output_bytes >= 0 || throw(ArgumentError("max_output_bytes cannot be negative"))
    context = _target_context(server, target; kwargs...)
    _target_format_command(context, target, "#{pane_id}"; max_output_bytes)
    result =
        _operation_command(context, "display-message", "-a", "-t", key; max_output_bytes)
    _target_format_command(context, target, "#{pane_id}"; max_output_bytes)
    names = String[]
    seen = Set{String}()
    for line in eachsplit(String(copy(result.stdout)), '\n')
        separator = findfirst('=', line)
        separator === nothing && continue
        name = String(SubString(line, firstindex(line), prevind(line, separator)))
        isvalid(name) && occursin(r"\A[a-z][a-z0-9_]*\z", name) || continue
        name in seen && continue
        push!(seen, name)
        push!(names, name)
    end
    _snapshot_remaining(context.started, context.budget)
    FormatHints(names, result, :unverified, false)
end

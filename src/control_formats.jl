function _read_control_formats(
    connection::ControlConnection,
    target,
    fields;
    max_output_bytes::Int=8 * 1024^2,
    kwargs...,
)
    key = _format_target(target)
    1 <= length(fields) <= 256 ||
        throw(ArgumentError("read between 1 and 256 format fields"))
    max_output_bytes >= 0 || throw(ArgumentError("max_output_bytes cannot be negative"))
    fields = collect(fields)
    prefix = "LIBTMUX\t"
    template = prefix * _format_template(String[field.name for field in fields])
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, target)
    predicate = target isa PaneRef ? "#{==:#{pane_id},$(target.id)}" : "#{pane_active}"
    result = _control_request(
        connection,
        ["list-panes", "-t", key, "-f", predicate, "-F", template],
        _ControlReplyPolicy(; prefix, diagnostics=true);
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    result.failed && throw(ControlCommandError(result, "list-panes"))
    length(result.stdout) <= max_output_bytes ||
        throw(OutputLimitExceeded(:stdout, max_output_bytes))
    rows = _decode_format_rows(result.stdout, length(fields) + 1)
    length(rows) == 1 || throw(ControlTargetError(string(target.id)))
    raw = only(rows)
    first(raw) == "LIBTMUX" || throw(_ControlProtocolError(:rows, :invalid_prefix))
    observations = FormatObservation[
        _format_observation(field, value, result) for
        (field, value) in zip(fields, raw[2:end])
    ]
    _snapshot_remaining(context.started, context.budget)
    observations
end

"""
    read_formats(connection::ControlConnection, target, fields::FormatField...; kwargs...)
    read_formats(connection::ControlConnection, target, fields::AbstractVector{<:FormatField}; kwargs...)

Read typed fields over a pinned control connection, with the target contexts and
empty-value semantics of the subprocess method. Names outside the snapshot
catalog remain valid. The escaped row grammar preserves tabs, newlines and
guard-looking text without admitting arbitrary command output.

The connection enforces its generation and never falls back to a subprocess.
`strict=false` does not weaken this identity contract. `FormatValueError.result`
retains the actual `ControlResult`. `max_output_bytes` bounds the encoded reply,
including row prefix and escapes; the connection's frame limit also applies.
"""
read_formats(connection::ControlConnection, target, fields::FormatField...; kwargs...) =
    _read_control_formats(connection, target, fields; kwargs...)
read_formats(
    connection::ControlConnection,
    target,
    fields::AbstractVector{<:FormatField};
    kwargs...,
) = _read_control_formats(connection, target, fields; kwargs...)

function _control_buffer_name(context, buffer, operation)
    _control_exact_target(context.connection, buffer)
    _control_singleline(string(buffer.id), operation)
end

function _with_control_spool(f, operation)
    directory = mktempdir(; prefix="libtmux-julia-buffer-", cleanup=false)
    primary = nothing
    try
        path = _control_singleline(joinpath(directory, "bytes"), operation)
        f(path)
    catch error
        primary = error
        rethrow()
    finally
        try
            rm(directory; recursive=true, force=true)
        catch cleanup
            primary === nothing && throw(cleanup)
            throw(CompositeException([primary, cleanup]))
        end
    end
end

function _control_load_buffer(context, bytes; _spool=_with_control_spool)
    connection = context.connection
    remaining() = _snapshot_remaining(context.started, context.budget)
    name = "libtmux_buffer_" * replace(string(uuid4()), "-"=>"")
    _control_buffer_size(connection, name; timeout=remaining(), cancel=context.cancel) ===
    nothing || throw(ArgumentError("generated buffer name already exists"))
    buffer = BufferRef(connection.identity, name)
    submitted = false
    try
        _spool(:load_buffer) do path
            write(path, bytes)
            submitted = true
            _control_effect(
                connection,
                ["load-buffer", "-b", name, replace(path, "#"=>"##")];
                timeout=remaining(),
                cancel=context.cancel,
            )
        end
    catch original
        if submitted
            try
                _control_remove_buffer(connection, buffer)
            catch cleanup
                throw(CompositeException([original, cleanup]))
            end
        end
        rethrow()
    end
    buffer
end

"""
    load_buffer(connection::ControlConnection, bytes; kwargs...) -> BufferRef

Load nonempty bytes through a private local file on the pinned daemon. The
caller owns the returned random buffer and releases it with `delete_buffer`.
Bytes never pass through the control reply grammar. The daemon must share the
local filesystem; its file I/O may block its event loop. Timeout and cancellation
follow the other typed control methods. Failed submissions attempt separate,
uncancelled 900 ms buffer cleanup; unresolved cleanup retains the buffer in
`ControlBufferCleanupError`. Local files are removed on every exit.
"""
function load_buffer(connection::ControlConnection, bytes::AbstractVector{UInt8}; kwargs...)
    isempty(bytes) && throw(ArgumentError("tmux does not create empty buffers"))
    context = _control_operation_context(connection; kwargs...)
    _control_load_buffer(context, collect(bytes))
end

"""
    save_buffer(connection::ControlConnection, buffer::BufferRef; max_bytes=8388608, kwargs...)

Read exact buffer bytes through a private local file and a completion fence.
Names must be valid UTF-8 without control bytes, because tmux can reflect them
in diagnostics or notifications. Missing buffers raise `StaleReference`.
The observed size is checked before saving and before reading; concurrent
replacement is not locked. `max_bytes` bounds returned bytes, not a concurrent
daemon write to the spool. Local files are always removed; the buffer remains
caller-owned. There is no subprocess fallback.
"""
function save_buffer(
    connection::ControlConnection,
    buffer::BufferRef;
    max_bytes::Int=8 * 1024^2,
    kwargs...,
)
    0 <= max_bytes < typemax(Int) || throw(ArgumentError("invalid buffer byte bound"))
    context = _control_operation_context(connection; kwargs...)
    name = _control_buffer_name(context, buffer, :save_buffer)
    remaining() = _snapshot_remaining(context.started, context.budget)
    size =
        _control_buffer_size(connection, name; timeout=remaining(), cancel=context.cancel)
    size === nothing && throw(StaleReference(name))
    size <= max_bytes || throw(OutputLimitExceeded(:stdout, max_bytes))
    _with_control_spool(:save_buffer) do path
        _control_effect(
            connection,
            ["save-buffer", "-b", name, replace(path, "#"=>"##")];
            timeout=remaining(),
            cancel=context.cancel,
        )
        isfile(path) && !islink(path) || throw(ArgumentError("invalid buffer spool"))
        filesize(path) <= max_bytes || throw(OutputLimitExceeded(:stdout, max_bytes))
        bytes = open(io -> read(io, max_bytes + 1), path)
        length(bytes) <= max_bytes || throw(OutputLimitExceeded(:stdout, max_bytes))
        remaining()
        context.cancel === nothing ||
            !iscancelled(context.cancel) ||
            throw(RequestCancelled(true))
        bytes
    end
end

"""Delete an exact single-line buffer name on the pinned daemon; return `ControlResult`."""
function delete_buffer(connection::ControlConnection, buffer::BufferRef; kwargs...)
    context = _control_operation_context(connection; kwargs...)
    name = _control_buffer_name(context, buffer, :delete_buffer)
    _control_effect(
        connection,
        ["delete-buffer", "-b", name];
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end

function _control_paste_args(context, pane, bracketed)
    prefix = "LIBTMUX\t"
    result = _control_request(
        context.connection,
        [
            "list-commands",
            "-F",
            prefix * _format_template(["command_list_name", "command_list_usage"]),
        ],
        _ControlReplyPolicy(; prefix, diagnostics=true);
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    result.failed && throw(ControlCommandError(result, "list-commands"))
    rows = _decode_format_rows(result.stdout, 3)
    all(row -> row[1] == "LIBTMUX", rows) ||
        throw(_ControlProtocolError(:rows, :invalid_prefix))
    matches = filter(row -> row[2] == "paste-buffer", rows)
    length(matches) == 1 ||
        throw(UnsupportedCapability(:paste_bytes, "paste-buffer is not advertised"))
    _paste_flags(only(matches)[3], pane, bracketed)
end

"""
    paste_bytes(connection::ControlConnection, pane::PaneRef, bytes; bracketed=false, kwargs...)

Paste exact buffer bytes through the pinned connection without appending Enter
or converting LF to CR. Bracketed paste and application transformations follow
the subprocess method. A private file and randomly named buffer carry the data;
success, failure and cancellation attempt uncancelled 900 ms remote cleanup.
Cleanup failure retains its buffer reference alongside any primary error.
Already-delivered input cannot be rolled back. Empty input validates the local
reference and returns `nothing` without submitting a command.
"""
function paste_bytes(
    connection::ControlConnection,
    pane::PaneRef,
    bytes::AbstractVector{UInt8};
    bracketed::Bool=false,
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, pane)
    isempty(bytes) && return nothing
    args = _control_paste_args(context, pane, bracketed)
    buffer = _control_load_buffer(context, collect(bytes))
    primary = nothing
    try
        _control_effect(
            connection,
            [args..., "-b", string(buffer.id)];
            timeout=_snapshot_remaining(context.started, context.budget),
            cancel=context.cancel,
        )
    catch error
        primary = error
        rethrow()
    finally
        try
            _control_remove_buffer(connection, buffer)
        catch cleanup
            primary === nothing && throw(cleanup)
            throw(CompositeException([primary, cleanup]))
        end
    end
end

"""Paste valid UTF-8 over the pinned connection, retaining the owned-buffer contract."""
function paste_text(
    connection::ControlConnection,
    pane::PaneRef,
    text::AbstractString;
    kwargs...,
)
    bytes = collect(codeunits(String(text)))
    decode_text(bytes)
    paste_bytes(connection, pane, bytes; kwargs...)
end

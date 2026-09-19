using UUIDs: uuid4

"""An exact tmux paste-buffer name."""
struct BufferID <: EntityID
    name::String
    function BufferID(name::AbstractString)
        value = _argument(name)
        isempty(value) && throw(ArgumentError("buffer name cannot be empty"))
        new(value)
    end
end
BufferID(id::BufferID) = id
Base.string(id::BufferID) = id.name
Base.:(==)(a::BufferID, b::BufferID) = a.name == b.name
Base.hash(id::BufferID, h::UInt) = hash((:buffer, id.name), h)
const BufferRef = EntityRef{BufferID}

"""A capture decoding failure with its cause and an owned copy of source bytes."""
struct CaptureDecodeError <: LibTmuxError
    cause::InvalidUTF8Error
    bytes::Vector{UInt8}
    CaptureDecodeError(cause::InvalidUTF8Error, bytes::AbstractVector{UInt8}) =
        new(cause, collect(bytes))
end

function Base.showerror(io::IO, error::CaptureDecodeError)
    print(io, "pane capture: ")
    showerror(io, error.cause)
    print(io, "; ", length(error.bytes), " source bytes retained")
end

function _decode_capture(bytes; invalid=:error)
    try
        decode_text(bytes; invalid)
    catch error
        error isa InvalidUTF8Error || rethrow()
        throw(CaptureDecodeError(error, bytes))
    end
end

function _capture_line(value, sentinel)
    value === sentinel && return "-"
    value isa Integer && !(value isa Bool) && typemin(Int32) <= value <= typemax(Int16) ||
        throw(ArgumentError("capture line must be an integer or $sentinel"))
    string(value)
end

"""
    capture_bytes(server, pane; start_line=nothing, end_line=nothing,
                  join_wrapped=false, preserve_trailing=false, escapes=false,
                  alternate=false, max_bytes=8388608, kwargs...)

Capture tmux's screen representation as owned bytes. The default keeps screen
line breaks and tmux's usual trailing-space trimming. `join_wrapped=true`
joins soft-wrapped lines and implies tmux's trailing-space preservation.
`preserve_trailing=true` requests `capture-pane -N`; `escapes=true` includes
style escape sequences. No additional trimming or newline conversion occurs.

Negative line numbers address history; `start_line=:history` selects its
beginning and `end_line=:bottom` selects the screen bottom. `alternate=true`
requests the alternate screen and errors if it is unavailable. Screen capture
does not reconstruct the original terminal byte stream.
"""
function capture_bytes(
    server::Server,
    pane::PaneRef;
    start_line=nothing,
    end_line=nothing,
    join_wrapped::Bool=false,
    preserve_trailing::Bool=false,
    escapes::Bool=false,
    alternate::Bool=false,
    max_bytes::Int=8 * 1024^2,
    kwargs...,
)
    max_bytes >= 0 || throw(ArgumentError("max_bytes must be nonnegative"))
    args = ["capture-pane", "-p", "-t", string(pane.id)]
    start_line === nothing || append!(args, ["-S", _capture_line(start_line, :history)])
    end_line === nothing || append!(args, ["-E", _capture_line(end_line, :bottom)])
    join_wrapped && push!(args, "-J")
    preserve_trailing && push!(args, "-N")
    escapes && push!(args, "-e")
    alternate && push!(args, "-a")
    context = _target_context(server, pane; kwargs...)
    _operation_command(context, args...; max_output_bytes=max_bytes).stdout
end

"""
Capture a pane as strict UTF-8 text. Malformed text raises `CaptureDecodeError`
with the bounded source bytes; use `invalid=:replace` explicitly for replacement.
"""
function capture_pane(server::Server, pane::PaneRef; invalid=:error, kwargs...)
    TextDecoder(; invalid)
    _decode_capture(capture_bytes(server, pane; kwargs...); invalid)
end

"""
    send_keys(server, pane, keys...; literal=false, kwargs...)

Send explicit tmux key arguments to an exact pane. Named tokens such as
`Enter` and `C-c` use tmux's normal key lookup; unrecognized tokens are text.
`literal=true` disables key lookup. No Enter, separator or format expansion
is added. Invalid UTF-8 raises `InvalidUTF8Error` before submission. Large
text and binary data belong in `paste_text` or `paste_bytes`.
"""
function send_keys(
    server::Server,
    pane::PaneRef,
    keys::AbstractString...;
    literal::Bool=false,
    kwargs...,
)
    isempty(keys) && throw(ArgumentError("supply at least one key argument"))
    args = ["send-keys", "-t", string(pane.id)]
    literal && push!(args, "-l")
    push!(args, "--")
    for key in keys
        text = _argument(key)
        isvalid(text) || decode_text(codeunits(text))
        push!(args, _literal_tmux_argument(text))
    end
    context = _target_context(server, pane; kwargs...)
    _operation_command(context, args...)
end

function _new_buffer_ref(context, identity)
    result =
        _operation_command(context, "list-buffers", "-F", _format_template(["buffer_name"]))
    names = Set(only(row) for row in _decode_format_rows(result.stdout, 1))
    for _ = 1:8
        name = "libtmux-julia-" * string(uuid4())
        name in names || return BufferRef(identity, name)
    end
    error("could not allocate a unique paste-buffer name")
end

function _cleanup_owned_buffer(server, buffer)
    context = _target_context(server, buffer; timeout=0.9)
    result = _operation_command(
        context,
        "delete-buffer",
        "-b",
        _literal_tmux_argument(string(buffer.id));
        check=false,
    )
    if result.exitcode != 0 || result.termsignal != 0
        result.stderr == codeunits("no buffer $(string(buffer.id))\n") ||
            throw(CommandError(result))
    end
    nothing
end

function _load_owned_buffer(context, buffer, bytes)
    try
        _operation_command(
            context,
            "load-buffer",
            "-b",
            _literal_tmux_argument(string(buffer.id)),
            "-";
            input=bytes,
        )
    catch original
        try
            _cleanup_owned_buffer(context.server, buffer)
        catch cleanup
            throw(CompositeException([original, cleanup]))
        end
        rethrow()
    end
    buffer
end

"""
    load_buffer(server, bytes; kwargs...) -> BufferRef

Load nonempty bytes through stdin into a randomly named, generation-bound
buffer. Existing names are checked before creation. The caller owns the
returned buffer and releases it with `delete_buffer`; no finalizer performs
remote I/O. Empty input errors because tmux does not create empty buffers.
"""
function load_buffer(server::Server, bytes::AbstractVector{UInt8}; kwargs...)
    isempty(bytes) && throw(ArgumentError("tmux does not create empty buffers"))
    context = _operation_context(server; kwargs...)
    _verify_row_codec(server, context.started, context.budget, context.cancel)
    identity = _snapshot_metadata(server, context.started, context.budget, context.cancel)
    buffer = _new_buffer_ref(context, identity)
    _load_owned_buffer(context, buffer, bytes)
end

"""Read exact buffer bytes without text conversion or newline changes."""
function save_buffer(
    server::Server,
    buffer::BufferRef;
    max_bytes::Int=8 * 1024^2,
    kwargs...,
)
    max_bytes >= 0 || throw(ArgumentError("max_bytes must be nonnegative"))
    context = _target_context(server, buffer; kwargs...)
    _operation_command(
        context,
        "save-buffer",
        "-b",
        _literal_tmux_argument(string(buffer.id)),
        "-";
        max_output_bytes=max_bytes,
    ).stdout
end

"""Delete the explicitly supplied generation-bound buffer."""
function delete_buffer(server::Server, buffer::BufferRef; kwargs...)
    context = _target_context(server, buffer; kwargs...)
    _operation_command(
        context,
        "delete-buffer",
        "-b",
        _literal_tmux_argument(string(buffer.id)),
    )
end

function _paste_args(context, pane, bracketed)
    catalog = _operation_command(
        context,
        "list-commands",
        "-F",
        "#{command_list_name}\t#{command_list_usage}",
    )
    usage = nothing
    for line in split(decode_text(catalog.stdout), '\n')
        startswith(line, "paste-buffer\t") || continue
        usage = split(line, '\t'; limit=2)[2]
        break
    end
    usage === nothing &&
        throw(UnsupportedCapability(:paste_bytes, "paste-buffer is not advertised"))
    flags = match(r"^\[-([A-Za-z]+)\]", usage)
    flags === nothing &&
        throw(UnsupportedCapability(:paste_bytes, "unrecognized paste-buffer flags"))
    args = ["paste-buffer", "-r", "-t", string(pane.id)]
    # Newer tmux sanitizes paste by default; -S retains the older raw behavior.
    'S' in flags.captures[1] && push!(args, "-S")
    bracketed && push!(args, "-p")
    args
end

"""
    paste_bytes(server, pane, bytes; bracketed=false, kwargs...)

Paste through a temporary owned buffer, retaining LF rather than converting
it to CR. `bracketed=true` requests bracketed paste when the application has
enabled it. No Enter is appended. tmux receives exact buffer bytes, but the
terminal driver and target application can transform them.

Success, failure and cancellation attempt bounded cleanup of only the new
buffer with an uncancelled 900 ms context. A cleanup failure preserves the
original error in `CompositeException`. Subprocess generation checks remain
best effort; input already delivered to the pane cannot be rolled back.
Empty bytes validate the target and return `nothing` without sending input.
"""
function paste_bytes(
    server::Server,
    pane::PaneRef,
    bytes::AbstractVector{UInt8};
    bracketed::Bool=false,
    kwargs...,
)
    context = _target_context(server, pane; kwargs...)
    isempty(bytes) && return nothing
    args = _paste_args(context, pane, bracketed)
    buffer = _new_buffer_ref(context, pane.server)
    _load_owned_buffer(context, buffer, bytes)
    original = nothing
    try
        _operation_command(
            context,
            args...,
            "-b",
            _literal_tmux_argument(string(buffer.id)),
        )
    catch error
        original = error
        rethrow()
    finally
        try
            _cleanup_owned_buffer(server, buffer)
        catch cleanup
            original === nothing && throw(cleanup)
            throw(CompositeException([original, cleanup]))
        end
    end
end

"""Paste valid UTF-8 text through an owned buffer without adding Enter."""
function paste_text(server::Server, pane::PaneRef, text::AbstractString; kwargs...)
    bytes = collect(codeunits(String(text)))
    decode_text(bytes)
    paste_bytes(server, pane, bytes; kwargs...)
end

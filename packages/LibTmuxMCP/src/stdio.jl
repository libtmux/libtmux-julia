"The stdio stream violated a bounded newline-delimited UTF-8 frame contract."
struct StdioFramingError <: Exception
    reason::Symbol
end
Base.showerror(io::IO, error::StdioFramingError) =
    print(io, "MCP stdio framing failed: ", error.reason)

struct _StdioTransport{I<:IO,O<:IO} <: SDK.Transport
    input::I
    output::O
    connected::Threads.Atomic{Bool}
    max_input_bytes::Int
    max_output_bytes::Int
end

function _StdioTransport(
    input::IO,
    output::IO;
    max_input_bytes::Int=2 * 1024^2,
    max_output_bytes::Int=8 * 1024^2,
)
    max_input_bytes > 0 && max_output_bytes > 0 ||
        throw(ArgumentError("stdio byte limits must be positive"))
    _StdioTransport(
        input,
        output,
        Threads.Atomic{Bool}(true),
        max_input_bytes,
        max_output_bytes,
    )
end
SDK.is_connected(transport::_StdioTransport) = transport.connected[]

function SDK.read_message(transport::_StdioTransport)
    transport.connected[] || return nothing
    bytes = UInt8[]
    sizehint!(bytes, min(8192, transport.max_input_bytes))
    while true
        byte = try
            read(transport.input, UInt8)
        catch error
            if error isa EOFError
                (!transport.connected[] || isempty(bytes)) && return nothing
                throw(StdioFramingError(:truncated_line))
            end
            rethrow()
        end
        byte == 0x0a && break
        length(bytes) < transport.max_input_bytes || throw(StdioFramingError(:input_limit))
        push!(bytes, byte)
    end
    message = String(bytes)
    isvalid(message) || throw(StdioFramingError(:invalid_utf8))
    message
end

function SDK.write_message(transport::_StdioTransport, message::String)
    transport.connected[] || throw(EOFError())
    ncodeunits(message) <= transport.max_output_bytes ||
        throw(StdioFramingError(:output_limit))
    (isvalid(message) && !occursin('\n', message) && !occursin('\r', message)) ||
        throw(StdioFramingError(:invalid_output))
    try
        # The dispatcher owns serialization. Closing never waits on a write lock.
        write(transport.output, message, '\n')
        flush(transport.output)
    catch error
        if !transport.connected[] && (
            error isa EOFError ||
            error isa Base.IOError &&
            error.code in (Base.UV_ECANCELED, Base.UV_EPIPE, Base.UV_EBADF)
        )
            throw(EOFError())
        end
        rethrow()
    end
    nothing
end

_close_stdio(stream::IO) = close(stream)
_close_stdio(stream::IOContext) = _close_stdio(stream.io)
function _close_stdio(stream::Base.Pipe)
    errors = Exception[]
    for endpoint in (stream.in, stream.out)
        try
            _close_stdio(endpoint)
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    nothing
end
function _close_stdio(stream::Base.LibuvStream)
    # Base.close flushes pending writes before closing a libuv stream. A peer
    # that stopped reading must not hold transport cancellation indefinitely.
    Base.iolock_begin()
    try
        if stream.handle != C_NULL && isopen(stream)
            ccall(:jl_forceclose_uv, Cvoid, (Ptr{Cvoid},), stream.handle)
            stream.status = Base.StatusClosing
        end
    finally
        Base.iolock_end()
    end
    Base.wait_close(stream)
    nothing
end

function SDK.close(transport::_StdioTransport)
    Threads.atomic_xchg!(transport.connected, false) || return nothing
    errors = Exception[]
    for stream in (transport.input, transport.output)
        try
            _close_stdio(stream)
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    nothing
end

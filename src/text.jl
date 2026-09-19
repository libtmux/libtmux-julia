"""Malformed UTF-8 at the one-based byte `offset` of a stream subsequence."""
struct InvalidUTF8Error <: LibTmuxError
    offset::Int
    reason::Symbol
end

function Base.showerror(io::IO, error::InvalidUTF8Error)
    description =
        error.reason === :incomplete_sequence ? "incomplete sequence" : "invalid sequence"
    print(io, "invalid UTF-8 at byte ", error.offset, " (", description, ')')
end

"""
    TextDecoder(; invalid=:error)

Create a single-owner incremental UTF-8 decoder. `decode!` returns complete
text and retains at most three copied bytes from an incomplete sequence.
`invalid=:error` throws `InvalidUTF8Error`; `invalid=:replace` emits U+FFFD
for each maximal subpart described by Unicode 17, section 3.9.6.

Final input or a strict decoding error closes the decoder. Use a new decoder
for another stream. Calls do not normalize whitespace or remove a BOM.
"""
mutable struct TextDecoder
    _invalid::Symbol
    _pending::Vector{UInt8}
    _received::Int
    _closed::Bool

    function TextDecoder(; invalid=:error)
        invalid in (:error, :replace) ||
            throw(ArgumentError("invalid must be :error or :replace"))
        new(invalid, UInt8[], 0, false)
    end
end

# Unicode 17, table 3-7: the second byte excludes overlong, surrogate and
# out-of-range encodings. Later continuation bytes always lie in 80..BF.
function _utf8_shape(lead::UInt8)
    0xc2 <= lead <= 0xdf && return (2, 0x80, 0xbf)
    lead == 0xe0 && return (3, 0xa0, 0xbf)
    0xe1 <= lead <= 0xec && return (3, 0x80, 0xbf)
    lead == 0xed && return (3, 0x80, 0x9f)
    0xee <= lead <= 0xef && return (3, 0x80, 0xbf)
    lead == 0xf0 && return (4, 0x90, 0xbf)
    0xf1 <= lead <= 0xf3 && return (4, 0x80, 0xbf)
    lead == 0xf4 && return (4, 0x80, 0x8f)
    (0, 0x80, 0xbf)
end

"""
    decode!(decoder::TextDecoder, chunk::AbstractVector{UInt8}; final=false)

Decode a copied chunk and return its complete text. Incomplete sequences
span calls. `final=true` finishes the stream: a remaining partial sequence
raises `InvalidUTF8Error` or produces one U+FFFD, according to `invalid`.
Further calls after final input or a strict error raise `InvalidStateException`.

Error offsets count all input bytes from one, including earlier chunks, and
identify the beginning of the malformed subsequence. No I/O occurs. The
decoder must not be shared by concurrent callers.
"""
function decode!(decoder::TextDecoder, chunk::AbstractVector{UInt8}; final::Bool=false)
    decoder._closed && throw(InvalidStateException("text decoder is closed", :closed))
    base = decoder._received - length(decoder._pending)
    data = copy(decoder._pending)
    append!(data, chunk)
    decoder._received += length(chunk)
    empty!(decoder._pending)
    output = UInt8[]
    sizehint!(output, length(data))
    index = 1
    while index <= length(data)
        lead = data[index]
        if lead <= 0x7f
            push!(output, lead)
            index += 1
            continue
        end

        width, lower, upper = _utf8_shape(lead)
        matched = 1
        valid = width != 0
        while valid && matched < width && index + matched <= length(data)
            byte = data[index+matched]
            if (matched == 1 ? lower : 0x80) <= byte <= (matched == 1 ? upper : 0xbf)
                matched += 1
            else
                valid = false
            end
        end

        if valid && matched == width
            for position = index:(index+width-1)
                push!(output, data[position])
            end
        elseif valid && !final
            for position = index:length(data)
                push!(decoder._pending, data[position])
            end
            break
        elseif decoder._invalid === :error
            decoder._closed = true
            reason = valid ? :incomplete_sequence : :invalid_sequence
            throw(InvalidUTF8Error(base + index, reason))
        else
            append!(output, (0xef, 0xbf, 0xbd))
        end
        index += matched
    end
    decoder._closed = final
    String(output)
end

"""
    decode_text(bytes::AbstractVector{UInt8}; invalid=:error)

Decode UTF-8 bytes without trimming or newline conversion. Malformed input
raises `InvalidUTF8Error` by default. `invalid=:replace` uses one U+FFFD per
maximal subpart; valid adjacent characters remain intact. The returned text
does not alias caller-owned bytes.

The replacement contract follows
[Unicode 17, section 3.9.6](https://www.unicode.org/versions/Unicode17.0.0/core-spec/chapter-3/#G66453).
"""
decode_text(bytes::AbstractVector{UInt8}; invalid=:error) =
    decode!(TextDecoder(; invalid), bytes; final=true)

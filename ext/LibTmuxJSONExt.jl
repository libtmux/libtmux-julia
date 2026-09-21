module LibTmuxJSONExt

using LibTmux
using JSON

# This scan only bounds parser work. JSON owns syntax and escape validation.
function check_json_bounds(text, limits, max_input_bytes)
    max_input_bytes > 0 || throw(ArgumentError("max_input_bytes must be positive"))
    ncodeunits(text) <= max_input_bytes ||
        LibTmux._wire_error(:limit, "\$", "JSON byte limit exceeded")
    isvalid(text) || LibTmux._wire_error(:value, "\$", "JSON must contain valid UTF-8")
    quoted, escaped, scalar = false, false, false
    depth, nodes, string_bytes, total_strings = 0, 0, 0, 0
    for byte in codeunits(text)
        if quoted
            if !escaped && byte == UInt8('"')
                quoted = false
                continue
            end
            string_bytes += 1
            total_strings += 1
            # Six encoded bytes per decoded byte is the largest escape ratio.
            cld(string_bytes, 6) <= limits.max_string_bytes ||
                LibTmux._wire_error(:limit, "\$", "JSON string bound exceeded")
            cld(total_strings, 6) <= limits.max_bytes ||
                LibTmux._wire_error(:limit, "\$", "JSON string byte bound exceeded")
            if escaped
                escaped = false
            elseif byte == UInt8('\\')
                escaped = true
            end
            continue
        end
        if byte == UInt8('"')
            quoted, scalar, string_bytes = true, false, 0
            nodes += 1
        elseif byte in (UInt8('{'), UInt8('['))
            depth += 1
            nodes += 1
            scalar = false
            depth <= limits.max_depth ||
                LibTmux._wire_error(:limit, "\$", "JSON nesting bound exceeded")
        elseif byte in (UInt8('}'), UInt8(']'))
            depth -= 1
            scalar = false
        elseif byte in (0x20, 0x09, 0x0a, 0x0d, UInt8(','), UInt8(':'))
            scalar = false
        elseif !scalar
            scalar = true
            nodes += 1
        end
        nodes <= limits.max_nodes ||
            LibTmux._wire_error(:limit, "\$", "JSON token bound exceeded")
    end
    nothing
end

function LibTmux.read_where_json(
    text::AbstractString;
    limits::WhereLimits=WhereLimits(),
    max_input_bytes::Int=8 * 1024^2,
)
    check_json_bounds(text, limits, max_input_bytes)
    data = try
        JSON.parse(text; dicttype=Dict{String,Any}, duplicate_keys=:error, allownan=false)
    catch error
        error isa JSON.DuplicateKeyError &&
            LibTmux._wire_error(:duplicate, "\$", "duplicate JSON key")
        error isa ArgumentError || rethrow()
        LibTmux._wire_error(:json, "\$", "invalid JSON document")
    end
    decode_where(data; limits)
end

function LibTmux.write_where_json(q::Criterion; kwargs...)
    JSON.json(encode_where(q; kwargs...))
end

end

# Escape backslashes first so literal "\\n" stays distinct from a newline.
# Ordered substitutions also work in tmux versions whose q modifier leaves
# record and field separators unescaped. Clients must use tmux's UTF-8 mode.
# Encoding dollars avoids tmux 3.4's extra print-layer backslash.
const _FORMAT_ROW_PREFIX =
    raw"#{s|\\|\\\\|;s|[$]|\\d|;s|" * "\t" * raw"|\\t|;s|" * "\n" * raw"|\\n|:"

function _format_template(fields::Vector{String})
    isempty(fields) && throw(ArgumentError("at least one tmux format field is required"))
    all(field -> occursin(r"\A[a-z][a-z0-9_]*\z", field), fields) ||
        throw(ArgumentError("tmux format fields must match [a-z][a-z0-9_]*"))
    join((_FORMAT_ROW_PREFIX * field * "}" for field in fields), '\t')
end

function _decode_format_rows(bytes::AbstractVector{UInt8}, nfields::Integer)
    nfields > 0 || throw(ArgumentError("tmux rows must have at least one field"))
    rows = Vector{Vector{String}}()
    row = String[]
    field = UInt8[]
    escaped = false
    octal_digits = 0
    octal_value = 0
    for byte in bytes
        if octal_digits > 0
            0x30 <= byte <= 0x37 || throw(ArgumentError("invalid format octal escape"))
            octal_value = 8 * octal_value + Int(byte - 0x30)
            octal_digits -= 1
            if octal_digits == 0
                octal_value <= 255 || throw(ArgumentError("format escape exceeds one byte"))
                push!(field, UInt8(octal_value))
            end
        elseif escaped
            if byte == UInt8('n')
                push!(field, UInt8('\n'))
            elseif byte == UInt8('t')
                push!(field, UInt8('\t'))
            elseif byte == UInt8('\\')
                push!(field, byte)
            elseif byte == UInt8('d')
                push!(field, UInt8('$'))
            elseif byte in (0x61, 0x62, 0x66, 0x72, 0x76)
                # server_client_print applies VIS_CSTYLE after format expansion.
                push!(
                    field,
                    byte == 0x61 ? 0x07 :
                    byte == 0x62 ? 0x08 : byte == 0x66 ? 0x0c : byte == 0x72 ? 0x0d : 0x0b,
                )
            elseif 0x30 <= byte <= 0x37
                octal_value = Int(byte - 0x30)
                octal_digits = 2
            else
                throw(ArgumentError("invalid escape in tmux format row"))
            end
            escaped = false
        elseif byte == UInt8('\\')
            escaped = true
        elseif byte == UInt8('\t') || byte == UInt8('\n')
            value = String(copy(field))
            isvalid(value) || throw(ArgumentError("invalid UTF-8 in tmux format row"))
            push!(row, value)
            empty!(field)
            length(row) <= nfields ||
                throw(ArgumentError("too many columns in tmux format row"))
            if byte == UInt8('\n')
                length(row) == nfields ||
                    throw(ArgumentError("wrong column count in tmux format row"))
                push!(rows, row)
                row = String[]
            end
        else
            push!(field, byte)
        end
    end
    (escaped || octal_digits > 0 || !isempty(field) || !isempty(row)) &&
        throw(ArgumentError("truncated tmux format row"))
    rows
end

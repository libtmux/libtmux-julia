# Escape backslashes first so literal "\\n" stays distinct from a newline.
# Ordered substitutions also work in tmux versions whose q modifier leaves
# record and field separators unescaped. Clients must use tmux's UTF-8 mode.
const _FORMAT_ROW_PREFIX = raw"#{s|\\|\\\\|;s|" * "\t" * raw"|\\t|;s|" * "\n" * raw"|\\n|:"

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
    for byte in bytes
        if escaped
            if byte == UInt8('n')
                push!(field, UInt8('\n'))
            elseif byte == UInt8('t')
                push!(field, UInt8('\t'))
            elseif byte == UInt8('\\')
                push!(field, byte)
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
    (escaped || !isempty(field) || !isempty(row)) &&
        throw(ArgumentError("truncated tmux format row"))
    rows
end

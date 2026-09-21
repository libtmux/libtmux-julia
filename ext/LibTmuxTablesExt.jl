module LibTmuxTablesExt

using LibTmux
using Tables

Tables.istable(::Type{<:RowProjection}) = true
Tables.rowaccess(::Type{<:RowProjection}) = true
Tables.rows(rows::RowProjection) = rows
Tables.schema(::RowProjection{R}) where {R} = Tables.Schema(fieldnames(R), fieldtypes(R))

end

# Project captured rows

Use `project_rows` to select scalar fields from a captured selection. The
result is a read-only vector of named tuples with explicit column types.
It preserves order, duplicates, typed IDs, and `nothing` for captured absence.
It checks coverage before returning and performs no tmux I/O.

```julia
using LibTmux

function pane_rows(snap::Snapshot)
    project_rows(panes(snap); columns=(:id, :current_command, :width))
end
```

Select only the fields your consumer needs. Relations are not scalar columns;
project them explicitly with ordinary Julia code. An unknown field or missing
coverage errors instead of producing a partial table. Retaining a projection
retains its source snapshot. `collect` produces an ordinary vector; `similar`
allocates writable workspace for generic Julia algorithms.

An empty projection retains its schema. Integer columns use `Integer` so the
projection does not silently narrow a captured integer; pane, window, session
and client IDs retain their corresponding library types.

## Tables integration

Loading Tables 1.14 or later activates the optional extension. The projection
implements its [row interface](https://tables.juliadata.org/stable/implementing-the-interface/)
and supplies the declared schema even when no rows match.

```julia
using LibTmux, Tables

function pane_columns(snap::Snapshot)
    Tables.columntable(project_rows(panes(snap); columns=(:id, :current_command)))
end
```

Core does not depend on Tables or DataFrames. A selection itself remains an
entity graph collection; converting it to a table requires this explicit
projection.

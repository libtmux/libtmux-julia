module LibTmuxCheckCompiler

import JuliaFormatter
using PrecompileTools: @compile_workload

compiler_format(source::String) = JuliaFormatter.format_text(
    source;
    style=JuliaFormatter.DefaultStyle(),
    indent=4,
    margin=92,
    format_docstrings=false,
    whitespace_in_kwargs=false,
)

# Inert syntax compiles the formatter policy without checking source files.
@compile_workload begin
    compiler_format(raw"""
    module CompilerSyntax
    "Inert compiler sample."
    struct Record{T}
        value::T
    end
    @noinline function compiler_probe(x::AbstractVector; limit=4)
        items = [value + 1 for value in x if value > 0]
        for (i, value) in enumerate(items)
            i > limit && break
            @assert value > 0
        end
        try
            map(items) do value
                value > 1 ? value : nothing
            end
        catch error
            error isa ArgumentError || rethrow()
        finally
            nothing
        end
        (name="compiler", values=items)
    end
    const VALUES = Dict("one"=>1, "two"=>2)
    end
    """)
end

end

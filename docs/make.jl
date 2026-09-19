using Documenter
include("source-links.jl")

source_root = dirname(@__DIR__)
included_source = source_contents(source_root)
using LibTmux, LibTmuxMCP, LibTmuxWorkspace

makedocs(
    sitename="LibTmux.jl",
    modules=[LibTmux, LibTmux.Filters, LibTmuxMCP, LibTmuxWorkspace],
    remotes=Dict(source_root=>(BuildSourceRemote(), "working-tree")),
    format=Documenter.HTML(;
        prettyurls=true,
        edit_link=nothing,
        repolink="https://github.com/libtmux/libtmux-julia",
    ),
    checkdocs=:exports,
    pages=[
        "Start here"=>"index.md",
        "Captured queries"=>"queries.md",
        "Ownership and I/O"=>"ownership.md",
        "Output observations"=>"observations.md",
        "MCP application"=>"mcp.md",
        "Workspace loading"=>"workspaces.md",
        "Compatibility"=>"compatibility.md",
        "Troubleshooting"=>"troubleshooting.md",
        "API reference"=>"api.md",
    ],
)

source_contents(source_root) == included_source ||
    error("Package source changed during documentation build; rebuild from stable sources")
write_source_pages(included_source, joinpath(@__DIR__, "build"))

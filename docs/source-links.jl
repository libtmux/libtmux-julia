using SHA

struct BuildSourceRemote <: Documenter.Remotes.Remote end
Documenter.Remotes.repourl(::BuildSourceRemote) = "https://github.com/libtmux/libtmux-julia"
function Documenter.Remotes.fileurl(::BuildSourceRemote, revision, filename, lines)
    fragment = lines === nothing ? "" : "#L$(first(lines))"
    "../source/" * filename * ".html" * fragment
end

_html(text) = replace(text, '&'=>"&amp;", '<'=>"&lt;", '>'=>"&gt;", '"'=>"&quot;")

function source_contents(root)
    result = Dict{String,String}()
    directories = ("src", "ext", "packages/LibTmuxMCP/src", "packages/LibTmuxWorkspace/src")
    for directory in directories
        for (parent, _, names) in walkdir(joinpath(root, directory)), name in names
            endswith(name, ".jl") || continue
            path = joinpath(parent, name)
            result[relpath(path, root)] = read(path, String)
        end
    end
    result
end

function write_source_pages(contents, build)
    for (relative, content) in contents
        destination = joinpath(build, "source", relative * ".html")
        mkpath(dirname(destination))
        digest = bytes2hex(sha256(content))
        open(destination, "w") do io
            println(
                io,
                "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">",
                "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
                "<title>",
                _html(relative),
                " · LibTmux source</title>",
                "<style>body{margin:2rem;font-family:system-ui}pre{line-height:1.55}",
                "a{color:#52617a;text-decoration:none}a:target{background:#ffedb0}",
                ".line:target{background:#ffedb0}small{overflow-wrap:anywhere}</style>",
                "<h1>",
                _html(relative),
                "</h1><p>Source included in this documentation build.</p>",
                "<small>SHA-256: ",
                digest,
                "</small><pre><code>",
            )
            for (number, line) in enumerate(split(content, '\n'))
                println(
                    io,
                    "<span class=\"line\" id=\"L",
                    number,
                    "\"><a href=\"#L",
                    number,
                    "\">",
                    lpad(number, 5),
                    "</a>  ",
                    _html(line),
                    "</span>",
                )
            end
            println(io, "</code></pre></html>")
        end
    end
end

using JSON
using LibTmux
using LibTmuxMCP
using LibTmuxWorkspace

const README_ROOT = dirname(@__DIR__)
const README_FILES =
    ("README.md", "packages/LibTmuxWorkspace/README.md", "packages/LibTmuxMCP/README.md")
const README_TREE = "https://github.com/libtmux/libtmux-julia/tree/master/"
const README_BLOB = "https://github.com/libtmux/libtmux-julia/blob/master/"
const README_SITE = "https://libtmux.org/en/julia/latest/"
const README_DEADLINE = 180.0
# Directories whose headings in the root README must link them, and a file
# that proves each one is the package directory it claims to be.
const README_JULIA_FLAGS = ("--compile", "--threads", "--project", "--startup-file")
const README_PACKAGES = (
    ("src", "LibTmux.jl"),
    ("ext", "LibTmuxJSONExt.jl"),
    ("packages/LibTmuxWorkspace", "Project.toml"),
    ("packages/LibTmuxMCP", "Project.toml"),
)

struct ReadmeFence
    info::String
    body::String
    line::Int
    marker::Union{Nothing,String}
end

function readme_fences(text)
    fences = ReadmeFence[]
    lines = split(text, '\n'; keepempty=true)
    open_at, info, body = 0, "", String[]
    for (number, line) in enumerate(lines)
        if open_at == 0
            occursin(r"^```", line) || continue
            open_at, info, body = number, strip(line[4:end]), String[]
        elseif occursin(r"^```\s*$", line)
            marker = nothing
            for previous = (open_at-1):-1:1
                isempty(strip(lines[previous])) && continue
                found = match(r"^<!-- (file: \S+|mcp-config) -->$", lines[previous])
                found === nothing || (marker = String(found.captures[1]))
                break
            end
            push!(fences, ReadmeFence(info, join(body, '\n') * "\n", open_at, marker))
            open_at = 0
        else
            push!(body, line)
        end
    end
    open_at == 0 || error("unclosed code fence opened at line $open_at")
    fences
end

function blank_fences(text)
    lines = split(text, '\n'; keepempty=true)
    inside = false
    for (number, line) in enumerate(lines)
        if occursin(r"^```", line)
            inside = !inside
            lines[number] = ""
        elseif inside
            lines[number] = ""
        end
    end
    join(lines, '\n')
end

# Prose with reference-style links rewritten as inline links, line numbers kept.
function resolved_prose(text)
    prose = blank_fences(text)
    definitions = Dict{String,String}()
    for found in eachmatch(r"^\[([^\]]+)\]:[ \t]*(\S+)[ \t]*$"m, prose)
        definitions[lowercase(found.captures[1])] = String(found.captures[2])
    end
    prose = replace(prose, r"^\[([^\]]+)\]:[ \t]*(\S+)[ \t]*$"m => "")
    replace(
        prose,
        r"\[((?:[^\[\]]|\[[^\]]*\])+)\]\[([^\]]+)\]" => function (whole)
            found = match(r"\[((?:[^\[\]]|\[[^\]]*\])+)\]\[([^\]]+)\]", whole)
            target = get(definitions, lowercase(found.captures[2]), nothing)
            target === nothing ? whole : "[" * found.captures[1] * "](" * target * ")"
        end,
    )
end

function readme_links(text)
    links = NamedTuple{(:text, :url, :line),Tuple{String,String,Int}}[]
    for (number, line) in enumerate(split(resolved_prose(text), '\n'; keepempty=true))
        for found in eachmatch(r"\[((?:[^\[\]]|\[[^\]]*\])+)\]\(([^)\s]+)\)", line)
            push!(links, (text=found.captures[1], url=found.captures[2], line=number))
        end
    end
    links
end

function heading_slug(heading)
    text = replace(heading, r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^)]*\)" => s"\1")
    text = replace(text, r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]*\]" => s"\1")
    text = replace(text, "`" => "")
    text = lowercase(strip(text))
    text = replace(text, r"[^\p{L}\p{N} _-]" => "")
    replace(text, ' ' => '-')
end

function heading_slugs(text)
    slugs = Set{String}()
    for line in split(blank_fences(text), '\n')
        found = match(r"^#{1,6}[ \t]+(.+?)[ \t]*$", line)
        found === nothing || push!(slugs, heading_slug(found.captures[1]))
    end
    slugs
end

# One command per console block; a trailing backslash continues the command.
function console_command(fence::ReadmeFence)
    words, continued = String[], false
    for line in split(chomp(fence.body), '\n')
        if continued
            push!(words, strip(line))
        elseif startswith(line, "\$ ") && isempty(words)
            push!(words, line[3:end])
        else
            error(
                "console block at line $(fence.line) holds more than one command or its output",
            )
        end
        continued = endswith(line, "\\")
        continued && (words[end] = strip(chop(words[end])))
    end
    isempty(words) && error("console block at line $(fence.line) is empty")
    continued && error("console block at line $(fence.line) ends in a continuation")
    join(words, " ")
end

struct ReadmeStep
    command::String
    fence::ReadmeFence
    output::Union{Nothing,String}
end

function readme_steps(text)
    fences = readme_fences(text)
    steps = ReadmeStep[]
    for (index, fence) in enumerate(fences)
        fence.info == "console" || continue
        following = index < length(fences) ? fences[index+1] : nothing
        output =
            following !== nothing && following.info == "text" ? following.body : nothing
        push!(steps, ReadmeStep(console_command(fence), fence, output))
    end
    steps
end

function console_problems(text, name)
    problems = String[]
    for fence in readme_fences(text)
        fence.info == "console" || continue
        try
            console_command(fence)
        catch error
            error isa ErrorException || rethrow()
            push!(problems, "$name: $(error.msg)")
        end
    end
    problems
end

# Code blocks are paste-and-run units, so links belong in the sentence before.
function fence_link_problems(text, name)
    [
        "$name:$(fence.line): a code block contains a Markdown link" for
        fence in readme_fences(text) if occursin(r"\]\(https?://", fence.body)
    ]
end

function link_target_problems(text, name; root=README_ROOT)
    problems = String[]
    slugs = heading_slugs(text)
    directory = dirname(joinpath(root, name))
    for link in readme_links(text)
        url = link.url
        startswith(url, "http") && continue
        if startswith(url, "#")
            url[2:end] in slugs ||
                push!(problems, "$name:$(link.line): no heading for anchor $url")
            continue
        end
        path = first(split(url, '#'; limit=2))
        ispath(joinpath(directory, path)) ||
            push!(problems, "$name:$(link.line): $url names a missing path")
    end
    problems
end

# A README is also read outside GitHub, in an exported package or on a registry
# page, where a relative link breaks. A link to a file of this repository is an
# absolute GitHub URL that names an existing path: blob for a file, tree for a
# directory. The new files of a pull request 404 there until it merges.
function repo_link_problems(text, name; root=README_ROOT)
    problems = String[]
    for link in readme_links(text)
        url = link.url
        (startswith(url, "#") || startswith(url, "mailto:")) && continue
        if !startswith(url, "http")
            push!(
                problems,
                "$name:$(link.line): $url is a relative repository link; use $(README_BLOB)PATH",
            )
            continue
        end
        for (prefix, kind) in ((README_BLOB, "blob"), (README_TREE, "tree"))
            startswith(url, prefix) || continue
            path = String(first(split(url[(length(prefix)+1):end], '#'; limit=2)))
            target = joinpath(root, path)
            if !ispath(target)
                push!(problems, "$name:$(link.line): $url names a missing path")
            elseif kind == "blob" && isdir(target)
                push!(
                    problems,
                    "$name:$(link.line): $url names a directory; use $(README_TREE)$path",
                )
            elseif kind == "tree" && !isdir(target)
                push!(
                    problems,
                    "$name:$(link.line): $url names a file; use $(README_BLOB)$path",
                )
            end
        end
    end
    problems
end

function package_heading_problems(text, name; root=README_ROOT)
    problems = String[]
    headings = Dict{String,String}()
    for line in split(blank_fences(text), '\n')
        found = match(r"^#{2,4} \[([^\]]+)\]\((https://github\.com/[^)]+)\)", line)
        found === nothing ||
            (headings[String(found.captures[2])] = String(found.captures[1]))
    end
    for (directory, proof) in README_PACKAGES
        url = README_TREE * directory
        haskey(headings, url) ||
            push!(problems, "$name: no heading links $directory to $url")
        isfile(joinpath(root, directory, proof)) ||
            push!(problems, "$name: $directory has no $proof")
    end
    for url in keys(headings)
        startswith(url, README_TREE) || continue
        isdir(joinpath(root, url[(length(README_TREE)+1):end])) ||
            push!(problems, "$name: heading link $url names a missing directory")
    end
    problems
end

# A README reads at a glance: prose blocks stay short, Quick start comes
# first, and the non-goals and support lines have their own sections.
const README_WALL = 240

# Paragraphs and list items outside code, tables and headings, with the line
# each one starts on. The contents line is a row of links, so it is skipped.
function prose_blocks(text)
    blocks = Tuple{Int,String}[]
    current = String[]
    start = 0
    function finish!()
        isempty(current) || push!(blocks, (start, join(current, ' ')))
        empty!(current)
    end
    for (number, line) in enumerate(split(resolved_prose(text), '\n'; keepempty=true))
        stripped = strip(line)
        if isempty(stripped) ||
           startswith(stripped, '|') ||
           startswith(stripped, '<') ||
           occursin(r"^#{1,6} ", stripped)
            finish!()
            continue
        end
        item = match(r"^(?:[-*]|\d+\.) (.*)$", stripped)
        if item !== nothing
            finish!()
            start = number
            push!(current, String(item.captures[1]))
            continue
        end
        isempty(current) && (start = number)
        push!(current, String(stripped))
    end
    finish!()
    [block for block in blocks if !startswith(block[2], "**Contents**")]
end

function rendered_length(block)
    text = replace(block, r"\[((?:[^\[\]]|\[[^\]]*\])+)\]\([^)]*\)" => s"\1")
    length(replace(text, "`" => ""))
end

function wall_problems(text, name)
    [
        "$name:$number: a prose block of $(rendered_length(block)) characters exceeds $README_WALL"
        for (number, block) in prose_blocks(text) if rendered_length(block) > README_WALL
    ]
end

function structure_problems(text, name)
    sections = String[
        strip(found.captures[1]) for found in eachmatch(r"^## (.+)$"m, blank_fences(text))
    ]
    problems = String[]
    if !isempty(sections) && first(sections) != "Quick start"
        push!(
            problems,
            "$name: the first section is \"$(first(sections))\"; it must be Quick start",
        )
    end
    for required in ("What it leaves out", "Support and status")
        required in sections || push!(problems, "$name: no \"$required\" section")
    end
    problems
end

function module_names(mod)
    Set(String(name) for name in names(mod) if name != nameof(mod))
end

# Reference page slug prefixes and the public names each one can document.
function api_index()
    Dict(
        "reference/libtmux-" =>
            union(module_names(LibTmux), "filters-" .* module_names(LibTmux.Filters)),
        "workspace/reference/libtmuxworkspace-" => module_names(LibTmuxWorkspace),
        "mcp/reference/libtmuxmcp-" => module_names(LibTmuxMCP),
    )
end

const README_MODULE_PAGES = (
    "reference/libtmux",
    "workspace/reference/libtmuxworkspace",
    "mcp/reference/libtmuxmcp",
)

function api_slug_name(index, path)
    for (prefix, public) in index
        startswith(path, prefix) || continue
        slug = path[(length(prefix)+1):end]
        lowered = Dict(lowercase(name) => name for name in public)
        haskey(lowered, slug) && return lowered[slug]
        trimmed = replace(slug, r"-[a-z0-9]{4}$" => "")
        # Names that differ only by case share a page name with a hash suffix.
        count(name -> lowercase(name) == trimmed, public) > 1 && return trimmed
        return nothing
    end
    :module
end

function api_link_problems(text, name, index, tools)
    problems = String[]
    for link in readme_links(text)
        startswith(link.url, README_SITE) || continue
        path = chopsuffix(link.url[(length(README_SITE)+1):end], "/")
        if startswith(path, "mcp/tools/")
            tool = path[(length("mcp/tools/")+1):end]
            tool in tools || push!(
                problems,
                "$name:$(link.line): $(link.url) names no tool of the catalog",
            )
            continue
        end
        path in README_MODULE_PAGES && continue
        occursin(r"^(workspace/|mcp/)?reference/", path) || continue
        endswith(path, "/glossary") && continue
        found = api_slug_name(index, path)
        found === nothing && push!(
            problems,
            "$name:$(link.line): $(link.url) does not name a public binding",
        )
    end
    problems
end

# Lowercase core names such as `panes` and `window` double as configuration
# keys in the package READMEs, so only distinctive core names count there.
function documented_names(name, index)
    own = Dict(
        "README.md" => "reference/libtmux-",
        "packages/LibTmuxWorkspace/README.md" => "workspace/reference/libtmuxworkspace-",
        "packages/LibTmuxMCP/README.md" => "mcp/reference/libtmuxmcp-",
    )[name]
    public = Set(index[own])
    if name != "README.md"
        union!(
            public,
            [name for name in index["reference/libtmux-"] if occursin(r"[A-Z_]", name)],
        )
    end
    public
end

# A public name mentioned in prose must be linked somewhere in the same README.
# MCP tool names are not library functions; their own checks cover them.
function mentioned_api_problems(text, name, index, tools=String[])
    public = setdiff(documented_names(name, index), tools)
    linked = Set{String}()
    for link in readme_links(text)
        startswith(link.url, README_SITE) || continue
        found = api_slug_name(index, chopsuffix(link.url[(length(README_SITE)+1):end], "/"))
        found isa String && push!(linked, lowercase(found))
    end
    problems = String[]
    mentioned = Set{String}()
    for line in split(resolved_prose(text), '\n')
        for span in eachmatch(r"`([^`]+)`", line)
            token = match(r"^[A-Za-z_][A-Za-z0-9_]*", span.captures[1])
            token === nothing || push!(mentioned, token.match)
        end
    end
    for token in sort!(collect(mentioned))
        token in public &&
            !(lowercase(token) in linked) &&
            push!(
                problems,
                "$name: `$token` is a public name mentioned in prose but never linked to its page",
            )
    end
    problems
end

# A tool named in a table row or list item links to its page, and the page
# names a tool of the catalog.
function tool_link_problems(text, name, tools)
    problems = String[]
    prose = resolved_prose(text)
    for (number, line) in enumerate(split(prose, '\n'))
        occursin(r"^\s*(\||[-*] |\d+\. )", line) || continue
        for tool in tools, found in eachmatch(Regex("`" * tool * "`"), line)
            before = line[1:prevind(line, found.offset)]
            after = line[found.offset:end]
            page = "`$tool`](" * README_SITE * "mcp/tools/" * tool * "/)"
            endswith(before, "[") && startswith(after, page) ||
                push!(problems, "$name:$number: tool $tool is not linked to its page")
        end
    end
    problems
end

function tool_table_problems(text, name, tools)
    rows = String[]
    for line in split(resolved_prose(text), '\n')
        found = match(r"^\| \[`([a-z_]+)`\]\(([^)]+)\) \|", line)
        found === nothing && continue
        page = README_SITE * "mcp/tools/" * found.captures[1] * "/"
        found.captures[2] == page ||
            return ["$name: table row $(found.captures[1]) does not link to $page"]
        push!(rows, String(found.captures[1]))
    end
    isempty(rows) && return String[]
    missing_rows = setdiff(tools, rows)
    extra_rows = setdiff(rows, tools)
    problems =
        ["$name: the tool table lacks $tool" for tool in sort!(collect(missing_rows))]
    append!(problems, ["$name: the tool table lists unknown $tool" for tool in extra_rows])
    problems
end

function help_text(program)
    output, errors = IOBuffer(), IOBuffer()
    code =
        program == "libtmux-mcp" ? LibTmuxMCP.main(["--help"]; output, err=errors) :
        LibTmuxWorkspace.main(["--help"]; out=output, err=errors)
    code == 0 || error("$program --help exited $code")
    String(take!(output))
end

function help_flags(help)
    Set(
        String(found.captures[1]) for
        found in eachmatch(r"(?<![\w-])(--[a-z][a-z0-9-]*)", help)
    )
end

function shell_words(command)
    try
        Base.shell_split(command)
    catch
        String[]
    end
end

function launcher_program(words)
    isempty(words) && return nothing
    program = basename(strip(words[1], '"'))
    program in ("libtmux-mcp", "libtmux-workspace") ? program : nothing
end

# Arguments a command passes to a launcher, whether it runs it directly or
# registers it with `claude mcp add NAME -- LAUNCHER ARGS...`.
function launcher_arguments(command)
    words = shell_words(command)
    if length(words) > 3 && words[1] == "claude" && words[2:3] == ["mcp", "add"]
        divider = findfirst(==("--"), words)
        divider === nothing && return nothing
        words = words[(divider+1):end]
    end
    program = launcher_program(words)
    program === nothing ? nothing : (program, words[2:end])
end

function flag_problems(text, name, helps)
    problems = String[]
    for step in readme_steps(text)
        found = launcher_arguments(step.command)
        found === nothing && continue
        program, arguments = found
        for word in arguments
            startswith(word, "--") || continue
            flag = first(split(word, '='; limit=2))
            flag in helps[program] ||
                push!(problems, "$name: $flag is not an option of $program")
        end
    end
    for fence in readme_fences(text)
        fence.marker == "mcp-config" || continue
        for server in values(JSON.parse(fence.body)["mcpServers"]), word in server["args"]
            startswith(word, "--") || continue
            word in helps["libtmux-mcp"] ||
                push!(problems, "$name: $word is not an option of libtmux-mcp")
        end
    end
    # Flags named in prose belong to the package the README documents.
    program = if name == "packages/LibTmuxMCP/README.md"
        "libtmux-mcp"
    elseif name == "packages/LibTmuxWorkspace/README.md"
        "libtmux-workspace"
    end
    if program !== nothing
        for found in eachmatch(r"`(--[a-z][a-z0-9-]*)[^`]*`", blank_fences(text))
            found.captures[1] in README_JULIA_FLAGS && continue
            found.captures[1] in helps[program] ||
                push!(problems, "$name: $(found.captures[1]) is not an option of $program")
        end
    end
    problems
end

function marker_problems(text, name)
    problems = String[]
    fences = readme_fences(text)
    for found in eachmatch(r"^<!-- (file: \S+|mcp-config) -->$"m, text)
        marked = [fence for fence in fences if fence.marker == found.captures[1]]
        isempty(marked) &&
            push!(problems, "$name: marker $(found.captures[1]) precedes no code block")
    end
    for fence in fences
        fence.marker == "mcp-config" || continue
        try
            servers = JSON.parse(fence.body)["mcpServers"]
            all(
                server -> haskey(server, "command") && haskey(server, "args"),
                values(servers),
            ) || push!(problems, "$name: an mcpServers entry lacks command or args")
        catch
            push!(
                problems,
                "$name:$(fence.line): the MCP client configuration is not valid JSON",
            )
        end
    end
    problems
end

function static_problems(name, text, tools, index, helps; root=README_ROOT)
    problems = String[]
    append!(problems, console_problems(text, name))
    append!(problems, fence_link_problems(text, name))
    append!(problems, link_target_problems(text, name; root))
    append!(problems, repo_link_problems(text, name; root))
    append!(problems, api_link_problems(text, name, index, tools))
    append!(problems, mentioned_api_problems(text, name, index, tools))
    append!(problems, tool_link_problems(text, name, tools))
    append!(problems, tool_table_problems(text, name, tools))
    append!(problems, marker_problems(text, name))
    append!(problems, flag_problems(text, name, helps))
    append!(problems, wall_problems(text, name))
    append!(problems, structure_problems(text, name))
    name == "README.md" && append!(problems, package_heading_problems(text, name; root))
    name == "packages/LibTmuxMCP/README.md" &&
        isempty(tool_rows(text)) &&
        push!(problems, "$name: no tool table")
    problems
end

tool_rows(text) = [
    line for
    line in split(resolved_prose(text), '\n') if occursin(r"^\| \[`[a-z_]+`\]\(", line)
]

readme_tools() = collect(LibTmuxMCP._TOOL_NAMES)

function static_check(; root=README_ROOT)
    tools = readme_tools()
    index = api_index()
    helps = Dict(
        program => help_flags(help_text(program)) for
        program in ("libtmux-mcp", "libtmux-workspace")
    )
    problems = String[]
    for name in README_FILES
        append!(
            problems,
            static_problems(
                name,
                read(joinpath(root, name), String),
                tools,
                index,
                helps;
                root,
            ),
        )
    end
    for problem in problems
        println(stderr, "README ", problem)
    end
    isempty(problems) || error("$(length(problems)) README problems; nothing was rewritten")
    println(
        "PASS README links, headings, tool pages, flags and code blocks: ",
        length(README_FILES),
        " files",
    )
end

# --- Running the commands the READMEs print --------------------------------

struct ReadmeSandbox
    root::String
    environment::Dict{String,String}
    tmux::String
end

function sandbox_create()
    root = mktempdir("/tmp"; prefix="ltj-readme-")
    for directory in ("bin", "home", "t", "tool")
        mkpath(joinpath(root, directory))
    end
    tmux = something(Sys.which(get(ENV, "LIBTMUX_TEST_TMUX", "tmux")))
    symlink(realpath(tmux), joinpath(root, "tool", "tmux"))
    for entry in ("packages", "examples")
        symlink(joinpath(README_ROOT, entry), joinpath(root, entry))
    end
    LibTmuxMCP.install_cli(joinpath(root, "bin"))
    LibTmuxWorkspace.install_cli(joinpath(root, "bin"))
    ReadmeSandbox(root, sandbox_environment(ENV, root), joinpath(root, "tool", "tmux"))
end

# Variables that select a server are removed so that a socket exported in the
# caller's shell cannot override the runner's own TMUX_TMPDIR.
function sandbox_environment(parent, root)
    environment = Dict{String,String}(parent)
    for name in collect(keys(environment))
        (name in ("TMUX", "TMUX_PANE") || startswith(name, "LIBTMUX_SOCKET")) &&
            delete!(environment, name)
    end
    environment["HOME"] = joinpath(root, "home")
    environment["TMUX_TMPDIR"] = joinpath(root, "t")
    environment["SHELL"] = "/bin/sh"
    environment["PATH"] =
        join([joinpath(root, "tool"), joinpath(root, "bin"), parent["PATH"]], ':')
    environment
end

function sandbox_sockets(box::ReadmeSandbox)
    directory = joinpath(box.root, "t")
    found = String[]
    for (path, _, files) in walkdir(directory), file in files
        ispath(joinpath(path, file)) &&
            issocket(joinpath(path, file)) &&
            push!(found, joinpath(path, file))
    end
    found
end

function sandbox_close(box::ReadmeSandbox)
    for socket in sandbox_sockets(box)
        # Julia 1.10 defines ignorestatus only for commands, not redirections.
        kill = ignorestatus(setenv(`$(box.tmux) -S $socket kill-server`, box.environment))
        run(pipeline(kill; stdout=devnull, stderr=devnull))
    end
    rm(box.root; recursive=true, force=true)
end

struct ReadmeRun
    status::Int
    stdout::String
    stderr::String
end

function sandbox_run(box::ReadmeSandbox, command::AbstractString)
    out, err = tempname(box.root), tempname(box.root)
    process = run(
        pipeline(
            ignorestatus(setenv(`/bin/sh -c $command`, box.environment; dir=box.root));
            stdout=out,
            stderr=err,
        );
        wait=false,
    )
    if timedwait(() -> process_exited(process), README_DEADLINE; pollint=0.1) != :ok
        kill(process, Base.SIGKILL)
        error("`$command` did not finish within $(README_DEADLINE) seconds")
    end
    ReadmeRun(process.exitcode, read(out, String), read(err, String))
end

# A bare `$ command` with a `text` block after it must print exactly that text.
function output_problem(command, expected, observed)
    expected === nothing && return nothing
    strip(expected) == strip(observed) && return nothing
    "`$command` printed $(repr(observed)), not the documented $(repr(expected))"
end

function json_lines(output)
    [JSON.parse(line) for line in split(chomp(output), '\n') if !isempty(line)]
end

function verify_launcher(box, step, program, arguments, ran)
    command = step.command
    if "--help" in arguments
        ran.status == 0 && startswith(ran.stdout, "Usage: ") ||
            return "`$command` did not print usage"
        return nothing
    end
    subcommand = isempty(arguments) ? "" : arguments[1]
    if program == "libtmux-workspace"
        ran.status == 0 || return "`$command` exited $(ran.status): $(ran.stderr)"
        if subcommand == "validate"
            ran.stdout == "valid\n" || return "`$command` did not print valid"
        elseif subcommand == "plan"
            steps = json_lines(ran.stdout)
            !isempty(steps) &&
            all(item -> haskey(item, "action"), steps) &&
            steps[1]["action"] == "create_session" ||
                return "`$command` did not print one plan step per line"
        elseif subcommand == "load"
            ran.stdout == "loaded\n" || return "`$command` did not print loaded"
        elseif subcommand == "freeze"
            frozen = if occursin(r" > (\S+)\s*$", command)
                read(joinpath(box.root, match(r" > (\S+)\s*$", command).captures[1]), String)
            else
                ran.stdout
            end
            startswith(frozen, "session_name: \"") ||
                return "`$command` did not freeze a workspace"
        else
            return "`$command` names no known subcommand"
        end
    end
    output_problem(command, step.output, ran.stdout)
end

# --- MCP client ------------------------------------------------------------

mutable struct McpClient
    process::Base.Process
    lines::Channel{Union{Nothing,String}}
    errors::String
    identity::Int
end

function mcp_open(box::ReadmeSandbox, command::Cmd)
    errors = tempname(box.root)
    process = open(pipeline(setenv(command, box.environment); stderr=errors), "r+")
    lines = Channel{Union{Nothing,String}}(Inf)
    @async begin
        try
            for line in eachline(process.out)
                put!(lines, line)
            end
        finally
            put!(lines, nothing)
        end
    end
    McpClient(process, lines, errors, 0)
end

function mcp_receive(client::McpClient)
    timedwait(() -> isready(client.lines), README_DEADLINE; pollint=0.05) == :ok ||
        error("the MCP launcher did not answer within $(README_DEADLINE) seconds")
    line = take!(client.lines)
    line === nothing && error("the MCP launcher exited before answering")
    JSON.parse(line)
end

function mcp_send(client::McpClient, method, params=Dict{String,Any}(); notify=false)
    message = Dict{String,Any}("jsonrpc" => "2.0", "method" => method, "params" => params)
    notify || (message["id"] = (client.identity += 1))
    println(client.process.in, JSON.json(message))
    flush(client.process.in)
    notify ? nothing : mcp_receive(client)
end

function mcp_call(client, name, arguments=Dict{String,Any}())
    reply = mcp_send(client, "tools/call", Dict("name" => name, "arguments" => arguments))
    haskey(reply, "result") || error("tools/call $name returned $(JSON.json(reply))")
    reply["result"]
end

function default_tools(help)
    found = match(r"Default tools: ([a-z_, ]+)\.", help)
    found === nothing && error("libtmux-mcp --help names no default tools")
    String.(split(found.captures[1], ", "))
end

function option_values(words, flag)
    [words[index+1] for index = 1:(length(words)-1) if words[index] == flag]
end

# Starts the launcher as a client would and checks what the README promises:
# the catalog equals the --tool list (or the default), --caller-pane supplies
# a target, and --allow-pane denies other panes.
function mcp_handshake(box::ReadmeSandbox, command::Cmd, arguments, help)
    client = mcp_open(box, command)
    try
        first_reply = mcp_send(
            client,
            "initialize",
            Dict(
                "protocolVersion" => "2025-11-25",
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict("name" => "readme-check", "version" => "1"),
            ),
        )
        result = first_reply["result"]
        result["protocolVersion"] == "2025-11-25" &&
        result["serverInfo"]["name"] == "libtmux" ||
            error("the launcher did not complete the initialize handshake")
        mcp_send(client, "notifications/initialized"; notify=true)
        listed = mcp_send(client, "tools/list")["result"]["tools"]
        observed = sort!(String[tool["name"] for tool in listed])
        requested = option_values(arguments, "--tool")
        expected = sort!(isempty(requested) ? default_tools(help) : requested)
        observed == expected || error(
            "the launcher serves $(join(observed, ", ")), not $(join(expected, ", "))",
        )
        caller = option_values(arguments, "--caller-pane")
        allowed = option_values(arguments, "--allow-pane")
        if "list_panes" in expected
            listing = mcp_call(client, "list_panes")
            get(listing, "isError", false) &&
                error("list_panes failed: $(JSON.json(listing))")
            panes = listing["structuredContent"]["panes"]
            isempty(panes) && error("list_panes found no pane on the README's server")
            isempty(caller) ||
                any(pane -> pane["caller"] === true, panes) ||
                error("--caller-pane did not mark a caller pane")
            if "capture_pane" in expected
                isempty(caller) || begin
                    captured = mcp_call(client, "capture_pane")
                    get(captured, "isError", false) && error(
                        "capture_pane without a target failed: $(JSON.json(captured))",
                    )
                end
                isempty(allowed) || begin
                    target = Dict(
                        "paneId" => "%999999",
                        "generation" => first(panes)["target"]["generation"],
                    )
                    denied = mcp_call(client, "capture_pane", Dict("target" => target))
                    get(denied, "isError", false) &&
                    denied["structuredContent"]["error"]["code"] == "target_denied" ||
                        error("--allow-pane did not deny another pane")
                end
            end
        end
        close(client.process.in)
        timedwait(() -> process_exited(client.process), 30.0; pollint=0.05) == :ok ||
            error("the launcher did not exit after stdin closed")
        client.process.exitcode == 0 ||
            error("the launcher exited $(client.process.exitcode)")
        isempty(read(client.errors, String)) ||
            error("the launcher wrote diagnostics: $(read(client.errors, String))")
    finally
        process_running(client.process) && kill(client.process, Base.SIGKILL)
    end
end

function readme_mcp_command(box, step)
    words = shell_words(step.command)
    divider = findfirst(==("--"), words)
    divider === nothing && error("`$(step.command)` has no `--` before the launcher")
    # A shell re-reads the documented words, so `"$PWD"` expands in the
    # sandbox exactly as it does for a reader.
    after = split(step.command, " -- "; limit=2)[2]
    Cmd(`/bin/sh -c $("exec " * after)`; dir=box.root), words[(divider+2):end]
end

function readme_config_commands(box, fence)
    commands = Tuple{Cmd,Vector{String}}[]
    for server in values(JSON.parse(fence.body)["mcpServers"])
        launcher =
            replace(String(server["command"]), r"^/absolute/path/to/" => box.root * "/")
        arguments = String.(server["args"])
        push!(commands, (Cmd(Cmd([launcher, arguments...]); dir=box.root), arguments))
    end
    commands
end

const README_SETUP = Dict(
    "git" => "checks out the source",
    "cd" => "changes directory",
    "rm" => "removes a staging directory",
)

# Commands that need a network, a release tag or a checkout are accounted for
# here. A command that is neither run nor accounted for fails the check.
function setup_reason(command, name)
    words = shell_words(command)
    isempty(words) && return nothing
    first_word = words[1]
    haskey(README_SETUP, first_word) && return README_SETUP[first_word]
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*=", first_word) && return "assigns a staging variable"
    first_word == "julia" || return nothing
    occursin("Pkg.", command) && return "resolves packages from the network or a checkout"
    occursin("install_cli", command) &&
        return "installs a launcher; this check installs launchers with the same function"
    for word in words
        endswith(word, ".jl") || continue
        directory = dirname(joinpath(README_ROOT, name))
        (isfile(joinpath(directory, word)) || isfile(joinpath(README_ROOT, word))) ||
            error("`$command` names the missing program $word")
        return "runs $word, which its own gate covers"
    end
    return "opens an interactive session"
end

function static_launcher_reason(command)
    occursin(r"--socket [\"']?/", command) ? "uses a socket path you choose" : nothing
end

function run_readme(name, text, helps, cache)
    box = sandbox_create()
    counts = Dict("run" => 0, "client" => 0, "accounted" => 0, "flags" => 0)
    try
        for fence in readme_fences(text)
            fence.marker !== nothing &&
                startswith(fence.marker, "file: ") &&
                write(joinpath(box.root, fence.marker[7:end]), fence.body)
        end
        items = Tuple{Int,Any}[]
        for step in readme_steps(text)
            push!(items, (step.fence.line, step))
        end
        for fence in readme_fences(text)
            fence.marker == "mcp-config" && push!(items, (fence.line, fence))
        end
        sort!(items; by=first)
        for (line, item) in items
            if item isa ReadmeFence
                for (command, arguments) in readme_config_commands(box, item)
                    key = join(arguments, '\0')
                    key in cache || begin
                        mcp_handshake(box, command, arguments, helps["libtmux-mcp-text"])
                        push!(cache, key)
                    end
                    counts["client"] += 1
                    println("PASS $name:$line MCP client configuration starts and answers")
                end
                continue
            end
            command = item.command
            words = shell_words(command)
            launcher = launcher_arguments(command)
            if words[1] == "claude"
                launcher === nothing &&
                    error("$name:$line `$command` does not register a libtmux launcher")
                mcp_command, arguments = readme_mcp_command(box, item)
                key = join(arguments, '\0')
                key in cache || begin
                    mcp_handshake(box, mcp_command, arguments, helps["libtmux-mcp-text"])
                    push!(cache, key)
                end
                counts["client"] += 1
                println(
                    "PASS $name:$line `claude mcp add` launcher starts and serves its tools",
                )
            elseif launcher !== nothing && static_launcher_reason(command) !== nothing
                counts["flags"] += 1
                println(
                    "FLAGS $name:$line $(static_launcher_reason(command)); options checked statically",
                )
            elseif launcher !== nothing || words[1] == "tmux"
                ran = sandbox_run(box, command)
                if launcher !== nothing
                    problem = verify_launcher(box, item, launcher[1], launcher[2], ran)
                    problem === nothing || error("$name:$line $problem")
                else
                    ran.status == 0 ||
                        error("$name:$line `$command` exited $(ran.status): $(ran.stderr)")
                    problem = output_problem(command, item.output, ran.stdout)
                    problem === nothing || error("$name:$line $problem")
                end
                counts["run"] += 1
                println("PASS $name:$line `$command`")
            else
                reason = setup_reason(command, name)
                reason === nothing && error("$name:$line `$command` has no verifier")
                counts["accounted"] += 1
                println(
                    "SKIP $name:$line `$(first(split(command, '\n'))[1:min(end, 60)])`: $reason",
                )
            end
        end
    finally
        sandbox_close(box)
    end
    @assert !ispath(box.root)
    println(
        "PASS $name: ",
        counts["run"],
        " commands run, ",
        counts["client"],
        " MCP clients started, ",
        counts["flags"],
        " checked against --help only, ",
        counts["accounted"],
        " accounted for",
    )
end

# A README whose documented output or command cannot be verified must fail.
function commands_negative_control(helps)
    workspace = "<!-- file: w.yaml -->\n\n```yaml\nsession_name: demo\nwindows:\n  - window_name: w\n```\n\n"
    planted = Dict(
        "a command with no verifier" =>
            ("```console\n\$ frobnicate --now\n```\n", "has no verifier"),
        "output that differs from the documented text" => (
            workspace *
            "```console\n\$ bin/libtmux-workspace validate w.yaml\n```\n\n```text\ninvalid\n```\n",
            "printed",
        ),
    )
    for (label, (text, fragment)) in planted
        failure = try
            run_readme("planted.md", text, helps, Set{String}())
            nothing
        catch error
            error isa ErrorException ? error.msg : rethrow()
        end
        failure !== nothing && occursin(fragment, failure) ||
            error("negative control failed: $label was not reported ($failure)")
    end
    println("PASS planted unverifiable commands and output drift are reported")
end

function commands_check()
    helps = Dict{String,Any}(
        "libtmux-mcp" => help_flags(help_text("libtmux-mcp")),
        "libtmux-workspace" => help_flags(help_text("libtmux-workspace")),
        "libtmux-mcp-text" => help_text("libtmux-mcp"),
    )
    commands_negative_control(helps)
    cache = Set{String}()
    for name in README_FILES
        run_readme(name, read(joinpath(README_ROOT, name), String), helps, cache)
    end
end

# --- Live URLs ---------------------------------------------------------------

function url_status(url)
    format = "%{http_code}"
    command = `curl --silent --show-error --output /dev/null --max-time 30 --write-out $format $url`
    try
        parse(Int, read(command, String))
    catch
        0
    end
end

# Every absolute URL must answer 200 without a redirect. The control proves
# that a page the site does not publish is not reported as 200.
function links_check()
    control = README_SITE * "mcp/tools/no_such_tool/"
    url_status(control) == 200 &&
        error("$control returned 200, so a 200 proves nothing about these links")
    failures = String[]
    seen = Set{String}()
    for name in README_FILES
        text = read(joinpath(README_ROOT, name), String)
        for link in readme_links(text)
            startswith(link.url, "http") || continue
            url = first(split(link.url, '#'; limit=2))
            url in seen && continue
            push!(seen, url)
            status = url_status(url)
            status == 200 || push!(failures, "$name:$(link.line): $url returned $status")
        end
    end
    foreach(failure -> println(stderr, "README ", failure), failures)
    isempty(failures) || error("$(length(failures)) README links did not return 200")
    println(
        "PASS ",
        length(seen),
        " distinct README URLs returned 200; the control did not",
    )
end

# --- Negative controls -----------------------------------------------------

function expect_problem(label, problems, fragment)
    any(problem -> occursin(fragment, problem), problems) ||
        error("$label: expected a problem containing $(repr(fragment)), got $problems")
end

function expect_clean(label, problems)
    isempty(problems) || error("$label: a clean control reported $problems")
end

function self_test()
    tools = readme_tools()
    index = api_index()
    helps = Dict(
        "libtmux-mcp" => help_flags(help_text("libtmux-mcp")),
        "libtmux-workspace" => help_flags(help_text("libtmux-workspace")),
    )
    page = README_SITE * "mcp/tools/list_panes/"
    linked = "- [`list_panes`]($page) lists panes\n"
    expect_clean("linked tool", tool_link_problems(linked, "t.md", tools))
    expect_problem(
        "unlinked tool",
        tool_link_problems("- `list_panes` lists panes\n", "t.md", tools),
        "list_panes is not linked",
    )
    expect_problem(
        "wrong tool page",
        tool_link_problems(
            "- [`list_panes`]($(README_SITE)mcp/tools/send_keys/) lists panes\n",
            "t.md",
            tools,
        ),
        "list_panes is not linked",
    )
    expect_problem(
        "page of no tool",
        api_link_problems("[x]($(README_SITE)mcp/tools/bogus/)\n", "t.md", index, tools),
        "names no tool",
    )
    row = "| [`list_panes`]($page) | x |\n"
    expect_problem("short tool table", tool_table_problems(row, "t.md", tools), "lacks")
    expect_clean(
        "full tool table",
        tool_table_problems(
            join(["| [`$t`]($(README_SITE)mcp/tools/$t/) | x |\n" for t in tools], ""),
            "t.md",
            tools,
        ),
    )

    two = "```console\n\$ one\n\$ two\n```\n"
    expect_problem("two commands", console_problems(two, "t.md"), "more than one command")
    expect_clean(
        "one chained command",
        console_problems("```console\n\$ one \\\n    --flag\n```\n", "t.md"),
    )
    expect_problem(
        "link in a code block",
        fence_link_problems("```julia\n[x](https://example.com)\n```\n", "t.md"),
        "contains a Markdown link",
    )

    command = "```console\n\$ bin/libtmux-mcp --socket-name a --nope b\n```\n"
    expect_problem("unknown flag", flag_problems(command, "t.md", helps), "--nope")
    expect_clean(
        "known flag",
        flag_problems(
            "```console\n\$ claude mcp add t -- \"\$PWD/bin/libtmux-mcp\" --socket-name a\n```\n",
            "t.md",
            helps,
        ),
    )

    expect_problem(
        "unlinked public name",
        mentioned_api_problems("Call `with_server` first.\n", "README.md", index),
        "with_server",
    )
    expect_clean(
        "tool name that is also a function",
        mentioned_api_problems("Call `send_keys` first.\n", "README.md", index, tools),
    )
    expect_clean(
        "linked public name",
        mentioned_api_problems(
            "Call [`with_server`][w] first.\n\n[w]: $(README_SITE)reference/libtmux-with_server/\n",
            "README.md",
            index,
        ),
    )
    expect_problem(
        "page of no public name",
        api_link_problems(
            "[x]($(README_SITE)reference/libtmux-not_a_function/)\n",
            "t.md",
            index,
            tools,
        ),
        "does not name a public binding",
    )
    expect_clean(
        "page of a case-collided name",
        api_link_problems(
            "[x]($(README_SITE)reference/libtmux-snapshot-1gv6/)\n",
            "t.md",
            index,
            tools,
        ),
    )

    mktempdir() do directory
        write(joinpath(directory, "a.md"), "text\n")
        mkpath(joinpath(directory, "pkg"))
        blob(path) = "[x]($(README_BLOB)$path)"
        expect_problem(
            "relative repository link",
            repo_link_problems("[x](a.md)\n", "t.md"; root=directory),
            "relative repository link",
        )
        expect_problem(
            "relative link with an anchor",
            repo_link_problems("[x](pkg/a.md#top)\n", "t.md"; root=directory),
            "relative repository link",
        )
        expect_problem(
            "relative reference-style link",
            repo_link_problems("[x][r]\n\n[r]: a.md\n", "t.md"; root=directory),
            "relative repository link",
        )
        expect_problem(
            "absolute link to a missing path",
            repo_link_problems(blob("gone.md") * "\n", "t.md"; root=directory),
            "names a missing path",
        )
        expect_problem(
            "blob link to a directory",
            repo_link_problems(blob("pkg") * "\n", "t.md"; root=directory),
            "names a directory",
        )
        expect_problem(
            "tree link to a file",
            repo_link_problems("[x]($(README_TREE)a.md)\n", "t.md"; root=directory),
            "names a file",
        )
        expect_problem(
            "relative link reaches the static check",
            static_problems(
                "README.md",
                "[x](a.md)\n",
                tools,
                index,
                helps;
                root=directory,
            ),
            "relative repository link",
        )
        expect_clean(
            "absolute, anchor and external links",
            repo_link_problems(
                blob("a.md#top") *
                " [y]($(README_TREE)pkg) [z](#top) [w](https://example.com/a.md)\n",
                "t.md";
                root=directory,
            ),
        )
    end

    mktempdir() do directory
        write(joinpath(directory, "t.md"), "# Title\n")
        text = "# Title\n\n[a](#title) [b](#nothing) [c](missing.md) [d](t.md)\n"
        problems = link_target_problems(text, "t.md"; root=directory)
        expect_problem("missing anchor", problems, "no heading for anchor #nothing")
        expect_problem("missing file", problems, "missing.md")
        @assert length(problems) == 2
        heading = "## [Core]($(README_TREE)src): the core\n"
        mkpath(joinpath(directory, "src"))
        write(joinpath(directory, "src", "LibTmux.jl"), "")
        expect_problem(
            "missing package heading",
            package_heading_problems(heading, "t.md"; root=directory),
            "no heading links ext",
        )
        expect_clean(
            "present package heading",
            filter(
                problem -> occursin("src", problem),
                package_heading_problems(heading, "t.md"; root=directory),
            ),
        )
    end

    wall = "Sentence one is here. " ^ 14
    expect_problem("a wall of prose", wall_problems(wall, "t.md"), "exceeds")
    expect_problem("a wall in a list item", wall_problems("- $wall\n", "t.md"), "exceeds")
    expect_clean("short prose", wall_problems("Sentence one is here. " ^ 5, "t.md"))
    expect_clean(
        "link targets are not prose",
        wall_problems("[a](https://example.com/" * "x" ^ 300 * ")\n", "t.md"),
    )
    expect_clean("a wall inside a code block", wall_problems("```\n$wall\n```\n", "t.md"))
    expect_clean("a contents line", wall_problems("**Contents** — $wall\n", "t.md"))
    sections = "## Quick start\n\n## What it leaves out\n\n## Support and status\n"
    expect_clean("ordered sections", structure_problems(sections, "t.md"))
    expect_problem(
        "Quick start second",
        structure_problems("## Install\n\n" * sections, "t.md"),
        "must be Quick start",
    )
    expect_problem(
        "no non-goals",
        structure_problems("## Quick start\n\n## Support and status\n", "t.md"),
        "What it leaves out",
    )
    expect_problem(
        "no support",
        structure_problems("## Quick start\n\n## What it leaves out\n", "t.md"),
        "Support and status",
    )

    decoys = Dict(
        "TMUX" => "/decoy,1,0",
        "TMUX_PANE" => "%9",
        "LIBTMUX_SOCKET" => "decoy",
        "LIBTMUX_SOCKET_PATH" => "/decoy",
        "LIBTMUX_TEST_TMUX" => "tmux",
        "TMUX_TMPDIR" => "/decoy",
        "PATH" => "/usr/bin",
    )
    box = sandbox_environment(decoys, "/sandbox-root")
    @assert !any(name -> name in keys(box), ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET"))
    @assert !haskey(box, "LIBTMUX_SOCKET_PATH")
    @assert box["TMUX_TMPDIR"] == "/sandbox-root/t" && box["LIBTMUX_TEST_TMUX"] == "tmux"
    @assert box["PATH"] == "/sandbox-root/tool:/sandbox-root/bin:/usr/bin"

    step = ReadmeStep("x", ReadmeFence("console", "\$ x\n", 1, nothing), "valid\n")
    @assert output_problem("x", "valid\n", "valid\n") === nothing
    @assert output_problem("x", "valid\n", "invalid\n") !== nothing
    @assert output_problem("x", nothing, "anything") === nothing
    @assert heading_slug("[LibTmux](https://x.test): the core library") ==
            "libtmux-the-core-library"
    @assert heading_slug("Install v0.1.0-alpha.1") == "install-v010-alpha1"
    @assert heading_slug("[`snapshot`][snapshot]: what tmux has now") ==
            "snapshot-what-tmux-has-now"
    @assert heading_slug("[`LibTmux`](https://x.test): the core library") ==
            "libtmux-the-core-library"
    @assert setup_reason("git clone x", "README.md") !== nothing
    @assert setup_reason("bin/libtmux-mcp --help", "README.md") === nothing
    println("PASS planted README failures are reported and clean controls stay clean")
end

function readme_main(arguments)
    mode = length(arguments) == 1 ? only(arguments) : ""
    mode in ("static", "commands", "links", "self-test") ||
        error("usage: check-readme-commands.jl [static|commands|links|self-test]")
    if mode == "self-test"
        self_test()
    elseif mode == "static"
        self_test()
        static_check()
    elseif mode == "links"
        links_check()
    else
        commands_check()
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && readme_main(ARGS)

using SHA

const DOC_EXAMPLE_ROOT = dirname(@__DIR__)
const DOC_EXAMPLE_LANGUAGES =
    Set(("julia", "jl", "jldoctest", "@example", "@repl", "@eval", "@setup"))

function document_fences(text, path)
    entries = NamedTuple[]
    lines = split(replace(text, "\r\n"=>"\n"), '\n'; keepempty=true)
    delimiter = nothing
    info = ""
    start = 0
    for (number, line) in enumerate(lines)
        if delimiter === nothing
            matched = match(r"^\s*(`{3,}|~{3,})([^`~]*)$", line)
            matched === nothing && continue
            delimiter, info = String.(matched.captures)
            info = strip(info)
            start = number
        elseif occursin(
            Regex(
                "^\\s*" * first(delimiter) * "{" * string(length(delimiter)) * ",}\\s*\$",
            ),
            line,
        )
            language = isempty(info) ? "" : first(split(info))
            if language in DOC_EXAMPLE_LANGUAGES
                code = join(lines[(start+1):(number-1)], '\n') * "\n"
                push!(
                    entries,
                    (;
                        path,
                        ordinal=length(entries)+1,
                        line=start,
                        info,
                        language,
                        code,
                        fingerprint=bytes2hex(sha256(info * "\n" * code)),
                    ),
                )
            end
            delimiter = nothing
        end
    end
    delimiter === nothing || error("Unclosed fence at $path:$start")
    entries
end

const DOC_SNIPPETS = Dict(
    ("docs/criteria-wire.md", 1) => (
        kind=:executable,
        gate=:doctest,
        fingerprint="5e39c218fce04c6abd60f8cadc6cf9744ae443167bbd2a961640b38c8a9c468d",
        source="",
        note="Pure criteria wire round trip",
    ),
    ("docs/criteria-wire.md", 2) => (
        kind=:executable,
        gate=:doctest,
        fingerprint="fdfc97d8a85c504af4f6ac0dbd2f51375f2291a3b172717ca6bd54410049a56a",
        source="",
        note="JSON 1.9 criteria codec round trip",
    ),
    ("docs/projections.md", 1) => (
        kind=:illustrative,
        gate=:none,
        fingerprint="4d56cc0a335200ba2b1e277d4745342edc3aeae8edc64cc12d6b4757f0f07d5f",
        source="",
        note="Caller supplies a captured Snapshot to pane_rows",
    ),
    ("docs/projections.md", 2) => (
        kind=:illustrative,
        gate=:none,
        fingerprint="b88c4bc32b35365f8f073940716b34bdeee28876ec6a1e5a1b2d64b0e31ddfd1",
        source="",
        note="Caller supplies a captured Snapshot and Tables 1.14",
    ),
    ("docs/src/index.md", 1) => (
        kind=:derived,
        gate=:external,
        fingerprint="cd8ae36ca441a4fc58c0251156380640005861762c32349331a13cc8b5a08872",
        source="examples/owned_capture.jl",
        note="",
    ),
    ("docs/src/observations.md", 1) => (
        kind=:derived,
        gate=:external,
        fingerprint="22027eab236347ca0ca20a9176c1848749fe344ef5191cfff38443480a5f4bc8",
        source="examples/output_stream.jl",
        note="",
    ),
    ("docs/src/ownership.md", 1) => (
        kind=:derived,
        gate=:external,
        fingerprint="f12f354402c7599c75c906532ad9dbabf247dd1d62a25645202ecaaea535e142",
        source="examples/control_cancel.jl",
        note="",
    ),
    ("docs/src/queries.md", 1) => (
        kind=:derived,
        gate=:external,
        fingerprint="653f6f18181230c5bf0157924b0cea02566465c38d1d6185caaff8d25095c45e",
        source="examples/shared_windows.jl",
        note="",
    ),
    ("docs/src/queries.md", 2) => (
        kind=:executable,
        gate=:doctest,
        fingerprint="d49a18ba90a5196cd097cfc4e8c72b50de4ee7b330988664f36a288776db8670",
        source="",
        note="Pure callable criteria and wire conversion",
    ),
    ("docs/src/workspaces.md", 1) => (
        kind=:derived,
        gate=:external,
        fingerprint="30416c46d48606ae135881798533f750bf53a945e194283b8509f3683b911d95",
        source="packages/LibTmuxWorkspace/examples/owned_load.jl",
        note="",
    ),
    ("packages/LibTmuxWorkspace/README.md", 1) => (
        kind=:executable,
        gate=:doctest,
        fingerprint="ca57abb7982931017f8f56d823101b8097adea66ba0e9c46653b1198f31c44cf",
        source="",
        note="Private copy of the shipped workspace configuration",
    ),
    ("packages/LibTmuxWorkspace/README.md", 2) => (
        kind=:illustrative,
        gate=:none,
        fingerprint="3e1a8b6a9a26fbebbe1ed64d528d142abe213658c96c24d95d9fb1a3ecf1ec27",
        source="",
        note="Caller supplies an existing explicit server and workspace.yaml",
    ),
    ("packages/LibTmuxWorkspace/README.md", 3) => (
        kind=:illustrative,
        gate=:none,
        fingerprint="32a8ef52caec6bb60ca7086b5792601b3db45efaae7ab92554817aee122c5bda",
        source="",
        note="Caller chooses an installation directory; owned launcher tests are separate",
    ),
    ("src/formats.jl", 1) => (
        kind=:illustrative,
        gate=:none,
        fingerprint="bc1e99dde60cc5f77405df4dd482b2ad03a6a8a44cc9dc7446cd051f4ea705b6",
        source="",
        note="Caller supplies an existing server and exact pane_ref",
    ),
)

const DOC_PROGRAMS = Dict(
    "examples/owned_capture.jl"=>"owned tmux: create, capture and cleanup",
    "examples/shared_windows.jl"=>"owned tmux: shared links and captured predicates",
    "examples/control_cancel.jl"=>"owned tmux: cancellation and control cleanup",
    "examples/output_stream.jl"=>"owned tmux: output observation and baseline",
    "packages/LibTmuxWorkspace/examples/plan.jl"=>"pure planning of the shipped configuration",
    "packages/LibTmuxWorkspace/examples/owned_load.jl"=>"owned tmux: apply, freeze and cleanup",
)

function shipped_documents(root)
    files = [joinpath(root, name) for name in readdir(root) if endswith(name, ".md")]
    for entry in ("docs", "examples", "packages", "benchmark")
        base = joinpath(root, entry)
        isdir(base) || continue
        for (directory, directories, names) in walkdir(base)
            filter!(
                name ->
                    !(name in ("build", "results", "__pycache__", "node_modules", ".git")),
                directories,
            )
            append!(
                files,
                [joinpath(directory, name) for name in names if endswith(name, ".md")],
            )
        end
    end
    sources = [joinpath(root, "src"), joinpath(root, "ext")]
    for package in readdir(joinpath(root, "packages"))
        append!(
            sources,
            [joinpath(root, "packages", package, entry) for entry in ("src", "ext")],
        )
    end
    for base in sources
        isdir(base) || continue
        for (directory, _, names) in walkdir(base)
            append!(
                files,
                [joinpath(directory, name) for name in names if endswith(name, ".jl")],
            )
        end
    end
    sort!(unique!(files))
end

function shipped_programs(root)
    bases = [joinpath(root, "examples")]
    append!(
        bases,
        [
            joinpath(root, "packages", name, "examples") for
            name in readdir(joinpath(root, "packages"))
        ],
    )
    files = String[]
    for base in bases
        isdir(base) || continue
        for (directory, _, names) in walkdir(base), name in names
            endswith(name, ".jl") && push!(files, relpath(joinpath(directory, name), root))
        end
    end
    sort!(files)
end

function derived_source(entry, root)
    matched = match(r"(?s)read\(joinpath\(@__DIR__,\s*(.*?)\),\s*String\)", entry.code)
    matched === nothing &&
        error("Derived fence must read one literal example path: $(entry.path)")
    arguments = matched.captures[1]
    parts = [part.captures[1] for part in eachmatch(r"\"([^\"]+)\"", arguments)]
    !isempty(parts) && occursin(r"^[\s,]*$", replace(arguments, r"\"[^\"]+\""=>"")) ||
        error("Derived example path must contain literal components")
    relpath(normpath(joinpath(root, dirname(entry.path), parts...)), root)
end

syntax_error(value) =
    value isa Expr && (value.head in (:error, :incomplete) || any(syntax_error, value.args))

function validate_snippets(entries, specifications, root)
    observed = Set((entry.path, entry.ordinal) for entry in entries)
    expected = Set(keys(specifications))
    observed == expected || error(
        "Snippet inventory changed; unclassified=$(sort!(collect(setdiff(observed, expected)))), missing=$(sort!(collect(setdiff(expected, observed))))",
    )
    for entry in entries
        spec = specifications[(entry.path, entry.ordinal)]
        entry.fingerprint == spec.fingerprint || error(
            "Snippet changed at $(entry.path):$(entry.line); review its classification and runtime gate before updating the fingerprint",
        )
        if spec.kind === :derived
            source = derived_source(entry, root)
            source == spec.source && haskey(DOC_PROGRAMS, source) || error(
                "Derived snippet does not reference its registered executable program",
            )
            isfile(joinpath(root, source)) || error("Derived example is missing: $source")
        elseif spec.gate === :doctest
            entry.language == "jldoctest" ||
                error("Pure executable snippets must use doctests")
        elseif spec.kind === :illustrative
            syntax_error(Meta.parseall(entry.code; filename=entry.path)) &&
                error("Illustrative snippet has invalid Julia syntax: $(entry.path)")
        else
            error("Unknown snippet classification")
        end
    end
    entries
end

function linked_programs(documents, root)
    linked = Set{String}()
    for path in documents
        endswith(path, ".md") || continue
        for matched in eachmatch(r"\[[^\]]+\]\(([^)]+)\)", read(path, String))
            target = first(split(matched.captures[1], '#'; limit=2))
            endswith(target, ".jl") || continue
            push!(linked, relpath(normpath(joinpath(dirname(path), target)), root))
        end
    end
    linked
end

function doc_example_check(; root=DOC_EXAMPLE_ROOT)
    documents = shipped_documents(root)
    entries = NamedTuple[]
    for path in documents
        append!(entries, document_fences(read(path, String), relpath(path, root)))
    end
    validate_snippets(entries, DOC_SNIPPETS, root)
    programs = shipped_programs(root)
    programs == sort!(collect(keys(DOC_PROGRAMS))) ||
        error("Executable example inventory changed")
    links = linked_programs(documents, root)
    all(program -> program in links, programs) ||
        error("Every shipped Julia program needs a documentation link")
    entries
end

function inventory_text(entries)
    output = IOBuffer()
    println(output, "# Julia example inventory\n")
    println(
        output,
        "Generated by `dev/check-doc-examples.jl inventory`. The fast `check` command",
    )
    println(
        output,
        "checks discovery, reviewed snippet fingerprints, literal example inclusions,",
    )
    println(output, "and program links. It does not establish runtime correctness.\n")
    println(
        output,
        "| Document and Julia fence | Class | Runtime gate | Source or prerequisite |",
    )
    println(output, "| --- | --- | --- | --- |")
    for entry in entries
        spec = DOC_SNIPPETS[(entry.path, entry.ordinal)]
        location = "[$(entry.path)](../$(entry.path)) ($(entry.ordinal))"
        detail = isempty(spec.source) ? spec.note : "[$(spec.source)](../$(spec.source))"
        gate =
            spec.gate === :doctest ? "snippet doctests" :
            spec.kind === :derived ? "external example runner" :
            "exact snippet not executed"
        println(output, "| $location | $(spec.kind) | $gate | $detail |")
    end
    println(output, "\n## Executable programs\n")
    println(
        output,
        "The external consumer checker discovers and executes all six programs from",
    )
    println(
        output,
        "exported packages. Preparation and normal runtime execution are separate",
    )
    println(output, "from this inventory check.\n")
    println(output, "| Program | Behavior |")
    println(output, "| --- | --- |")
    for path in sort!(collect(keys(DOC_PROGRAMS)))
        println(output, "| [$path](../$path) | $(DOC_PROGRAMS[path]) |")
    end
    println(output, "\n## Runtime boundaries\n")
    println(
        output,
        "`dev/check-doc-examples.jl doctest` runs the four pure fences exactly as",
    )
    println(
        output,
        "shipped through Documenter, with a private copy of the workspace fixture.",
    )
    println(output, "Use the prepared quality project containing Documenter, JSON and both")
    println(output, "consumer packages; dependency resolution stays outside the check.\n")
    println(
        output,
        "The five derived fences read their executable programs directly during the",
    )
    println(
        output,
        "manual build. `dev/check-consumers.jl examples STAGE` supplies their separate",
    )
    println(
        output,
        "owned-tmux runtime check. `dev/check-consumers.jl launchers STAGE` checks both",
    )
    println(
        output,
        "installed consumer launchers; shell command blocks are not Julia fences.\n",
    )
    println(
        output,
        "Illustrative snippets require caller-owned context or installation choices.",
    )
    println(
        output,
        "Their syntax and drift are checked; exact execution is not claimed. Existing",
    )
    println(
        output,
        "API tests do not replace that missing snippet-level runtime evidence.\n",
    )
    println(
        output,
        "The scan includes Markdown and library source docstrings. Documenter reference",
    )
    println(
        output,
        "directives such as `@autodocs` are not displayed Julia examples; their source",
    )
    println(
        output,
        "docstring fences are included here. A normal manual build and an unfamiliar",
    )
    println(output, "Julia developer's task walkthrough remain separate required checks.")
    String(take!(output))
end

function run_snippet_doctests(entries)
    @eval import Documenter
    mktempdir(; prefix="libtmux-julia-doctests-") do directory
        source = joinpath(directory, "src")
        mkpath(source)
        mkpath(joinpath(directory, "examples"))
        cp(
            joinpath(
                DOC_EXAMPLE_ROOT,
                "packages",
                "LibTmuxWorkspace",
                "examples",
                "workspace.yaml",
            ),
            joinpath(directory, "examples", "workspace.yaml"),
        )
        selected = filter(
            entry -> DOC_SNIPPETS[(entry.path, entry.ordinal)].gate === :doctest,
            entries,
        )
        for (index, entry) in enumerate(selected)
            write(
                joinpath(source, "snippet$index.md"),
                "# $(entry.path), Julia fence $(entry.ordinal)\n\n```$(entry.info)\n$(entry.code)```\n",
            )
        end
        Base.invokelatest(directory) do root
            Documenter.makedocs(;
                root,
                source="src",
                build="build",
                doctest=:only,
                modules=Module[],
                remotes=nothing,
                sitename="Shipped Julia snippets",
            )
        end
        println("PASS ", length(selected), " exact shipped doctest fences; no tmux started")
    end
end

function doc_example_self_test()
    text = "```text\n```julia\n```\n\n~~~~julia\nx = 1\n~~~~\n"
    entries = document_fences(text, "owned.md")
    @assert length(entries) == 1
    @assert only(entries).code == "x = 1\n"
    @assert only(entries).line == 5
    failure = try
        document_fences("```julia\nx = 1\n", "unclosed.md")
        nothing
    catch error
        error
    end
    @assert failure isa ErrorException
    spec = (
        kind=:illustrative,
        gate=:none,
        fingerprint=only(entries).fingerprint,
        source="",
        note="fixture",
    )
    catalog = Dict(("owned.md", 1)=>spec)
    validate_snippets(entries, catalog, DOC_EXAMPLE_ROOT)
    changed = document_fences("```julia\nx = 2\n```\n", "owned.md")
    for (candidate, specifications) in ((changed, catalog), (entries, empty(catalog)))
        failed = try
            validate_snippets(candidate, specifications, DOC_EXAMPLE_ROOT)
            false
        catch
            true
        end
        @assert failed
    end
    println(
        "PASS fence boundaries, unclosed fences, unclassified snippets and reviewed-content drift",
    )
end

function doc_examples_main(arguments)
    mode = isempty(arguments) ? "check" : only(arguments)
    mode in ("check", "inventory", "write", "doctest", "self-test") ||
        error("usage: check-doc-examples.jl [check|inventory|write|doctest|self-test]")
    mode == "self-test" && return doc_example_self_test()
    entries = doc_example_check()
    inventory = inventory_text(entries)
    destination = joinpath(DOC_EXAMPLE_ROOT, "docs", "example-inventory.md")
    if mode == "inventory"
        print(inventory)
    elseif mode == "write"
        write(destination, inventory)
        println("Updated docs/example-inventory.md")
    else
        isfile(destination) && read(destination, String) == inventory || error(
            "Example inventory is stale; run the write mode after reviewing snippet metadata",
        )
        mode == "doctest" && run_snippet_doctests(entries)
        println(
            "PASS discovery/drift: ",
            length(entries),
            " Julia fences and ",
            length(DOC_PROGRAMS),
            " programs; runtime gates remain separate",
        )
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && doc_examples_main(ARGS)

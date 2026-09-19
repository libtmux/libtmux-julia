using Test

const QUALITY_PHASE = isempty(ARGS) ? "quality" : only(ARGS)
if QUALITY_PHASE == "quality"
    import Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, JSON, Tables
elseif QUALITY_PHASE == "format"
    import JuliaFormatter
end

const QUALITY_ROOT = dirname(@__DIR__)
const QUALITY_PACKAGES = ("LibTmux", "LibTmuxWorkspace", "LibTmuxMCP")
const GENERATED_JULIA = Set(["src/criteria_generated.jl"])

function source_files()
    files = String[]
    for entry in ("src", "ext", "test", "examples", "dev", "packages", "docs", "benchmark")
        base = joinpath(QUALITY_ROOT, entry)
        isdir(base) || continue
        for (directory, directories, names) in walkdir(base)
            filter!(name -> !(name in ("build", ".git", "node_modules")), directories)
            for name in names
                endswith(name, ".jl") || continue
                path = joinpath(directory, name)
                relative = relpath(path, QUALITY_ROOT)
                relative in GENERATED_JULIA || push!(files, path)
            end
        end
    end
    sort!(unique!(files))
end

function quality()
    # The driver starts a fresh process; no test fixtures precede this scan.
    packages = [getproperty(@__MODULE__, Symbol(name)) for name in QUALITY_PACKAGES]
    extensions =
        [Base.get_extension(LibTmux, name) for name in (:LibTmuxJSONExt, :LibTmuxTablesExt)]
    @testset "native package quality" begin
        @test all(extension -> extension !== nothing, extensions)
        ambiguities = Test.detect_ambiguities(packages..., extensions...; recursive=true)
        isempty(ambiguities) || foreach(item -> println(stderr, item), ambiguities)
        @test isempty(ambiguities)
        for package in packages
            @testset "$(nameof(package))" begin
                Aqua.test_unbound_args(package)
                Aqua.test_undefined_exports(package)
                Aqua.test_project_extras(package)
                Aqua.test_deps_compat(package)
                Aqua.test_piracies(package)
            end
        end
    end
end

function format_check()
    mismatches = String[]
    files = source_files()
    for path in files
        source = read(path, String)
        formatted = JuliaFormatter.format_text(
            source;
            style=JuliaFormatter.DefaultStyle(),
            indent=4,
            margin=92,
            format_docstrings=false,
            whitespace_in_kwargs=false,
        )
        source == formatted || push!(mismatches, relpath(path, QUALITY_ROOT))
    end
    for path in mismatches
        println(stderr, "FORMAT ", path)
    end
    isempty(mismatches) || error(
        "$(length(mismatches)) of $(length(files)) Julia files need formatting; no files changed",
    )
    println(
        "PASS formatter: ",
        length(files),
        " files; generated criteria checked separately",
    )
end

function main(args)
    phase = isempty(args) ? "quality" : only(args)
    phase in ("quality", "format", "list") ||
        error("usage: check-quality.jl [quality|format|list]")
    if phase == "list"
        foreach(path -> println(relpath(path, QUALITY_ROOT)), source_files())
    elseif phase == "quality"
        quality()
    else
        format_check()
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)

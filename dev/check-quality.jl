using Test

const QUALITY_PHASE = isempty(ARGS) ? "quality" : only(ARGS)
if QUALITY_PHASE == "quality"
    cache = get(ENV, "LIBTMUX_QUALITY_COMPILER_CACHE", "0")
    cache in ("0", "1") || error("quality compiler cache control must be 0 or 1")
    if cache == "1"
        import LibTmuxQualityCheckCompiler
    else
        include(joinpath(@__DIR__, "quality-checks.jl"))
    end
    import Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, JSON, Tables
elseif QUALITY_PHASE == "format"
    import JuliaFormatter
    if Base.find_package("LibTmuxCheckCompiler") !== nothing
        import LibTmuxCheckCompiler
    end
end

const QUALITY_ROOT = dirname(@__DIR__)
if !isdefined(@__MODULE__, :LibTmuxQualityCheckCompiler)
    include(joinpath(@__DIR__, "generate-options.jl"))
end
const QUALITY_PACKAGES = ("LibTmux", "LibTmuxWorkspace", "LibTmuxMCP")
const GENERATED_JULIA = Set(["src/criteria_generated.jl", "src/options_generated.jl"])

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
    if isdefined(@__MODULE__, :LibTmuxQualityCheckCompiler)
        LibTmuxQualityCheckCompiler.run_quality(packages, extensions)
    else
        quality_checks(packages, extensions)
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
        " files; generated sources checked separately",
    )
end

function options_check()
    if isdefined(@__MODULE__, :LibTmuxQualityCheckCompiler)
        LibTmuxQualityCheckCompiler.run_options(["--check"])
    else
        options_main(["--check"])
    end
end

function main(args)
    phase = isempty(args) ? "quality" : only(args)
    phase in ("quality", "format", "list") ||
        error("usage: check-quality.jl [quality|format|list]")
    phase == "list" || options_check()
    if phase == "list"
        foreach(path -> println(relpath(path, QUALITY_ROOT)), source_files())
    elseif phase == "quality"
        quality()
    else
        format_check()
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)

if abspath(PROGRAM_FILE) == (@__FILE__) &&
   isdefined(@__MODULE__, :LibTmuxQualityCheckCompiler)
    println(
        "TIMED QA entries: quality=",
        LibTmuxQualityCheckCompiler.QUALITY_ENTRIES[],
        "; options=",
        LibTmuxQualityCheckCompiler.OPTIONS_ENTRIES[],
    )
end

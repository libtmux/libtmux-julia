module LibTmuxQualityCheckCompiler
using Test
import Aqua
const SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const QUALITY_ENTRIES = Ref(0)
const OPTIONS_ENTRIES = Ref(0)
include(joinpath(SOURCE_ROOT, "dev", "quality-checks.jl"))
include(joinpath(SOURCE_ROOT, "dev", "generate-options.jl"))

function run_quality(packages, extensions)
    QUALITY_ENTRIES[] += 1
    quality_checks(packages, extensions)
end

function run_options(args)
    OPTIONS_ENTRIES[] += 1
    options_main(args)
end

if ccall(:jl_generating_output, Cint, ()) == 1
    requests = (
        precompile(run_quality, (Vector{Module}, Vector{Module})),
        precompile(run_quality, (Vector{Module}, Vector{Union{Nothing,Module}})),
        precompile(run_options, (Vector{String},)),
    )
    QUALITY_ENTRIES[] == 0 && OPTIONS_ENTRIES[] == 0 ||
        error("quality/options checks executed during compiler preparation")
    println(
        "PREPARED ",
        count(identity, requests),
        " QA signatures; quality entries=",
        QUALITY_ENTRIES[],
        "; options entries=",
        OPTIONS_ENTRIES[],
    )
end
end

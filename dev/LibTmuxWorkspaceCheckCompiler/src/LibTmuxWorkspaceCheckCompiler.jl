module LibTmuxWorkspaceCheckCompiler
using Test
using LibTmux
using LibTmuxWorkspace
import JSON
const SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const TEST_CACHE_DEFINITIONS_ONLY = true
const TEST_CACHE_ENTRIES = Ref(0)
const TEST_CACHE_FIXTURES = Ref(0)
include(joinpath(SOURCE_ROOT, "packages", "LibTmuxWorkspace", "test", "config.jl"))
include(joinpath(SOURCE_ROOT, "packages", "LibTmuxWorkspace", "test", "script.jl"))
include(joinpath(SOURCE_ROOT, "packages", "LibTmuxWorkspace", "test", "readiness.jl"))
const FILE_CHECKS = (
    config=(
        test_config_strict_parser_admission,
        test_config_schema_validation_and_owned_values,
        test_config_explicit_expansion_and_inheritance,
        test_config_plans_contain_ordered_inert_effects,
    ),
    script=(
        test_script_owned_before_script_execution,
        test_script_expired_script_deadline_refuses_admission,
        test_script_worker_interrupt_remains_cancellation,
    ),
    readiness=(
        test_readiness_owned_readiness_marker_lifecycle,
        test_readiness_asynchronous_publication_after_readiness_inspection,
        test_readiness_readiness_uses_published_state_and_unnamed_wakes,
    ),
)
if ccall(:jl_generating_output, Cint, ()) == 1
    compiled = count(check -> precompile(check, ()), Iterators.flatten(values(FILE_CHECKS)))
    TEST_CACHE_ENTRIES[] == 0 && TEST_CACHE_FIXTURES[] == 0 ||
        error("checks/fixtures executed during compiler preparation")
    println(
        "PREPARED ",
        compiled,
        " named signatures; test entries=",
        TEST_CACHE_ENTRIES[],
        "; fixture entries=",
        TEST_CACHE_FIXTURES[],
    )
end
function run_file(file::AbstractString)
    for check in getproperty(FILE_CHECKS, Symbol(file))
        check()
    end
    nothing
end
end

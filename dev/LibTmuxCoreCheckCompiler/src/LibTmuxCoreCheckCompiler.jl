module LibTmuxCoreCheckCompiler
using Test
import LibTmuxTestDiagnostics
using LibTmux
using TOML
const SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const TEST_CACHE_DEFINITIONS_ONLY = true
const TEST_CACHE_ENTRIES = Ref(0)
const TEST_CACHE_FIXTURES = Ref(0)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "model.jl"),
)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "lookup.jl"),
)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "criteria.jl"),
)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "wire.jl"),
)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "sibling_wire.jl"),
)
LibTmuxTestDiagnostics.diagnostic_include(
    @__MODULE__,
    joinpath(SOURCE_ROOT, "test", "projection.jl"),
)
const FILE_CHECKS = (
    model=(
        test_model_captured_identity_and_local_collections,
        test_model_schema_accessors_infer_and_retain_numeric_values,
        test_model_indexed_relations_preserve_captured_order_and_unknown_edges,
        test_model_membership_coverage_and_graph_closure,
    ),
    lookup=(test_lookup_generation_bound_captured_lookup,),
    criteria=(
        test_criteria_callable_criteria_use_base_collections,
        test_criteria_criteria_reject_invalid_meanings,
        test_criteria_relations_retain_correlation_and_check_all_coverage,
    ),
    wire=(
        test_wire_inert_criteria_preserve_typed_local_meaning,
        test_wire_wire_criteria_reject_ambiguity_and_bound_work,
    ),
    sibling_wire=(test_sibling_wire_explicit_sibling_wire_adapters,),
    projection=(
        test_projection_explicit_scalar_projection_retains_captured_coverage_and_schema,
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

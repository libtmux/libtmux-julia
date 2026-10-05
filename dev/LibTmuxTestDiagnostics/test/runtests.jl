include(joinpath(@__DIR__, "..", "src", "LibTmuxTestDiagnostics.jl"))
using .LibTmuxTestDiagnostics
using Random, Test

const D = LibTmuxTestDiagnostics
const FIXTURE = raw"""
using Test, Random
const NativeDefault = Test.DefaultTestSet
const QUOTED = :(@testset "quoted data" begin error("must not execute") end)
function fixture(mode)
    rng_before = copy(Random.default_rng())
    result = @testset "root" begin
        @test true
        @testset NativeDefault "explicit" begin
            @test true
            @testset "nested" begin
                @test rand() isa Float64
                mode == "failure" && (@test 1 == 2)
                mode == "interrupt" && throw(InterruptException())
                mode == "error" && error("expected deliberate error")
            end
        end
        @testset "loop" for i in 1:3
            @test i > 0
            i == 1 && continue
            i == 2 && break
        end
    end
    @assert rand(copy(Random.default_rng())) == rand(rng_before)
    result
end
function returns_fixture()
    @testset "returns" begin
        @test true
        return 42
    end
    99
end
function context_fixture()
    @testset "context parent" begin
        @testset let value=1
            @test value == 1
        end
    end
end
mutable struct CustomSet <: Test.AbstractTestSet
    results::Vector{Any}
end
CustomSet(description; kwargs...) = CustomSet(Any[])
Test.record(ts::CustomSet, result) = push!(ts.results, result)
Test.finish(ts::CustomSet) = ts
function custom_fixture()
    @testset CustomSet "custom" begin
        @test true
    end
end
function worker(index)
    @testset "worker $index" begin
        @test index > 0
    end
end
function parallel_fixture()
    tasks = map(1:2) do index
        Threads.@spawn worker(index)
    end
    fetch.(tasks)
end
module NestedFixture
using Test
const NativeAlias = Test.DefaultTestSet
const QUOTED = :(@testset "nested quoted data" begin error("must not execute") end)
function fixture()
    @testset "native nested-module root" begin
        @test true
        @testset NativeAlias "native nested-module child" begin
            @test 2 == 2
        end
    end
end
end
module ShadowFixture
macro testset(arguments...)
    QuoteNode(:original_shadow_macro)
end
function fixture()
    @testset "foreign macro" begin error("must not execute") end
end
end
nested_fixture() = NestedFixture.fixture()
shadow_fixture() = ShadowFixture.fixture()
"""

function outcome(module_, name, args...)
    try
        function_ = Base.invokelatest(getfield, module_, name)
        answer = Base.invokelatest(function_, args...)
        answer isa Test.DefaultTestSet && return ("returned", D.total_counts(answer))
        answer isa Integer && return ("returned", answer)
        answer isa Symbol && return ("returned", answer)
        answer isa AbstractVector && return ("returned", D.total_counts.(answer))
        ("returned", string(nameof(typeof(answer))))
    catch error
        error isa Test.TestSetException &&
            return ("TestSetException", (error.pass, error.fail, error.error, error.broken))
        (string(nameof(typeof(error))), nothing)
    end
end

function load_fixture(path, mapped)
    module_ = Module(gensym(:Fixture))
    Core.eval(module_, :(using Test, Random))
    mapped ? D.diagnostic_include(module_, path) : Base.include(module_, path)
    module_
end

function check_controls(directory)
    path = joinpath(directory, "fixture.jl")
    write(path, FIXTURE)
    baseline = load_fixture(path, false)
    observed = load_fixture(path, isempty(ARGS) || ARGS[1] != "negative")
    @assert D.OBSERVER[] === nothing
    @assert string(Base.invokelatest(getfield, baseline, :QUOTED)) ==
            string(Base.invokelatest(getfield, observed, :QUOTED))
    expected = Dict(
        mode=>outcome(baseline, :fixture, mode) for
        mode in ("pass", "failure", "interrupt", "error")
    )
    expected_return = outcome(baseline, :returns_fixture)
    expected_context = outcome(baseline, :context_fixture)
    expected_custom = outcome(baseline, :custom_fixture)
    expected_parallel = outcome(baseline, :parallel_fixture)
    expected_nested = outcome(baseline, :nested_fixture)
    expected_shadow = outcome(baseline, :shadow_fixture)
    @assert expected_shadow == ("returned", :original_shadow_macro)
    D.start_observer(
        directory;
        root=directory,
        invocation="helper-controls",
        source_digest=repeat("a", 64),
        process_birth_id="helper-process",
        phase="helper-controls",
    )
    D.declare_files([path])
    for mode in ("pass", "failure", "interrupt", "error")
        @assert outcome(observed, :fixture, mode) == expected[mode]
    end
    @assert outcome(observed, :returns_fixture) == expected_return == ("returned", 42)
    @assert outcome(observed, :context_fixture) == expected_context
    @assert outcome(observed, :custom_fixture) == expected_custom
    @assert outcome(observed, :parallel_fixture) == expected_parallel
    @assert outcome(observed, :nested_fixture) == expected_nested
    @assert outcome(observed, :shadow_fixture) == expected_shadow
    D.close_observer(; outcome="returned")
    events = read(joinpath(directory, "events-helper-process.jsonl"), String)
    @assert occursin("\"description\":\"explicit\"", events)
    @assert occursin("\"phase\":\"helper-controls\"", events)
    @assert occursin("\"description\":\"native nested-module root\"", events)
    @assert occursin("\"description\":\"native nested-module child\"", events)
    @assert !occursin("\"description\":\"foreign macro\"", events)
    @assert occursin("\"file\":\"fixture.jl\"", events)
    @assert occursin("\"body_outcome\":\"interrupted\"", events)
    @assert occursin("\"body_outcome\":\"nonlocal_exit\"", events)
    @assert occursin("\"detail\":", events)
    @assert occursin("1 == 2", events)
    @assert occursin("expected deliberate error", events)
    @assert occursin("\"reason\":\"context_testset\"", events)
    @assert occursin("\"reason\":\"custom_or_unresolved_testset\"", events)
    @assert occursin("\"coverage_complete\":false", events)
    @assert !occursin(directory, events)
    @assert !occursin(r"/(?:home|tmp|mnt)/", events)
    for (sequence, line) in enumerate(split(chomp(events), '\n'))
        @assert occursin("\"seq\":$sequence,", line)
        @assert occursin("\"invocation\":\"helper-controls\"", line)
        @assert occursin("\"source_digest\":\"" * repeat("a", 64) * "\"", line)
        @assert occursin("\"process_birth_id\":\"helper-process\"", line)
    end
    (directory=directory, lines=length(split(chomp(events), '\n')))
end

started = time_ns()
result = mktempdir(check_controls)
println(
    "PASS native diagnostic controls; threads=",
    Threads.nthreads(),
    "; seconds=",
    (time_ns()-started)/1e9,
    "; events=",
    result.lines,
)

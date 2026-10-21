const CI_TEST_IMPORTS_STARTED = time_ns()
using TOML

const CI_TEST_ROOT = dirname(@__DIR__)
const CI_TEST_FILE_FAILURES = CapturedException[]
const CI_TEST_FILE_RESULTS = Dict{String,Any}[]

function finish_test_imports()
    println(
        stderr,
        "IMPORTS END pid=",
        getpid(),
        " seconds=",
        (time_ns() - CI_TEST_IMPORTS_STARTED) / 1e9,
    )
    flush(stderr)
end

_test_interrupted(error) =
    error isa InterruptException || error isa LoadError && _test_interrupted(error.error)

function run_test_file(f::Function, path::AbstractString)
    file = relpath(abspath(path), CI_TEST_ROOT)
    started = time_ns()
    outcome = "ABORTED"
    println(stderr, "FILE START ", repr(file), " pid=", getpid())
    flush(stderr)
    try
        f()
        outcome = "RETURNED"
    catch error
        if _test_interrupted(error)
            outcome = "INTERRUPTED"
            rethrow()
        end
        captured = CapturedException(error, catch_backtrace())
        push!(CI_TEST_FILE_FAILURES, captured)
        showerror(stderr, captured)
        println(stderr)
    finally
        seconds = (time_ns() - started) / 1e9
        push!(
            CI_TEST_FILE_RESULTS,
            Dict("file"=>file, "outcome"=>outcome, "seconds"=>seconds),
        )
        println(
            stderr,
            "FILE END ",
            repr(file),
            " outcome=",
            outcome,
            " seconds=",
            seconds,
            " pid=",
            getpid(),
        )
        flush(stdout)
        flush(stderr)
    end
    nothing
end

include_test_file(namespace::Module, path::AbstractString) =
    run_test_file(() -> Base.include(namespace, path), path)

function finish_test_diagnostics()
    status = isempty(CI_TEST_FILE_FAILURES) ? "PASS" : "FAIL"
    if haskey(ENV, "LIBTMUX_TEST_COMPLETION")
        report = Dict(
            "invocation"=>ENV["LIBTMUX_TEST_INVOCATION"],
            "pid"=>getpid(),
            "status"=>status,
            "files"=>CI_TEST_FILE_RESULTS,
        )
        open(ENV["LIBTMUX_TEST_COMPLETION"], "w") do io
            TOML.print(io, report; sorted=true)
        end
    end
    println(stderr, "TESTS COMPLETE status=", status, " pid=", getpid())
    flush(stderr)
    isempty(CI_TEST_FILE_FAILURES) || throw(first(CI_TEST_FILE_FAILURES).ex)
    nothing
end

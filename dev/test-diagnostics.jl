const CI_TEST_DIAGNOSTICS = if haskey(ENV, "LIBTMUX_CI_DIAGNOSTICS_DIR")
    import LibTmuxTestDiagnostics
    import UUIDs
    LibTmuxTestDiagnostics.start_observer(
        ENV["LIBTMUX_CI_DIAGNOSTICS_DIR"];
        root=normpath(joinpath(@__DIR__, "..")),
        invocation=ENV["LIBTMUX_CI_INVOCATION"],
        source_digest=ENV["LIBTMUX_CI_SOURCE_DIGEST"],
        process_birth_id=haskey(ENV, "LIBTMUX_CI_PROCESS_TOKEN") ?
                         ENV["LIBTMUX_CI_PROCESS_TOKEN"] * "-" * string(getpid()) :
                         string(UUIDs.uuid4()),
        console=get(ENV, "LIBTMUX_CI_TEST_CONSOLE", "0") == "1",
    )
    atexit() do code
        LibTmuxTestDiagnostics.close_observer(; outcome="exit_status_$(code)")
    end
    LibTmuxTestDiagnostics
else
    nothing
end

const CI_TEST_IMPORTS_STARTED = time_ns()
CI_TEST_DIAGNOSTICS === nothing ||
    CI_TEST_DIAGNOSTICS.emit("span_start"; kind="imports", label="test runner imports")

function finish_test_imports()
    CI_TEST_DIAGNOSTICS === nothing || CI_TEST_DIAGNOSTICS.emit(
        "span_finish";
        kind="imports",
        label="test runner imports",
        outcome="returned",
        seconds=(time_ns()-CI_TEST_IMPORTS_STARTED)/1e9,
    )
    nothing
end

function declare_test_files(files::AbstractVector{<:AbstractString})
    CI_TEST_DIAGNOSTICS === nothing || CI_TEST_DIAGNOSTICS.declare_files(files)
    if get(ENV, "LIBTMUX_TEST_INVENTORY_ONLY", "0") == "1"
        root = normpath(joinpath(@__DIR__, ".."))
        for file in files
            println("LIBTMUX_TEST_FILE\t", relpath(abspath(file), root))
        end
        exit(0)
    end
    nothing
end

function include_test_file(module_context::Module, path::AbstractString)
    if CI_TEST_DIAGNOSTICS === nothing
        Base.include(module_context, path)
    else
        run_test_file(path) do
            CI_TEST_DIAGNOSTICS.diagnostic_include(module_context, path)
        end
    end
end

const CI_TEST_CONTINUE_VALUE = get(ENV, "LIBTMUX_CI_TEST_CONTINUE", "0")
CI_TEST_CONTINUE_VALUE in ("0", "1") || error("test continuation must be 0 or 1")
const CI_TEST_CONTINUE = CI_TEST_DIAGNOSTICS !== nothing && CI_TEST_CONTINUE_VALUE == "1"
const CI_TEST_FILE_FAILURES = Any[]

function retain_test_file_failure(error, path, backtrace, exceptions)
    captured = CapturedException(error, backtrace)
    retained = (; exception=error, captured, backtrace, exceptions, file=String(path))
    push!(CI_TEST_FILE_FAILURES, retained)
    CI_TEST_DIAGNOSTICS.incomplete(
        "test_file_aborted",
        LineNumberNode(0, Symbol(path));
        file_exception=Dict(
            "error_type"=>string(nameof(typeof(error))),
            "detail"=>CI_TEST_DIAGNOSTICS.sanitize(sprint(showerror, captured)),
            "exception_details"=>[
                CI_TEST_DIAGNOSTICS.sanitize(sprint(showerror, item.exception)) for
                item in exceptions
            ],
            "backtrace_scope"=>"original_caught_file_exception",
        ),
    )
    retained
end

function run_test_file(f::Function, path::AbstractString)
    if CI_TEST_DIAGNOSTICS === nothing
        return f()
    elseif !CI_TEST_CONTINUE
        return CI_TEST_DIAGNOSTICS.observe_span(
            f,
            "file",
            CI_TEST_DIAGNOSTICS.source_file(path),
        )
    end
    if CI_TEST_DIAGNOSTICS.admission_stopped()
        isempty(CI_TEST_FILE_FAILURES) && throw(InterruptException())
        throw(last(CI_TEST_FILE_FAILURES).exception)
    end
    context = Test.get_testset()
    depth = Test.get_testset_depth()
    try
        return CI_TEST_DIAGNOSTICS.observe_span(
            f,
            "file",
            CI_TEST_DIAGNOSTICS.source_file(path),
        )
    catch error
        backtrace = catch_backtrace()
        exceptions = Base.current_exceptions()
        retain_test_file_failure(error, path, backtrace, exceptions)
        fatal =
            CI_TEST_DIAGNOSTICS.admission_stopped() || any(
                item -> CI_TEST_DIAGNOSTICS.stop_cause(item.exception) !== nothing,
                exceptions,
            )
        fatal && rethrow()
        if Test.get_testset_depth() != depth || Test.get_testset() !== context
            CI_TEST_DIAGNOSTICS.incomplete(
                "native_test_context_not_restored",
                LineNumberNode(0, Symbol(path)),
            )
            rethrow()
        end
    end
    nothing
end

function finish_test_diagnostics()
    if !isempty(CI_TEST_FILE_FAILURES)
        try
            CI_TEST_DIAGNOSTICS.close_observer(; outcome="failed")
        finally
            throw(first(CI_TEST_FILE_FAILURES).exception)
        end
    end
    CI_TEST_DIAGNOSTICS === nothing ||
        CI_TEST_DIAGNOSTICS.close_observer(; outcome="returned")
    nothing
end

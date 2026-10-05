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

function run_test_file(f::Function, path::AbstractString)
    if CI_TEST_DIAGNOSTICS === nothing
        f()
    else
        CI_TEST_DIAGNOSTICS.observe_span(f, "file", CI_TEST_DIAGNOSTICS.source_file(path))
    end
end

function finish_test_diagnostics()
    CI_TEST_DIAGNOSTICS === nothing ||
        CI_TEST_DIAGNOSTICS.close_observer(; outcome="returned")
    nothing
end

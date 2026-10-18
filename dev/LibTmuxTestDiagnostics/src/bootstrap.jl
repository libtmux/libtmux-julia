module LibTmuxChildDiagnostics

const ENTERED_NS = time_ns()
const MODE = get(ENV, "LIBTMUX_CI_PROFILE", "off")
const ENABLED = MODE != "off" || !isempty(get(ENV, "LIBTMUX_CI_DIAGNOSTICS_DIR", ""))
const HELPER_IMPORT_NS = time_ns()
const HELPER_SOURCE = joinpath(@__DIR__, "LibTmuxTestDiagnostics.jl")
const HELPER_LOADING = Ref("disabled")
const HELPER_CACHE_USED = Ref(false)
if ENABLED
    project = get(ENV, "LIBTMUX_CI_CHILD_HELPER_PROJECT", "")
    depot = get(ENV, "LIBTMUX_CI_CHILD_HELPER_DEPOT", "")
    selected = Ref(false)
    if !isempty(project) && !isempty(depot)
        saved_load_path = copy(LOAD_PATH)
        saved_depot_path = copy(DEPOT_PATH)
        try
            pushfirst!(LOAD_PATH, project)
            pushfirst!(DEPOT_PATH, depot)
            resolved = Base.find_package("LibTmuxTestDiagnostics")
            package = Base.identify_package("LibTmuxTestDiagnostics")
            if resolved !== nothing &&
               package !== nothing &&
               realpath(resolved) == realpath(HELPER_SOURCE) &&
               Base.isprecompiled(package)
                import LibTmuxTestDiagnostics
                loaded = pathof(LibTmuxTestDiagnostics)
                loaded !== nothing &&
                realpath(loaded) == realpath(HELPER_SOURCE) &&
                Base.PkgId(LibTmuxTestDiagnostics) == package ||
                    error("cached child diagnostic helper differs from the owned source")
                origin = get(Base.pkgorigins, package, nothing)
                HELPER_CACHE_USED[] = origin !== nothing && origin.cachepath !== nothing
                selected[] = true
                HELPER_LOADING[] = "owned_package_loader"
            end
        finally
            empty!(LOAD_PATH)
            append!(LOAD_PATH, saved_load_path)
            empty!(DEPOT_PATH)
            append!(DEPOT_PATH, saved_depot_path)
        end
    end
    if !selected[]
        include(HELPER_SOURCE)
        HELPER_LOADING[] = "owned_source_include"
        HELPER_CACHE_USED[] = false
    end
end
const DIAGNOSTICS = ENABLED ? LibTmuxTestDiagnostics : nothing
const HELPER_IMPORTED_NS = time_ns()
const APPLICATION_STARTED_NS = Ref{UInt64}(0)

function required(name)
    value = get(ENV, name, "")
    isempty(value) && throw(ArgumentError("missing child diagnostic binding: $name"))
    value
end

function finish_child(exitcode::Int32)
    diagnostics = DIAGNOSTICS
    diagnostics === nothing && return
    diagnostics.OBSERVER[] === nothing && return
    outcome = exitcode == 0 ? "exit_zero" : "exit_nonzero"
    diagnostics.emit(
        "span_finish";
        kind="application",
        label="child entry to exit hook",
        outcome,
        seconds=(time_ns()-APPLICATION_STARTED_NS[])/1e9,
        metric_scope="inclusive_until_exit_hook; excludes_final_profile_export_and_process_reaping",
        compile_seconds=nothing,
        compile_status="unavailable_no_counter_ownership",
    )
    diagnostics.emit(
        "child_exit_hook";
        exit_code=Int(exitcode),
        outcome,
        exit_code_scope="Julia_exit_hook_argument; supervisor_exit_receipt_is_authoritative",
        interruption_status="requires_supervisor_signal_or_application_exception_evidence",
        application_completion="unproved",
    )
    diagnostics.close_observer(; outcome)
    nothing
end

function start_child()
    diagnostics = DIAGNOSTICS
    diagnostics === nothing && return
    MODE in ("off", "cpu", "wall") ||
        throw(ArgumentError("child profile mode must be off, cpu or wall"))
    token = diagnostics.identity(required("LIBTMUX_CI_CHILD_TOKEN"), "child token")
    token != get(ENV, "LIBTMUX_CI_PROCESS_TOKEN", "") ||
        throw(ArgumentError("child token must differ from its inherited process token"))
    parent = diagnostics.identity(
        required("LIBTMUX_CI_PARENT_PROCESS_BIRTH_ID"),
        "parent process birth identity",
    )
    birth = diagnostics.identity(token*"-"*string(getpid()), "child process birth identity")
    started = time_ns()
    observer = diagnostics.start_observer(
        required("LIBTMUX_CI_DIAGNOSTICS_DIR");
        root=required("LIBTMUX_CI_SOURCE_ROOT"),
        invocation=required("LIBTMUX_CI_INVOCATION"),
        source_digest=required("LIBTMUX_CI_SOURCE_DIGEST"),
        process_birth_id=birth,
        phase=required("LIBTMUX_CI_PHASE"),
        profile_mode=MODE,
        profile_symbolization=get(ENV, "LIBTMUX_CI_PROFILE_SYMBOLIZATION", "deferred"),
    )
    observer.coverage_complete = false
    diagnostics.emit(
        "child_bootstrap_start";
        child_token=token,
        parent_process_birth_id=parent,
        parent_pid=Int(ccall(:getppid, Cint, ())),
        admission_status="self_reported_requires_parent_launch_receipt",
        phase=required("LIBTMUX_CI_PHASE"),
        file=diagnostics.source_file(@__FILE__),
    )
    diagnostics.emit(
        "coverage_incomplete";
        reason="child_application_not_instrumented_as_native_tests",
        file=diagnostics.source_file(@__FILE__),
        line=0,
    )
    # Import/setup measurements predate the first available observer record.
    diagnostics.emit(
        "span_finish";
        kind="imports",
        label="private child diagnostics helper",
        outcome="returned",
        seconds=(HELPER_IMPORTED_NS-HELPER_IMPORT_NS)/1e9,
        metric_scope="bootstrap_helper_import; excludes_Julia_startup_and_sampler_import",
        start_record_status="unavailable_before_observer",
        compile_seconds=nothing,
        compile_status="unavailable_no_counter_ownership",
    )
    diagnostics.emit(
        "span_finish";
        kind="setup",
        label="private child observer and sampler",
        outcome="returned",
        seconds=(time_ns()-started)/1e9,
        metric_scope="inclusive_bootstrap_setup; overlaps_profile_import_and_setup",
        start_record_status="unavailable_before_observer",
        compile_seconds=nothing,
        compile_status="unavailable_no_counter_ownership",
    )
    diagnostics.emit(
        "child_entry_ready";
        bootstrap_seconds=(time_ns()-ENTERED_NS)/1e9,
        startup_seconds=nothing,
        startup_status="requires_parent_launch_receipt",
        first_byte_seconds=nothing,
        first_byte_status="requires_parent_protocol_observation",
        application_subphase_status="unavailable_without_application_landmarks",
        helper_loading=HELPER_LOADING[],
        helper_cache_origin_observed=HELPER_CACHE_USED[],
        helper_cache_scope="Julia_loader_cache_origin; cold_work_requires_paired_measurement",
    )
    APPLICATION_STARTED_NS[] = time_ns()
    diagnostics.emit("span_start"; kind="application", label="child entry to exit hook")
    # Zero exit is an observed code, never native-test or application completion.
    atexit(code::Int32->Base.invokelatest(finish_child, code))
    nothing
end

Base.invokelatest(start_child)

end

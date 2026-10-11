module LibTmuxConsumerDiagnostics

using SHA
include("LibTmuxTestDiagnostics.jl")
const Diagnostics = LibTmuxTestDiagnostics
const NEXT_CHILD = Threads.Atomic{Int}(0)

function required(name)
    value = get(ENV, name, "")
    isempty(value) && throw(ArgumentError("missing consumer diagnostic binding: $name"))
    value
end

function observer()
    Diagnostics.OBSERVER[] === nothing || return Diagnostics.OBSERVER[]
    token = Diagnostics.identity(required("LIBTMUX_CI_PROCESS_TOKEN"), "process token")
    owner = Diagnostics.start_observer(
        required("LIBTMUX_CI_DIAGNOSTICS_DIR");
        root=required("LIBTMUX_CI_SOURCE_ROOT"),
        invocation=required("LIBTMUX_CI_INVOCATION"),
        source_digest=required("LIBTMUX_CI_SOURCE_DIGEST"),
        process_birth_id=token*"-"*string(getpid()),
        phase=required("LIBTMUX_CI_PHASE"),
        profile_mode=required("LIBTMUX_CI_PROFILE"),
        profile_symbolization="deferred",
    )
    owner.coverage_complete = false
    Diagnostics.emit(
        "coverage_incomplete";
        reason="consumer_driver_has_no_native_test_inventory; nested_child_admission_unproved",
        file=Diagnostics.source_file(@__FILE__),
        line=0,
    )
    atexit() do code::Int32
        Base.invokelatest(
            Diagnostics.close_observer;
            outcome=code == 0 ? "exit_zero" : "exit_nonzero",
        )
    end
    owner
end

function child_command(command::Cmd, owner, token)
    injected = command.exec[1] == Base.julia_cmd().exec[1]
    if injected
        arguments = vcat(
            command.exec[1:1],
            ["--load="*joinpath(@__DIR__, "bootstrap.jl")],
            command.exec[2:end],
        )
        identity = hasfield(Cmd, :uid) ? (command.uid, command.gid) : ()
        command = Cmd(
            Cmd(arguments),
            command.ignorestatus,
            command.flags,
            command.env,
            command.dir,
            command.cpus,
            identity...,
        )
        command = addenv(
            command,
            "LIBTMUX_CI_PROFILE"=>required("LIBTMUX_CI_PROFILE"),
            "LIBTMUX_CI_PROFILE_SYMBOLIZATION"=>get(
                ENV,
                "LIBTMUX_CI_PROFILE_SYMBOLIZATION",
                "deferred",
            ),
            "LIBTMUX_CI_DIAGNOSTICS_DIR"=>required("LIBTMUX_CI_DIAGNOSTICS_DIR"),
            "LIBTMUX_CI_SOURCE_ROOT"=>owner.root,
            "LIBTMUX_CI_INVOCATION"=>owner.invocation,
            "LIBTMUX_CI_SOURCE_DIGEST"=>owner.source_digest,
            "LIBTMUX_CI_PHASE"=>required("LIBTMUX_CI_PHASE"),
            "LIBTMUX_CI_PROCESS_TOKEN"=>required("LIBTMUX_CI_PROCESS_TOKEN"),
        )
    end
    command = addenv(
        command,
        "LIBTMUX_CI_CHILD_TOKEN"=>token,
        "LIBTMUX_CI_PARENT_PROCESS_BIRTH_ID"=>owner.process_birth_id,
    )
    command, injected
end

# Retain the live libuv handle until getpid returns; perform no waits or exports here.
function admitted_spawn(command::Cmd)
    Base.iolock_begin()
    try
        process =
            run(pipeline(command; stdin=stdin, stdout=stdout, stderr=stderr); wait=false)
        process, Int(getpid(process))
    finally
        Base.iolock_end()
    end
end

function run_child(phase::AbstractString, original::Cmd)
    owner = observer()
    serial = Threads.atomic_add!(NEXT_CHILD, 1)+1
    token = "child-"*bytes2hex(sha256(owner.process_birth_id*"-"*string(serial)))[1:32]
    command, injected = child_command(original, owner, token)
    started = time_ns()
    process, pid = admitted_spawn(command)
    admitted = time_ns()
    birth = token*"-"*string(pid)
    Diagnostics.emit(
        "child_admitted";
        child_pid=pid,
        child_token=token,
        child_process_birth_id=birth,
        label=Diagnostics.sanitize(phase),
        profile_injected=injected,
        pid_status="captured_from_live_libuv_handle",
        startup_seconds=(admitted-started)/1e9,
        startup_scope="spawn_and_pid_capture; excludes_child_bootstrap_and_application_readiness",
        first_byte_seconds=nothing,
        first_byte_status="unavailable_inherited_stdio",
    )
    Diagnostics.emit(
        "span_finish";
        kind="child_startup",
        label=Diagnostics.sanitize(phase),
        seconds=(admitted-started)/1e9,
        outcome="admitted",
    )
    wait_started = time_ns()
    returned = false
    try
        wait(process)
        returned = true
    finally
        exited = process_exited(process)
        Diagnostics.emit(
            "child_exit_observed";
            child_pid=pid,
            child_process_birth_id=birth,
            label=Diagnostics.sanitize(phase),
            wait_returned=returned,
            exit_observed=exited,
            exit_code=exited ? Int(process.exitcode) : nothing,
            signal=exited ? Int(process.termsignal) : nothing,
            observation_seconds=(time_ns()-started)/1e9,
            kernel_reap_time_status="unavailable_libuv_owned",
            cleanup_status=returned ? "libuv_exit_wait_returned" : "unproved",
            descendants_retired="unproved",
        )
        Diagnostics.emit(
            "span_finish";
            kind="child_exit_wait",
            label=Diagnostics.sanitize(phase),
            seconds=(time_ns()-wait_started)/1e9,
            outcome=returned ? "wait_returned" : "interrupted_or_error",
            metric_scope="wait_call; overlaps_child_runtime; kernel_reap_time_unavailable",
        )
    end
    success(process) || Base.pipeline_error(process)
    process
end

end

"""Outer control: admit and profile actual consumer Julia children without changing stdout."""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def capture_child(driver, argv, environment, directory, *, hard_seconds=45, cleanup_seconds=2):
    if any(not math.isfinite(value) or value <= 0 for value in (hard_seconds, cleanup_seconds)):
        raise ValueError("control deadlines must be finite and positive")
    group = driver.PhaseGroup()
    done = threading.Event()
    observed = {}
    process = None
    waiter = None
    started = time.monotonic()
    timed_out = False
    errors = []
    output_path, error_path = Path(directory)/"stdout.bin", Path(directory)/"stderr.bin"

    def cleanup_action(action, *args, **kwargs):
        try:
            return action(*args, **kwargs)
        except BaseException as error:
            errors.append(type(error).__name__)
            return None

    def observe():
        try:
            event = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
            observed["exit"] = event is not None and event.si_pid == process.pid
        except BaseException as error:
            errors.append(type(error).__name__)
        finally:
            done.set()

    with output_path.open("wb") as output, error_path.open("wb") as error_output:
        try:
            process = subprocess.Popen(argv, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=error_output, start_new_session=True)
            group.add(process)
            waiter = threading.Thread(target=observe, daemon=True)
            waiter.start()
            timed_out = not done.wait(driver.remaining(started+hard_seconds))
            if timed_out:
                cleanup_action(group.cancel)
        except BaseException as error:
            errors.append(type(error).__name__)
            if process is not None:
                cleanup_action(group.cancel)
        finally:
            cleanup_started = time.monotonic()
            cleanup_deadline = cleanup_started+cleanup_seconds
            if process is not None:
                if waiter is None:
                    waiter = threading.Thread(target=observe, daemon=True)
                    cleanup_action(waiter.start)
                    if waiter.ident is None:
                        done.set()
                if not done.is_set():
                    cleanup_action(group.cancel)
                    done.wait(driver.remaining(cleanup_deadline))
                if not observed.get("exit"):
                    cleanup_action(group.signal, driver.signal.SIGKILL, process)
                    if not waiter.is_alive() and driver.remaining(cleanup_deadline):
                        done.clear()
                        waiter = threading.Thread(target=observe, daemon=True)
                        cleanup_action(waiter.start)
                        if waiter.ident is None:
                            done.set()
                        done.wait(driver.remaining(cleanup_deadline))
                if observed.get("exit"):
                    cleanup_action(group.reap, process, retire_group=True)
            if waiter is not None:
                cleanup_action(waiter.join, timeout=driver.remaining(cleanup_deadline))
            timer_retired = cleanup_action(group.close, cleanup_deadline) is True
            cleanup_elapsed = time.monotonic()-cleanup_started
    reaped = process is not None and process.returncode is not None
    cleanup = dict(direct_child_reaped=reaped,
                   exit_observer_retired=waiter is not None and not waiter.is_alive(),
                   escalation_timer_retired=timer_retired,
                   leader_exit_observed=bool(observed.get("exit")),
                   identity_reserved_at_capture_return=process in group.processes,
                   descendant_inventory="UNPROVED", hard_limit_seconds=hard_seconds,
                   cleanup_limit_seconds=cleanup_seconds, cleanup_seconds=cleanup_elapsed,
                   hard_limit_exceeded=timed_out,
                   errors=errors)
    code = process.returncode if process is not None else None
    return code, output_path.read_bytes(), error_path.read_bytes(), time.monotonic()-started, cleanup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("julia")
    parser.add_argument("--threads", type=int, choices=(1, 4), default=1)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    spec = importlib.util.spec_from_file_location("libtmux_child_control_matrix", root/"dev/check-matrix.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    source = root / "dev" / "check-consumers.jl"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    program = r'''
    include(ARGS[1])
    using Random
    Random.seed!(9183)
    expected_randomness = rand(UInt64, 4)
    Random.seed!(9183)
    body = "function main(); write(stdout, UInt8[0x00, 0x7f, 0xff]); println(getpid()); flush(stdout); deadline=time_ns()+UInt64(300_000_000); x=0.0; while time_ns()<deadline; x=sin(x+0.7); end; end; main()"
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --threads=$(Threads.nthreads()) -e $body`
    @assert success(run_consumer_child("profiled consumer", command))
    restricted_body = "@assert ENV[\"LTJ_CONTROL_SENTINEL\"] == \"kept\"; @assert !haskey(ENV, \"LTJ_CONTROL_PARENT_SECRET\"); @assert ENV[\"JULIA_LOAD_PATH\"] == \"@stdlib\"; println(\"restricted-child \", getpid()); flush(stdout); function main(); deadline=time_ns()+UInt64(300_000_000); x=0.0; while time_ns()<deadline; x=sin(x+0.7); end; end; main()"
    restricted = setenv(`$(Base.julia_cmd()) --startup-file=no --history-file=no --threads=$(Threads.nthreads()) -e $restricted_body`,
                       ["LTJ_CONTROL_SENTINEL"=>"kept", "JULIA_LOAD_PATH"=>"@stdlib"])
    @assert success(run_consumer_child("restricted environment", restricted))
    failure = try
        run_consumer_child("expected failed child", `/bin/sh -c "echo failed-child; echo child-diagnostic >&2; exit 7"`)
    catch error
        error
    end
    @assert failure isa ConsumerProcessError
    @assert failure.cause isa ProcessFailedException
    @assert only(failure.cause.procs).exitcode == 7
    ignored = run_consumer_child("ignored exit status", ignorestatus(`/bin/sh -c "echo ignored-status; exit 7"`))
    @assert !success(ignored) && ignored.exitcode == 7
    for _ in 1:3
        @assert success(run_consumer_child("fast child", `/bin/true`))
    end
    @assert rand(UInt64, 4) == expected_randomness
    '''
    with tempfile.TemporaryDirectory(prefix="ltj-child-control-") as directory:
        env = dict(os.environ, LIBTMUX_CI_PROFILE="cpu",
                   LIBTMUX_CI_INVOCATION="child-control",
                   LIBTMUX_CI_SOURCE_DIGEST=digest,
                   LIBTMUX_CI_PROCESS_TOKEN="control-parent",
                   LIBTMUX_CI_PHASE="consumer-control",
                   LIBTMUX_CI_SOURCE_ROOT=str(root),
                   LIBTMUX_CI_DIAGNOSTICS_DIR=directory,
                   LTJ_CONTROL_PARENT_SECRET="must-not-inherit")
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        started = time.monotonic()
        code, stdout, stderr, command_seconds, cleanup = capture_child(
            driver, [args.julia, "--startup-file=no", "--history-file=no",
                     f"--threads={args.threads}", "-e", program, str(source)], env, directory)
        process_receipt = dict(exit_code=code, julia_command_seconds=command_seconds,
                               source_digest=digest, source_scope="consumer_driver_control_only",
                               cleanup=cleanup)
        (Path(directory)/"process.json").write_text(json.dumps(process_receipt, indent=2)+"\n")
        if args.evidence is not None:
            shutil.copytree(directory, args.evidence)
        assert code == 0, stderr.decode(errors="replace")
        assert not cleanup["hard_limit_exceeded"] and not cleanup["errors"], cleanup
        assert all(cleanup[name] for name in ("direct_child_reaped", "exit_observer_retired", "escalation_timer_retired")), cleanup
        assert stdout.startswith(b"\x00\x7f\xff"), "consumer stdout bytes changed"
        pid_bytes, _, trailing = stdout[3:].partition(b"\n")
        child_pid = int(pid_bytes)
        restricted_bytes, _, trailing = trailing.partition(b"\n")
        assert restricted_bytes.startswith(b"restricted-child "), stdout
        restricted_pid = int(restricted_bytes.removeprefix(b"restricted-child "))
        assert trailing == b"failed-child\nignored-status\n", stdout
        assert stderr == b"child-diagnostic\n", "consumer stderr bytes changed"
        records = [json.loads(line) for path in Path(directory).glob("events-*.jsonl")
                   for line in path.read_text().splitlines()]
        admitted = [record for record in records if record["event"] == "child_admitted"]
        assert len(admitted) == 7, "actual consumer children were not independently admitted"
        assert len({record["child_token"] for record in admitted}) == 7
        profiled = [record for record in admitted if record["profile_injected"]]
        assert {record["child_pid"] for record in profiled} == {child_pid, restricted_pid}
        for admission in profiled:
            pid = admission["child_pid"]
            child_records = [record for record in records if record["pid"] == pid]
            entry = next(record for record in child_records if record["event"] == "child_bootstrap_start")
            assert entry["process_birth_id"] == admission["child_process_birth_id"]
            assert entry["parent_process_birth_id"] == admission["process_birth_id"]
            child_start, = [record for record in child_records if record["event"] == "process_start"]
            assert child_start["threads"] == args.threads
            checkpoints = [record for record in child_records if record["event"] == "profile_checkpoint"]
            assert checkpoints, "actual child checkpoint was not retained"
            payloads = [json.loads((Path(directory) / record["file"]).read_text()) for record in checkpoints]
            assert any(payload["data"] for payload in payloads), "actual child has no CPU samples"
            assert all(payload["pid"] == pid and payload["threads"] == args.threads for payload in payloads)
        exits = [record for record in records if record["event"] == "child_exit_observed"]
        assert len(exits) == 7
        child_exit, = [record for record in exits if record["child_pid"] == child_pid]
        assert child_exit["exit_code"] == 0
        assert sorted(record["exit_code"] for record in exits) == [0, 0, 0, 0, 0, 7, 7]
        assert all(record["wait_returned"] is True for record in exits)
        assert all(record["kernel_reap_time_status"] == "unavailable_libuv_owned" for record in exits)
        assert all(record["invocation"] == "child-control" and record["source_digest"] == digest
                   for record in records)
        receipt = dict(status="PASS", threads=args.threads, actual_child_profile=True,
                       admitted_children=7, stdout_bytes_preserved=True,
                       stderr_bytes_preserved=True, ignorestatus_preserved=True,
                       parent_randomness_preserved=True,
                       restricted_environment_preserved=True,
                       cleanup=cleanup,
                       source_scope="consumer_driver_control_only",
                       julia_command_seconds=command_seconds,
                       control_elapsed_seconds=time.monotonic()-started)
        if args.evidence is not None:
            (args.evidence / "receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
        print(json.dumps(receipt))


if __name__ == "__main__":
    main()

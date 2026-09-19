"""Fresh-process startup measurements; prepare Julia dependencies beforehand."""

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tomllib

ROOT = Path(__file__).resolve().parent.parent
PROFILES = {"normal": [], "o0": ["-O0"], "minimal": ["--compile=min", "-O0"]}
OUTPUT_LIMIT = 1024 * 1024
BASELINE = ('println("LTJ_STARTUP_BASELINE\\t", VERSION, "\\t", '
            'Threads.nthreads(), "\\t", Sys.maxrss())')


def owned_process(command, environment, deadline, *, grace=0.9):
    """Observe exit without reaping, retire the owned group, then collect wait4 RSS."""
    if not all(hasattr(os, name) for name in ("waitid", "WNOWAIT", "wait4", "P_PID")):
        raise RuntimeError("measurement requires POSIX waitid/WNOWAIT and wait4")
    started = time.perf_counter_ns()
    result = {"command": command, "status": "running", "direct_child_reaped": False,
              "termination_signal": None, "stdout": b"", "stderr": b""}
    captured = {name: bytearray() for name in ("stdout", "stderr")}
    counts = {name: 0 for name in captured}
    eof = {name: False for name in captured}
    child = watcher = selector = exit_reader = exit_writer = None
    exited = threading.Event()
    watch_errors = []
    stop_reason = None
    stop_deadline = None

    def stop(number):
        try:
            os.killpg(child.pid, number)
        except ProcessLookupError:
            pass

    def request_stop(reason):
        nonlocal stop_reason, stop_deadline
        if stop_reason is None:
            stop_reason = reason
            stop_deadline = time.monotonic() + grace
            result["termination_signal"] = "SIGINT"
            stop(signal.SIGINT)

    def read_stream(stream, name):
        try:
            chunk = os.read(stream.fileno(), 65536)
        except BlockingIOError:
            return False
        if not chunk:
            eof[name] = True
            try:
                selector.unregister(stream)
            except KeyError:
                pass
            return False
        result.setdefault("first_output_ns", time.perf_counter_ns() - started)
        counts[name] += len(chunk)
        captured[name].extend(chunk[:max(0, OUTPUT_LIMIT - len(captured[name]))])
        if counts[name] > OUTPUT_LIMIT:
            request_stop("output_limit")
        return True

    try:
        if time.monotonic() >= deadline:
            result["status"] = "not_started_deadline"
            return result
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=environment, bufsize=0,
                                 start_new_session=True)
        result["spawn_ns"] = time.perf_counter_ns() - started
        selector = selectors.DefaultSelector()
        exit_reader, exit_writer = socket.socketpair()
        for name in captured:
            stream = getattr(child, name)
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        selector.register(exit_reader, selectors.EVENT_READ, "exit")

        def observe_exit():
            try:
                # WNOWAIT keeps the process identity reserved until group cleanup.
                os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT)
                result["exit_observed_ns"] = time.perf_counter_ns() - started
            except BaseException as error:
                watch_errors.append(type(error).__name__)
            finally:
                exited.set()
                exit_writer.sendall(b"x")

        watcher = threading.Thread(target=observe_exit, name="startup-child-exit")
        watcher.start()
        while not exited.is_set():
            now = time.monotonic()
            if stop_reason is None and now >= deadline:
                request_stop("deadline")
            if stop_deadline is not None and now >= stop_deadline:
                result["termination_signal"] = "SIGKILL"
                stop(signal.SIGKILL)
                stop_deadline = None
            next_deadline = stop_deadline if stop_reason is not None else deadline
            timeout = None if next_deadline is None else max(0, next_deadline - now)
            for key, _ in selector.select(timeout):
                if key.data == "exit":
                    exit_reader.recv(1)
                else:
                    read_stream(key.fileobj, key.data)
    except KeyboardInterrupt:
        stop_reason = "interrupted"
    except OSError as error:
        stop_reason = "spawn_error" if child is None else "driver_error"
        result["error_type"] = type(error).__name__
    finally:
        if child is not None:
            if stop_reason == "interrupted" and watcher is not None and watcher.ident is not None:
                result["termination_signal"] = "SIGINT"
                stop(signal.SIGINT)
                if not exited.wait(grace):
                    result["termination_signal"] = "SIGKILL"
            # The direct child is still unreaped: its process-group number cannot
            # be reassigned while this run sends the final owned-group signal.
            stop(signal.SIGKILL)
            if watcher is not None and watcher.ident is not None:
                watcher.join()
            if selector is not None:
                for name in captured:
                    stream = getattr(child, name)
                    os.set_blocking(stream.fileno(), False)
                    # An escaped descendant may keep writing; never drain it
                    # indefinitely or wait for an EOF that this run cannot own.
                    for _ in range(16):
                        if eof[name] or not read_stream(stream, name):
                            break
            _, status, usage = os.wait4(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(status)
            result.update(exit_code=child.returncode, direct_child_reaped=True,
                          owned_group_retirement_signal="SIGKILL",
                          wait4_max_rss_bytes=int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)),
                          user_cpu_seconds=usage.ru_utime, system_cpu_seconds=usage.ru_stime)
            for name in captured:
                getattr(child, name).close()
            result["status"] = stop_reason or ("failed" if child.returncode else "pass")
            if watch_errors:
                result.update(status="driver_error", watcher_errors=watch_errors)
        elif stop_reason is not None:
            result["status"] = stop_reason
        if selector is not None:
            selector.close()
        if exit_reader is not None:
            exit_reader.close()
        if exit_writer is not None:
            exit_writer.close()
        result.update(stdout=bytes(captured["stdout"]), stderr=bytes(captured["stderr"]),
                      observed_bytes=counts, pipe_eof=eof,
                      whole_ns=time.perf_counter_ns() - started)
    return result


def source_hashes():
    files = [ROOT / name for name in ("Project.toml", "benchmark/Project.toml",
                                     "benchmark/startup.jl", "benchmark/startup.py")]
    for directory in ("src", "ext"):
        files.extend(sorted((ROOT / directory).rglob("*.jl")))
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in files}


def decode_sample(result, kind):
    stdout = result["stdout"].decode("utf-8", "replace")
    rows = []
    for line in stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 6 and fields[0] == "LTJ_STARTUP_PHASE":
            rows.append(dict(name=fields[1], status=fields[2], elapsed_ns=int(fields[3]),
                             from_script_entry_ns=int(fields[4]), max_rss_bytes=int(fields[5])))
        elif kind == "baseline" and len(fields) == 4 and fields[0] == "LTJ_STARTUP_BASELINE":
            result["baseline"] = dict(julia=fields[1], threads=int(fields[2]), max_rss_bytes=int(fields[3]))
    result["phase_records"] = rows
    begin, end = "LTJ_STARTUP_TOML_BEGIN\n", "LTJ_STARTUP_TOML_END\n"
    if begin in stdout and end in stdout:
        body = stdout.split(begin, 1)[1].split(end, 1)[0]
        result["measurement"] = tomllib.loads(body)
    if result["status"] == "pass":
        if kind == "baseline":
            valid = "baseline" in result
        else:
            valid = result.get("measurement", {}).get("status") == "pass"
        if not valid:
            result["status"] = "invalid_measurement"


def options(arguments):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--tmux", default=os.environ.get("LIBTMUX_TEST_TMUX", "tmux"))
    parser.add_argument("--project", default=str(ROOT / "benchmark"))
    parser.add_argument("--profiles", default="normal")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--threads", type=int, choices=(1, 4), default=1)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--budget", type=float, default=480)
    parser.add_argument("--process-budget", type=float, default=120)
    parser.add_argument("--output", type=Path, default=ROOT / "benchmark/results/startup.json")
    args = parser.parse_args(arguments)
    args.profiles = args.profiles.split(",")
    if not args.profiles or len(set(args.profiles)) != len(args.profiles) or any(name not in PROFILES for name in args.profiles):
        parser.error("profiles must be distinct normal,o0,minimal names")
    if not 1 <= args.samples <= 10:
        parser.error("samples must be in 1:10")
    if not math.isfinite(args.budget) or not 0 < args.budget <= 540:
        parser.error("budget must be in (0,540] seconds")
    if not math.isfinite(args.process_budget) or not 0 < args.process_budget <= 180:
        parser.error("process-budget must be in (0,180] seconds")
    return args


def main(arguments):
    args = options(arguments)
    if args.self_test:
        self_test()
        return 0
    started = time.monotonic()
    deadline = started + args.budget
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as evidence:
        hashes = source_hashes()
        project = Path(args.project).resolve()
        project_files = [path for path in (project / "Project.toml", project / "Manifest.toml") if path.is_file()]
        report = dict(schema_version=1, status="running", source_sha256=hashes,
                      python=sys.version, platform=platform.platform(), machine=platform.machine(),
                      project_files_sha256={str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in project_files},
                      executables={"julia": shutil.which(args.julia), "tmux": shutil.which(args.tmux)},
                      tmux_version_status="not_started_deadline",
                      load_average_start=list(os.getloadavg()),
                      profiles={name: PROFILES[name] for name in args.profiles}, threads=args.threads,
                      seed=args.seed, repetitions=args.samples, budget_seconds=args.budget,
                      process_budget_seconds=args.process_budget, samples=[],
                      limitations=[
                          "Fresh processes; dependency and OS caches are not flushed",
                          "No runtime warmup, package resolution, or core deadline overrides",
                          "Baseline executes only Base output and RSS metadata",
                          "Package load excludes SHA setup; TOML reporting follows measured teardown",
                          "Whole process includes reporting, imports, compilation and harness overhead",
                          "driver_body_seconds starts after Python argument parsing; time the outer command separately",
                          "wait4 RSS includes the child and waited descendants where the OS reports them",
                          "Owned process-group signalling does not prove escaped descendants retired",
                          "Raw samples are descriptive; no ranking or population-tail claim is made",
                      ])
        def save():
            report["driver_body_seconds"] = time.monotonic() - started
            evidence.seek(0)
            json.dump(report, evidence, indent=2)
            evidence.write("\n")
            evidence.truncate()
            evidence.flush()
        save()
        environment = dict(os.environ)
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        environment.update(JULIA_PKG_OFFLINE="true", JULIA_PKG_PRECOMPILE_AUTO="0",
                           LIBTMUX_TEST_TMUX=args.tmux)
        randomizer = random.Random(args.seed)
        jobs = [(iteration, profile, kind) for iteration in range(1, args.samples + 1)
                for profile in args.profiles for kind in ("baseline", "core")]
        randomizer.shuffle(jobs)
        report["order"] = jobs
        try:
            for iteration, profile, kind in jobs:
                if time.monotonic() >= deadline:
                    report["samples"].append(dict(iteration=iteration, profile=profile, kind=kind,
                                                  status="not_started_deadline"))
                    continue
                command = [args.julia, "--startup-file=no", "--history-file=no",
                           f"--threads={args.threads}", f"--project={Path(args.project).resolve()}",
                           *PROFILES[profile]]
                command.extend(["-e", BASELINE] if kind == "baseline" else [str(ROOT / "benchmark/startup.jl")])
                result = owned_process(command, environment, min(deadline, time.monotonic() + args.process_budget))
                result.update(iteration=iteration, profile=profile, kind=kind)
                try:
                    decode_sample(result, kind)
                    if kind == "core" and "measurement" in result and result["measurement"].get("source_sha256") != hashes:
                        result["status"] = "stale_source"
                except (ValueError, TypeError) as error:
                    result.update(status="invalid_measurement", decode_error=type(error).__name__)
                for name in ("stdout", "stderr"):
                    raw = result.pop(name)
                    result[name + "_base64"] = base64.b64encode(raw).decode("ascii")
                    result[name + "_sha256"] = hashlib.sha256(raw).hexdigest()
                report["samples"].append(result)
                save()
                print(f'{result["status"]} {profile}/{kind}/{iteration} {result["whole_ns"] / 1e9:.3f}s', flush=True)
                if result["status"] == "interrupted":
                    break
            if time.monotonic() < deadline:
                version = owned_process([args.tmux, "-V"], environment, min(deadline, time.monotonic() + 0.9))
                report["tmux_version"] = version["stdout"].decode("utf-8", "replace").strip()
                report["tmux_version_status"] = version["status"]
            report["status"] = "pass" if len(report["samples"]) == len(jobs) and all(sample["status"] == "pass" for sample in report["samples"]) else "failed"
            if report["status"] == "pass" and report["tmux_version_status"] != "pass":
                report["status"] = "partial_metadata"
            if source_hashes() != hashes:
                report["status"] = "stale_source"
            if any(not Path(path).is_file() or hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest
                   for path, digest in report["project_files_sha256"].items()):
                report["status"] = "stale_project"
            report["load_average_end"] = list(os.getloadavg())
        except BaseException as error:
            report.update(status="driver_error", error_type=type(error).__name__)
            raise
        finally:
            save()
    return 0 if report["status"] == "pass" else 1


def self_test():
    with tempfile.TemporaryDirectory(prefix="ltj-startup-test-") as directory:
        marker = Path(directory) / "must-not-exist"
        literal = f"; $(touch {marker})"
        result = owned_process([sys.executable, "-c", "import sys; print(sys.argv[1])", literal],
                               dict(os.environ), time.monotonic() + 0.9)
        assert result["status"] == "pass" and result["stdout"] == (literal + "\n").encode()
        assert result["direct_child_reaped"] and not marker.exists()
        result = owned_process([sys.executable, "-c", "print('retained'); raise SystemExit(7)"],
                               dict(os.environ), time.monotonic() + 0.9)
        assert result["status"] == "failed" and result["exit_code"] == 7
        assert result["stdout"] == b"retained\n"
        result = owned_process([sys.executable, "-c", "import signal, threading; signal.signal(signal.SIGINT, signal.SIG_IGN); threading.Event().wait()"],
                               dict(os.environ), time.monotonic() + 0.05, grace=0.05)
        assert result["status"] == "deadline" and result["direct_child_reaped"]
        assert result["termination_signal"] == "SIGKILL"
        result = owned_process([sys.executable, "-c", f"import os; os.write(1, b'x' * {OUTPUT_LIMIT + 1})"],
                               dict(os.environ), time.monotonic() + 0.9)
        assert result["status"] == "output_limit" and len(result["stdout"]) == OUTPUT_LIMIT
        assert result["direct_child_reaped"]
        result = owned_process([str(marker)], dict(os.environ), time.monotonic() - 1)
        assert result["status"] == "not_started_deadline" and not result["direct_child_reaped"]
        partial = {"status": "failed", "stdout": b'LTJ_STARTUP_PHASE\tpackage_load\tfailed\t7\t9\t11\nLTJ_STARTUP_TOML_BEGIN\nstatus = "failed"\nLTJ_STARTUP_TOML_END\n'}
        decode_sample(partial, "core")
        assert partial["phase_records"][0]["elapsed_ns"] == 7
        assert partial["measurement"]["status"] == "failed"
    print("PASS argv, retained failure, deadline admission, byte bound, reaping and partial report")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

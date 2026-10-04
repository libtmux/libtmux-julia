#!/usr/bin/env python3
"""Prepare isolated Julia tooling, then record offline quality and matrix cells."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed, wait, FIRST_COMPLETED
import ctypes
import errno
from functools import cache
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import tarfile
import urllib.request
import threading
import time
import tomllib
import uuid

ROOT = Path(__file__).resolve().parent.parent
PINNED_TOOLS = {
    "Aqua": "0.8.18", "JuliaFormatter": "2.14.0", "Documenter": "1.17.0",
    "Tables": "1.14.0", "JSON": "1.9.0", "YAML": "0.4.17",
    "ModelContextProtocol": "0.7.0",
}

# JuliaFormatter's default workload formats a copied package tree in every style.
# Keep that optional workload out of tool setup; the normal format gate still runs.
TOOL_PREFERENCES = "[JuliaFormatter]\nprecompile_workload = false\n"

DELIVERY_PHASES = frozenset(("extensions", "docs", "doc-snippets", "doc-contextual",
                            "imports", "external-examples", "external-launchers"))
SUITES = ("runtime", "delivery")
LOOP_BUDGETS = {"mid": 10, "outer": 60}
HARD_LIMITS = {"mid": 30, "outer": 180}
CLEANUP_SECONDS = 2.0


def remaining(deadline):
    return max(0.0, deadline - time.monotonic())

TMUX_SHA256 = {
    "3.2a": "551553a4f82beaa8dadc9256800bcc284d7c000081e47aa6ecbb6ff36eacd05f",
    "3.3a": "e4fd347843bd0772c4f48d6dde625b0b109b7a380ff15db21e97c11a4dcdf93f",
    "3.4": "551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa",
    "3.5a": "16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951",
    "3.6b": "390759d25fdba016887ec982b808927e637070fd7d03a8021f8ef3102b9ae3c7",
    "3.7c": "7c60cae9a0e25288e2e24750aafc9e8800fc7fd4555e447e1b29ee4201cfb3bf",
}


def tmux_configure_command(target, version, os_name):
    command = ["./configure", f"--prefix={target}"]
    if os_name == "Darwin":
        command.append("--enable-utf8proc")
        if version in ("3.5a", "3.6b", "3.7c"):
            command.append("--enable-jemalloc")
    return command


def build_tmux(args):
    stage = checked_stage(args.stage, create=True)
    target = stage / "tmux" / args.version
    binary = target / "bin" / "tmux"
    if not binary.is_file():
        target.mkdir(parents=True, exist_ok=True)
        archive = target / "source.tar.gz"
        url = f"https://github.com/tmux/tmux/releases/download/{args.version}/tmux-{args.version}.tar.gz"
        with urllib.request.urlopen(url) as source, archive.open("wb") as output:
            shutil.copyfileobj(source, output)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != TMUX_SHA256[args.version]:
            raise ValueError("tmux source digest differs from the pinned official release")
        with tarfile.open(archive) as source:
            source.extractall(target, filter="data")
        source_root = target / f"tmux-{args.version}"
        subprocess.run(tmux_configure_command(target, args.version, platform.system()),
                       cwd=source_root, check=True)
        subprocess.run(["make", "-j2"], cwd=source_root, check=True)
        subprocess.run(["make", "install"], cwd=source_root, check=True)
    observed = subprocess.check_output([str(binary), "-V"], text=True).strip()
    if observed != f"tmux {args.version}":
        raise ValueError("built tmux version differs from the requested release")
    print(binary)


def qa_cells():
    cells = []

    def add(os_name, runner, arch, julia, tmux, threads=1, suites=SUITES):
        label = f"{os_name}-{arch}-julia{julia}-tmux{tmux}-t{threads}"
        cells.append(dict(label=label, os=os_name, runner=runner, arch=arch,
                          julia=julia, tmux=tmux, threads=threads, suites=tuple(suites),
                          optional=os_name != "Linux", status="NOT RUN"))

    for julia, tmux in (("1.10.0", "3.2a"), ("1.13.0", "3.7c")):
        for threads in (1, 4):
            add("Linux", "ubuntu-24.04", "x86_64", julia, tmux, threads, ("all",))
    for runner, arch in (("macos-15", "arm64"), ("macos-15-intel", "x86_64")):
        add("Darwin", runner, arch, "1.13.0", "3.7c", suites=("all",))
    return cells


def source_digest():
    digest = hashlib.sha256()
    inputs = ("Project.toml", "README.md", "LICENSE", "CHANGELOG.md", "CONTRIBUTING.md", "WRITING.md", "AGENTS.md",
              ".github/workflows",
              "src", "ext", "test", "schema", "docs", "examples", "packages",
              "dev", "benchmark")
    for base in inputs:
        root = ROOT / base
        files = [root] if root.is_file() else root.rglob("*")
        for path in sorted(files):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(ROOT)
            if relative.parts[:2] == ("benchmark", "results"):
                continue
            if any(part in ("build", "__pycache__", ".git", "node_modules") for part in relative.parts):
                continue
            if path.name.startswith("Manifest") or path.suffix in (".log", ".pyc"):
                continue
            digest.update(str(relative).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()


def checked_stage(path, *, create=False):
    stage = Path(path).resolve()
    if stage == ROOT or ROOT in stage.parents:
        raise ValueError("the prepared stage must be outside the checkout")
    marker = stage / ".libtmux-julia-matrix"
    if create:
        stage.mkdir(parents=True, exist_ok=True)
        if not marker.exists() and any(stage.iterdir()):
            raise ValueError("preparation requires an empty stage or an owned matrix stage")
        if not marker.exists():
            marker.write_text(str(uuid.uuid4()))
    elif not marker.is_file():
        raise ValueError("stage is not prepared; run prepare outside timed checks")
    return stage


def signal_group(process, number):
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        # Exit may win the race between the waiter deadline and signal delivery.
        pass


class _DarwinBSDInfo(ctypes.Structure):
    # libproc's PROC_PIDTBSDINFO ABI, including its microsecond start identity.
    _fields_ = [("flags", ctypes.c_uint32), ("state", ctypes.c_uint32),
                ("exit_status", ctypes.c_uint32), ("pid", ctypes.c_uint32),
                ("parent", ctypes.c_uint32), ("credentials", ctypes.c_uint32 * 7),
                ("command", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
                ("files", ctypes.c_uint32), ("group", ctypes.c_uint32),
                ("job_control", ctypes.c_uint32 * 3), ("nice", ctypes.c_int32),
                ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64)]


@cache
def _darwin_libproc():
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int)
    library.proc_listpids.argtypes = (ctypes.c_uint32, ctypes.c_uint32,
                                    ctypes.c_void_p, ctypes.c_int)
    library.proc_pidinfo.restype = library.proc_listpids.restype = ctypes.c_int
    return library


def _darwin_process_info(pid):
    info = _DarwinBSDInfo()
    ctypes.set_errno(0)
    # The nonzero argument also admits unreaped zombies to PROC_PIDTBSDINFO.
    size = _darwin_libproc().proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info):
        raise OSError(ctypes.get_errno() or errno.EIO, "incomplete Darwin process identity")
    return dict(pid=info.pid, parent=info.parent, group=info.group, state=info.state,
                start=(info.start_seconds, info.start_microseconds))


def _darwin_group_pids(group):
    library = _darwin_libproc()
    ctypes.set_errno(0)
    required = library.proc_listpids(2, group, None, 0)
    item_size = ctypes.sizeof(ctypes.c_int)
    if required <= 0 or required % item_size:
        raise OSError(ctypes.get_errno() or errno.EIO, "unknown Darwin process group")
    buffer = (ctypes.c_int * (required // item_size + 16))()
    ctypes.set_errno(0)
    filled = library.proc_listpids(2, group, buffer, ctypes.sizeof(buffer))
    if (filled < 0 or filled >= ctypes.sizeof(buffer) or filled % item_size or
            (filled == 0 and ctypes.get_errno())):
        raise OSError(ctypes.get_errno() or errno.EIO, "incomplete Darwin process group")
    members = tuple(sorted(buffer[:filled // item_size]))
    if len(set(members)) != len(members) or any(pid <= 0 for pid in members):
        raise OSError(errno.EIO, "invalid Darwin process group members")
    return members


class PhaseGroup:
    """Keep child identities reserved until signalling and final reap finish."""

    def __init__(self):
        self.lock = threading.Lock()
        self.processes = set()
        self.identities = {}
        self.cancelled = False
        self.escalation = None

    def add(self, process):
        with self.lock:
            self.processes.add(process)
            if sys.platform == "darwin":
                info = _darwin_process_info(process.pid)
                if (info["pid"] != process.pid or info["parent"] != os.getpid() or
                        info["group"] != process.pid or info["start"][0] <= 0 or
                        not 0 <= info["start"][1] < 1000000):
                    raise RuntimeError("Darwin phase leader identity is not owned")
                self.identities[process] = {key: info[key]
                                            for key in ("pid", "parent", "group", "start")}
            if self.cancelled:
                self._signal(process, signal.SIGKILL)

    def _zombie_group(self, process):
        identity = self.identities.get(process)
        if (not self.lock.locked() or process not in self.processes or
                identity is None or process.returncode is not None):
            return False
        try:
            observed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
            if observed is None or observed.si_pid != process.pid:
                return False
            leader = _darwin_process_info(process.pid)
            if leader["state"] != 5 or any(leader[key] != value for key, value in identity.items()):
                return False
            members = _darwin_group_pids(process.pid)
            if process.pid not in members:
                return False
            infos = [_darwin_process_info(pid) for pid in members]
            if any(info["pid"] != pid or info["group"] != process.pid or info["state"] != 5
                   for pid, info in zip(members, infos)):
                return False
            return (all(_darwin_process_info(pid) == info for pid, info in zip(members, infos))
                    and _darwin_group_pids(process.pid) == members)
        except OSError:
            return False

    def _signal(self, process, number):
        try:
            signal_group(process, number)
        except PermissionError as error:
            # XNU skips SZOMB members and returns EPERM when none can be signalled.
            if error.errno != errno.EPERM or sys.platform != "darwin" or not self._zombie_group(process):
                raise

    def reap(self, process, *, retire_group=False):
        # Call only after WNOWAIT observed exit, so wait cannot block this lock.
        with self.lock:
            if retire_group or self.cancelled:
                self._signal(process, signal.SIGKILL)
            code = process.wait()
            self.processes.discard(process)
            self.identities.pop(process, None)
            return code

    def signal(self, number, process=None):
        with self.lock:
            targets = self.processes if process is None else (process,)
            for child in targets:
                if child in self.processes:
                    self._signal(child, number)

    def cancel(self):
        with self.lock:
            if self.cancelled:
                return
            self.cancelled = True
        self.signal(signal.SIGINT)
        # Retire nested groups before the supervisor's 900 ms worker grace ends.
        self.escalation = threading.Timer(0.8, self.signal, (signal.SIGKILL,))
        self.escalation.daemon = True
        self.escalation.start()

    def close(self, deadline=None):
        deadline = time.monotonic() + CLEANUP_SECONDS if deadline is None else deadline
        if self.escalation is not None:
            self.escalation.cancel()
            self.escalation.join(timeout=remaining(deadline))
            return not self.escalation.is_alive()
        return True


def phase(name, argv, *, cwd, env, log, budget, group=None, soft_budget=None, deadline=None):
    """Wait on a child-exit event; retire only this run's process group."""
    if not callable(getattr(os, "waitid", None)) or not hasattr(os, "WNOWAIT"):
        raise RuntimeError("owned process retirement needs waitid/WNOWAIT; use Python 3.13+ on macOS")
    if not math.isfinite(budget) or budget < 0:
        raise ValueError("hard allowance must be finite and nonnegative")
    if soft_budget is not None and (not math.isfinite(soft_budget) or soft_budget < 0):
        raise ValueError("soft allowance must be finite and nonnegative")
    start = time.monotonic()
    deadline = min(start + budget, deadline) if deadline is not None else start + budget
    log.parent.mkdir(parents=True, exist_ok=True)
    answer = dict(name=name, command=argv, status="NOT RUN", budget_seconds=budget,
                  started=False, soft_limit_seconds=soft_budget, soft_limit_exceeded=False,
                  hard_deadline=deadline, direct_child_reaped=False, cleanup_status="NOT NEEDED")
    owned_group = group or PhaseGroup()
    process = None
    waiter = None
    done = threading.Event()
    observed_exit = threading.Event()
    observer_errors = []
    cleanup_deadline = None

    def cleanup_time():
        nonlocal cleanup_deadline
        if cleanup_deadline is None:
            cleanup_deadline = min(time.monotonic() + CLEANUP_SECONDS, deadline + CLEANUP_SECONDS)
        return remaining(cleanup_deadline)

    def observe_exit():
        try:
            observed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
            if observed is None or observed.si_pid != process.pid:
                raise RuntimeError("owned leader exit identity was not observed")
            observed_exit.set()
        except BaseException as error:
            observer_errors.append(error)
        finally:
            done.set()

    def unretired(reason):
        answer.update(status="UNRETIRED", semantic_status="UNRETIRED",
                      cleanup_status="UNRETIRED", reason=reason,
                      owned_identity_reserved=process in owned_group.processes,
                      leader_exit_observed=observed_exit.is_set())

    try:
        if owned_group.cancelled:
            answer["status"] = "CANCELLED"
            return answer
        with log.open("wb") as output:
            if remaining(deadline) == 0:
                answer["reason"] = "hard deadline expired before phase admission"
                return answer
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            answer["started"] = True
            answer.update(pid=process.pid, process_group=process.pid)
            owned_group.add(process)
            answer.update(owned_identity_reserved=True,
                          owned_identity=owned_group.identities.get(process, dict(
                              pid=process.pid, parent=os.getpid(), group=process.pid,
                              reservation="direct child retained until WNOWAIT reap")))
            waiter = threading.Thread(target=observe_exit, name=f"matrix-{name}", daemon=True)
            waiter.start()
            if soft_budget is not None:
                soft_deadline = start + soft_budget
                if not done.wait(min(remaining(deadline), remaining(soft_deadline))):
                    answer["soft_limit_exceeded"] = time.monotonic() >= soft_deadline
                    if answer["soft_limit_exceeded"]:
                        record = json.dumps(dict(event="soft-limit", phase=name, pid=process.pid,
                            seconds=time.monotonic() - start, soft_limit_seconds=soft_budget,
                            hard_deadline=deadline))
                        output.write((record + "\n").encode())
                        output.flush()
                        print(record, flush=True)
            timed_out = not done.wait(remaining(deadline))
            if timed_out:
                owned_group.signal(signal.SIGINT, process)
                if not done.wait(min(0.9, cleanup_time())):
                    owned_group.signal(signal.SIGKILL, process)
                    if not done.wait(cleanup_time()):
                        unretired("owned leader exit was not observed after SIGKILL")
                        return answer
            waiter.join(timeout=cleanup_time())
            if waiter.is_alive():
                unretired("owned exit observer exceeded its cleanup allowance")
                return answer
            if observer_errors:
                raise observer_errors[0]
            if not observed_exit.is_set():
                raise RuntimeError("cannot reap an unobserved owned leader")
            code = owned_group.reap(process, retire_group=timed_out)
            status = ("TIMEOUT" if timed_out else "CANCELLED" if owned_group.cancelled
                      else "PASS" if code == 0 else "FAIL")
            answer.update(status=status, semantic_status=status,
                          exit_code=code, direct_child_reaped=True, cleanup_status="REAPED",
                          owned_identity_reserved=False, leader_exit_observed=True)
            if timed_out:
                answer["cleanup"] = "owned process group signalled; escaped descendants not proved retired"
    except FileNotFoundError:
        answer["reason"] = "required executable is unavailable"
    except BaseException:
        if process is not None and process.returncode is None and waiter is not None:
            # Let an owned worker retire its separately grouped children and receipt.
            owned_group.signal(signal.SIGINT, process)
            done.wait(min(0.9, cleanup_time()))
        raise
    finally:
        if process is not None and process.returncode is None and answer["status"] != "UNRETIRED":
            owned_group.signal(signal.SIGKILL, process)
            if waiter is None:
                waiter = threading.Thread(target=observe_exit, name=f"matrix-{name}", daemon=True)
                waiter.start()
            if done.wait(cleanup_time()) and observed_exit.is_set() and not observer_errors:
                owned_group.reap(process)
                answer.update(direct_child_reaped=True, cleanup_status="REAPED",
                              owned_identity_reserved=False, leader_exit_observed=True)
            else:
                unretired("owned identity remains reserved after bounded cleanup")
        if waiter is not None:
            waiter.join(timeout=cleanup_time())
            answer["exit_observer_retired"] = not waiter.is_alive()
        if group is None:
            cleanup_time()
            if not owned_group.close(cleanup_deadline):
                unretired("owned escalation timer did not retire before cleanup expired")
        answer["seconds"] = time.monotonic() - start
        if soft_budget is not None and answer["seconds"] >= soft_budget:
            answer["soft_limit_exceeded"] = True
            if answer["status"] == "PASS":
                answer["status"] = "FAIL"
        answer["log"] = str(log)
    return answer


def version_probe(name, argv, *, env, log, deadline):
    answer = phase(name, argv, cwd=ROOT, env=env, log=log,
                   budget=remaining(deadline), deadline=deadline)
    if answer["status"] == "PASS":
        answer["version"] = log.read_text().strip()
    return answer


def parallel_mid(commands, *, stage, env, result, save, deadline=None):
    """Run independent offline phases; receipts and cancellation stay with the worker."""
    priority = {"core-unit": 0, "mcp-unit": 1, "format": 2, "quality": 3}
    ordered = sorted(commands, key=lambda item: priority.get(item[0], 4))
    group = PhaseGroup()
    pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="matrix-phase")
    futures = {}
    completed = set()
    deadline = time.monotonic() + HARD_LIMITS["mid"] if deadline is None else deadline

    def progress():
        result["active_phases"] = [item[0] for future, item in futures.items()
                                   if future.running() and not future.done()]
        result["pending_phases"] = [item[0] for future, item in futures.items()
                                    if not future.running() and not future.done()]
        result["active_phase"] = ",".join(result["active_phases"]) or None
        save()

    try:
        for name, argv, budget, _ in ordered:
            if remaining(deadline) == 0:
                result["phases"].append(dict(name=name, command=argv, status="NOT RUN",
                    started=False, seconds=0.0, reason="hard deadline expired before phase admission"))
                continue
            future = pool.submit(phase, name, argv, cwd=ROOT, env=env,
                                 log=stage / "logs" / f"{name}.log", budget=HARD_LIMITS["mid"],
                                 soft_budget=budget, deadline=deadline, group=group)
            futures[future] = (name, argv, budget)
        progress()
        for future in as_completed(futures):
            item = future.result()
            completed.add(future)
            result["phases"].append(item)
            progress()
            print(f"{item['status']} {item['name']} {item['seconds']:.3f}s", flush=True)
    except BaseException:
        group.cancel()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
        for future, (name, argv, budget) in futures.items():
            if future in completed:
                continue
            if future.cancelled():
                item = dict(name=name, command=argv, status="CANCELLED", started=False,
                            budget_seconds=HARD_LIMITS["mid"], soft_limit_seconds=budget, seconds=0.0)
            else:
                try:
                    item = future.result()
                except BaseException as error:
                    item = dict(name=name, command=argv, status="FAIL",
                                error_type=type(error).__name__)
            result["phases"].append(item)
        progress()
        if not group.close(deadline + CLEANUP_SECONDS):
            result["cleanup_status"] = "UNRETIRED"
        save()


def parallel_outer(commands, *, stage, env, result, save, deadline=None):
    priority = {"core-normal": 0, "workspace-normal": 1, "mcp-normal": 2, "imports": 3,
                "external-examples": 3, "external-launchers": 3}
    pending = sorted(commands, key=lambda item: priority.get(item[0], 4))
    names = {item[0] for item in commands}
    dependencies = {"external-examples": {"imports"} & names,
                    "external-launchers": {"imports"} & names}
    group = PhaseGroup()
    pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="matrix-outer")
    running, futures, completed, finished = {}, {}, set(), set()
    deadline = time.monotonic() + HARD_LIMITS["outer"] if deadline is None else deadline

    def progress():
        result["active_phases"] = [item[0] for future, item in running.items()
                                   if future.running() and not future.done()]
        result["pending_phases"] = [item[0] for item in pending] + [
            item[0] for future, item in running.items() if not future.running() and not future.done()]
        result["active_phase"] = ",".join(result["active_phases"]) or None
        save()

    def admit():
        while len(running) < 4:
            if remaining(deadline) == 0:
                for name, argv, _, _ in pending:
                    result["phases"].append(dict(name=name, command=argv, status="NOT RUN",
                        started=False, seconds=0.0, reason="hard deadline expired before phase admission"))
                pending.clear()
                if running:
                    group.cancel()
                break
            index = next((i for i, item in enumerate(pending)
                          if dependencies.get(item[0], set()) <= finished), None)
            if index is None:
                break
            item = pending.pop(index)
            name, argv, budget, _ = item
            future = pool.submit(phase, name, argv, cwd=ROOT, env=env,
                                 log=stage / "logs" / f"{name}.log", budget=HARD_LIMITS["outer"],
                                 soft_budget=budget, deadline=deadline, group=group)
            running[future] = futures[future] = item
        progress()

    try:
        admit()
        while running:
            ready, _ = wait(running, timeout=remaining(deadline), return_when=FIRST_COMPLETED)
            if not ready:
                group.cancel()
                break
            for future in ready:
                item = future.result()
                completed.add(future)
                finished.add(running.pop(future)[0])
                result["phases"].append(item)
                print(f"{item['status']} {item['name']} {item['seconds']:.3f}s", flush=True)
            admit()
        if pending and remaining(deadline) > 0:
            raise RuntimeError("outer phase dependencies cannot be satisfied")
    except BaseException:
        group.cancel()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
        for future, (name, argv, budget, _) in futures.items():
            if future in completed:
                continue
            if future.cancelled():
                item = dict(name=name, command=argv, status="CANCELLED", started=False,
                            budget_seconds=HARD_LIMITS["outer"], soft_limit_seconds=budget, seconds=0.0)
            else:
                try:
                    item = future.result()
                except BaseException as error:
                    item = dict(name=name, command=argv, status="FAIL",
                                error_type=type(error).__name__)
            result["phases"].append(item)
        for name, argv, budget, _ in pending:
            result["phases"].append(dict(name=name, command=argv, status="CANCELLED",
                                        started=False, budget_seconds=HARD_LIMITS["outer"],
                                        soft_limit_seconds=budget, seconds=0.0))
        running.clear()
        pending.clear()
        progress()
        if not group.close(deadline + CLEANUP_SECONDS):
            result["cleanup_status"] = "UNRETIRED"
        save()


PACKAGE_SPECIFICATIONS = r'''
using Pkg
function package_specifications(arguments)
    pairs = [split(argument, '='; limit=2) for argument in arguments]
    [PackageSpec(name=String(first(pair)), version=VersionNumber(last(pair))) for pair in pairs]
end
'''

PREPARE = PACKAGE_SPECIFICATIONS + r'''
root, project = ARGS[1:2]
Pkg.activate(project)
Pkg.develop([PackageSpec(path=root),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxWorkspace")),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxMCP")),
             PackageSpec(path=joinpath(root, "dev", "LibTmuxCheckCompiler")),
             PackageSpec(path=joinpath(root, "dev", "LibTmuxCoreCheckCompiler")),
             PackageSpec(path=joinpath(root, "dev", "LibTmuxWorkspaceCheckCompiler")),
             PackageSpec(path=joinpath(root, "dev", "LibTmuxQualityCheckCompiler"))])
packages = package_specifications(ARGS[3:end])
Pkg.add(packages)
resolved = values(Pkg.dependencies())
for package in packages
    any(info -> info.name == package.name && info.version == package.version, resolved) ||
        error("resolved quality tool differs from its admitted version: " * package.name)
end
Pkg.precompile()
'''


def environment(stage, *, offline):
    env = os.environ.copy()
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    env.update(JULIA_DEPOT_PATH=str(stage / "depot"), JULIA_LOAD_PATH="@:@stdlib",
               JULIA_PKG_OFFLINE="true" if offline else "false", JULIA_PKG_PRECOMPILE_AUTO="0")
    return env


def seed_registry_cache(source_depot, consumer_depot):
    """Copy registry bytes without sharing writable files or extending DEPOT_PATH."""
    source = source_depot / "registries"
    destination = consumer_depot / "registries"
    if not source.is_dir() or source.is_symlink():
        raise ValueError("quality preparation did not produce an owned registry cache")
    if destination.exists() or destination.is_symlink():
        raise ValueError("consumer registry seeding requires an empty destination")
    entries = sorted(source.rglob("*"))
    if not entries or any(path.is_symlink() or not (path.is_file() or path.is_dir())
                          for path in entries):
        raise ValueError("registry cache must contain only regular files and directories")
    records = []
    for path in entries:
        relative = path.relative_to(source)
        copied = destination / relative
        if path.is_dir():
            copied.mkdir(parents=True, exist_ok=True)
            continue
        expected = hashlib.sha256(path.read_bytes()).hexdigest()
        copied.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, copied)
        if copied.samefile(path) or hashlib.sha256(copied.read_bytes()).hexdigest() != expected:
            raise ValueError("consumer registry copy failed independent-byte verification")
        records.append(dict(file=str(relative), sha256=expected, bytes=copied.stat().st_size))
    return records


def seed_stdlib_cache(source_depot, consumer_depot, version, modules):
    source = source_depot / "compiled" / version
    destination = consumer_depot / "compiled" / version
    if destination.exists() or destination.is_symlink():
        raise ValueError("stdlib seeding requires an empty consumer cache")
    records = []
    for module in sorted(modules):
        directory = source / module
        if directory.is_symlink():
            raise ValueError("stdlib cache must not contain symbolic links")
        if not directory.is_dir():
            continue
        for path in sorted(directory.iterdir()):
            if path.suffix not in (".ji", ".so", ".dylib") or path.name.startswith("jl_"):
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError("stdlib cache must contain regular completed files")
            relative = path.relative_to(source)
            copied = destination / relative
            expected = hashlib.sha256(path.read_bytes()).hexdigest()
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, copied)
            if copied.samefile(path) or hashlib.sha256(copied.read_bytes()).hexdigest() != expected:
                raise ValueError("stdlib copy failed independent-byte verification")
            records.append(dict(file=str(relative), sha256=expected, bytes=copied.stat().st_size))
    return records


def stdlib_cache_profile(julia, env):
    program = '''println(VERSION)
    println("v", VERSION.major, ".", VERSION.minor)
    foreach(println, filter(name -> isdir(joinpath(Sys.STDLIB, name)), readdir(Sys.STDLIB)))
    '''
    lines = subprocess.check_output([julia, "--startup-file=no", "--history-file=no",
                                     "-e", program], env=env, text=True).splitlines()
    return dict(julia=lines[0], version=lines[1], modules=lines[2:])


def prepare(args):
    stage = checked_stage(args.stage, create=True)
    initial_digest = source_digest()
    project = stage / "environment"
    project.mkdir(exist_ok=True)
    (project / "LocalPreferences.toml").write_text(TOOL_PREFERENCES)
    env = environment(stage, offline=False)
    argv = [args.julia, "--startup-file=no", f"--project={project}", "-e", PREPARE,
            str(ROOT), str(project), *[f"{name}={version}" for name, version in PINNED_TOOLS.items()]]
    # Preparation is a separate tier: package resolution/network/precompilation.
    subprocess.run(argv, cwd=ROOT, env=env, check=True)
    subprocess.run([args.julia, "--startup-file=no", "--compile=min", "-O0",
                    f"--project={project}", "-e",
                    "using Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, ModelContextProtocol, JSON, Tables"],
                   cwd=ROOT, env=env, check=True)
    subprocess.run(format_warmup_command(args, project), cwd=ROOT,
                   env=environment(stage, offline=True), check=True)
    for package in ("LibTmuxCoreCheckCompiler", "LibTmuxWorkspaceCheckCompiler"):
        script = f'using {package}; println("PREPARED test entries=", {package}.TEST_CACHE_ENTRIES[], "; fixture entries=", {package}.TEST_CACHE_FIXTURES[])'
        subprocess.run([args.julia, "--startup-file=no", f"--threads={args.threads}",
                        f"--project={project}", "-e", script], cwd=ROOT,
                       env=environment(stage, offline=True), check=True)
    subprocess.run([args.julia, "--startup-file=no", f"--threads={args.threads}",
                    f"--project={project}", "-e", '''using LibTmuxQualityCheckCompiler
println("PREPARED QA entries=", LibTmuxQualityCheckCompiler.QUALITY_ENTRIES[],
        "; options entries=", LibTmuxQualityCheckCompiler.OPTIONS_ENTRIES[])'''],
                   cwd=ROOT, env=environment(stage, offline=True), check=True)
    consumers = stage / ("consumers-" + uuid.uuid4().hex)
    started = time.monotonic()
    registry_files = seed_registry_cache(stage / "depot", consumers / "depot")
    registry_seed = dict(seconds=time.monotonic() - started, files=registry_files)
    started = time.monotonic()
    profile = stdlib_cache_profile(args.julia, env)
    stdlib_files = seed_stdlib_cache(stage / "depot", consumers / "depot",
                                     profile["version"], profile["modules"])
    stdlib_seed = dict(seconds=time.monotonic() - started, profile=profile, files=stdlib_files)
    subprocess.run([args.julia, "--startup-file=no", "--compile=yes", "-O2",
                    str(ROOT / "dev/check-consumers.jl"), "prepare", str(consumers)],
                   cwd=ROOT, env=env, check=True)
    if initial_digest != source_digest():
        raise ValueError("source changed during preparation; rerun with stable source (dependency cache retained)")
    metadata = dict(schema_version=1, source_digest=initial_digest, tools=PINNED_TOOLS,
                    consumers=str(consumers), project=str(project), registry_seed=registry_seed,
                    stdlib_seed=stdlib_seed,
                    tool_preferences=tomllib.loads(TOOL_PREFERENCES))
    (stage / "prepared.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("PASS prepared dependencies and immutable external consumers; no timed checks run")


def format_warmup_command(args, project):
    return [args.julia, "--startup-file=no", f"--threads={args.threads}",
            f"--project={project}", "-e", '''using LibTmuxCheckCompiler
println("PASS formatter compiler preparation; no source files checked")''']


def command_plan(args, stage, metadata):
    project = metadata["project"]
    normal = [args.julia, "--startup-file=no", f"--threads={args.threads}", f"--project={project}"]
    cache = os.environ.get("LIBTMUX_LOOP_NATIVE_TEST_CACHE", "1")
    if cache not in ("0", "1"):
        raise ValueError("native compiler cache control must be 0 or 1")
    cached_normal = ["env", f"LIBTMUX_TEST_COMPILER_CACHE={cache}", *normal]
    minimal = [*normal, "--compile=min", "-O0"]
    qa_cache = os.environ.get("LIBTMUX_LOOP_QUALITY_CACHE", "1")
    if qa_cache not in ("0", "1"):
        raise ValueError("QA compiler cache control must be 0 or 1")
    quality_command = ["env", f"LIBTMUX_QUALITY_COMPILER_CACHE={qa_cache}", *minimal]
    commands = []
    outer_budget = LOOP_BUDGETS["outer"]
    def add(name, argv, budget, tier):
        commands.append((name, argv, budget, tier))
    add("core-unit", [*minimal, "test/runtests.jl", "unit"], 10, "unit")
    add("workspace-unit", [*minimal, "packages/LibTmuxWorkspace/test/runtests.jl", "unit"], 10, "unit")
    add("mcp-unit", [*minimal, "packages/LibTmuxMCP/test/runtests.jl", "unit"], 10, "unit")
    add("quality", [*quality_command, "dev/check-quality.jl", "quality"], 10, "quality")
    add("format", [*normal, "dev/check-quality.jl", "format"], 10, "quality")
    add("generated", [*minimal, "dev/generate-criteria.jl", "--check"], 10, "quality")
    add("generated-options", [*minimal, "dev/generate-options.jl", "--check"], 10, "quality")
    add("consumer-diagnostics", [*minimal, "dev/check-consumers.jl", "--self-test"], 10, "quality")
    add("example-inventory", [*minimal, "dev/check-doc-examples.jl", "check"], 10, "quality")
    add("core-normal", [*cached_normal, "test/runtests.jl", "all"], outer_budget, "outer")
    add("workspace-normal", [*cached_normal, "packages/LibTmuxWorkspace/test/runtests.jl", "all"], outer_budget, "outer")
    add("mcp-normal", [*normal, "packages/LibTmuxMCP/test/runtests.jl", "all"], outer_budget, "outer")
    add("mcp-product", [*normal, "packages/LibTmuxMCP/test/product.jl"], outer_budget, "outer")
    add("mcp-stopped-reader", [sys.executable, "packages/LibTmuxMCP/test/stdio_backpressure.py",
                              args.julia, project, "--compile", "normal", "--threads",
                              str(args.threads)], outer_budget, "outer")
    extensions = 'using Test, LibTmux; include("test/criteria.jl"); include("test/json_extension.jl"); include("test/tables_extension.jl")'
    add("extensions", [*normal, "-e", extensions], outer_budget, "outer")
    add("docs", [*normal, "docs/make.jl"], outer_budget, "outer")
    add("doc-snippets", [*normal, "dev/check-doc-examples.jl", "doctest"], outer_budget, "outer")
    add("doc-contextual", [*normal, "dev/check-doc-examples.jl", "contextual"], outer_budget, "outer")
    add("imports", [*minimal, "dev/check-consumers.jl", "check", metadata["consumers"]], outer_budget, "outer")
    add("external-examples", [*minimal, "dev/check-consumers.jl", "examples", metadata["consumers"]], outer_budget, "outer")
    add("external-launchers", [*minimal, "dev/check-consumers.jl", "launchers", metadata["consumers"]], outer_budget, "outer")
    return commands


def result_path(stage, args, *, worker=False):
    suffix = "" if args.suite == "all" else f"-{args.suite}"
    if worker:
        suffix += "-worker-" + args.worker_phase
    return stage / f"results-{args.tier}{suffix}-t{args.threads}.json"


def run_checks(args):
    command_started = time.monotonic()
    batch = "outer" if getattr(args, "worker_phase", None) == "outer" or (
        not getattr(args, "worker", False) and args.tier in ("all", "outer")) else "mid"
    deadline = min(command_started + HARD_LIMITS[batch],
                   getattr(args, "deadline", None) or command_started + HARD_LIMITS[batch])
    stage = checked_stage(args.stage)
    metadata = json.loads((stage / "prepared.json").read_text())
    if metadata["source_digest"] != source_digest():
        raise ValueError("source changed since preparation; prepare a fresh source snapshot before checks")
    preferences = Path(metadata["project"]) / "LocalPreferences.toml"
    if tomllib.loads(preferences.read_text()) != metadata["tool_preferences"]:
        raise ValueError("tool preferences changed since preparation; prepare a fresh stage")
    env = environment(stage, offline=True)
    env.update(LIBTMUX_TEST_TMUX=args.tmux, LIBTMUX_TEST_CLI_COMPILE="normal",
               LIBTMUX_TEST_MINIMAL_CHILD="0")
    result = dict(schema_version=2, source_digest=metadata["source_digest"],
                  platform=platform.system(), machine=platform.machine(), kernel=platform.release(),
                  wsl="microsoft" in platform.release().lower(), threads=args.threads,
                  tools=metadata["tools"], status="NOT RUN", phases=[], suite=args.suite,
                  tier=args.tier, active_phase=None, active_phases=[], pending_phases=[],
                  planned_phases=[], probes=[], loops={}, completion_status="INCOMPLETE",
                  invocation=getattr(args, "invocation", None))
    destination = result_path(stage, args, worker=getattr(args, "worker", False))

    def save():
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(destination)

    save()
    for key, argv in (("julia", [args.julia, "--startup-file=no", "--version"]),
                      ("tmux", [args.tmux, "-V"])):
        if remaining(deadline) == 0:
            result.update(status="FAIL", reason="hard deadline expired before version probe admission")
            break
        resolved = shutil.which(argv[0])
        if resolved is None:
            result["reason"] = f"{key} executable is unavailable"
            break
        result["active_phase"] = f"{key}-version"
        save()
        try:
            probe = version_probe(result["active_phase"], argv, env=env,
                log=stage / "logs" / f"{key}-version-{getattr(args, 'worker_phase', None) or 'direct'}.log",
                deadline=deadline)
            result["probes"].append(probe)
            if probe["status"] != "PASS":
                result.update(status="FAIL", reason=f"{key} version probe did not finish successfully")
                break
            result[key] = probe["version"]
        except BaseException as error:
            result.update(status="INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAIL",
                          error_type=type(error).__name__)
            raise
        finally:
            result["active_phase"] = None
            save()
    else:
        expected = ((args.expected_julia, result["julia"].removeprefix("julia version "), "Julia"),
                    (args.expected_tmux, result["tmux"].removeprefix("tmux "), "tmux"),
                    (args.expected_os, result["platform"], "OS"),
                    (args.expected_arch, result["machine"], "architecture"))
        mismatch = next((name for requested, actual, name in expected if requested and requested != actual), None)
        if mismatch:
            result["reason"] = f"observed {mismatch} differs from the requested cell"
        else:
            commands = selected_commands(args, stage, metadata)
            scope_args = argparse.Namespace(**(vars(args) | dict(worker=False)))
            result.update(status="RUNNING", planned_phases=[item[0] for item in commands],
                          required_phases=[item[0] for item in selected_commands(scope_args, stage, metadata)])
            loop_started = command_started
            active_loop = None
            try:
                if getattr(args, "worker_phase", None) == "mid":
                    active_loop = "mid"
                    parallel_mid(commands, stage=stage, env=env, result=result, save=save, deadline=deadline)
                    commands = []
                elif getattr(args, "worker_phase", None) == "outer":
                    active_loop = "outer"
                    parallel_outer(commands, stage=stage, env=env, result=result, save=save, deadline=deadline)
                    commands = []
                for name, argv, budget, tier in commands:
                    loop = "outer" if tier == "outer" else "mid"
                    if active_loop is not None and loop != active_loop:
                        result["loops"][active_loop] = loop_result(
                            active_loop, time.monotonic() - loop_started, args)
                        loop_started = command_started if loop == "outer" else time.monotonic()
                    active_loop = loop
                    result["active_phase"] = name
                    save()
                    item = phase(name, argv, cwd=ROOT, env=env, log=stage / "logs" / f"{name}.log",
                                 budget=HARD_LIMITS[loop], soft_budget=budget, deadline=deadline)
                    result["phases"].append(item)
                    result["active_phase"] = None
                    save()
                    print(f"{item['status']} {name} {item['seconds']:.3f}s", flush=True)
                result["status"] = "PASS" if result["phases"] and all(p["status"] == "PASS" for p in result["phases"]) else "FAIL"
                if metadata["source_digest"] != source_digest():
                    result.update(status="STALE", reason="source changed during checks")
                if active_loop is not None:
                    result["loops"][active_loop] = loop_result(
                        active_loop, time.monotonic() - loop_started, args)
                if result["status"] == "PASS" and any(
                        loop["status"] == "FAIL" for loop in result["loops"].values()):
                    result.update(status="FAIL", reason="aggregate whole-command loop budget exceeded")
                if result.get("cleanup_status") == "UNRETIRED":
                    result.update(status="FAIL", reason="owned escalation timer did not retire")
            except BaseException as error:
                result.update(status="INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAIL",
                              error_type=type(error).__name__)
                raise
            finally:
                result["completion_status"] = "COMPLETE" if phases_finished(
                    result, result["planned_phases"]) else "INCOMPLETE"
                save()
    save()
    print(f"{result['status']} matrix result: {destination}")
    return 0 if result["status"] == "PASS" else 1


def loop_result(name, seconds, args):
    complete = args.suite == "all" and (
        args.tier in ("all", "mid", "outer") if name == "mid" else args.tier in ("all", "outer"))
    return dict(seconds=seconds, budget_seconds=LOOP_BUDGETS[name], complete=complete,
                status="PASS" if seconds < LOOP_BUDGETS[name] else "FAIL")


def receipt_issues(details):
    """Critical progress fields must be explicit before admitting more work."""
    statuses = {"PASS", "FAIL", "NOT RUN", "RUNNING", "STALE", "INTERRUPTED",
                "TIMEOUT", "CANCELLED", "UNRETIRED"}
    issues = []
    if not isinstance(details.get("status"), str) or details["status"] not in statuses:
        issues.append("status")
    if "active_phase" not in details or not (
            details["active_phase"] is None or isinstance(details["active_phase"], str)):
        issues.append("active_phase")
    for field in ("active_phases", "pending_phases", "planned_phases"):
        values = details.get(field)
        if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
            issues.append(field)
        elif len(values) != len(set(values)):
            issues.append(field)
    phases = details.get("phases")
    if not isinstance(phases, list) or any(not isinstance(item, dict)
            or not isinstance(item.get("name"), str) or not item["name"]
            or not isinstance(item.get("status"), str) or item["status"] not in statuses for item in phases):
        issues.append("phases")
    return issues


def phases_finished(details, expected):
    """Every selected command finalized; assertion coverage is recorded separately."""
    if details.get("receipt_status") == "INVALID" or receipt_issues(details):
        return False
    phases = details.get("phases", [])
    names = [item.get("name") for item in phases]
    return (details.get("status") in ("PASS", "FAIL")
            and details.get("cleanup_status") != "UNRETIRED"
            and details.get("active_phase") is None
            and not details.get("active_phases") and not details.get("pending_phases")
            and details.get("planned_phases") == expected
            and len(names) == len(set(names)) == len(expected)
            and set(names) == set(expected)
            and all(item.get("status") in ("PASS", "FAIL")
                    and item.get("started") is True and item.get("direct_child_reaped") is True
                    and item.get("cleanup_status") != "UNRETIRED" for item in phases))


def worker_receipt(path, invocation, digest):
    """Read only this invocation's source-bound receipt."""
    try:
        details = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(details, dict) or details.get("invocation") != invocation or details.get("source_digest") != digest:
        return {}
    issues = receipt_issues(details)
    if issues:
        # Preserve named source-bound failures, but never use malformed progress to admit work.
        phases = details.get("phases", [])
        details["phases"] = [item for item in phases if isinstance(item, dict)
                            and isinstance(item.get("name"), str) and item["name"]] \
            if isinstance(phases, list) else []
        details.update(status="FAIL", receipt_status="INVALID", receipt_errors=issues)
        if "active_phase" in issues:
            details["active_phase"] = None
        for field in ("active_phases", "pending_phases", "planned_phases"):
            if field in issues:
                details.pop(field, None)
    return details


def selected_commands(args, stage, metadata):
    return [item for item in command_plan(args, stage, metadata)
            if (args.tier in ("all", "outer") or item[3] == args.tier
                or args.tier == "mid" and item[3] in ("unit", "quality"))
            and (not getattr(args, "worker", False)
                 or (item[3] == "outer") == (args.worker_phase == "outer"))
            and (args.suite == "all" or (item[0] in DELIVERY_PHASES) == (args.suite == "delivery"))]


def cancelled_receipts(result, details):
    """Keep source-bound names without guessing an unfinished worker's starts."""
    retained = {item["name"] for item in result["phases"]}
    planned = set(details.get("planned_phases", []))
    for name in result["required_phases"]:
        if name in retained:
            continue
        unstarted = name not in planned
        result["phases"].append(dict(name=name,
                                    status="NOT RUN" if unstarted else "CANCELLED",
                                    started=False if unstarted else None,
                                    seconds=0.0 if unstarted else None,
                                    reason="complete loop stopped before final phase receipt"))


def run(args):
    """Measure complete workers through exit, including their final receipts."""
    started = time.monotonic()
    stage = checked_stage(args.stage)
    metadata = json.loads((stage / "prepared.json").read_text())
    if metadata["source_digest"] != source_digest():
        raise ValueError("source changed since preparation; prepare again before checks")
    plan = selected_commands(args, stage, metadata)
    invocation = uuid.uuid4().hex
    batches = ("mid", "outer") if args.tier in ("all", "outer") else ("mid",)
    result = dict(schema_version=3, status="RUNNING", phases=[], loops={},
                  tier=args.tier, suite=args.suite, threads=args.threads,
                  invocation=invocation, workers=[], active_phase=None,
                  source_digest=metadata["source_digest"],
                  soft_limits=LOOP_BUDGETS, hard_limits=HARD_LIMITS, cleanup_seconds=CLEANUP_SECONDS,
                  required_phases=[item[0] for item in plan],
                  timing_boundary="worker launch through exit; outer includes supervisor orchestration")
    destination = result_path(stage, args)
    def save():
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(destination)
    save()
    for batch in batches:
        deadline = started + HARD_LIMITS[batch]
        cancellation = dict(planned_phases=[item[0] for item in plan
                                           if (item[3] == "outer") == (batch == "outer")])
        details = {}
        if remaining(deadline) == 0:
            result.update(status="FAIL", reason=f"hard deadline expired before {batch} admission")
            for pending in batches[batches.index(batch):]:
                result["loops"][pending] = dict(status="NOT RUN", complete=False, seconds=None,
                    budget_seconds=LOOP_BUDGETS[pending], reason="hard deadline expired before admission")
            cancellation["planned_phases"] = []
            break
        argv = [sys.executable, str(Path(__file__).resolve()), "run", str(stage),
                "--julia", args.julia, "--tmux", args.tmux, "--threads", str(args.threads),
                "--tier", args.tier, "--suite", args.suite, "--worker",
                "--worker-phase", batch, "--invocation", invocation, "--deadline", repr(deadline)]
        for name in ("julia", "tmux", "os", "arch"):
            value = getattr(args, f"expected_{name}")
            if value is not None:
                argv.extend((f"--expected-{name}", value))
        budget = remaining(deadline)
        soft_budget = max(0.0, started + LOOP_BUDGETS[batch] - time.monotonic())
        worker_args = argparse.Namespace(**(vars(args) | dict(worker=True, worker_phase=batch)))
        receipt = result_path(stage, worker_args, worker=True)
        try:
            worker = phase(batch, argv, cwd=ROOT, env=os.environ.copy(),
                           log=stage / "logs" / f"whole-{batch}-t{args.threads}.log",
                           budget=budget, soft_budget=soft_budget, deadline=deadline)
        except BaseException as error:
            result.update(status="INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAIL",
                          active_phase=batch, error_type=type(error).__name__,
                          supervisor_seconds=time.monotonic() - started)
            details = worker_receipt(receipt, invocation, metadata["source_digest"])
            if details:
                result["phases"].extend(details["phases"])
                result["active_phase"] = details["active_phase"] or batch
                cancelled_receipts(result, cancellation | details)
            else:
                cancelled_receipts(result, cancellation)
            save()
            raise
        result["workers"].append(worker)
        details = worker_receipt(receipt, invocation, metadata["source_digest"])
        if details:
            result["phases"].extend(details["phases"])
            result["active_phase"] = details["active_phase"]
            for name in ("source_digest", "platform", "machine", "kernel", "wsl", "tools", "julia", "tmux"):
                if name in details:
                    result[name] = details[name]
        else:
            worker.update(status="FAIL", reason="worker did not retain a receipt for this invocation")
        seconds = time.monotonic() - started
        result["loops"][batch] = loop_result(batch, seconds, args)
        complete = (worker["status"] in ("PASS", "FAIL")
                    and worker.get("direct_child_reaped") is True
                    and worker.get("cleanup_status") != "UNRETIRED"
                    and phases_finished(details, cancellation["planned_phases"]))
        result["loops"][batch]["complete"] &= complete
        if worker["status"] != "PASS" or details.get("status") != "PASS" or any(
                item.get("status") != "PASS" for item in details.get("phases", [])):
            result["loops"][batch]["status"] = "FAIL"
        if not complete:
            result.update(status="FAIL", reason=f"complete {batch} worker failed or exceeded its budget")
            for later in batches[batches.index(batch) + 1:]:
                result["loops"][later] = dict(status="NOT RUN", complete=False,
                    seconds=None, budget_seconds=LOOP_BUDGETS[later])
            break
        save()
    else:
        result["status"] = "PASS" if all(loop["status"] == "PASS" for loop in result["loops"].values()) \
            and all(worker["status"] == "PASS" for worker in result["workers"]) else "FAIL"
    if result["status"] != "PASS":
        cancelled_receipts(result, cancellation | details
                           if details else cancellation)
    result["supervisor_seconds"] = time.monotonic() - started
    save()
    print(f"{result['status']} supervised matrix result: {destination}")
    return 0 if result["status"] == "PASS" else 1


def self_test(julia=None):
    if julia:
        script = PACKAGE_SPECIFICATIONS + r'''
specifications = package_specifications(["Aqua=0.8.18", "JSON=1.9.0"])
@assert length(specifications) == 2
@assert specifications[1].name == "Aqua"
@assert specifications[1].version == v"0.8.18"
@assert specifications[2].name == "JSON"
@assert specifications[2].version == v"1.9.0"
println("PASS admitted version arguments construct real Pkg specifications")
'''
        subprocess.run([julia, "--startup-file=no", "--compile=min", "-O0", "-e", script],
                       check=True)
    with tempfile.TemporaryDirectory(prefix="libtmux-julia-matrix-test-") as directory:
        base = Path(directory)
        compiled = base / "tool-depot" / "compiled" / "v1.13"
        for module in ("Pkg", "LibTmux"):
            (compiled / module).mkdir(parents=True)
            (compiled / module / "cache.ji").write_bytes(b"cache bytes")
            (compiled / module / "cache.so").write_bytes(b"native bytes")
        (compiled / "Pkg" / "cache.pidfile").write_text("unfinished")
        (compiled / "Pkg" / "jl_incomplete.so").write_text("unfinished")
        destination = base / "stdlib-consumer"
        copied = seed_stdlib_cache(compiled.parent.parent, destination, "v1.13", ["Pkg"])
        assert [item["file"] for item in copied] == ["Pkg/cache.ji", "Pkg/cache.so"]
        assert not (destination / "compiled" / "v1.13" / "LibTmux").exists()
        copy = destination / "compiled" / "v1.13" / "Pkg" / "cache.ji"
        copy.write_bytes(b"changed consumer cache")
        assert (compiled / "Pkg" / "cache.ji").read_bytes() == b"cache bytes"
        try:
            seed_stdlib_cache(compiled.parent.parent, destination, "v1.13", ["Pkg"])
        except ValueError:
            pass
        else:
            raise AssertionError("stdlib seeding overwrote a consumer cache")
        (compiled / "Pkg" / "linked.ji").symlink_to(compiled / "Pkg" / "cache.ji")
        try:
            seed_stdlib_cache(compiled.parent.parent, base / "linked-stdlib", "v1.13", ["Pkg"])
        except ValueError:
            pass
        else:
            raise AssertionError("stdlib seeding accepted a symbolic link")
        registry = base / "quality-depot" / "registries"
        registry.mkdir(parents=True)
        (registry / "General.toml").write_bytes(b"registry metadata")
        (registry / "General.tar.gz").write_bytes(b"registry archive")
        consumer_depot = base / "consumer-depot"
        copies = seed_registry_cache(registry.parent, consumer_depot)
        assert [item["file"] for item in copies] == ["General.tar.gz", "General.toml"]
        for item in copies:
            copied = consumer_depot / "registries" / item["file"]
            assert copied.read_bytes() == (registry / item["file"]).read_bytes()
            assert item["sha256"] == hashlib.sha256(copied.read_bytes()).hexdigest()
            assert not copied.is_symlink()
        (consumer_depot / "registries" / "General.toml").write_bytes(b"changed copy")
        assert (registry / "General.toml").read_bytes() == b"registry metadata"
        try:
            seed_registry_cache(registry.parent, consumer_depot)
        except ValueError:
            pass
        else:
            raise AssertionError("registry seeding overwrote an existing owned cache")
        (registry / "linked.toml").symlink_to(registry / "General.toml")
        try:
            seed_registry_cache(registry.parent, base / "linked-consumer")
        except ValueError:
            pass
        else:
            raise AssertionError("registry seeding accepted a shared symbolic link")
        assert tmux_configure_command(base, "3.7c", "Darwin") == [
            "./configure", f"--prefix={base}", "--enable-utf8proc", "--enable-jemalloc"]
        assert tmux_configure_command(base, "3.2a", "Darwin") == [
            "./configure", f"--prefix={base}", "--enable-utf8proc"]
        assert tmux_configure_command(base, "3.7c", "Linux") == [
            "./configure", f"--prefix={base}"]
        literal = "; $(touch must-not-exist)"
        ok = phase("literal", [sys.executable, "-c", "import sys; print(sys.argv[1])", literal],
                   cwd=base, env=os.environ.copy(), log=base / "literal.log", budget=0.9)
        assert ok["status"] == "PASS" and (base / "literal.log").read_text().strip() == literal
        assert not (base / "must-not-exist").exists()
        failed = phase("failure", [sys.executable, "-c", "raise SystemExit(7)"],
                       cwd=base, env=os.environ.copy(), log=base / "failure.log", budget=0.9)
        assert failed["status"] == "FAIL" and failed["exit_code"] == 7
        absent = phase("missing", [str(base / "missing")], cwd=base,
                       env=os.environ.copy(), log=base / "missing.log", budget=0.9)
        assert absent["status"] == "NOT RUN"
        timed = phase("deadline", [sys.executable, "-c", "import threading; threading.Event().wait()"],
                      cwd=base, env=os.environ.copy(), log=base / "deadline.log", budget=0.05)
        assert timed["status"] == "TIMEOUT" and timed["direct_child_reaped"]
        soft = phase("soft-overrun", [sys.executable, "-c",
            "import signal,sys,threading;signal.signal(signal.SIGINT,lambda *_:sys.exit(17));"
            "threading.Event().wait(0.035);print('completed')"], cwd=base,
            env=os.environ.copy(), log=base / "soft.log", budget=0.4, soft_budget=0.01)
        assert soft["status"] == "FAIL" and soft["semantic_status"] == "PASS"
        assert soft["soft_limit_exceeded"] and soft["exit_code"] == 0 and soft["direct_child_reaped"]
        assert "completed" in (base / "soft.log").read_text().splitlines()
        assert any(json.loads(line).get("event") == "soft-limit" for line in
                   (base / "soft.log").read_text().splitlines() if line.startswith("{"))
        version = version_probe("julia-version", [sys.executable, "-c",
            "print('julia version 1.13.0')"], env=os.environ.copy(),
            log=base / "version.log", deadline=time.monotonic() + 0.9)
        assert version["status"] == "PASS" and version["direct_child_reaped"]
        assert version["version"] == "julia version 1.13.0"
        from unittest.mock import patch
        with patch.object(subprocess, "Popen") as launch:
            expired = phase("expired", [], cwd=base, env={}, log=base / "expired.log",
                            budget=1, deadline=time.monotonic() - 1)
            launch.assert_not_called()
        assert expired["status"] == "NOT RUN" and not expired["started"]
        release_observer, exit_seen = threading.Event(), threading.Event()
        original_waitid = os.waitid
        ownership = PhaseGroup()
        owned = []
        original_add = ownership.add
        def remember(child):
            original_add(child)
            owned.append(child)
        def stalled_waitid(kind, pid, flags):
            if not flags & os.WNOHANG:
                release_observer.wait()
            observed = original_waitid(kind, pid, flags)
            if not flags & os.WNOHANG:
                exit_seen.set()
            return observed
        try:
            with patch.object(ownership, "add", side_effect=remember), \
                 patch.object(os, "waitid", side_effect=stalled_waitid), \
                 patch(__name__ + ".CLEANUP_SECONDS", 0.08):
                stalled = phase("stalled-observer", [sys.executable, "-c",
                    "import signal,threading;signal.signal(signal.SIGINT,signal.SIG_IGN);"
                    "threading.Event().wait()"], cwd=base, env=os.environ.copy(),
                    log=base / "stalled.log", budget=0.03, group=ownership)
            assert stalled["status"] == "UNRETIRED" and not stalled["direct_child_reaped"]
            assert stalled["seconds"] < 0.5 and stalled["owned_identity_reserved"]
            assert stalled["pid"] == owned[0].pid == stalled["process_group"]
            assert stalled["owned_identity"]["pid"] == owned[0].pid
            assert owned[0] in ownership.processes
        finally:
            release_observer.set()
            assert exit_seen.wait(0.9), "control did not observe its owned child exit"
            ownership.reap(owned[0], retire_group=True)
            ownership.close()
        assert not ownership.processes
        cells = qa_cells()
        assert [
            (cell["os"], cell["arch"], cell["julia"], cell["tmux"], cell["threads"])
            for cell in cells
        ] == [
            ("Linux", "x86_64", "1.10.0", "3.2a", 1),
            ("Linux", "x86_64", "1.10.0", "3.2a", 4),
            ("Linux", "x86_64", "1.13.0", "3.7c", 1),
            ("Linux", "x86_64", "1.13.0", "3.7c", 4),
            ("Darwin", "arm64", "1.13.0", "3.7c", 1),
            ("Darwin", "x86_64", "1.13.0", "3.7c", 1),
        ]
        assert sum(len(cell["suites"]) for cell in cells) == 6
        assert len({cell["label"] for cell in cells}) == len(cells)
        assert all(cell["status"] == "NOT RUN" for cell in cells)
        assert all(cell["optional"] == (cell["os"] != "Linux") for cell in cells)
        from types import SimpleNamespace
        from contextlib import redirect_stdout
        from io import StringIO
        assert ctypes.sizeof(_DarwinBSDInfo) == 136
        assert (_DarwinBSDInfo.pid.offset, _DarwinBSDInfo.group.offset,
                _DarwinBSDInfo.start_seconds.offset, _DarwinBSDInfo.start_microseconds.offset) == (12, 100, 120, 128)
        zombie = dict(pid=4321, parent=os.getpid(), group=4321,
                      start=(123, 456), state=5)
        class OwnedChild:
            pid = 4321
            returncode = None
            def wait(self):
                self.returncode = 7
                return 7
        for members in ((4321,), (4321, 4322)):
            child = OwnedChild()
            def zombie_info(pid):
                return dict(zombie, pid=pid, start=(123, pid))
            with patch.object(sys, "platform", "darwin"), \
                 patch(__name__ + "._darwin_process_info", side_effect=zombie_info), \
                 patch(__name__ + "._darwin_group_pids", return_value=members), \
                 patch.object(os, "waitid", return_value=SimpleNamespace(si_pid=4321)), \
                 patch.object(os, "killpg", side_effect=PermissionError(errno.EPERM, "denied")):
                zombies = PhaseGroup()
                zombies.add(child)
                assert zombies.reap(child, retire_group=True) == 7
                assert child.returncode == 7 and not zombies.processes and not zombies.identities
        for case in ("live-leader", "live-member", "unknown-member", "unknown-group",
                     "changed-start", "changed-member-start", "changed-inventory",
                     "unobserved", "reaped", "other-os", "other-error"):
            child = OwnedChild()
            member_reads = 0
            def member_info(pid):
                nonlocal member_reads
                if pid == 4321:
                    return zombie
                if case == "unknown-member":
                    raise ProcessLookupError(errno.ESRCH, "member disappeared")
                if case == "changed-member-start":
                    member_reads += 1
                    return dict(zombie, pid=pid, parent=4321, start=(123, member_reads))
                return dict(zombie, pid=pid, parent=4321, state=1)
            members = (4321, 4322) if case in ("live-member", "unknown-member", "changed-member-start") else (4321,)
            error = PermissionError(errno.EACCES if case == "other-error" else errno.EPERM, "denied")
            with patch.object(sys, "platform", "linux" if case == "other-os" else "darwin"), \
                 patch(__name__ + "._darwin_process_info", side_effect=member_info), \
                 patch(__name__ + "._darwin_group_pids", return_value=members) as inventory, \
                 patch.object(os, "waitid", return_value=None if case == "unobserved"
                              else SimpleNamespace(si_pid=4321)), \
                 patch.object(os, "killpg", side_effect=error):
                zombies = PhaseGroup()
                zombies.add(child)
                if case == "live-leader":
                    zombie["state"] = 1
                elif case == "changed-start":
                    zombie["start"] = (123, 457)
                elif case == "unknown-group":
                    inventory.side_effect = OSError(errno.EIO, "inventory truncated")
                elif case == "changed-inventory":
                    inventory.side_effect = [members, (4321, 4322)]
                elif case == "reaped":
                    child.returncode = 7
                try:
                    zombies.signal(signal.SIGKILL)
                except PermissionError as observed:
                    assert observed is error
                else:
                    raise AssertionError("Darwin retirement accepted " + case)
                finally:
                    zombie.update(state=5, start=(123, 456))
        with patch.object(os, "waitid", None), patch.object(subprocess, "Popen") as spawn:
            try:
                phase("unsupported", [], cwd=base, env={}, log=base / "unsupported.log", budget=0.9)
            except RuntimeError as error:
                assert "Python 3.13+ on macOS" in str(error)
            else:
                raise AssertionError("missing WNOWAIT support was accepted")
            spawn.assert_not_called()
        barrier = threading.Barrier(4)
        counter_lock = threading.Lock()
        counters = dict(active=0, peak=0)
        def concurrent_phase(name, argv, **kwargs):
            with counter_lock:
                counters["active"] += 1
                counters["peak"] = max(counters["peak"], counters["active"])
            try:
                if int(name[1:]) < 4:
                    barrier.wait(0.9)
                return dict(name=name, status="FAIL" if name == "p7" else "PASS", seconds=0.01)
            finally:
                with counter_lock:
                    counters["active"] -= 1
        parallel_result = dict(phases=[])
        with patch(__name__ + ".phase", side_effect=concurrent_phase), \
             redirect_stdout(StringIO()):
            parallel_mid([(f"p{i}", [], 10, "unit") for i in range(9)], stage=base,
                         env={}, result=parallel_result, save=lambda: None)
        assert counters == dict(active=0, peak=4)
        assert {item["name"] for item in parallel_result["phases"]} == {f"p{i}" for i in range(9)}
        assert [item["name"] for item in parallel_result["phases"] if item["status"] == "FAIL"] == ["p7"]
        assert not parallel_result["active_phases"] and not parallel_result["pending_phases"]
        launchers_started = threading.Event()
        def installed_phase(name, argv, **kwargs):
            if name == "external-examples":
                assert launchers_started.wait(0.2), "independent launcher blocked behind examples"
            elif name == "external-launchers":
                launchers_started.set()
            return dict(name=name, status="PASS", seconds=0.0)
        installed_result = dict(phases=[])
        installed_names = ("imports", "external-examples", "external-launchers")
        with patch(__name__ + ".phase", side_effect=installed_phase), \
             redirect_stdout(StringIO()):
            parallel_outer([(name, [], 60, "outer") for name in installed_names],
                           stage=base, env={}, result=installed_result, save=lambda: None)
        assert {item["name"] for item in installed_result["phases"]} == set(installed_names)
        assert all(item["status"] == "PASS" for item in installed_result["phases"])
        assert not installed_result["active_phases"] and not installed_result["pending_phases"]
        def interrupted_phase(name, argv, **kwargs):
            if name == "second":
                raise KeyboardInterrupt()
            return dict(name=name, status="FAIL", seconds=0.01)
        interrupted_result = dict(phases=[])
        with patch(__name__ + ".phase", side_effect=interrupted_phase), \
             redirect_stdout(StringIO()):
            try:
                parallel_mid([("first", [], 10, "unit"), ("second", [], 10, "unit")],
                             stage=base, env={}, result=interrupted_result, save=lambda: None)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("parallel interruption was swallowed")
        assert {item["name"] for item in interrupted_result["phases"]} == {"first", "second"}
        assert all(item["status"] == "FAIL" for item in interrupted_result["phases"])
        assert next(item for item in interrupted_result["phases"]
                    if item["name"] == "second")["error_type"] == "KeyboardInterrupt"
        release = threading.Event()
        started = threading.Barrier(5)
        class InterruptedPool(ThreadPoolExecutor):
            def shutdown(self, wait=True, *, cancel_futures=False):
                super().shutdown(wait=False, cancel_futures=cancel_futures)
                release.set()
                if wait:
                    super().shutdown(wait=True, cancel_futures=cancel_futures)
        def held_phase(name, argv, **kwargs):
            started.wait(0.9)
            assert release.wait(0.9)
            return dict(name=name, status="CANCELLED", started=True, seconds=0.01)
        def interrupt_pending(futures):
            started.wait(0.9)
            raise KeyboardInterrupt()
        queued_result = dict(phases=[])
        with patch(__name__ + ".ThreadPoolExecutor", InterruptedPool), \
             patch(__name__ + ".phase", side_effect=held_phase), \
             patch(__name__ + ".as_completed", side_effect=interrupt_pending):
            try:
                parallel_mid([(f"q{i}", [], 10, "unit") for i in range(9)], stage=base,
                             env={}, result=queued_result, save=lambda: None)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("queued interruption was swallowed")
        assert {item["name"] for item in queued_result["phases"]} == {f"q{i}" for i in range(9)}
        assert all(item["status"] == "CANCELLED" for item in queued_result["phases"])
        assert sum(not item["started"] for item in queued_result["phases"]) == 5
        assert not queued_result["active_phases"] and not queued_result["pending_phases"]
        # Exit observation reserves the leader PID; signals and final reap share a lock.
        reserved = subprocess.Popen([sys.executable, "-c", "raise SystemExit(7)"],
                                    start_new_session=True)
        ownership = PhaseGroup()
        ownership.add(reserved)
        observed = os.waitid(os.P_PID, reserved.pid, os.WEXITED | os.WNOWAIT)
        assert observed.si_pid == reserved.pid and reserved.returncode is None
        assert os.waitid(os.P_PID, reserved.pid, os.WEXITED | os.WNOWAIT).si_pid == reserved.pid
        deliveries = []
        def guarded_signal(child, number):
            assert ownership.lock.locked() and child in ownership.processes
            assert child.returncode is None
            deliveries.append((child.pid, number))
        original_wait = reserved.wait
        def guarded_reap():
            assert ownership.lock.locked() and reserved in ownership.processes
            return original_wait()
        with patch(__name__ + ".signal_group", side_effect=guarded_signal), \
             patch.object(reserved, "wait", side_effect=guarded_reap):
            ownership.signal(signal.SIGINT)
            with ownership.lock:
                ownership.cancelled = True
            assert ownership.reap(reserved) == 7
            ownership.signal(signal.SIGKILL)
        assert deliveries == [(reserved.pid, signal.SIGINT), (reserved.pid, signal.SIGKILL)]
        assert not ownership.processes
        group = PhaseGroup()
        registered = threading.Event()
        original_add = group.add
        def register_child(process):
            original_add(process)
            registered.set()
        with patch.object(group, "add", side_effect=register_child):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(phase, "cancelled", [
                    sys.executable, "-c", "import threading; threading.Event().wait()"],
                    cwd=base, env=os.environ.copy(), log=base / "cancelled.log",
                    budget=0.9, group=group)
                assert registered.wait(0.9)
                group.cancel()
                cancelled = future.result(timeout=0.9)
        group.close()
        assert cancelled["status"] == "CANCELLED" and cancelled["direct_child_reaped"]
        assert not group.processes
        # A leader may exit on SIGINT while its same-group child ignores it.
        leaf = ("import signal,socket,sys;signal.signal(signal.SIGINT,signal.SIG_IGN);"
                "connection=socket.socket(socket.AF_UNIX);connection.connect(sys.argv[1]);"
                "connection.sendall(b'r');connection.recv(1)")
        leader = ("import os,sys,threading\n"
                  "program,address=sys.argv[1:]\n"
                  "if os.fork()==0:\n"
                  " sys.argv=['-c',address]\n"
                  " exec(program)\n"
                  " os._exit(0)\n"
                  "threading.Event().wait()\n")
        for mode in ("timeout", "cancel"):
            descendants = PhaseGroup()
            address = str(base / ("descendant-" + mode))
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(address)
                listener.listen(1)
                listener.settimeout(0.9)
                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(phase, mode, [sys.executable, "-c", leader, leaf, address],
                        cwd=base, env=os.environ.copy(), log=base / (mode + ".log"),
                        budget=0.2 if mode == "timeout" else 0.9, group=descendants)
                    connection, _ = listener.accept()
                    # Closing this owned connection releases a leaf left alive by a regression.
                    with connection:
                        connection.settimeout(0.9)
                        assert connection.recv(1) == b"r"
                        if mode == "cancel":
                            descendants.cancel()
                        retired = future.result(timeout=0.9)
                        assert retired["status"] == ("TIMEOUT" if mode == "timeout" else "CANCELLED")
                        assert retired["direct_child_reaped"]
                        assert connection.recv(1) == b"", "same-group descendant survived retirement"
            descendants.close()
            assert not descendants.processes
        args = SimpleNamespace(stage=str(base), julia="julia", tmux="tmux", threads=1,
                               tier="all", suite="all", expected_julia=None,
                               expected_tmux=None, expected_os=None, expected_arch=None)
        metadata = dict(source_digest="fixed", tools={}, project=str(base), consumers=str(base),
                        tool_preferences=tomllib.loads(TOOL_PREFERENCES))
        all_names = [item[0] for item in selected_commands(args, base, metadata)]
        budgets = {
            name: budget for name, _, budget, _ in selected_commands(args, base, metadata)
        }
        assert budgets["format"] == 10
        warmup = format_warmup_command(args, base)
        assert warmup[:5] == ["julia", "--startup-file=no", "--threads=1", f"--project={base}", "-e"]
        assert "using LibTmuxCheckCompiler" in warmup[5]
        assert "source_files" not in warmup[5] and "check-quality" not in warmup[5]
        compiler_source = (ROOT / "dev/LibTmuxCheckCompiler/src/LibTmuxCheckCompiler.jl").read_text()
        assert "compiler_probe" in compiler_source and "@compile_workload" in compiler_source
        assert "read(" not in compiler_source and "source_files" not in compiler_source
        partitions = []
        for suite in SUITES:
            args.suite = suite
            partitions.extend(item[0] for item in selected_commands(args, base, metadata))
        assert len(partitions) == len(set(partitions)) == len(all_names)
        assert set(partitions) == set(all_names)
        assert DELIVERY_PHASES <= set(all_names)
        args.suite = "all"
        assert loop_result("mid", 10, args)["status"] == "FAIL"
        assert loop_result("mid", 9.9, args)["status"] == "PASS"
        assert loop_result("outer", 60, args)["status"] == "FAIL"
        assert loop_result("outer", 59.9, args)["status"] == "PASS"
        args.tier = "unit"
        assert not loop_result("mid", 1, args)["complete"]
        args.tier = "mid"
        assert loop_result("mid", 1, args)["complete"]
        assert {item[3] for item in selected_commands(args, base, metadata)} == {"unit", "quality"}
        args.tier = "outer"
        assert {item[0] for item in selected_commands(args, base, metadata)} == set(all_names)
        assert loop_result("mid", 1, args)["complete"]
        args.tier = "all"
        (base / ".libtmux-julia-matrix").touch()
        (base / "LocalPreferences.toml").write_text(TOOL_PREFERENCES)
        (base / "prepared.json").write_text(json.dumps(metadata))
        fingerprint_root = base / "fingerprint-source"
        fingerprints = [fingerprint_root / name for name in (
            "CHANGELOG.md", "CONTRIBUTING.md", "WRITING.md", "AGENTS.md", "dev/quality-checks.jl",
            "dev/generate-options.jl", "dev/LibTmuxCheckCompiler/src/LibTmuxCheckCompiler.jl",
            "dev/LibTmuxCoreCheckCompiler/Project.toml",
            "dev/LibTmuxCoreCheckCompiler/src/LibTmuxCoreCheckCompiler.jl",
            "dev/LibTmuxWorkspaceCheckCompiler/Project.toml",
            "dev/LibTmuxWorkspaceCheckCompiler/src/LibTmuxWorkspaceCheckCompiler.jl",
            "dev/LibTmuxQualityCheckCompiler/Project.toml",
            "dev/LibTmuxQualityCheckCompiler/src/LibTmuxQualityCheckCompiler.jl")]
        for path in fingerprints:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("original")
        with patch(__name__ + ".ROOT", fingerprint_root):
            fingerprint = source_digest()
            (base / "prepared.json").write_text(json.dumps(metadata | dict(source_digest=fingerprint)))
            for path in fingerprints:
                path.write_text("changed")
                with patch(__name__ + ".phase") as launch, \
                     patch.object(subprocess, "check_output", side_effect=AssertionError(
                         "stale source reached executable probe")) as probe:
                    try:
                        run_checks(args)
                    except ValueError as error:
                        assert "source changed since preparation" in str(error)
                    else:
                        raise AssertionError("changed policy or compiler source was accepted")
                    launch.assert_not_called()
                    probe.assert_not_called()
                path.write_text("original")
                assert source_digest() == fingerprint
        (base / "prepared.json").write_text(json.dumps(metadata))
        expired_args = SimpleNamespace(**(vars(args) | dict(
            worker=True, worker_phase="mid", invocation="expired-worker", deadline=time.monotonic() - 1)))
        with patch(__name__ + ".source_digest", return_value="fixed"), \
             patch(__name__ + ".version_probe") as probe, \
             patch(__name__ + ".phase") as launch, \
             redirect_stdout(StringIO()):
            assert run_checks(expired_args) == 1
            probe.assert_not_called()
            launch.assert_not_called()
        retained = json.loads(result_path(base, expired_args, worker=True).read_text())
        assert retained["status"] == "FAIL" and retained["completion_status"] == "INCOMPLETE"
        assert not retained["probes"] and not retained["phases"]
        plan = [("first", [], 30, "unit"), ("second", [], 30, "unit")]
        with patch(__name__ + ".source_digest", return_value="fixed"), \
             patch.object(shutil, "which", return_value="binary"), \
             patch(__name__ + ".version_probe", return_value=dict(status="PASS", version="version")), \
             patch(__name__ + ".command_plan", return_value=plan), \
             patch(__name__ + ".phase", side_effect=[
                 dict(name="first", status="FAIL", seconds=0.01), KeyboardInterrupt()]), \
             redirect_stdout(StringIO()):
            try:
                run_checks(args)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("matrix interruption was swallowed")
        retained = json.loads((base / "results-all-t1.json").read_text())
        assert retained["status"] == "INTERRUPTED" and retained["active_phase"] == "second"
        assert retained["phases"][0]["status"] == "FAIL"
        clock = [0.0]
        def slow_check(name, argv, **kwargs):
            clock[0] = 12.0
            return dict(name=name, status="PASS", seconds=0.01)
        with patch(__name__ + ".source_digest", return_value="fixed"), \
             patch.object(shutil, "which", return_value="binary"), \
             patch(__name__ + ".version_probe", return_value=dict(status="PASS", version="version")), \
             patch(__name__ + ".command_plan", return_value=plan[:1]), \
             patch(__name__ + ".phase", side_effect=slow_check), \
             patch.object(time, "monotonic", side_effect=lambda: clock[0]), \
             redirect_stdout(StringIO()):
            assert run_checks(args) == 1
        retained = json.loads((base / "results-all-t1.json").read_text())
        assert retained["phases"][0]["status"] == "PASS"
        assert retained["loops"]["mid"]["complete"]
        assert retained["loops"]["mid"]["status"] == "FAIL"
        assert retained["status"] == "FAIL"
        metadata = metadata | dict(source_digest=source_digest())
        (base / "prepared.json").write_text(json.dumps(metadata))
        args.tier = "mid"
        def complete_worker(name, argv, **kwargs):
            invocation = argv[argv.index("--invocation") + 1]
            worker_args = SimpleNamespace(**(vars(args) | dict(worker_phase=name)))
            expected = [item[0] for item in selected_commands(args, base, metadata)
                        if (item[3] == "outer") == (name == "outer")]
            result_path(base, worker_args, worker=True).write_text(json.dumps(dict(
                invocation=invocation, source_digest=metadata["source_digest"], status="PASS",
                phases=[dict(name=case, status="PASS", seconds=0.01, started=True,
                             direct_child_reaped=True) for case in expected],
                active_phase=None, active_phases=[], pending_phases=[], planned_phases=expected,
            )))
            return dict(name=name, status="PASS", seconds=12, direct_child_reaped=True)
        clock = [0.0]
        def aged_complete_worker(*call_args, **kwargs):
            answer = complete_worker(*call_args, **kwargs)
            clock[0] = 12.0
            return answer
        with patch(__name__ + ".phase", side_effect=aged_complete_worker), \
             patch.object(time, "monotonic", side_effect=lambda: clock[0]), \
             redirect_stdout(StringIO()):
            assert run(args) == 1
        retained = json.loads(result_path(base, args).read_text())
        assert retained["phases"][0]["status"] == "PASS"
        assert retained["loops"]["mid"]["seconds"] == 12
        assert retained["loops"]["mid"]["status"] == "FAIL"
        assert retained["status"] == "FAIL"
        with patch(__name__ + ".phase", return_value=dict(name="mid", status="PASS", seconds=0.01)), \
             redirect_stdout(StringIO()):
            assert run(args) == 1
        retained = json.loads(result_path(base, args).read_text())
        assert retained["workers"][0]["reason"] == "worker did not retain a receipt for this invocation"
        # A completed failing worker must not hide the remaining outer checks.
        continuation_args = SimpleNamespace(**(vars(args) | dict(tier="all")))
        continuation_plan = [("mid-case", [], 10, "unit"), ("outer-case", [], 60, "outer")]
        admitted = []
        def completed_failure(name, argv, **kwargs):
            admitted.append(name)
            invocation = argv[argv.index("--invocation") + 1]
            case = "mid-case" if name == "mid" else "outer-case"
            status = "FAIL" if name == "mid" else "PASS"
            worker_args = SimpleNamespace(**(vars(continuation_args) | dict(worker_phase=name)))
            result_path(base, worker_args, worker=True).write_text(json.dumps(dict(
                invocation=invocation, source_digest=metadata["source_digest"], status=status,
                phases=[dict(name=case, status=status, seconds=0.01, started=True,
                             direct_child_reaped=True)],
                active_phase=None, active_phases=[], pending_phases=[], planned_phases=[case],
            )))
            return dict(name=name, status=status, seconds=0.01, direct_child_reaped=True)
        with patch(__name__ + ".command_plan", return_value=continuation_plan), \
             patch(__name__ + ".phase", side_effect=completed_failure), \
             redirect_stdout(StringIO()):
            assert run(continuation_args) == 1
        retained = json.loads(result_path(base, continuation_args).read_text())
        assert admitted == ["mid", "outer"], "completed mid failure suppressed outer checks"
        assert retained["loops"]["mid"]["complete"]
        assert retained["loops"]["outer"]["complete"] and retained["status"] == "FAIL"
        admitted.clear()
        def contradictory_worker(*call_args, **kwargs):
            answer = completed_failure(*call_args, **kwargs)
            answer["status"] = "PASS"
            return answer
        with patch(__name__ + ".command_plan", return_value=continuation_plan), \
             patch(__name__ + ".phase", side_effect=contradictory_worker), \
             redirect_stdout(StringIO()):
            assert run(continuation_args) == 1
        retained = json.loads(result_path(base, continuation_args).read_text())
        assert admitted == ["mid", "outer"] and retained["loops"]["mid"]["complete"]
        assert retained["status"] == "FAIL" and retained["phases"][0]["status"] == "FAIL"
        for invalid in ("stale", "stale-source", "incomplete", "unretired", "malformed",
                        "missing-active", "malformed-active", "missing-pending", "malformed-plan"):
            admitted.clear()
            def stopped_worker(name, argv, **kwargs):
                answer = completed_failure(name, argv, **kwargs)
                worker_args = SimpleNamespace(**(vars(continuation_args) | dict(worker_phase=name)))
                receipt = result_path(base, worker_args, worker=True)
                details = json.loads(receipt.read_text())
                if invalid == "stale":
                    details["invocation"] = "older-invocation"
                elif invalid == "stale-source":
                    details["source_digest"] = "other-source"
                elif invalid == "incomplete":
                    details.update(active_phase="mid-case", phases=[])
                elif invalid == "unretired":
                    answer["cleanup_status"] = "UNRETIRED"
                elif invalid == "missing-active":
                    details.pop("active_phase")
                elif invalid == "malformed-active":
                    details["active_phase"] = []
                elif invalid == "missing-pending":
                    details.pop("pending_phases")
                elif invalid == "malformed-plan":
                    details["planned_phases"] = [dict(name="mid-case")]
                receipt.write_text("{" if invalid == "malformed" else json.dumps(details))
                return answer
            with patch(__name__ + ".command_plan", return_value=continuation_plan), \
                 patch(__name__ + ".phase", side_effect=stopped_worker), \
                 redirect_stdout(StringIO()):
                assert run(continuation_args) == 1
            retained = json.loads(result_path(base, continuation_args).read_text())
            assert admitted == ["mid"] and not retained["loops"]["mid"]["complete"], invalid
            assert retained["loops"]["outer"]["status"] == "NOT RUN" and retained["status"] == "FAIL"
            if invalid in ("missing-active", "malformed-active", "missing-pending", "malformed-plan"):
                assert retained["phases"][0]["status"] == "FAIL", "known source-bound failure was lost"
        admitted.clear()
        clock = [0.0]
        def delayed_supervisor(*call_args, **kwargs):
            answer = completed_failure(*call_args, **kwargs)
            clock[0] = 181.0
            return answer
        with patch(__name__ + ".command_plan", return_value=continuation_plan), \
             patch(__name__ + ".phase", side_effect=delayed_supervisor), \
             patch.object(time, "monotonic", side_effect=lambda: clock[0]), \
             redirect_stdout(StringIO()):
            assert run(continuation_args) == 1
        retained = json.loads(result_path(base, continuation_args).read_text())
        assert admitted == ["mid"] and retained["loops"]["outer"]["status"] == "NOT RUN"
        assert retained["phases"][-1]["status"] == "NOT RUN" and not retained["phases"][-1]["started"]
        for runner in (parallel_mid, parallel_outer):
            expired_result = dict(phases=[])
            with patch(__name__ + ".phase") as launch:
                runner(continuation_plan, stage=base, env={}, result=expired_result,
                       save=lambda: None, deadline=time.monotonic() - 1)
                launch.assert_not_called()
            assert len(expired_result["phases"]) == 2
            assert all(item["status"] == "NOT RUN" and not item["started"] for item in expired_result["phases"])
        def interrupted_worker(name, argv, **kwargs):
            complete_worker(name, argv, **kwargs)
            worker_args = SimpleNamespace(**(vars(args) | dict(worker_phase=name)))
            receipt = result_path(base, worker_args, worker=True)
            details = json.loads(receipt.read_text())
            details["phases"] = details["phases"][:1]
            details["phases"][0]["status"] = "FAIL"
            details["active_phase"] = "second"
            details["active_phases"] = ["second"]
            details["required_phases"] = details["planned_phases"] = [
                "first", "second", *[f"pending-{index}" for index in range(19)]]
            details["pending_phases"] = details["planned_phases"][2:]
            receipt.write_text(json.dumps(details))
            raise KeyboardInterrupt()
        interrupted_plan = [(name, [], 30, "unit") for name in (
            "first", "second", *[f"pending-{index}" for index in range(19)])]
        with patch(__name__ + ".phase", side_effect=interrupted_worker), \
             patch(__name__ + ".command_plan", return_value=interrupted_plan), \
             redirect_stdout(StringIO()):
            try:
                run(args)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("supervisor interruption was swallowed")
        retained = json.loads(result_path(base, args).read_text())
        assert retained["status"] == "INTERRUPTED" and retained["active_phase"] == "second"
        assert retained["phases"][0]["status"] == "FAIL"
        assert len(retained["phases"]) == 21
        assert retained["phases"][1]["started"] is None
        assert all(item["status"] == "CANCELLED" and item["started"] is None
                   for item in retained["phases"][2:])
        with patch(__name__ + ".phase", side_effect=KeyboardInterrupt()), \
             redirect_stdout(StringIO()):
            try:
                run(args)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("missing-receipt interruption was swallowed")
        retained = json.loads(result_path(base, args).read_text())
        assert {item["name"] for item in retained["phases"]} == {
            item[0] for item in selected_commands(args, base, metadata)}
        assert all(item["started"] is None for item in retained["phases"])
    print("PASS owned preparation, phase retirement, suite coverage and interrupted result retention")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    matrix = sub.add_parser("matrix")
    matrix.add_argument("--split", action="store_true", help="emit runtime and delivery jobs for every cell")
    self_check = sub.add_parser("self-test")
    self_check.add_argument("--julia", help="also check real Pkg argument conversion offline")
    build = sub.add_parser("build-tmux", help="setup only: download, verify and build one pinned release")
    build.add_argument("stage")
    build.add_argument("version", choices=tuple(TMUX_SHA256))
    preparation = sub.add_parser("prepare")
    preparation.add_argument("stage")
    preparation.add_argument("--julia", default="julia")
    preparation.add_argument("--threads", type=int, choices=(1, 4), default=1)
    execution = sub.add_parser("run")
    execution.add_argument("stage")
    execution.add_argument("--julia", default="julia")
    execution.add_argument("--tmux", default="tmux")
    execution.add_argument("--threads", type=int, choices=(1, 4), default=1)
    execution.add_argument("--tier", choices=("unit", "quality", "mid", "outer", "all"), default="all")
    execution.add_argument("--suite", choices=("all", *SUITES), default="all")
    execution.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    execution.add_argument("--worker-phase", choices=("mid", "outer"), help=argparse.SUPPRESS)
    execution.add_argument("--invocation", help=argparse.SUPPRESS)
    execution.add_argument("--deadline", type=float, help=argparse.SUPPRESS)
    for option in ("julia", "tmux", "os", "arch"):
        execution.add_argument(f"--expected-{option}")
    args = parser.parse_args()
    try:
        if getattr(args, "deadline", None) is not None and (not math.isfinite(args.deadline) or args.deadline <= 0):
            raise ValueError("worker deadline must be finite and positive")
        if args.command == "matrix":
            cells = qa_cells()
            if args.split:
                cells = [dict(cell, suite=suite, job_label=f"{cell['label']}-{suite}")
                         for cell in cells for suite in cell["suites"]]
            print(json.dumps({"include": cells}))
        elif args.command == "self-test":
            self_test(args.julia)
        elif args.command == "build-tmux":
            build_tmux(args)
        elif args.command == "prepare":
            prepare(args)
        else:
            return run_checks(args) if args.worker else run(args)
    except (ValueError, FileNotFoundError, subprocess.CalledProcessError) as error:
        print(f"NOT RUN: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

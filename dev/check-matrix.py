#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Prepare isolated Julia tooling, then record offline quality and matrix cells."""

from __future__ import annotations

import argparse
import atexit
import contextlib
import csv
import ctypes
import hashlib
import json
import os
import platform
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import urllib.request
import uuid
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any, NotRequired, TypedDict

from plan_matrix import (
    MINIMUM_TMUX,
    REJECTED_TMUX,
    SUITES,
    SUPPORTED_TMUX,
    check_ref,
    qa_cells,
    rejection_cells,
    split_cells,
)

ROOT = Path(__file__).resolve().parent.parent
PINNED_TOOLS = {
    "Aqua": "0.8.18",
    "JuliaFormatter": "2.14.0",
    "Documenter": "1.17.0",
    "Tables": "1.14.0",
    "JSON": "1.9.0",
    "YAML": "0.4.17",
    "ModelContextProtocol": "0.7.0",
}

# JuliaFormatter's default workload formats a copied package tree in every style.
# Keep that optional workload out of tool setup; the normal format gate still runs.
TOOL_PREFERENCES = "[JuliaFormatter]\nprecompile_workload = false\n"

DELIVERY_PHASES = frozenset(
    (
        "extensions",
        "docs",
        "doc-snippets",
        "doc-contextual",
        "imports",
        "external-examples",
        "external-launchers",
        "readme-commands",
        "api-export",
        "api-export-check",
    )
)
TMUX_SHA256 = {
    "3.0a": "4ad1df28b4afa969e59c08061b45082fdc49ff512f30fc8e43217d7b0e5f8db9",
    "3.1c": "918f7220447bef33a1902d4faff05317afd9db4ae1c9971bef5c787ac6c88386",
    "3.2a": "551553a4f82beaa8dadc9256800bcc284d7c000081e47aa6ecbb6ff36eacd05f",
    "3.3": "b2382ac391f6a1c5b93293016cdc9488337d9a04b9d611ae05eac164740351dc",
    "3.3a": "e4fd347843bd0772c4f48d6dde625b0b109b7a380ff15db21e97c11a4dcdf93f",
    "3.4": "551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa",
    "3.5a": "16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951",
    "3.6b": "390759d25fdba016887ec982b808927e637070fd7d03a8021f8ef3102b9ae3c7",
    "3.7": "2344f191501b8a73eb71dd6c5fd5dcf8c765f5066f34ab46f04b3013dc7bc1a5",
    "3.7a": "8ee44ce951182845fd57ad12dd6f27fb677b1afb900e2e84df4798112ed0dbf0",
    "3.7b": "87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96",
    "3.7c": "7c60cae9a0e25288e2e24750aafc9e8800fc7fd4555e447e1b29ee4201cfb3bf",
    "3.8": "e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e",
}


HARD_WORK_SECONDS = 15 * 60


class CleanupReceipt(TypedDict):
    descendant_retirement: str
    reaped: list[int]
    killed: list[int]
    survivors: list[int]
    temporary_directory_removed: NotRequired[bool]


class PhaseResult(TypedDict):
    name: str
    command: list[str]
    status: str
    hard_limit_seconds: float
    pid: NotRequired[int]
    invocation: NotRequired[str]
    direct_child_reaped: NotRequired[bool]
    exit_code: NotRequired[int | None]
    reason: NotRequired[str]
    log_complete: NotRequired[bool]
    cleanup: NotRequired[CleanupReceipt]
    seconds: NotRequired[float]
    log: NotRequired[str]
    target_seconds: NotRequired[float]
    over_target: NotRequired[bool]
    skipped: NotRequired[list[str]]


def tmux_configure_command(target: Path, version: str, os_name: str) -> list[str]:
    command = ["./configure", f"--prefix={target}"]
    if os_name == "Darwin":
        command.append("--enable-utf8proc")
        if version in ("3.5a", "3.6b", "3.7c"):
            command.append("--enable-jemalloc")
    return command


def build_tmux(args: argparse.Namespace) -> None:
    stage = checked_stage(args.stage, create=True)
    target = stage / "tmux" / args.version
    binary = target / "bin" / "tmux"
    if not binary.is_file():
        target.mkdir(parents=True, exist_ok=True)
        archive = target / "source.tar.gz"
        url = f"https://github.com/tmux/tmux/releases/download/{args.version}/tmux-{args.version}.tar.gz"
        with urllib.request.urlopen(url) as source, archive.open("wb") as output:
            shutil.copyfileobj(source, output)
        if (
            hashlib.sha256(archive.read_bytes()).hexdigest()
            != TMUX_SHA256[args.version]
        ):
            raise ValueError(
                "tmux source digest differs from the pinned official release"
            )
        with tarfile.open(archive) as source:
            source.extractall(target, filter="data")
        source_root = target / f"tmux-{args.version}"
        subprocess.run(
            tmux_configure_command(target, args.version, platform.system()),
            cwd=source_root,
            check=True,
        )
        subprocess.run(["make", "-j2"], cwd=source_root, check=True)
        subprocess.run(["make", "install"], cwd=source_root, check=True)
    observed = subprocess.check_output([str(binary), "-V"], text=True).strip()
    if observed != f"tmux {args.version}":
        raise ValueError("built tmux version differs from the requested release")
    print(binary)


def tmux_repository() -> str:
    return os.environ.get("LIBTMUX_TMUX_REPOSITORY", "https://github.com/tmux/tmux.git")


def resolve_tmux_ref(ref: str) -> str:
    """Name the commit that a tag, a branch or a full commit of tmux points at.

    A tag is peeled to its commit and wins over a branch of the same name, as it
    does for a clone.
    """
    check_ref(ref)
    if re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    names = (f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}")
    listing = subprocess.check_output(
        ["git", "ls-remote", tmux_repository(), *names], text=True
    )
    found = {
        name: commit
        for commit, _, name in (line.partition("\t") for line in listing.splitlines())
    }
    for name in names:
        if re.fullmatch(r"[0-9a-f]{40}", found.get(name, "")):
            return found[name]
    raise ValueError(f"{ref} is not a tag, a branch or a full commit of tmux")


def build_tmux_ref(args: argparse.Namespace) -> None:
    """Build tmux from source at the commit a ref names.

    Table releases are built from their official tarballs and checked against
    pinned digests. A ref has neither, so it is fetched by commit and its built
    version is reported, not compared with a release.
    """
    commit = resolve_tmux_ref(args.ref)
    stage = checked_stage(args.stage, create=True)
    target = stage / "tmux" / f"ref-{commit}"
    binary = target / "bin" / "tmux"
    if not binary.is_file():
        source = target / "source"
        source.mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(source)]
        subprocess.run([*git, "init", "--quiet"], check=True)
        subprocess.run(
            [*git, "fetch", "--quiet", "--depth", "1", tmux_repository(), commit],
            check=True,
        )
        subprocess.run(
            [*git, "checkout", "--quiet", "--detach", "FETCH_HEAD"], check=True
        )
        if (
            subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()
            != commit
        ):
            raise ValueError("tmux source is not at the requested commit")
        for command in (
            ["sh", "autogen.sh"],
            tmux_configure_command(target, commit, platform.system()),
            ["make", "-j2"],
            ["make", "install"],
        ):
            subprocess.run(command, cwd=source, check=True, stdout=sys.stderr)
    observed = subprocess.check_output([str(binary), "-V"], text=True).strip()
    if not observed.startswith("tmux "):
        raise ValueError("built tmux reports no version")
    print(f"commit={commit}")
    print(f"binary={binary}")
    print(f"version={observed.removeprefix('tmux ')}")


SKIPPED_PATTERN = re.compile(r"(?:^|\s)SKIPPED\b.*|Warning: .*\bskipped\b.*")


def skipped_checks(log: Path) -> list[str]:
    """Lines in a phase log that report a check skipped on this tmux release."""
    if not log.is_file():
        return []
    found = []
    for line in log.read_text(errors="replace").splitlines():
        matched = SKIPPED_PATTERN.search(line)
        if matched and matched.group(0).strip() not in found:
            found.append(matched.group(0).strip())
    return found


def report_skipped(result: dict[str, Any]) -> None:
    """Surface skipped checks in the result and the job summary; a skip is not a pass."""
    skipped = [
        (item["name"], line)
        for item in result["phases"]
        for line in item.get("skipped", [])
    ]
    result["skipped_checks"] = [
        {"phase": name, "detail": line} for name, line in skipped
    ]
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if skipped and summary:
        with Path(summary).open("a", encoding="utf-8") as output:
            output.write("### Skipped checks\n\n")
            output.writelines(f"- `{name}`: {line}\n" for name, line in skipped)


def source_digest() -> str:
    digest = hashlib.sha256()
    inputs = (
        "Project.toml",
        "pyproject.toml",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        ".github/workflows",
        "src",
        "ext",
        "test",
        "schema",
        "docs",
        "examples",
        "packages",
        "dev",
        "benchmark",
    )
    for base in inputs:
        root = ROOT / base
        files = [root] if root.is_file() else root.rglob("*")
        for path in sorted(files):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(ROOT)
            if relative.parts[:2] == ("benchmark", "results"):
                continue
            if any(
                part in ("build", "__pycache__", ".git", "node_modules")
                for part in relative.parts
            ):
                continue
            if path.name.startswith("Manifest") or path.suffix in (".log", ".pyc"):
                continue
            digest.update(str(relative).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()


def checked_stage(path: str | Path, *, create: bool = False) -> Path:
    stage = Path(path).resolve()
    if stage == ROOT or ROOT in stage.parents:
        raise ValueError("the prepared stage must be outside the checkout")
    marker = stage / ".libtmux-julia-matrix"
    if create:
        stage.mkdir(parents=True, exist_ok=True)
        if not marker.exists() and any(stage.iterdir()):
            raise ValueError(
                "preparation requires an empty stage or an owned matrix stage"
            )
        if not marker.exists():
            marker.write_text(str(uuid.uuid4()))
    elif not marker.is_file():
        raise ValueError("stage is not prepared; run prepare outside timed checks")
    return stage


def signal_group(process: subprocess.Popen[bytes], number: int) -> None:
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        # Exit may win the race between the waiter deadline and signal delivery.
        pass
    except PermissionError:
        # macOS refuses to signal a group whose leader has exited; the leader
        # is reaped by the waiter either way.
        if sys.platform != "darwin":
            raise


def enable_subreaper() -> None:
    """Linux reparents orphaned descendants to this runner for bounded cleanup."""
    if sys.platform == "linux":
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise OSError(ctypes.get_errno(), "cannot own orphaned test descendants")


def retire(process: subprocess.Popen[bytes]) -> bool:
    for number, grace in ((signal.SIGINT, 3), (signal.SIGTERM, 2), (signal.SIGKILL, 5)):
        if process.poll() is not None:
            return True
        signal_group(process, number)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            continue
    return process.poll() is not None


def retire_orphans(budget: float = 10) -> CleanupReceipt:
    """Reap only our children, including detached daemons adopted on Linux."""
    answer: CleanupReceipt = {
        "descendant_retirement": "unverified on this platform",
        "reaped": [],
        "killed": [],
        "survivors": [],
    }
    if sys.platform != "linux":
        return answer
    children = Path(f"/proc/{os.getpid()}/task/{os.getpid()}/children")
    deadline = time.monotonic() + budget
    while True:
        owned = [int(pid) for pid in children.read_text().split()]
        if not owned:
            answer["descendant_retirement"] = "verified"
            return answer
        if time.monotonic() >= deadline:
            answer["survivors"] = owned
            return answer
        for pid in owned:
            if os.waitpid(pid, os.WNOHANG)[0]:
                answer["reaped"].append(pid)
                continue
            with selectors.DefaultSelector() as selector:
                descriptor = os.pidfd_open(pid)
                try:
                    selector.register(descriptor, selectors.EVENT_READ)
                    if not selector.select(0):
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                        answer["killed"].append(pid)
                    if selector.select(max(0, deadline - time.monotonic())):
                        os.waitpid(pid, 0)
                        answer["reaped"].append(pid)
                finally:
                    os.close(descriptor)


def phase(
    name: str,
    argv: list[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    log: Path,
    budget: float,
    completion: bool = False,
) -> PhaseResult:
    """Stream original output; bound work and cleanup independently."""
    start = time.monotonic()
    log.parent.mkdir(parents=True, exist_ok=True)
    answer: PhaseResult = {
        "name": name,
        "command": argv,
        "status": "NOT RUN",
        "hard_limit_seconds": budget,
    }
    process = None
    tee = None
    receipt = log.with_suffix(".toml")
    receipt.unlink(missing_ok=True)
    invocation = uuid.uuid4().hex
    temporary = tempfile.mkdtemp(prefix="ltj-check-", dir="/tmp")
    env = dict(
        env, JULIA_TEST_VERBOSE="true", TMPDIR=temporary, LIBTMUX_TEST_TMPDIR=temporary
    )
    if completion:
        env.update(
            LIBTMUX_TEST_COMPLETION=str(receipt), LIBTMUX_TEST_INVOCATION=invocation
        )
    else:
        env.pop("LIBTMUX_TEST_COMPLETION", None)
        env.pop("LIBTMUX_TEST_INVOCATION", None)
    print(f"PHASE START {name} invocation={invocation}", flush=True)
    try:
        tee = subprocess.Popen(
            ["tee", str(log)], stdin=subprocess.PIPE, start_new_session=True
        )
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=tee.stdin,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        assert tee.stdin is not None
        tee.stdin.close()
        answer.update({"pid": process.pid, "invocation": invocation})
        try:
            process.wait(timeout=max(0, budget))
            answer["status"] = "PASS" if process.returncode == 0 else "FAIL"
        except subprocess.TimeoutExpired:
            answer["status"] = "TIMEOUT"
        if completion and answer["status"] == "PASS":
            try:
                report = tomllib.loads(receipt.read_text())
                valid = (
                    report["invocation"] == invocation
                    and report["pid"] == process.pid
                    and report["status"] == "PASS"
                    and bool(report["files"])
                    and all(row["outcome"] == "RETURNED" for row in report["files"])
                )
            except (OSError, ValueError, KeyError, TypeError):
                valid = False
            if not valid:
                answer.update(
                    {
                        "status": "INCOMPLETE",
                        "reason": "missing, stale or incomplete test receipt",
                    }
                )
    except KeyboardInterrupt:
        answer["status"] = "INTERRUPTED"
    except FileNotFoundError:
        answer["reason"] = "required executable is unavailable"
    finally:
        if process is not None:
            answer.update(
                {
                    "direct_child_reaped": retire(process),
                    "exit_code": process.returncode,
                }
            )
        if tee is not None:
            assert tee.stdin is not None
            if not tee.stdin.closed:
                tee.stdin.close()
            try:
                tee.wait(timeout=2)
            except subprocess.TimeoutExpired:
                retire(tee)
            answer["log_complete"] = tee.returncode == 0
        answer["cleanup"] = retire_orphans()
        if not answer["cleanup"]["survivors"] and answer.get(
            "direct_child_reaped", True
        ):
            shutil.rmtree(temporary)
            answer["cleanup"]["temporary_directory_removed"] = True
        else:
            answer["cleanup"]["temporary_directory_removed"] = False
        if answer["status"] == "PASS" and (
            answer["cleanup"]["killed"]
            or answer["cleanup"]["survivors"]
            or not answer.get("log_complete", False)
        ):
            answer.update(
                {
                    "status": "FAIL",
                    "reason": "test process left descendants or incomplete output",
                }
            )
        answer["seconds"] = time.monotonic() - start
        answer["log"] = str(log)
        print(
            f"PHASE END {name} {answer['status']} {answer['seconds']:.3f}s", flush=True
        )
    return answer


PACKAGE_SPECIFICATIONS = r"""
using Pkg
function package_specifications(arguments)
    pairs = [split(argument, '='; limit=2) for argument in arguments]
    [PackageSpec(name=String(first(pair)), version=VersionNumber(last(pair))) for pair in pairs]
end
"""

PREPARE = (
    PACKAGE_SPECIFICATIONS
    + r"""
root, project = ARGS[1:2]
Pkg.activate(project)
Pkg.develop([PackageSpec(path=root),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxWorkspace")),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxMCP"))])
packages = package_specifications(ARGS[3:end])
Pkg.add(packages)
resolved = values(Pkg.dependencies())
for package in packages
    any(info -> info.name == package.name && info.version == package.version, resolved) ||
        error("resolved quality tool differs from its admitted version: " * package.name)
end
Pkg.precompile()
"""
)


# A client that names no socket follows an inherited TMUX to the server its
# caller is inside, and otherwise goes to the default socket under TMUX_TMPDIR.
# sun_path is 104 bytes on macOS; the sandbox leaves room for /tmux-<uid>/<name>.
SANDBOX_MAX_BYTES = 60
SANDBOX_PREFIX = "ltj-sb-"
_sandbox: Path | None = None


def selects_server(name: str) -> bool:
    return name in ("TMUX", "TMUX_PANE") or name.startswith("LIBTMUX_SOCKET")


def make_sandbox(roots: Iterable[str]) -> Path:
    """Make a private directory under the first root short enough for a socket path."""
    for root in roots:
        # The separator, the prefix and the eight characters mkdtemp appends.
        if len(root.encode()) + len(SANDBOX_PREFIX) + 9 <= SANDBOX_MAX_BYTES:
            try:
                return Path(tempfile.mkdtemp(prefix=SANDBOX_PREFIX, dir=root))
            except OSError:
                continue
    raise ValueError(
        "no temporary directory is short enough for a tmux socket path; "
        "set TMPDIR to a shorter one"
    )


def matrix_sandbox() -> Path:
    """Return this process's sandbox, made once and removed when it exits."""
    global _sandbox
    if _sandbox is None:
        _sandbox = make_sandbox(dict.fromkeys([tempfile.gettempdir(), "/tmp"]))
        atexit.register(remove_sandbox, _sandbox)
    _sandbox.mkdir(mode=0o700, exist_ok=True)
    return _sandbox


def sandbox_findings(env: Mapping[str, str], sandbox: Path) -> list[str]:
    """Name what keeps `env` from being the sandbox, never a value."""
    found = [f"{name} is set" for name in sorted(env) if selects_server(name)]
    if env.get("TMUX_TMPDIR") != str(sandbox):
        found.append("TMUX_TMPDIR is not the matrix sandbox")
    return found


def sandbox_leaks(sandbox: Path) -> list[str]:
    """List every socket below the sandbox, however a server came to be on it.

    A client with no -S or -L chooses one under tmux-<uid>; a test may name its
    own. A symbolic link is not followed: the server it names is not ours to stop.
    """
    found = []
    for directory, _, names in os.walk(sandbox):
        for name in names:
            path = Path(directory) / name
            try:
                is_socket = stat.S_ISSOCK(os.lstat(path).st_mode)
            except OSError:
                continue
            if is_socket:
                found.append(str(path.relative_to(sandbox)))
    return sorted(found)


def socket_answers(path: Path) -> bool:
    """Connect as a client does: only a live server accepts, or is too busy to."""
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(1)
        try:
            client.connect(str(path))
        except (TimeoutError, BlockingIOError):
            return True
        except OSError:
            return False
    return True


def socket_gone(path: Path, patience: float = 5.0) -> bool:
    deadline = time.monotonic() + patience
    while socket_answers(path):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.025)
    return True


def remove_sandbox(sandbox: Path) -> None:
    """Remove the sandbox unless a server still answers on a socket in it."""
    if not any(socket_answers(sandbox / name) for name in sandbox_leaks(sandbox)):
        shutil.rmtree(sandbox, ignore_errors=True)


def release_sandbox(
    sandbox: Path, tmux: str, patience: float = 5.0
) -> tuple[list[str], list[str]]:
    """Stop the server on each socket with -S and list them, then remove the sandbox.

    Return the sockets found and those whose server still answers after
    kill-server. The sandbox stays while any answers.
    """
    found = sandbox_leaks(sandbox)
    kept = []
    env = {k: v for k, v in os.environ.items() if not selects_server(k)}
    for relative in found:
        path = sandbox / relative
        with contextlib.suppress(subprocess.TimeoutExpired):
            subprocess.run(
                [tmux, "-u", "-N", "-S", str(path), "kill-server"],
                env=env,
                capture_output=True,
                check=False,
                timeout=patience,
            )
        if not socket_gone(path, patience):
            kept.append(relative)
    if not kept:
        shutil.rmtree(sandbox, ignore_errors=True)
    return found, kept


def environment(stage: Path, *, offline: bool) -> dict[str, str]:
    sandbox = matrix_sandbox()
    env = {k: v for k, v in os.environ.items() if not selects_server(k)}
    env.pop("LIBTMUX_TEST_SANDBOX", None)
    env.update(
        JULIA_DEPOT_PATH=str(stage / "depot"),
        JULIA_LOAD_PATH="@:@stdlib",
        JULIA_PKG_OFFLINE="true" if offline else "false",
        JULIA_PKG_PRECOMPILE_AUTO="0",
        TMUX_TMPDIR=str(sandbox),
    )
    findings = sandbox_findings(env, sandbox)
    if findings:
        raise ValueError(
            "the cell environment is not a tmux sandbox: " + "; ".join(findings)
        )
    return env


def seed_registry_cache(
    source_depot: Path, consumer_depot: Path
) -> list[dict[str, Any]]:
    """Copy registry bytes without sharing writable files or extending DEPOT_PATH."""
    source = source_depot / "registries"
    destination = consumer_depot / "registries"
    if not source.is_dir() or source.is_symlink():
        raise ValueError("quality preparation did not produce an owned registry cache")
    if destination.exists() or destination.is_symlink():
        raise ValueError("consumer registry seeding requires an empty destination")
    entries = sorted(source.rglob("*"))
    if not entries or any(
        path.is_symlink() or not (path.is_file() or path.is_dir()) for path in entries
    ):
        raise ValueError(
            "registry cache must contain only regular files and directories"
        )
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
        if (
            copied.samefile(path)
            or hashlib.sha256(copied.read_bytes()).hexdigest() != expected
        ):
            raise ValueError(
                "consumer registry copy failed independent-byte verification"
            )
        records.append(
            {"file": str(relative), "sha256": expected, "bytes": copied.stat().st_size}
        )
    return records


def seed_stdlib_cache(
    source_depot: Path, consumer_depot: Path, version: str, modules: Iterable[str]
) -> list[dict[str, Any]]:
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
            if path.suffix not in (".ji", ".so", ".dylib") or path.name.startswith(
                "jl_"
            ):
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError("stdlib cache must contain regular completed files")
            relative = path.relative_to(source)
            copied = destination / relative
            expected = hashlib.sha256(path.read_bytes()).hexdigest()
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, copied)
            if (
                copied.samefile(path)
                or hashlib.sha256(copied.read_bytes()).hexdigest() != expected
            ):
                raise ValueError("stdlib copy failed independent-byte verification")
            records.append(
                {
                    "file": str(relative),
                    "sha256": expected,
                    "bytes": copied.stat().st_size,
                }
            )
    return records


def stdlib_cache_profile(julia: str, env: Mapping[str, str]) -> dict[str, Any]:
    program = """println(VERSION)
    println("v", VERSION.major, ".", VERSION.minor)
    foreach(println, filter(name -> isdir(joinpath(Sys.STDLIB, name)), readdir(Sys.STDLIB)))
    """
    lines = subprocess.check_output(
        [julia, "--startup-file=no", "--history-file=no", "-e", program],
        env=env,
        text=True,
    ).splitlines()
    return {"julia": lines[0], "version": lines[1], "modules": lines[2:]}


def prepare(args: argparse.Namespace) -> None:
    started_preparation = time.monotonic()
    stage = checked_stage(args.stage, create=True)
    initial_digest = source_digest()
    project = stage / "environment"
    project.mkdir(exist_ok=True)
    (project / "LocalPreferences.toml").write_text(TOOL_PREFERENCES)
    env = environment(stage, offline=False)
    argv = [
        args.julia,
        "--startup-file=no",
        f"--project={project}",
        "-e",
        PREPARE,
        str(ROOT),
        str(project),
        *[f"{name}={version}" for name, version in PINNED_TOOLS.items()],
    ]
    # Preparation is a separate tier: package resolution/network/precompilation.
    subprocess.run(argv, cwd=ROOT, env=env, check=True)
    subprocess.run(
        [
            args.julia,
            "--startup-file=no",
            "--compile=min",
            "-O0",
            f"--project={project}",
            "-e",
            "using Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, ModelContextProtocol, JSON, Tables",
        ],
        cwd=ROOT,
        env=env,
        check=True,
    )
    subprocess.run(
        format_warmup_command(args, project),
        cwd=ROOT,
        env=environment(stage, offline=True),
        check=True,
    )
    consumers = stage / ("consumers-" + uuid.uuid4().hex)
    started = time.monotonic()
    registry_files = seed_registry_cache(stage / "depot", consumers / "depot")
    registry_seed = {"seconds": time.monotonic() - started, "files": registry_files}
    started = time.monotonic()
    profile = stdlib_cache_profile(args.julia, env)
    stdlib_files = seed_stdlib_cache(
        stage / "depot", consumers / "depot", profile["version"], profile["modules"]
    )
    stdlib_seed = {
        "seconds": time.monotonic() - started,
        "profile": profile,
        "files": stdlib_files,
    }
    subprocess.run(
        [
            args.julia,
            "--startup-file=no",
            "--compile=yes",
            "-O2",
            str(ROOT / "dev/check-consumers.jl"),
            "prepare",
            str(consumers),
        ],
        cwd=ROOT,
        env=env,
        check=True,
    )
    if initial_digest != source_digest():
        raise ValueError(
            "source changed during preparation; rerun with stable source (dependency cache retained)"
        )
    metadata = {
        "schema_version": 1,
        "source_digest": initial_digest,
        "tools": PINNED_TOOLS,
        "seconds": time.monotonic() - started_preparation,
        "consumers": str(consumers),
        "project": str(project),
        "registry_seed": registry_seed,
        "stdlib_seed": stdlib_seed,
        "tool_preferences": tomllib.loads(TOOL_PREFERENCES),
    }
    (stage / "prepared.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(
        "PASS prepared dependencies and immutable external consumers; no timed checks run"
    )


def format_warmup_command(args: argparse.Namespace, project: Path) -> list[str]:
    return [
        args.julia,
        "--startup-file=no",
        f"--threads={args.threads}",
        f"--project={project}",
        str(ROOT / "dev/check-quality.jl"),
        "format",
    ]


def command_plan(
    args: argparse.Namespace, stage: Path, metadata: dict[str, Any]
) -> list[tuple[str, list[str], float, str]]:
    project = metadata["project"]
    normal = [
        args.julia,
        "--startup-file=no",
        f"--threads={args.threads}",
        f"--project={project}",
    ]
    minimal = [*normal, "--compile=min", "-O0"]
    commands = []

    def add(name: str, argv: list[str], budget: float, tier: str) -> None:
        commands.append((name, argv, budget, tier))

    add("core-unit", [*minimal, "test/runtests.jl", "unit"], 30, "unit")
    add(
        "workspace-unit",
        [*minimal, "packages/LibTmuxWorkspace/test/runtests.jl", "unit"],
        30,
        "unit",
    )
    add(
        "mcp-unit",
        [*minimal, "packages/LibTmuxMCP/test/runtests.jl", "unit"],
        30,
        "unit",
    )
    add("quality", [*minimal, "dev/check-quality.jl", "quality"], 30, "quality")
    add("format", [*normal, "dev/check-quality.jl", "format"], 30, "quality")
    add("generated", [*minimal, "dev/generate-criteria.jl", "--check"], 30, "quality")
    add(
        "generated-options",
        [*minimal, "dev/generate-options.jl", "--check"],
        30,
        "quality",
    )
    add(
        "consumer-diagnostics",
        [*minimal, "dev/check-consumers.jl", "--self-test"],
        30,
        "quality",
    )
    add(
        "test-progress",
        [sys.executable, "dev/test-progress.py", args.julia],
        5,
        "quality",
    )
    add(
        "example-inventory",
        [*minimal, "dev/check-doc-examples.jl", "check"],
        30,
        "quality",
    )
    add(
        "readme-links",
        [*minimal, "dev/check-readme-commands.jl", "static"],
        30,
        "quality",
    )
    add("core-normal", [*normal, "test/runtests.jl", "all"], 300, "outer")
    add(
        "workspace-normal",
        [*normal, "packages/LibTmuxWorkspace/test/runtests.jl", "all"],
        300,
        "outer",
    )
    add(
        "mcp-normal",
        [*normal, "packages/LibTmuxMCP/test/runtests.jl", "all"],
        300,
        "outer",
    )
    add("mcp-product", [*normal, "packages/LibTmuxMCP/test/product.jl"], 300, "outer")
    add(
        "mcp-stopped-reader",
        [
            sys.executable,
            "packages/LibTmuxMCP/test/stdio_backpressure.py",
            args.julia,
            project,
            "--compile",
            "normal",
            "--threads",
            str(args.threads),
        ],
        300,
        "outer",
    )
    extensions = 'using Test, LibTmux; include("test/criteria.jl"); include("test/json_extension.jl"); include("test/tables_extension.jl")'
    add("extensions", [*normal, "-e", extensions], 300, "outer")
    add("docs", [*normal, "docs/make.jl"], 300, "outer")
    add("api-export", [*normal, "docs/export-api.jl"], 300, "outer")
    add("api-export-check", [*normal, "docs/test-export-api.jl"], 300, "outer")
    add("doc-snippets", [*normal, "dev/check-doc-examples.jl", "doctest"], 300, "outer")
    add(
        "doc-contextual",
        [*normal, "dev/check-doc-examples.jl", "contextual"],
        300,
        "outer",
    )
    add(
        "imports",
        [*minimal, "dev/check-consumers.jl", "check", metadata["consumers"]],
        300,
        "outer",
    )
    add(
        "external-examples",
        [*minimal, "dev/check-consumers.jl", "examples", metadata["consumers"]],
        300,
        "outer",
    )
    add(
        "external-launchers",
        [*minimal, "dev/check-consumers.jl", "launchers", metadata["consumers"]],
        300,
        "outer",
    )
    add(
        "readme-commands",
        [*normal, "dev/check-readme-commands.jl", "commands"],
        300,
        "outer",
    )
    return commands


def run(args: argparse.Namespace) -> int:
    enable_subreaper()
    stage = checked_stage(args.stage)
    metadata = json.loads((stage / "prepared.json").read_text())
    if metadata["source_digest"] != source_digest():
        raise ValueError(
            "source changed since preparation; prepare a fresh source snapshot before checks"
        )
    preferences = Path(metadata["project"]) / "LocalPreferences.toml"
    if tomllib.loads(preferences.read_text()) != metadata["tool_preferences"]:
        raise ValueError(
            "tool preferences changed since preparation; prepare a fresh stage"
        )
    env = environment(stage, offline=True)
    env.update(
        LIBTMUX_TEST_TMUX=args.tmux,
        LIBTMUX_TEST_CLI_COMPILE="normal",
        LIBTMUX_TEST_MINIMAL_CHILD="0",
        JULIA_TEST_VERBOSE="true",
    )
    work_seconds: float = HARD_WORK_SECONDS
    if "MATRIX_JOB_DEADLINE" in env:
        work_seconds = min(
            work_seconds, max(0, float(env["MATRIX_JOB_DEADLINE"]) - time.time() - 180)
        )
    deadline = time.monotonic() + work_seconds
    phases: list[PhaseResult] = []
    result = {
        "schema_version": 2,
        "source_digest": metadata["source_digest"],
        "platform": platform.system(),
        "machine": platform.machine(),
        "kernel": platform.release(),
        "wsl": "microsoft" in platform.release().lower(),
        "threads": args.threads,
        "tools": metadata["tools"],
        "status": "NOT RUN",
        "phases": phases,
        "suite": args.suite,
        "tier": args.tier,
        "active_phase": None,
    }
    result["invocation"] = uuid.uuid4().hex
    result.update(
        hard_work_seconds=work_seconds, preparation_seconds=metadata.get("seconds")
    )
    suffix = "" if args.suite == "all" else f"-{args.suite}"
    destination = (
        stage
        / f"results-{args.tier}{suffix}-t{args.threads}-{result['invocation'][:8]}.json"
    )
    log_directory = stage / "logs" / result["invocation"]

    def save() -> None:
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(destination)

    save()
    for key, argv in (
        ("julia", [args.julia, "--startup-file=no", "--version"]),
        ("tmux", [args.tmux, "-V"]),
    ):
        resolved = shutil.which(argv[0])
        if resolved is None:
            result["reason"] = f"{key} executable is unavailable"
            break
        result[key] = subprocess.check_output(argv, env=env, text=True).strip()
    else:
        expected = (
            (
                args.expected_julia,
                result["julia"].removeprefix("julia version "),
                "Julia",
            ),
            (args.expected_tmux, result["tmux"].removeprefix("tmux "), "tmux"),
            (args.expected_os, result["platform"], "OS"),
            (args.expected_arch, result["machine"], "architecture"),
        )
        mismatch = next(
            (
                name
                for requested, actual, name in expected
                if requested and requested != actual
            ),
            None,
        )
        if mismatch:
            result["reason"] = f"observed {mismatch} differs from the requested cell"
        else:
            commands = selected_commands(args, stage, metadata)
            result.update(
                status="RUNNING", planned_phases=[item[0] for item in commands]
            )
            try:
                for name, argv, budget, _tier in commands:
                    result["active_phase"] = name
                    save()
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        result.update(
                            status="TIMEOUT", reason="hard work limit reached"
                        )
                        break
                    native_suite = any(
                        argument.endswith("/test/runtests.jl")
                        or argument == "test/runtests.jl"
                        for argument in argv
                    )
                    item = phase(
                        name,
                        argv,
                        cwd=ROOT,
                        env=env,
                        log=log_directory / f"{name}.log",
                        budget=remaining,
                        completion=native_suite,
                    )
                    item.update(
                        {
                            "target_seconds": budget,
                            "over_target": item["seconds"] > budget,
                        }
                    )
                    item["skipped"] = skipped_checks(log_directory / f"{name}.log")
                    phases.append(item)
                    result["active_phase"] = None
                    save()
                    print(f"{item['status']} {name} {item['seconds']:.3f}s", flush=True)
                    for line in item["skipped"]:
                        print(f"::warning title=Skipped in {name}::{line}", flush=True)
                    if (
                        item["status"] in ("TIMEOUT", "INTERRUPTED")
                        or item["cleanup"]["survivors"]
                    ):
                        result["status"] = item["status"]
                        break
                report_skipped(result)
                leaked, kept = release_sandbox(Path(env["TMUX_TMPDIR"]), args.tmux)
                result["sandbox_leaks"] = leaked
                result["sandbox_kept"] = kept
                for relative in leaked:
                    print(
                        f"::error title=tmux sandbox::a socket was left at {relative}"
                        + (
                            "; its server still answers and the sandbox was kept"
                            if relative in kept
                            else ""
                        ),
                        flush=True,
                    )
                completed = {item["name"] for item in phases}
                result["not_run"] = [
                    name for name, *_ in commands if name not in completed
                ]
                if result["status"] == "RUNNING":
                    result["status"] = (
                        "PASS"
                        if not result["not_run"]
                        and not leaked
                        and phases
                        and all(p["status"] == "PASS" for p in phases)
                        else "FAIL"
                    )
                if metadata["source_digest"] != source_digest():
                    result.update(status="STALE", reason="source changed during checks")
            except BaseException as error:
                result.update(
                    status="INTERRUPTED"
                    if isinstance(error, KeyboardInterrupt)
                    else "FAIL",
                    error_type=type(error).__name__,
                )
                raise
            finally:
                save()
    save()
    print(f"{result['status']} matrix result: {destination}")
    return 0 if result["status"] == "PASS" else 1


def selected_commands(
    args: argparse.Namespace, stage: Path, metadata: dict[str, Any]
) -> list[tuple[str, list[str], float, str]]:
    return [
        item
        for item in command_plan(args, stage, metadata)
        if (args.tier == "all" or item[3] == args.tier)
        and (
            args.suite == "all"
            or (item[0] in DELIVERY_PHASES) == (args.suite == "delivery")
        )
    ]


def artifacts(stage: str | Path) -> int:
    """Export readable evidence without local paths or known credential values."""
    stage = checked_stage(stage)
    destination = stage / "artifacts"
    destination.mkdir(exist_ok=True)
    deadline = time.monotonic() + 30
    replacements = [
        (str(stage), "<stage>"),
        (str(ROOT), "<checkout>"),
        (str(Path.home()), "<home>"),
    ]
    replacements += [
        (path.replace(str(Path.home()), "~", 1), replacement)
        for path, replacement in list(replacements)
        if path.startswith(str(Path.home()) + os.sep)
    ]
    replacements.append(("~/", "<home>/"))
    replacements += [
        (value, "<redacted>")
        for key, value in os.environ.items()
        if re.search(r"TOKEN|SECRET|PASSWORD|CREDENTIAL", key) and len(value) >= 8
    ]

    def sanitize(text: str) -> str:
        for value, replacement in sorted(
            replacements, key=lambda pair: len(pair[0]), reverse=True
        ):
            text = text.replace(value, replacement)
        return text

    sources = [
        *stage.glob("results-*.json"),
        *stage.glob("prepared.json"),
        *stage.glob("logs/**/*.log"),
        *stage.glob("logs/**/*.toml"),
    ]
    incomplete = []
    for source in sources:
        exported = destination / source.relative_to(stage)
        exported.parent.mkdir(parents=True, exist_ok=True)
        with source.open(errors="replace") as original, exported.open("w") as output:
            for line in original:
                if time.monotonic() >= deadline:
                    incomplete.append(source.name)
                    output.write(
                        "\nARTIFACT EXPORT INTERRUPTED: finalization deadline\n"
                    )
                    break
                output.write(sanitize(line))
    rows = []
    summary = []
    receipts = {}
    for source in stage.glob("results-*.json"):
        result = json.loads(source.read_text())
        summary.append(f"{source.name}: {result['status']}\n")
        summary.append(f"Preparation: {result.get('preparation_seconds')} seconds\n")
        if result.get("active_phase"):
            summary.append(f"  INCOMPLETE {result['active_phase']}\n")
        for item in result["phases"]:
            if "log" in item and "invocation" in item:
                receipts[Path(item["log"]).with_suffix(".toml")] = (
                    item["invocation"],
                    item["pid"],
                )
            rows.append(
                {
                    "name": item["name"],
                    "status": item["status"],
                    "seconds": item["seconds"],
                    "target_seconds": item.get("target_seconds", ""),
                }
            )
            summary.append(
                f"  {item['status']} {item['name']}: {item['seconds']:.3f}s"
                + (" (over diagnostic target)" if item.get("over_target") else "")
                + "\n"
            )
        for name in result.get("not_run", []):
            summary.append(f"  NOT RUN {name}\n")
    for source in stage.glob("logs/**/*.toml"):
        try:
            receipt = tomllib.loads(source.read_text())
            if receipts.get(source) != (receipt.get("invocation"), receipt.get("pid")):
                summary.append(f"Unmatched test receipt: {source.name}\n")
                continue
            for row in receipt["files"]:
                rows.append(
                    {
                        "name": row["file"],
                        "status": row["outcome"],
                        "seconds": row["seconds"],
                        "target_seconds": "",
                    }
                )
        except (ValueError, KeyError):
            summary.append(f"Incomplete test receipt: {source.name}\n")
    with (destination / "timings.csv").open("w", newline="") as output:
        writer = csv.DictWriter(
            output, fieldnames=("name", "status", "seconds", "target_seconds")
        )
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda row: row["seconds"], reverse=True))
    summary.append(
        "File and command timings overlap; add neither to their enclosing command.\n"
    )
    if incomplete:
        summary.append(f"Incomplete artifact exports: {', '.join(incomplete)}\n")
    rendered = sanitize("".join(summary))
    (destination / "summary.txt").write_text(rendered)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write("```text\n" + rendered + "```\n")
    print(rendered)
    return 1 if incomplete else 0


STAND_IN_AUTOGEN = """\
cat > configure <<'CONFIGURE'
#!/bin/sh
case "$1" in --prefix=*) prefix="${1#--prefix=}" ;; esac
printf 'PREFIX = %s\\n' "$prefix" > Makefile
cat >> Makefile <<'MAKEFILE'
all:
\t:
install:
\tmkdir -p $(PREFIX)/bin
\tprintf '#!/bin/sh\\necho "tmux %s"\\n' "$$(cat VERSION)" > $(PREFIX)/bin/tmux
\tchmod +x $(PREFIX)/bin/tmux
MAKEFILE
CONFIGURE
chmod +x configure
"""


def check_tmux_ref(base: Path) -> None:
    """Resolve and build refs against a local stand-in for the tmux repository."""
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest import mock

    repository = base / "tmux-stand-in"
    repository.mkdir()
    identity = {
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.invalid",
    }

    def git(*arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(repository), *arguments],
            text=True,
            env={**os.environ, **identity},
        ).strip()

    def commit(version: str) -> str:
        (repository / "VERSION").write_text(version + "\n")
        (repository / "autogen.sh").write_text(STAND_IN_AUTOGEN)
        git("add", "-A")
        git("commit", "--quiet", "-m", f"tmux {version}")
        return git("rev-parse", "HEAD")

    git("init", "--quiet", "-b", "master")
    release = commit("3.8")
    git("tag", "3.8")
    git("checkout", "--quiet", "-b", "topic")
    annotated = commit("9.1")
    git("tag", "-a", "-m", "annotated", "9.1")
    tip = commit("9.2")

    def refusal(ref: str) -> str:
        try:
            resolve_tmux_ref(ref)
        except ValueError as error:
            return str(error)
        return ""

    with mock.patch.dict(os.environ, {"LIBTMUX_TMUX_REPOSITORY": str(repository)}):
        assert resolve_tmux_ref("3.8") == release
        assert resolve_tmux_ref("9.1") == annotated != git("rev-parse", "9.1")
        assert resolve_tmux_ref("topic") == tip
        assert resolve_tmux_ref(tip) == tip
        git("branch", "3.8", tip)
        assert resolve_tmux_ref("3.8") == release, "a tag wins over a branch"
        for bad in ("--upload-pack=x", "a..b", "topic.lock", "$(id)", "deadbeef"):
            assert "tmux-ref item" in refusal(bad), bad
        assert "is not a tag, a branch" in refusal("no-such")

        stage = base / "ref-stage"
        arguments = argparse.Namespace(stage=str(stage), ref="topic")
        for _ in range(2):
            printed = StringIO()
            with redirect_stdout(printed):
                build_tmux_ref(arguments)
            binary = stage / "tmux" / f"ref-{tip}" / "bin" / "tmux"
            assert dict(
                line.split("=", 1) for line in printed.getvalue().splitlines()
            ) == {
                "commit": tip,
                "binary": str(binary),
                "version": "9.2",
            }
        # Preparation accepts only an empty or an owned stage, so a ref build has
        # to leave the owner's marker.
        assert (stage / ".libtmux-julia-matrix").is_file()
    print("PASS tmux refs resolve to commits and build at them")


def bind_stale_socket(path: Path) -> None:
    """Leave a socket file nothing listens on, as a server killed mid-run does."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with socket.socket(socket.AF_UNIX) as stale:
        stale.bind(str(path))


def self_test(julia: str | None = None) -> None:
    enable_subreaper()
    if julia:
        script = (
            PACKAGE_SPECIFICATIONS
            + r"""
specifications = package_specifications(["Aqua=0.8.18", "JSON=1.9.0"])
@assert length(specifications) == 2
@assert specifications[1].name == "Aqua"
@assert specifications[1].version == v"0.8.18"
@assert specifications[2].name == "JSON"
@assert specifications[2].version == v"1.9.0"
println("PASS admitted version arguments construct real Pkg specifications")
"""
        )
        subprocess.run(
            [julia, "--startup-file=no", "--compile=min", "-O0", "-e", script],
            check=True,
        )
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
        copied = seed_stdlib_cache(
            compiled.parent.parent, destination, "v1.13", ["Pkg"]
        )
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
            seed_stdlib_cache(
                compiled.parent.parent, base / "linked-stdlib", "v1.13", ["Pkg"]
            )
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
            "./configure",
            f"--prefix={base}",
            "--enable-utf8proc",
            "--enable-jemalloc",
        ]
        assert tmux_configure_command(base, "3.3a", "Darwin") == [
            "./configure",
            f"--prefix={base}",
            "--enable-utf8proc",
        ]
        assert tmux_configure_command(base, "3.7c", "Linux") == [
            "./configure",
            f"--prefix={base}",
        ]
        literal = "; $(touch must-not-exist)"
        ok = phase(
            "literal",
            [sys.executable, "-c", "import sys; print(sys.argv[1])", literal],
            cwd=base,
            env=os.environ.copy(),
            log=base / "literal.log",
            budget=0.9,
        )
        assert (
            ok["status"] == "PASS"
            and (base / "literal.log").read_text().strip() == literal
        )
        assert not (base / "must-not-exist").exists()
        failed = phase(
            "failure",
            [sys.executable, "-c", "raise SystemExit(7)"],
            cwd=base,
            env=os.environ.copy(),
            log=base / "failure.log",
            budget=0.9,
        )
        assert failed["status"] == "FAIL" and failed["exit_code"] == 7
        absent = phase(
            "missing",
            [str(base / "missing")],
            cwd=base,
            env=os.environ.copy(),
            log=base / "missing.log",
            budget=0.9,
        )
        assert absent["status"] == "NOT RUN"
        timed = phase(
            "deadline",
            [sys.executable, "-c", "import threading; threading.Event().wait()"],
            cwd=base,
            env=os.environ.copy(),
            log=base / "deadline.log",
            budget=0.05,
        )
        assert timed["status"] == "TIMEOUT" and timed["direct_child_reaped"]
        incomplete = phase(
            "incomplete",
            [sys.executable, "-c", "pass"],
            cwd=base,
            env=os.environ.copy(),
            log=base / "incomplete.log",
            budget=1,
            completion=True,
        )
        assert incomplete["status"] == "INCOMPLETE"
        for content in ('invocation = "stale"\n', 'invocation = "truncated'):
            code = (
                "import os; open(os.environ['LIBTMUX_TEST_COMPLETION'], 'w').write("
                + repr(content)
                + ")"
            )
            incomplete = phase(
                "bad-receipt",
                [sys.executable, "-c", code],
                cwd=base,
                env=os.environ.copy(),
                log=base / "bad.log",
                budget=1,
                completion=True,
            )
            assert incomplete["status"] == "INCOMPLETE"
        if sys.platform == "linux":
            child = "import threading; threading.Event().wait()"
            code = (
                "import subprocess,sys,threading; "
                f"subprocess.Popen([sys.executable,'-c',{child!r}],start_new_session=True); "
                "print('DETACHED_CHILD_STARTED',flush=True); threading.Event().wait()"
            )
            cancelled = phase(
                "detached",
                [sys.executable, "-c", code],
                cwd=base,
                env=os.environ.copy(),
                log=base / "detached.log",
                budget=0.2,
            )
            assert cancelled["status"] == "TIMEOUT"
            assert (
                cancelled["cleanup"]["reaped"] and not cancelled["cleanup"]["survivors"]
            )
            assert cancelled["cleanup"]["temporary_directory_removed"]
        log = base / "skipped.log"
        log.write_text(
            "PASS core\n\u250c Warning: control suites skipped: below 3.7\n"
            "SKIPPED README.md fence 3: control acquisition needs tmux 3.7\nPASS x\n"
        )
        assert skipped_checks(log) == [
            "Warning: control suites skipped: below 3.7",
            "SKIPPED README.md fence 3: control acquisition needs tmux 3.7",
        ]
        assert skipped_checks(base / "absent.log") == []
        # The plan carries its own checks; these hold the full scope to the cells
        # it has always had, and to the table and documents the workflow relies on.
        cells = qa_cells()
        assert [
            (cell["os"], cell["arch"], cell["julia"], cell["tmux"], cell["threads"])
            for cell in cells
        ] == [
            ("Linux", "x86_64", "1.13.1", "3.3a", 1),
            ("Linux", "x86_64", "1.13.1", "3.4", 1),
            ("Linux", "x86_64", "1.13.1", "3.5a", 1),
            ("Linux", "x86_64", "1.13.1", "3.6b", 1),
            ("Linux", "x86_64", "1.13.1", "3.7", 1),
            ("Linux", "x86_64", "1.13.1", "3.7a", 1),
            ("Linux", "x86_64", "1.13.1", "3.7b", 1),
            ("Linux", "x86_64", "1.13.1", "3.7c", 1),
            ("Linux", "x86_64", "1.13.1", "3.7c", 4),
            ("Linux", "x86_64", "1.13.1", "3.8", 1),
        ]
        floor_and_newest = ("3.3a", "3.7c", "3.8")
        assert all(
            cell["suites"]
            == (SUITES if cell["tmux"] in floor_and_newest else ("runtime",))
            for cell in cells
        )
        jobs = [(cell["label"], suite) for cell in cells for suite in cell["suites"]]
        assert len(jobs) == len(set(jobs))
        assert {cell["tmux"] for cell in cells} <= set(TMUX_SHA256)
        assert set(TMUX_SHA256) == {*SUPPORTED_TMUX, *REJECTED_TMUX}
        assert len({cell["label"] for cell in cells}) == len(cells)
        assert all(cell["status"] == "NOT RUN" for cell in cells)
        # A push and a pull request run the oldest and newest release, and the
        # newest release at four threads.
        newest = SUPPORTED_TMUX[-1]
        assert {cell["tmux"] for cell in qa_cells("edges")} == {MINIMUM_TMUX, newest}
        assert [cell["tmux"] for cell in cells if cell["docs_artifact"] == "true"] == [
            newest
        ]
        for name in ("docs/src/compatibility.md", "CONTRIBUTING.md"):
            text = (ROOT / name).read_text()
            unnamed = [
                tmux
                for tmux in (*SUPPORTED_TMUX, *REJECTED_TMUX)
                if not re.search(rf"(?<![\w.]){re.escape(tmux)}(?![\w])", text)
            ]
            assert not unnamed, f"{name} does not name tmux {unnamed}"
        check_tmux_ref(base)
        rejected = rejection_cells()
        assert [cell["tmux"] for cell in rejected] == ["3.0a", "3.1c", "3.2a", "3.3"]
        assert [cell["tmux"] for cell in rejected if cell["real_old"] == "true"] == [
            "3.0a",
            "3.1c",
        ]
        assert all(cell["tmux"] in TMUX_SHA256 for cell in rejected)
        # Every rejection lane runs behind a client at the floor release.
        workflow = (ROOT / ".github" / "workflows" / "julia.yml").read_text()
        step = workflow.split("- name: Prepare the current client", 1)[1]
        step = step.split("- name:", 1)[0]
        assert "if:" not in step and MINIMUM_TMUX in step
        client = [l for l in workflow.splitlines() if "LIBTMUX_TEST_CLIENT_TMUX" in l]
        assert client and all("real_old" not in l for l in client)
        # The package suites that need real old daemons run in the reject job
        # and fail rather than skip when the builds are absent.
        for suite in ("LibTmuxWorkspace", "LibTmuxMCP"):
            command = f"packages/{suite}/test/runtests.jl old-daemon"
            assert command in workflow, command
        assert workflow.count("LIBTMUX_TEST_REQUIRE_OLD_DAEMON: '1'") == 2
        # The reject environment must import what those steps import: direct
        # dependencies for the test files, and the core package's weak
        # dependencies, which Pkg.develop cannot validate on Julia 1.10 alone.
        prepare = workflow.split("- name: Prepare the package environment", 1)[1]
        prepare = prepare.split("- name:", 1)[0]
        needed = set(tomllib.loads((ROOT / "Project.toml").read_text())["weakdeps"])
        for suite in ("LibTmuxWorkspace", "LibTmuxMCP"):
            source = (ROOT / "packages" / suite / "test" / "old_daemon.jl").read_text()
            needed |= set(
                re.findall(r"(?m)^\s*(?:using|import)\s+([A-Za-z0-9_]+)", source)
            )
        needed -= {"Test", "LibTmux", "LibTmuxWorkspace", "LibTmuxMCP"}
        missing = sorted(name for name in needed if f'"{name}"' not in prepare)
        assert not missing, f"reject environment lacks {missing}"
        assert not {cell["tmux"] for cell in rejected} & {
            cell["tmux"] for cell in cells
        }
        assert all(cell["tmux"] != MINIMUM_TMUX for cell in rejected)
        assert len({cell["label"] for cell in rejected}) == len(rejected)
        from contextlib import redirect_stdout
        from io import StringIO
        from unittest.mock import patch

        dirty = {
            "TMUX": "/decoy-secret/sock,1,0",
            "TMUX_PANE": "%decoy-secret",
            "LIBTMUX_SOCKET": "decoy-secret",
            "LIBTMUX_SOCKET_PATH": "/decoy-secret",
            "LIBTMUX_SOCKET_FUTURE": "decoy-secret",
            "TMUX_TMPDIR": "/decoy-secret",
            "LIBTMUX_TEST_SANDBOX": "/decoy-secret",
            "LIBTMUX_TEST_TMUX": "tmux",
        }
        sandbox_stage = base / "sandbox-stage"
        sandbox_stage.mkdir()
        with patch.dict(os.environ, dirty):
            cleaned = environment(sandbox_stage, offline=True)
        sandbox = Path(cleaned["TMUX_TMPDIR"])
        assert sandbox_findings(cleaned, sandbox) == []
        assert sandbox == matrix_sandbox() and sandbox.is_dir()
        assert len(str(sandbox).encode()) < SANDBOX_MAX_BYTES
        assert cleaned["LIBTMUX_TEST_TMUX"] == "tmux"
        assert "LIBTMUX_TEST_SANDBOX" not in cleaned
        # The check fails on the environment it replaced, and names no value.
        flagged = sandbox_findings(dirty, sandbox)
        assert flagged == [
            "LIBTMUX_SOCKET is set",
            "LIBTMUX_SOCKET_FUTURE is set",
            "LIBTMUX_SOCKET_PATH is set",
            "TMUX is set",
            "TMUX_PANE is set",
            "TMUX_TMPDIR is not the matrix sandbox",
        ]
        assert "decoy-secret" not in "".join(flagged)
        too_long = "/" + "x" * SANDBOX_MAX_BYTES
        try:
            make_sandbox([too_long])
        except ValueError:
            pass
        else:
            raise AssertionError("a root too long for a socket path was accepted")
        fallback = make_sandbox([too_long, "/tmp"])
        assert fallback.parent == Path("/tmp") and fallback.is_dir()
        fallback.rmdir()
        assert sandbox_leaks(sandbox) == []
        (sandbox / "tmux-1000").mkdir()
        (sandbox / "tmux-1000" / "regular-file").write_text("")
        assert sandbox_leaks(sandbox) == []
        for name in ("tmux-1000/default", "custom.sock", "deep/er/nested.sock"):
            bind_stale_socket(sandbox / name)
        (sandbox / "link.sock").symlink_to(sandbox / "custom.sock")
        everywhere = ["custom.sock", "deep/er/nested.sock", "tmux-1000/default"]
        assert sandbox_leaks(sandbox) == everywhere
        # `true` stands in for a tmux whose kill-server leaves nothing listening.
        assert release_sandbox(sandbox, "true", patience=0.2) == (everywhere, [])
        assert not sandbox.exists()
        # A listener outlives a tmux that stops nothing, so the sandbox stays.
        sandbox = matrix_sandbox()
        survivor = sandbox / "survivor.sock"
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(survivor))
            listener.listen()
            released = release_sandbox(sandbox, "true", patience=0.2)
            assert released == (["survivor.sock"], ["survivor.sock"])
            remove_sandbox(sandbox)
            assert sandbox.is_dir() and survivor.exists()
        remove_sandbox(sandbox)
        assert not sandbox.exists()

        args = argparse.Namespace(
            stage=str(base),
            julia="julia",
            tmux="tmux",
            threads=1,
            tier="all",
            suite="all",
            expected_julia=None,
            expected_tmux=None,
            expected_os=None,
            expected_arch=None,
        )
        metadata = {
            "source_digest": "fixed",
            "tools": {},
            "project": str(base),
            "consumers": str(base),
            "tool_preferences": tomllib.loads(TOOL_PREFERENCES),
        }
        all_names = [item[0] for item in selected_commands(args, base, metadata)]
        budgets = {
            name: budget
            for name, _, budget, _ in selected_commands(args, base, metadata)
        }
        assert budgets["format"] == 30
        assert format_warmup_command(args, base) == [
            "julia",
            "--startup-file=no",
            "--threads=1",
            f"--project={base}",
            str(ROOT / "dev/check-quality.jl"),
            "format",
        ]
        partitions: list[str] = []
        for suite in SUITES:
            args.suite = suite
            partitions.extend(
                item[0] for item in selected_commands(args, base, metadata)
            )
        assert len(partitions) == len(set(partitions)) == len(all_names)
        assert set(partitions) == set(all_names)
        assert set(all_names) >= DELIVERY_PHASES
        args.suite = "all"
        (base / ".libtmux-julia-matrix").touch()
        (base / "LocalPreferences.toml").write_text(TOOL_PREFERENCES)
        (base / "prepared.json").write_text(json.dumps(metadata))
        plan: list[tuple[str, list[str], float, str]] = [
            ("first", [], 30, "unit"),
            ("second", [], 30, "unit"),
        ]
        with (
            patch(__name__ + ".source_digest", return_value="fixed"),
            patch.object(shutil, "which", return_value="binary"),
            patch.object(subprocess, "check_output", return_value="version"),
            patch(__name__ + ".command_plan", return_value=plan),
            patch(
                __name__ + ".phase",
                side_effect=[
                    {
                        "name": "first",
                        "status": "FAIL",
                        "seconds": 0.01,
                        "cleanup": {"survivors": []},
                    },
                    KeyboardInterrupt(),
                ],
            ),
            redirect_stdout(StringIO()),
        ):
            try:
                run(args)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("matrix interruption was swallowed")
        retained = json.loads(next(base.glob("results-all-t1-*.json")).read_text())
        assert (
            retained["status"] == "INTERRUPTED" and retained["active_phase"] == "second"
        )
        assert retained["phases"][0]["status"] == "FAIL"
        with (
            patch(__name__ + ".source_digest", return_value="fixed"),
            patch.object(shutil, "which", return_value="binary"),
            patch.object(subprocess, "check_output", return_value="version"),
            patch(
                __name__ + ".command_plan",
                return_value=[
                    ("slow", [], 0.001, "unit"),
                    ("following", [], 30, "unit"),
                ],
            ),
            patch(
                __name__ + ".phase",
                side_effect=[
                    {
                        "name": "slow",
                        "status": "PASS",
                        "seconds": 0.01,
                        "cleanup": {"survivors": []},
                    },
                    {
                        "name": "following",
                        "status": "PASS",
                        "seconds": 0.01,
                        "cleanup": {"survivors": []},
                    },
                ],
            ),
            redirect_stdout(StringIO()),
        ):
            assert run(args) == 0
        reports = [
            json.loads(path.read_text()) for path in base.glob("results-all-t1-*.json")
        ]
        passed = next(report for report in reports if report["status"] == "PASS")
        assert passed["phases"][0]["over_target"] and len(passed["phases"]) == 2

        def leaking_phase(name: str, argv: list[str], **kwargs: Any) -> dict[str, Any]:
            bind_stale_socket(
                Path(kwargs["env"]["TMUX_TMPDIR"]) / "tmux-1000" / "default"
            )
            return {
                "name": name,
                "status": "PASS",
                "seconds": 0.01,
                "cleanup": {"survivors": []},
            }

        with (
            patch(__name__ + ".source_digest", return_value="fixed"),
            patch.object(shutil, "which", return_value="binary"),
            patch.object(subprocess, "check_output", return_value="version"),
            patch(__name__ + ".command_plan", return_value=[("leaky", [], 30, "unit")]),
            patch(__name__ + ".phase", side_effect=leaking_phase),
            redirect_stdout(StringIO()),
        ):
            assert run(args) == 1
        leaked = next(
            report
            for report in (
                json.loads(path.read_text())
                for path in base.glob("results-all-t1-*.json")
            )
            if report["phases"] and report["phases"][0]["name"] == "leaky"
        )
        assert leaked["status"] == "FAIL"
        assert leaked["sandbox_leaks"] == ["tmux-1000/default"]
        assert leaked["sandbox_kept"] == [] and passed["sandbox_kept"] == []
        assert passed["sandbox_leaks"] == []
        logs = base / "logs" / "probe"
        logs.mkdir(parents=True)
        (logs / "failure.log").write_text(
            f"{Path.home()}/private failed: original assertion\n~/private failure\nsecret-value\n"
        )
        with (
            patch.dict(os.environ, {"TEST_SECRET": "secret-value"}),
            redirect_stdout(StringIO()),
        ):
            assert artifacts(base) == 0
        exported = (base / "artifacts" / "logs" / "probe" / "failure.log").read_text()
        assert str(Path.home()) not in exported and "secret-value" not in exported
        assert "~/" not in exported
        assert "original assertion" in exported
        assert "INCOMPLETE second" in (base / "artifacts" / "summary.txt").read_text()
    print(
        "PASS owned preparation, bounded cleanup, diagnostic overruns and retained sanitized artifacts"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    matrix = sub.add_parser("matrix")
    matrix.add_argument(
        "--split",
        action="store_true",
        help="emit runtime and delivery jobs for every cell",
    )
    matrix.add_argument(
        "--rejection",
        action="store_true",
        help="emit the unsupported releases whose refusal is asserted",
    )
    self_check = sub.add_parser("self-test")
    self_check.add_argument(
        "--julia", help="also check real Pkg argument conversion offline"
    )
    build = sub.add_parser(
        "build-tmux", help="setup only: download, verify and build one pinned release"
    )
    build.add_argument("stage")
    build.add_argument("version", choices=tuple(TMUX_SHA256))
    resolve = sub.add_parser(
        "resolve-tmux", help="print the commit a tmux tag, branch or commit names"
    )
    resolve.add_argument("ref")
    build_ref = sub.add_parser(
        "build-tmux-ref",
        help="setup only: build tmux from source at a tag, branch or commit",
    )
    build_ref.add_argument("stage")
    build_ref.add_argument("ref")
    export = sub.add_parser("artifacts", help="sanitize logs and results for upload")
    export.add_argument("stage")
    preparation = sub.add_parser("prepare")
    preparation.add_argument("stage")
    preparation.add_argument("--julia", default="julia")
    preparation.add_argument("--threads", type=int, choices=(1, 4), default=1)
    execution = sub.add_parser("run")
    execution.add_argument("stage")
    execution.add_argument("--julia", default="julia")
    execution.add_argument("--tmux", default="tmux")
    execution.add_argument("--threads", type=int, choices=(1, 4), default=1)
    execution.add_argument(
        "--tier", choices=("unit", "quality", "outer", "all"), default="all"
    )
    execution.add_argument("--suite", choices=("all", *SUITES), default="all")
    for option in ("julia", "tmux", "os", "arch"):
        execution.add_argument(f"--expected-{option}")
    args = parser.parse_args()
    try:
        if args.command == "matrix" and args.rejection:
            print(json.dumps({"include": rejection_cells()}))
        elif args.command == "matrix":
            cells = qa_cells()
            if args.split:
                cells = split_cells(cells)
            print(json.dumps({"include": cells}))
        elif args.command == "self-test":
            self_test(args.julia)
        elif args.command == "build-tmux":
            build_tmux(args)
        elif args.command == "resolve-tmux":
            print(f"commit={resolve_tmux_ref(args.ref)}")
        elif args.command == "build-tmux-ref":
            build_tmux_ref(args)
        elif args.command == "prepare":
            prepare(args)
        elif args.command == "artifacts":
            return artifacts(args.stage)
        else:
            return run(args)
    except (ValueError, FileNotFoundError, subprocess.CalledProcessError) as error:
        print(f"NOT RUN: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

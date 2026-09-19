#!/usr/bin/env python3
"""Prepare isolated Julia tooling, then record offline quality and matrix cells."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import tarfile
import urllib.request
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
PINNED_TOOLS = {
    "Aqua": "0.8.18", "JuliaFormatter": "2.14.0", "Documenter": "1.17.0",
    "Tables": "1.14.0", "JSON": "1.9.0", "YAML": "0.4.17",
    "ModelContextProtocol": "0.7.0",
}

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


def support_cells():
    cells = []

    def add(os_name, runner, arch, julia, tmux, threads=1):
        label = f"{os_name}-{arch}-julia{julia}-tmux{tmux}-t{threads}"
        cells.append(dict(label=label, os=os_name, runner=runner, arch=arch,
                          julia=julia, tmux=tmux, threads=threads, status="NOT RUN"))

    add("Linux", "ubuntu-24.04", "x86_64", "1.10.0", "3.2a")
    add("Linux", "ubuntu-24.04", "x86_64", "1.10.0", "3.2a", 4)
    for version in ("1.10.12", "1.11.9", "1.12.7"):
        add("Linux", "ubuntu-24.04", "x86_64", version, "3.7c")
    for tmux in ("3.2a", "3.3a", "3.4", "3.5a", "3.6b", "3.7c"):
        add("Linux", "ubuntu-24.04", "x86_64", "1.13.0", tmux)
    add("Linux", "ubuntu-24.04", "x86_64", "1.13.0", "3.7c", 4)
    for runner, arch in (("macos-15", "arm64"), ("macos-15-intel", "x86_64")):
        for julia, tmux in (("1.10.0", "3.2a"), ("1.13.0", "3.7c")):
            for threads in (1, 4):
                add("Darwin", runner, arch, julia, tmux, threads)
    return cells


def source_digest():
    digest = hashlib.sha256()
    inputs = ("Project.toml", "README.md", "LICENSE", ".github/workflows",
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


def phase(name, argv, *, cwd, env, log, budget):
    """Wait on a child-exit event; retire only this run's process group."""
    start = time.monotonic()
    log.parent.mkdir(parents=True, exist_ok=True)
    answer = dict(name=name, command=argv, status="NOT RUN", budget_seconds=budget)
    process = None
    waiter = None
    done = threading.Event()
    try:
        with log.open("wb") as output:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            def reap():
                try:
                    process.wait()
                finally:
                    done.set()
            waiter = threading.Thread(target=reap, name=f"matrix-{name}")
            waiter.start()
            timed_out = not done.wait(budget)
            if timed_out:
                signal_group(process, signal.SIGINT)
                if not done.wait(0.9):
                    signal_group(process, signal.SIGKILL)
                    done.wait()
            waiter.join()
            answer.update(status="TIMEOUT" if timed_out else "PASS" if process.returncode == 0 else "FAIL",
                          exit_code=process.returncode, direct_child_reaped=True)
            if timed_out:
                answer["cleanup"] = "owned process group signalled; escaped descendants not proved retired"
    except FileNotFoundError:
        answer["reason"] = "required executable is unavailable"
    finally:
        if process is not None and process.poll() is None:
            signal_group(process, signal.SIGKILL)
            process.wait()
        if waiter is not None:
            waiter.join()
        answer["seconds"] = time.monotonic() - start
        answer["log"] = str(log)
    return answer


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
             PackageSpec(path=joinpath(root, "packages", "LibTmuxMCP"))])
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


def prepare(args):
    stage = checked_stage(args.stage, create=True)
    initial_digest = source_digest()
    project = stage / "environment"
    project.mkdir(exist_ok=True)
    env = environment(stage, offline=False)
    argv = [args.julia, "--startup-file=no", f"--project={project}", "-e", PREPARE,
            str(ROOT), str(project), *[f"{name}={version}" for name, version in PINNED_TOOLS.items()]]
    # Preparation is a separate tier: package resolution/network/precompilation.
    subprocess.run(argv, cwd=ROOT, env=env, check=True)
    subprocess.run([args.julia, "--startup-file=no", "--compile=min", "-O0",
                    f"--project={project}", "-e",
                    "using Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, ModelContextProtocol, JSON, Tables"],
                   cwd=ROOT, env=env, check=True)
    consumers = stage / ("consumers-" + uuid.uuid4().hex)
    started = time.monotonic()
    registry_files = seed_registry_cache(stage / "depot", consumers / "depot")
    registry_seed = dict(seconds=time.monotonic() - started, files=registry_files)
    subprocess.run([args.julia, "--startup-file=no", "--compile=yes", "-O2",
                    str(ROOT / "dev/check-consumers.jl"), "prepare", str(consumers)],
                   cwd=ROOT, env=env, check=True)
    if initial_digest != source_digest():
        raise ValueError("source changed during preparation; rerun with stable source (dependency cache retained)")
    metadata = dict(schema_version=1, source_digest=initial_digest, tools=PINNED_TOOLS,
                    consumers=str(consumers), project=str(project), registry_seed=registry_seed)
    (stage / "prepared.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("PASS prepared dependencies and immutable external consumers; no timed checks run")


def command_plan(args, stage, metadata):
    project = metadata["project"]
    normal = [args.julia, "--startup-file=no", f"--threads={args.threads}", f"--project={project}"]
    minimal = [*normal, "--compile=min", "-O0"]
    commands = []
    def add(name, argv, budget, tier):
        commands.append((name, argv, budget, tier))
    add("core-unit", [*minimal, "test/runtests.jl", "unit"], 30, "unit")
    add("workspace-unit", [*minimal, "packages/LibTmuxWorkspace/test/runtests.jl", "unit"], 30, "unit")
    add("mcp-unit", [*minimal, "packages/LibTmuxMCP/test/runtests.jl", "unit"], 30, "unit")
    add("quality", [*minimal, "dev/check-quality.jl", "quality"], 30, "quality")
    add("format", [*normal, "dev/check-quality.jl", "format"], 30, "quality")
    add("generated", [*minimal, "dev/generate-criteria.jl", "--check"], 30, "quality")
    add("example-inventory", [*minimal, "dev/check-doc-examples.jl", "check"], 30, "quality")
    add("core-normal", [*normal, "test/runtests.jl", "all"], 300, "outer")
    add("workspace-normal", [*normal, "packages/LibTmuxWorkspace/test/runtests.jl", "all"], 300, "outer")
    add("mcp-normal", [*normal, "packages/LibTmuxMCP/test/runtests.jl", "all"], 300, "outer")
    add("mcp-product", [*normal, "packages/LibTmuxMCP/test/product.jl"], 300, "outer")
    add("mcp-stopped-reader", [sys.executable, "packages/LibTmuxMCP/test/stdio_backpressure.py",
                              args.julia, project, "--compile", "normal", "--threads",
                              str(args.threads)], 300, "outer")
    extensions = 'using Test, LibTmux; include("test/criteria.jl"); include("test/json_extension.jl"); include("test/tables_extension.jl")'
    add("extensions", [*normal, "-e", extensions], 300, "outer")
    add("docs", [*normal, "docs/make.jl"], 300, "outer")
    add("doc-snippets", [*normal, "dev/check-doc-examples.jl", "doctest"], 300, "outer")
    add("doc-contextual", [*normal, "dev/check-doc-examples.jl", "contextual"], 300, "outer")
    add("imports", [*minimal, "dev/check-consumers.jl", "check", metadata["consumers"]], 300, "outer")
    add("external-examples", [*minimal, "dev/check-consumers.jl", "examples", metadata["consumers"]], 300, "outer")
    add("external-launchers", [*minimal, "dev/check-consumers.jl", "launchers", metadata["consumers"]], 300, "outer")
    return commands


def run(args):
    stage = checked_stage(args.stage)
    metadata = json.loads((stage / "prepared.json").read_text())
    if metadata["source_digest"] != source_digest():
        raise ValueError("source changed since preparation; prepare a fresh source snapshot before checks")
    env = environment(stage, offline=True)
    env.update(LIBTMUX_TEST_TMUX=args.tmux, LIBTMUX_TEST_CLI_COMPILE="normal",
               LIBTMUX_TEST_MINIMAL_CHILD="0")
    result = dict(schema_version=1, source_digest=metadata["source_digest"],
                  platform=platform.system(), machine=platform.machine(), kernel=platform.release(),
                  wsl="microsoft" in platform.release().lower(), threads=args.threads,
                  tools=metadata["tools"], status="NOT RUN", phases=[])
    for key, argv in (("julia", [args.julia, "--startup-file=no", "--version"]),
                      ("tmux", [args.tmux, "-V"])):
        resolved = shutil.which(argv[0])
        if resolved is None:
            result["reason"] = f"{key} executable is unavailable"
            break
        result[key] = subprocess.check_output(argv, env=env, text=True).strip()
    else:
        expected = ((args.expected_julia, result["julia"].removeprefix("julia version "), "Julia"),
                    (args.expected_tmux, result["tmux"].removeprefix("tmux "), "tmux"),
                    (args.expected_os, result["platform"], "OS"),
                    (args.expected_arch, result["machine"], "architecture"))
        mismatch = next((name for requested, actual, name in expected if requested and requested != actual), None)
        if mismatch:
            result["reason"] = f"observed {mismatch} differs from the requested cell"
        else:
            for name, argv, budget, tier in command_plan(args, stage, metadata):
                if args.tier != "all" and args.tier != tier:
                    continue
                item = phase(name, argv, cwd=ROOT, env=env, log=stage / "logs" / f"{name}.log", budget=budget)
                result["phases"].append(item)
                print(f"{item['status']} {name} {item['seconds']:.3f}s", flush=True)
            result["status"] = "PASS" if result["phases"] and all(p["status"] == "PASS" for p in result["phases"]) else "FAIL"
            if metadata["source_digest"] != source_digest():
                result.update(status="STALE", reason="source changed during checks")
    destination = stage / f"results-{args.tier}-t{args.threads}.json"
    destination.write_text(json.dumps(result, indent=2) + "\n")
    print(f"{result['status']} matrix result: {destination}")
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
        cells = support_cells()
        assert len({cell["label"] for cell in cells}) == len(cells)
        assert all(cell["status"] == "NOT RUN" for cell in cells)
    print("PASS independent registry copies, argv boundaries, failed/missing/deadline status, owned reaping and planned-cell identity")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("matrix")
    self_check = sub.add_parser("self-test")
    self_check.add_argument("--julia", help="also check real Pkg argument conversion offline")
    build = sub.add_parser("build-tmux", help="setup only: download, verify and build one pinned release")
    build.add_argument("stage")
    build.add_argument("version", choices=tuple(TMUX_SHA256))
    preparation = sub.add_parser("prepare")
    preparation.add_argument("stage")
    preparation.add_argument("--julia", default="julia")
    execution = sub.add_parser("run")
    execution.add_argument("stage")
    execution.add_argument("--julia", default="julia")
    execution.add_argument("--tmux", default="tmux")
    execution.add_argument("--threads", type=int, choices=(1, 4), default=1)
    execution.add_argument("--tier", choices=("unit", "quality", "outer", "all"), default="all")
    for option in ("julia", "tmux", "os", "arch"):
        execution.add_argument(f"--expected-{option}")
    args = parser.parse_args()
    try:
        if args.command == "matrix":
            print(json.dumps({"include": support_cells()}))
        elif args.command == "self-test":
            self_test(args.julia)
        elif args.command == "build-tmux":
            build_tmux(args)
        elif args.command == "prepare":
            prepare(args)
        else:
            return run(args)
    except (ValueError, FileNotFoundError, subprocess.CalledProcessError) as error:
        print(f"NOT RUN: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

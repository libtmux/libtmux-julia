#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Exercise native Julia progress, failure continuation and completion evidence."""

from __future__ import annotations

import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
from collections.abc import Sequence
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "dev/test-diagnostics.jl"
PROGRAM = """
include(ARGS[1])
using Test, Random
Random.seed!(23)
original = copy(Random.default_rng())
for file in ARGS[2:end]
    include_test_file(Main, file)
end
@assert rand(original) == rand(Random.default_rng())
finish_test_diagnostics()
"""


def start(
    julia: str, directory: Path, files: Sequence[Path]
) -> subprocess.Popen[bytes]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("LIBTMUX_CI_")
    }
    env.update(
        JULIA_TEST_VERBOSE="true",
        LIBTMUX_TEST_INVOCATION=directory.name,
        LIBTMUX_TEST_COMPLETION=str(directory / "complete.toml"),
    )
    return subprocess.Popen(
        [
            julia,
            "--startup-file=no",
            "--compile=min",
            "-O0",
            f"--project={ROOT}",
            "-e",
            PROGRAM,
            str(HELPER),
            *map(str, files),
        ],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def retire(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


def fixture(directory: Path, name: str, source: str) -> Path:
    path = directory / name
    path.write_text(source)
    return path


def main(julia: str) -> None:
    with tempfile.TemporaryDirectory(prefix="ltj-progress-") as temporary:
        directory = Path(temporary)
        passing = fixture(
            directory,
            "passing.jl",
            """using Test
@testset "outer" begin
    @test true
    @testset "nested live" begin
        readline(stdin)
        @test 2 == 2
    end
    @test_skip false
end
""",
        )
        process = start(julia, directory, [passing])
        assert process.stdout is not None
        prefix = b""
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + 20
                while b"Starting testset: nested live" not in prefix:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, prefix.decode(errors="replace")
                    assert selector.select(remaining), prefix.decode(errors="replace")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    assert chunk, prefix.decode(errors="replace")
                    prefix += chunk
            assert process.poll() is None
            assert b"FILE START" in prefix, prefix.decode(errors="replace")
            output = prefix + process.communicate(input=b"\n", timeout=20)[0]
            assert process.returncode == 0, output.decode(errors="replace")
            assert b"Broken" in output and b"Finished testset: nested live" in output
            receipt = tomllib.loads((directory / "complete.toml").read_text())
            assert (
                receipt["invocation"] == directory.name and receipt["status"] == "PASS"
            )
            assert receipt["files"][0]["outcome"] == "RETURNED"
        finally:
            retire(process)

        (directory / "complete.toml").unlink()
        failing = fixture(
            directory,
            "failing.jl",
            'using Test\n@testset "intentional failure" begin\n    @test 1 == 2\nend\n',
        )
        following = fixture(
            directory,
            "following.jl",
            'using Test\n@testset "following file" begin\n    @test true\nend\nprintln("FOLLOWING_REACHED")\n',
        )
        process = start(julia, directory, [failing, following])
        try:
            output = process.communicate(timeout=20)[0]
            assert process.returncode != 0
            assert b"FOLLOWING_REACHED" in output, output.decode(errors="replace")
            assert b"failing.jl:3" in output and b"1 == 2" in output
            receipt = tomllib.loads((directory / "complete.toml").read_text())
            assert receipt["status"] == "FAIL"
            assert [row["outcome"] for row in receipt["files"]] == [
                "ABORTED",
                "RETURNED",
            ]
        finally:
            retire(process)

        (directory / "complete.toml").unlink()
        interrupted = fixture(
            directory,
            "interrupted.jl",
            'using Test\n@testset "outer" begin\n    @testset "nested interruption" begin\n        throw(InterruptException())\n    end\nend\n',
        )
        process = start(julia, directory, [interrupted, following])
        try:
            output = process.communicate(timeout=20)[0]
            assert process.returncode != 0
            assert b"FOLLOWING_REACHED" not in output
            assert b"INTERRUPTED" in output, output.decode(errors="replace")
            assert not (directory / "complete.toml").exists()
        finally:
            retire(process)

        premature = fixture(directory, "premature.jl", "exit(0)\n")
        process = start(julia, directory, [premature])
        try:
            process.communicate(timeout=20)
            assert process.returncode == 0
            assert not (directory / "complete.toml").exists()
        finally:
            retire(process)
    print(
        "PASS native live progress, assertion details, continuation, RNG and incomplete exits"
    )


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "julia")

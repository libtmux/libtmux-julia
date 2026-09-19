"""Outer regression: default Julia stdio retires after EOF with a stopped reader."""

import argparse
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("julia")
    parser.add_argument("project")
    parser.add_argument("--compile", choices=("normal", "minimal"), default="normal")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--compiled-modules", choices=("yes", "no", "existing"), default="yes")
    args = parser.parse_args()
    command = [args.julia, "--startup-file=no", f"--project={args.project}",
               f"--threads={args.threads}", f"--compiled-modules={args.compiled_modules}"]
    if args.compile == "minimal":
        command.extend(["--compile=min", "-O0"])
    command.extend([str(Path(__file__).with_name("stdio_child.jl")), "backpressure"])
    started = time.monotonic()
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, bufsize=0)
    ready, completed = socket.socketpair()
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, "stdout")
    selector.register(child.stderr, selectors.EVENT_READ, "stderr")
    selector.register(ready, selectors.EVENT_READ, "exit")
    diagnostics = bytearray()

    def reap():
        child.wait()
        completed.sendall(b"x")

    watcher = threading.Thread(target=reap)
    watcher.start()

    def send(request_id, method, params=None):
        value = {"jsonrpc": "2.0", "id": request_id, "method": method,
                 "params": {"_meta": {
                     "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                     "io.modelcontextprotocol/clientCapabilities": {}}, **(params or {})}}
        child.stdin.write(json.dumps(value).encode() + b"\n")

    def next_byte(deadline):
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "stdio response deadline"
            events = selector.select(remaining)
            assert events, "stdio response deadline"
            for key, _ in events:
                if key.data == "stdout":
                    byte = os.read(key.fd, 1)
                    assert byte, f"child exited before response: {diagnostics!r}"
                    return byte
                if key.data == "exit":
                    raise AssertionError(f"child exited before response: {diagnostics!r}")
                chunk = os.read(key.fd, 65536)
                if chunk:
                    diagnostics.extend(chunk)
                    assert len(diagnostics) <= 1024 * 1024
                else:
                    selector.unregister(key.fileobj)

    try:
        send(1, "server/discover")
        line = bytearray()
        deadline = time.monotonic() + 45
        while not line.endswith(b"\n"):
            line.extend(next_byte(deadline))
            assert len(line) <= 65536
        assert json.loads(line)["id"] == 1
        send(2, "tools/call", {"name": "large", "arguments": {}})
        assert next_byte(time.monotonic() + 45) == b"{"
        # Exactly one response byte establishes write entry; no further reads
        # can drain the output before the process has retired.
        selector.unregister(child.stdout)
        retired = time.monotonic()
        child.stdin.close()
        deadline = retired + 0.9
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "EOF did not retire the blocked default-stdio writer"
            events = selector.select(remaining)
            assert events, "EOF did not retire the blocked default-stdio writer"
            if any(key.data == "exit" for key, _ in events):
                break
            for key, _ in events:
                chunk = os.read(key.fd, 65536)
                if chunk:
                    diagnostics.extend(chunk)
                    assert len(diagnostics) <= 1024 * 1024
                else:
                    selector.unregister(key.fileobj)
        watcher.join(0.9)
        assert not watcher.is_alive(), "process reaper did not join"
        elapsed = time.monotonic() - retired
        assert child.returncode == 0, diagnostics.decode(errors="replace")
        trailing = child.stdout.read(8 * 1024**2 + 1)
        assert len(trailing) < 2 * 1024**2, f"response drained instead of blocking: {len(trailing)} bytes"
        diagnostics.extend(child.stderr.read(1024 * 1024 + 1))
        assert not diagnostics, diagnostics.decode(errors="replace")
        print(json.dumps({"status": "PASS", "eof_retirement_ms": elapsed * 1000,
                          "partial_response_bytes": len(trailing) + 1,
                          "whole_seconds": time.monotonic() - started,
                          "compile": args.compile, "threads": args.threads}))
    finally:
        if watcher.is_alive():
            child.kill()
        watcher.join(0.9)
        assert not watcher.is_alive(), "forced process reaper did not join"
        selector.close()
        ready.close()
        completed.close()
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()


if __name__ == "__main__":
    main()

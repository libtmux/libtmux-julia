"""Outer check of the actual Julia child process and newline protocol."""

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time


def main():
    julia, project = sys.argv[1:]
    command = [julia, "--startup-file=no", f"--project={project}",
               "--compiled-modules=existing", str(Path(__file__).with_name("stdio_child.jl"))]
    started = time.perf_counter()
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, "stdout")
    selector.register(child.stderr, selectors.EVENT_READ, "stderr")
    pending = bytearray()
    diagnostics = bytearray()

    def send(request_id, method, params=None):
        metadata = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": {}}
        value = {"jsonrpc": "2.0", "method": method,
                 "params": {"_meta": metadata, **(params or {})}}
        if request_id is not None:
            value["id"] = request_id
        child.stdin.write(json.dumps(value).encode() + b"\n")

    def receive():
        deadline = time.perf_counter() + 45
        while b"\n" not in pending:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise AssertionError("stdio child did not answer within outer limit")
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if key.data == "stdout":
                        raise AssertionError("stdio child exited before response")
                elif key.data == "stderr":
                    diagnostics.extend(chunk)
                    assert len(diagnostics) <= 1024 * 1024
                else:
                    pending.extend(chunk)
                    assert len(pending) <= 8 * 1024 * 1024
        line, _, rest = pending.partition(b"\n")
        pending[:] = rest
        return json.loads(line)

    try:
        send(1, "server/discover")
        discovery = receive()
        assert discovery["id"] == 1 and "result" in discovery
        send(2, "tools/list")
        listed = receive()
        assert listed["id"] == 2
        assert [tool["name"] for tool in listed["result"]["tools"]] == ["wait"]
        send("long", "tools/call", {"name": "wait", "arguments": {},
             "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                       "io.modelcontextprotocol/clientCapabilities": {}, "progressToken": "p"}})
        progress = receive()
        assert progress["method"] == "notifications/progress"
        send(3, "server/discover")
        assert receive()["id"] == 3
        send(None, "notifications/cancelled", {"requestId": "long"})
        send(4, "ping")
        assert receive()["id"] == 4
        child.stdin.close()
        child.wait(timeout=10)
        assert child.returncode == 0, diagnostics.decode(errors="replace")
        remaining = bytes(pending) + child.stdout.read()
        assert not remaining, "cancelled tool emitted a late response"
        diagnostics.extend(child.stderr.read())
        assert not diagnostics, diagnostics.decode(errors="replace")
        print(f"PASS real stdio discovery/list/progress/cancel/fairness/EOF {time.perf_counter()-started:.3f}s")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        selector.close()
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()


if __name__ == "__main__":
    main()

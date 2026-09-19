"""Selector-driven installed-MCP measurements; one bounded sample per invocation."""
import argparse
from collections import deque
import hashlib
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time

PROTOCOL = "2026-07-28"
FRAME_LIMIT = 8 * 1024 * 1024
DIAGNOSTIC_LIMIT = 1024 * 1024
TOOLS = ("list_panes", "capture_pane", "send_keys", "paste_text", "resize_pane",
         "kill_pane", "run_operations", "create_session", "teardown_session",
         "wait_for_text", "send_keys_and_wait")


class MeasurementError(Exception):
    """A measurement could not establish its stated boundary."""


def frame(identity, method, params=None):
    metadata = {"io.modelcontextprotocol/protocolVersion": PROTOCOL,
                "io.modelcontextprotocol/clientCapabilities": {}}
    arguments = dict(params or {})
    metadata.update(arguments.pop("_meta", {}))
    arguments["_meta"] = metadata
    message = {"jsonrpc": "2.0", "method": method, "params": arguments}
    if identity is not None:
        message["id"] = identity
    return (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def checked_result(message):
    if "error" in message or "result" not in message:
        raise MeasurementError("protocol request failed")
    result = message["result"]
    if result.get("isError", False):
        code = result.get("structuredContent", {}).get("error", {}).get("code", "unknown")
        raise MeasurementError("tool failed: " + str(code)[:64])
    return result


class Client:
    """Own a child, its pipes and one blocking waitpid watcher; never poll readiness."""
    def __init__(self, command, deadline):
        self.deadline = deadline
        self.started_ns = time.perf_counter_ns()
        environment = dict(os.environ)
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, bufsize=0, env=environment)
        self.spawned_ns = time.perf_counter_ns()
        try:
            self.selector = selectors.DefaultSelector()
            self.exit_reader, self.exit_writer = socket.socketpair()
        except BaseException:
            self.child.kill()
            self.child.wait()
            for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
                pipe.close()
            if hasattr(self, "selector"):
                self.selector.close()
            raise
        self.pending = bytearray()
        self.messages = deque()
        self.pending_output = bytearray()
        self.message_bytes = 0
        self.stdout_bytes = self.stderr_bytes = self.stdin_bytes = 0
        self.stdout_digest, self.stderr_digest = hashlib.sha256(), hashlib.sha256()
        self.exit_ns = None
        self.usage = None
        self.reap_error = None
        self.paused = False
        self.wire_samples = []
        try:
            for pipe, label in ((self.child.stdout, "stdout"), (self.child.stderr, "stderr")):
                os.set_blocking(pipe.fileno(), False)
                self.selector.register(pipe, selectors.EVENT_READ, label)
            os.set_blocking(self.child.stdin.fileno(), False)
            self.selector.register(self.exit_reader, selectors.EVENT_READ, "exit")
            self.watcher = threading.Thread(target=self._reap, name="mcp-benchmark-waitpid")
            self.watcher.start()
        except BaseException:
            self.child.kill()
            self.child.wait()
            self.selector.close()
            self.exit_reader.close()
            self.exit_writer.close()
            for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
                pipe.close()
            raise

    def _reap(self):
        try:
            if hasattr(os, "wait4"):
                _, status, self.usage = os.wait4(self.child.pid, 0)
                self.child.returncode = os.waitstatus_to_exitcode(status)
            else:
                self.child.wait()
            self.exit_ns = time.perf_counter_ns()
        except BaseException as error:
            self.reap_error = type(error).__name__
        finally:
            self.exit_writer.sendall(b"x")

    def _remaining(self, deadline):
        remaining = min(self.deadline, deadline) - time.perf_counter()
        if remaining <= 0:
            raise MeasurementError("event deadline exceeded")
        return remaining

    def _unregister(self, stream):
        try:
            self.selector.unregister(stream)
        except KeyError:
            pass

    def _accept_stdout(self, chunk):
        self.stdout_bytes += len(chunk)
        self.stdout_digest.update(chunk)
        self.pending.extend(chunk)
        if len(self.pending) > FRAME_LIMIT:
            raise MeasurementError("stdout frame exceeded byte bound")
        while b"\n" in self.pending:
            line, _, rest = self.pending.partition(b"\n")
            self.pending[:] = rest
            data = json.loads(line)
            self.message_bytes += len(line) + 1
            if len(self.messages) >= 64 or self.message_bytes > FRAME_LIMIT:
                raise MeasurementError("unconsumed reply queue exceeded bound")
            self.messages.append((data, time.perf_counter_ns(), len(line) + 1,
                                  hashlib.sha256(line + b"\n").hexdigest()))

    def pump(self, deadline):
        events = self.selector.select(self._remaining(deadline))
        if not events:
            raise MeasurementError("event deadline exceeded")
        for key, _ in events:
            if key.data == "stdin":
                try:
                    count = os.write(key.fd, self.pending_output)
                except BlockingIOError:
                    continue
                self.stdin_bytes += count
                del self.pending_output[:count]
                if not self.pending_output:
                    self._unregister(self.child.stdin)
            elif key.data == "exit":
                self.exit_reader.recv(1)
                self._unregister(self.exit_reader)
                if self.reap_error:
                    raise MeasurementError("process watcher failed: " + self.reap_error)
            else:
                try:
                    chunk = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    self._unregister(key.fileobj)
                elif key.data == "stdout":
                    self._accept_stdout(chunk)
                else:
                    self.stderr_bytes += len(chunk)
                    self.stderr_digest.update(chunk)
                    if self.stderr_bytes > DIAGNOSTIC_LIMIT:
                        raise MeasurementError("diagnostics exceeded byte bound")

    def send(self, identity, method, params=None, *, timeout=30):
        if self.child.returncode is not None:
            raise MeasurementError("child exited before request")
        data = frame(identity, method, params)
        if self.pending_output or len(data) > 2 * 1024 * 1024:
            raise MeasurementError("outgoing request exceeded bound")
        self.pending_output.extend(data)
        self.selector.register(self.child.stdin, selectors.EVENT_WRITE, "stdin")
        deadline = time.perf_counter() + timeout
        while self.pending_output:
            self.pump(deadline)
        return len(data)

    def receive(self, *, identity=None, progress=None, timeout=30):
        deadline = time.perf_counter() + timeout
        while True:
            for index, item in enumerate(self.messages):
                data = item[0]
                matches = (identity is not None and data.get("id") == identity) or (
                    progress is not None and data.get("method") == "notifications/progress"
                    and data.get("params", {}).get("progressToken") == progress)
                if matches:
                    del self.messages[index]
                    self.message_bytes -= item[2]
                    return item
            if self.child.returncode is not None:
                raise MeasurementError("child exited before expected reply")
            self.pump(deadline)

    def request(self, identity, method, params=None, *, timeout=30, label=None):
        started = time.perf_counter_ns()
        request_bytes = self.send(identity, method, params, timeout=timeout)
        response, received, response_bytes, digest = self.receive(identity=identity, timeout=timeout)
        checked_result(response)
        self.wire_samples.append({"phase": label or method, "elapsed_ns": received - started,
                                  "request_bytes": request_bytes, "response_bytes": response_bytes,
                                  "response_sha256": digest})
        return response, response_bytes

    def call(self, identity, name, arguments=None, *, label=None):
        response, _ = self.request(identity, "tools/call", {"name": name, "arguments": arguments or {}},
                                   label=label or name)
        return checked_result(response)["structuredContent"]

    def wait_progress(self, identity):
        started = time.perf_counter_ns()
        sent = self.send(identity, "tools/call", {"name": "wait_for_text",
            "arguments": {"text": "absent-benchmark-marker"}, "_meta": {"progressToken": identity}})
        data, received, count, digest = self.receive(progress=identity)
        if data["params"].get("message") != "waiting":
            raise MeasurementError("wait did not reach its observation boundary")
        self.wire_samples.append({"phase": "wait_progress", "elapsed_ns": received - started,
                                  "request_bytes": sent, "response_bytes": count,
                                  "response_sha256": digest})

    def pause_stdout(self):
        self._unregister(self.child.stdout)
        self.paused = True

    def first_paused_byte(self, timeout=30):
        selector = selectors.DefaultSelector()
        try:
            selector.register(self.child.stdout, selectors.EVENT_READ, "stdout")
            selector.register(self.exit_reader, selectors.EVENT_READ, "exit")
            deadline = time.perf_counter() + timeout
            events = selector.select(self._remaining(deadline))
            if not events or any(key.data == "exit" for key, _ in events):
                raise MeasurementError("writer did not enter before child exit/deadline")
            byte = os.read(self.child.stdout.fileno(), 1)
            if not byte:
                raise MeasurementError("stdout ended before writer entry")
            self.stdout_bytes += 1
            self.stdout_digest.update(byte)
        finally:
            selector.close()

    def eof_and_join(self):
        self._unregister(self.child.stdin)
        eof_ns = time.perf_counter_ns()
        self.child.stdin.close()
        while self.exit_ns is None:
            self.pump(self.deadline)
        self.watcher.join()
        if self.child.returncode != 0:
            raise MeasurementError("launcher exit was not clean")
        # A paused pipe stays unread until the child has exited. Only then drain
        # its finite remaining bytes, without interpreting a partial reply.
        for pipe, label in ((self.child.stdout, "stdout"), (self.child.stderr, "stderr")):
            while True:
                try:
                    chunk = os.read(pipe.fileno(), 65536)
                except BlockingIOError:
                    raise MeasurementError("pipe remained open after direct child exit")
                if not chunk:
                    break
                if label == "stdout" and not self.paused:
                    self._accept_stdout(chunk)
                elif label == "stdout":
                    self.stdout_bytes += len(chunk)
                    self.stdout_digest.update(chunk)
                    if self.stdout_bytes > FRAME_LIMIT:
                        raise MeasurementError("paused output exceeded byte bound")
                else:
                    self.stderr_bytes += len(chunk)
                    self.stderr_digest.update(chunk)
                    if self.stderr_bytes > DIAGNOSTIC_LIMIT:
                        raise MeasurementError("diagnostics exceeded byte bound")
        return eof_ns, self.exit_ns

    def report(self):
        rss = None
        if self.usage is not None:
            rss = self.usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
        return {"spawn_ns": self.spawned_ns - self.started_ns, "exit_code": self.child.returncode,
                "stdin_bytes": self.stdin_bytes, "stdout_bytes": self.stdout_bytes,
                "stderr_bytes": self.stderr_bytes, "stdout_sha256": self.stdout_digest.hexdigest(),
                "stderr_sha256": self.stderr_digest.hexdigest(), "child_max_rss_bytes": rss,
                "child_user_seconds": None if self.usage is None else self.usage.ru_utime,
                "child_system_seconds": None if self.usage is None else self.usage.ru_stime,
                "samples": self.wire_samples}

    def close(self):
        if self.child.returncode is None:
            try:
                self.child.kill()
            except ProcessLookupError:
                pass
        self.watcher.join()
        self.selector.close()
        self.exit_reader.close()
        self.exit_writer.close()
        for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
            pipe.close()


def run_sample(command, options, deadline, *, backpressure):
    client = Client(command, deadline)
    result = {"kind": "backpressure" if backpressure else "workflow", "status": "running"}
    try:
        response, _ = client.request("discover", "server/discover", timeout=options.startup,
                                     label="discovery")
        result["process_to_discovery_ns"] = time.perf_counter_ns() - client.started_ns
        result["supported_versions"] = checked_result(response)["supportedVersions"]
        _, catalog_bytes = client.request("catalog1", "tools/list", label="catalog")
        if backpressure:
            try:
                import fcntl
                capacity = fcntl.fcntl(client.child.stdout.fileno(), fcntl.F_GETPIPE_SZ)
                original_capacity = capacity
                if catalog_bytes - 1 <= capacity and hasattr(fcntl, "F_SETPIPE_SZ"):
                    try:
                        fcntl.fcntl(client.child.stdout.fileno(), fcntl.F_SETPIPE_SZ, 4096)
                        capacity = fcntl.fcntl(client.child.stdout.fileno(), fcntl.F_GETPIPE_SZ)
                    except OSError:
                        pass
            except (ImportError, AttributeError, OSError):
                result["status"] = "unsupported_pipe_capacity"
                client.eof_and_join()
                return result
            if catalog_bytes - 1 <= capacity:
                result["status"] = "inconclusive_reply_fits_pipe"
                result["pipe_capacity_bytes"] = capacity
                client.eof_and_join()
                return result
            client.wait_progress("blocked-wait")
            if client.messages or client.pending:
                raise MeasurementError("unexpected output before backpressure boundary")
            client.pause_stdout()
            prior_stdout_bytes = client.stdout_bytes
            requested_ns = time.perf_counter_ns()
            client.send("catalog2", "tools/list")
            client.first_paused_byte()
            writer_entry_ns = time.perf_counter_ns() - requested_ns
            cancelled_ns = time.perf_counter_ns()
            client.send(None, "notifications/cancelled", {"requestId": "blocked-wait"})
            eof_ns, exit_ns = client.eof_and_join()
            result.update({"backpressure_proven": True, "pipe_capacity_bytes": capacity,
                           "original_pipe_capacity_bytes": original_capacity,
                           "expected_reply_bytes": catalog_bytes, "bytes_consumed_before_eof": 1,
                           "writer_entry_ns": writer_entry_ns,
                           "bytes_drained_after_exit": client.stdout_bytes - prior_stdout_bytes - 1,
                           "cancel_to_exit_ns": exit_ns - cancelled_ns,
                           "eof_to_exit_ns": exit_ns - eof_ns})
        else:
            first = client.call("list-first", "list_panes", label="first_list")
            if len(first["panes"]) != 1 or not first["panes"][0]["caller"]:
                raise MeasurementError("fixture pane policy changed")
            captured = client.call("capture-first", "capture_pane", label="first_capture")
            capture_digest = hashlib.sha256(captured["text"].encode()).hexdigest()
            result["capture_text_bytes"] = len(captured["text"].encode())
            for index in range(options.warm):
                client.call(f"list-{index}", "list_panes", label="warm_list")
                actual = client.call(f"capture-{index}", "capture_pane", label="warm_capture")
                if hashlib.sha256(actual["text"].encode()).hexdigest() != capture_digest:
                    raise MeasurementError("capture content changed between equal workloads")
            created = client.call("create", "create_session", {"name": "benchmark-owned", "command": ["/bin/cat"]})
            result["application_owned_session_created"] = created["ownership"] == "application"
            client.wait_progress("waiting")
            client.call("concurrent", "list_panes", label="unrelated_list_during_wait")
            cancelled_ns = time.perf_counter_ns()
            client.send(None, "notifications/cancelled", {"requestId": "waiting"})
            client.request("after-cancel", "ping", label="reader_ping_after_cancel")
            eof_ns, exit_ns = client.eof_and_join()
            result.update({"cancel_to_exit_ns": exit_ns - cancelled_ns,
                           "eof_to_exit_ns": exit_ns - eof_ns,
                           "cancellation_retirement": "EOF-joined upper bound; no cancellation acknowledgement"})
            if client.messages or client.pending:
                raise MeasurementError("unexpected late protocol output")
        result["status"] = "pass"
        return result
    except BaseException as error:
        result["status"] = "fail"
        result["error_type"] = type(error).__name__
        if isinstance(error, MeasurementError):
            result["error"] = str(error)
        raise
    finally:
        client.close()
        result.update(client.report())
        options.results.append(result)


def self_test():
    data = json.loads(frame("one", "tools/call", {"_meta": {"progressToken": "p"}}))
    assert data["params"]["_meta"]["progressToken"] == "p"
    assert data["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == PROTOCOL
    assert "id" not in json.loads(frame(None, "notifications/cancelled"))
    client = object.__new__(Client)
    client.stdout_bytes = client.message_bytes = 0
    client.stdout_digest = hashlib.sha256()
    client.pending, client.messages = bytearray(), deque()
    raw = b'{"id":1,"result":{"text":"\xce\xbb"}}\n'
    client._accept_stdout(raw[:-2])
    assert not client.messages
    client._accept_stdout(raw[-2:])
    assert client.messages[0][0]["result"]["text"] == "λ"
    assert client.stdout_bytes == len(raw)
    assert checked_result(client.messages[0][0])["text"] == "λ"
    responder = ("import json,sys\n"
                 "for line in sys.stdin:\n"
                 " request=json.loads(line)\n"
                 " print(json.dumps({'id':request['id'],'result':{'ok':True}}),flush=True)\n")
    child = Client([sys.executable, "-u", "-c", responder], time.perf_counter() + 0.9)
    try:
        response, _ = child.request("test", "ping", timeout=0.9)
        assert checked_result(response)["ok"]
        child.eof_and_join()
        assert child.report()["exit_code"] == 0 and child.stderr_bytes == 0
    finally:
        child.close()
    print("PASS benchmark framing and owned-process event checks")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--tmux", required=True)
    parser.add_argument("--pane", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--warm", type=int, default=5)
    parser.add_argument("--budget", type=float, default=180)
    parser.add_argument("--startup", type=float, default=90)
    options = parser.parse_args()
    if not (0 <= options.warm <= 64 and 0 < options.budget <= 600 and 0 < options.startup <= 180):
        parser.error("warm, budget or startup limit is out of range")
    options.results = []
    command = [options.launcher, "--socket", options.socket, "--tmux", options.tmux,
               "--caller-pane", options.pane, "--allow-pane", options.pane,
               "--timeout", "30", "--workers", "2", "--capacity", "4", "--allow-create"]
    for tool in TOOLS:
        command.extend(["--tool", tool])
    started = time.perf_counter_ns()
    deadline = time.perf_counter() + options.budget
    report = {"schema_version": 1, "status": "running", "protocol": PROTOCOL,
              "python": sys.version.split()[0], "platform": sys.platform, "samples": options.results}
    def interrupted(_number, _frame):
        raise MeasurementError("benchmark driver interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        run_sample(command, options, deadline, backpressure=False)
        run_sample(command, options, deadline, backpressure=True)
        report["status"] = "pass" if all(item["status"] == "pass" for item in options.results) else "partial"
    except BaseException as error:
        report["status"] = "fail"
        report["error_type"] = type(error).__name__
        raise
    finally:
        report["client_driver_body_ns"] = time.perf_counter_ns() - started
        with open(options.output, "x", encoding="utf-8") as destination:
            json.dump(report, destination, indent=2, ensure_ascii=False)
            destination.write("\n")


if __name__ == "__main__":
    main()

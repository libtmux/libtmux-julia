"""Observe owned phase output without exposing application bytes to CI stdout."""

from __future__ import annotations

import json
import os
import selectors
import socket
import threading
import time
from collections import deque


PREFIX = b"LIBTMUX_TEST_PROGRESS "
MAX_LINE_BYTES = 1024 * 1024
READ_BYTES = 64 * 1024
EVENTS = frozenset((
    "process_start", "process_finish", "span_start", "span_finish",
    "testset_start", "testset_body_end", "testset_finalize", "assertion_problem",
    "profile_checkpoint", "coverage_incomplete",
))
MAX_CONSOLE_BYTES = 4 * 1024 * 1024
MAX_CONSOLE_RECORDS = 256
_console_lock = threading.Lock()
_console_sink = None
_console_generation = 0
_console_closed = False
_console_history = dict(dropped_records=0, dropped_bytes=0, cancelled_records=0,
                        cancelled_bytes=0, failed_records=0, failed_bytes=0)


def write_all(descriptor, data):
    view = memoryview(data)
    while view:
        count = os.write(descriptor, view)
        if count <= 0:
            raise OSError("phase output write made no progress")
        view = view[count:]


class ConsoleSink:
    """Serialize bounded packets without putting console I/O on a supervisor."""

    def __init__(self, descriptor=1, *, generation=1,
                 maximum_bytes=MAX_CONSOLE_BYTES, maximum_records=MAX_CONSOLE_RECORDS):
        self.descriptor = os.dup(descriptor)
        self.generation = generation
        self.maximum_bytes = maximum_bytes
        self.maximum_records = maximum_records
        self.condition = threading.Condition()
        self.queue = deque()
        self.closing = False
        self.sequence = 0
        self.delivered_sequence = 0
        self.cancelled_from = None
        self.active = None
        self.outstanding_bytes = 0
        self.outstanding_records = 0
        self.accepted_bytes = 0
        self.accepted_records = 0
        self.delivered_bytes = 0
        self.delivered_records = 0
        self.dropped_bytes = 0
        self.dropped_records = 0
        self.cancelled_bytes = 0
        self.cancelled_records = 0
        self.failed_bytes = 0
        self.failed_records = 0
        self.error_type = None
        self.thread = threading.Thread(target=self._run, name="matrix-console", daemon=True)
        try:
            self.thread.start()
        except BaseException:
            os.close(self.descriptor)
            raise

    def submit(self, data):
        size = len(data)
        with self.condition:
            # The active write counts against both bounds, even after dequeue.
            if (self.closing or self.error_type or self.sequence >= 0xffffffff
                    or self.outstanding_bytes + size > self.maximum_bytes
                    or self.outstanding_records >= self.maximum_records):
                self.dropped_bytes += size
                self.dropped_records += 1
                return 0
            self.sequence += 1
            ticket = (self.generation << 32) | self.sequence
            self.queue.append((self.sequence, bytes(data)))
            self.outstanding_bytes += size
            self.outstanding_records += 1
            self.accepted_bytes += size
            self.accepted_records += 1
            self.condition.notify_all()
            return ticket

    def _cancel_queued(self):
        if self.queue and self.cancelled_from is None:
            self.cancelled_from = self.queue[0][0]
        while self.queue:
            _, data = self.queue.popleft()
            self.cancelled_bytes += len(data)
            self.cancelled_records += 1
            self.outstanding_bytes -= len(data)
            self.outstanding_records -= 1
        self.condition.notify_all()

    def _run(self):
        try:
            while True:
                with self.condition:
                    self.condition.wait_for(lambda: self.queue or self.closing)
                    if not self.queue:
                        break
                    sequence, data = self.queue.popleft()
                    self.active = (sequence, len(data))
                # A blocked writer owns its duplicate until it exits. Never hold
                # admission/wait locks or change the shared open-file description.
                try:
                    write_all(self.descriptor, data)
                except OSError as error:
                    with self.condition:
                        self.error_type = type(error).__name__
                        self.failed_records += 1
                        self.failed_bytes += len(data)
                        self.closing = True
                        self.outstanding_records -= 1
                        self.outstanding_bytes -= len(data)
                        self.active = None
                        self._cancel_queued()
                    break
                with self.condition:
                    self.delivered_sequence = sequence
                    self.delivered_records += 1
                    self.delivered_bytes += len(data)
                    self.outstanding_records -= 1
                    self.outstanding_bytes -= len(data)
                    self.active = None
                    self.condition.notify_all()
        finally:
            os.close(self.descriptor)
            with self.condition:
                self.condition.notify_all()

    def wait(self, ticket, deadline):
        if type(ticket) is not int or ticket <= 0 or ticket >> 32 != self.generation:
            return False
        sequence = ticket & 0xffffffff
        with self.condition:
            if sequence == 0 or sequence > self.sequence:
                return False
            while self.delivered_sequence < sequence:
                if (self.error_type or (self.cancelled_from is not None and sequence >= self.cancelled_from)
                        or not self.thread.is_alive()):
                    return False
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(timeout=remaining)
            return True

    def delivery(self, ticket):
        with self.condition:
            sequence = ticket & 0xffffffff if type(ticket) is int and ticket > 0 else 0
            if (not sequence or ticket >> 32 != self.generation or sequence > self.sequence):
                state = "UNAVAILABLE"
            elif sequence <= self.delivered_sequence:
                state = "DELIVERED"
            elif self.cancelled_from is not None and sequence >= self.cancelled_from:
                state = "CANCELLED"
            elif self.error_type or not self.thread.is_alive():
                state = "FAILED"
            else:
                state = "PENDING"
            return dict(state=state, console_writer_retired=not self.thread.is_alive(),
                        error_type=self.error_type)

    def finish(self, deadline):
        with self.condition:
            self.closing = True
            self.condition.notify_all()
        self.thread.join(timeout=max(0.0, deadline - time.monotonic()))
        with self.condition:
            if self.thread.is_alive():
                # Release the queued tail, but retain the in-flight packet and FD.
                self._cancel_queued()
            return self._receipt()

    def _receipt(self):
        retired = not self.thread.is_alive()
        fault = self.error_type or self.dropped_records or self.cancelled_records or self.failed_records
        return dict(status="UNRETIRED" if not retired else "FAIL" if fault else "PASS",
                    console_writer_retired=retired,
                    console_delivery_complete=retired and not fault,
                    generation=self.generation, accepted_records=self.accepted_records,
                    accepted_bytes=self.accepted_bytes, delivered_records=self.delivered_records,
                    delivered_bytes=self.delivered_bytes, dropped_records=self.dropped_records,
                    dropped_bytes=self.dropped_bytes, cancelled_records=self.cancelled_records,
                    cancelled_bytes=self.cancelled_bytes, failed_records=self.failed_records,
                    failed_bytes=self.failed_bytes, queued_records=len(self.queue),
                    queued_bytes=sum(len(data) for _, data in self.queue),
                    in_flight_records=int(self.active is not None),
                    in_flight_bytes=self.active[1] if self.active else 0,
                    maximum_bytes=self.maximum_bytes, maximum_records=self.maximum_records,
                    error_type=self.error_type, failed_packet_delivery="partial_or_none_unknown")


def write_console(data):
    """Admit a full console packet; return its ticket or zero without waiting on I/O."""
    global _console_sink, _console_generation
    with _console_lock:
        if _console_closed:
            if _console_sink is None:
                _console_history["dropped_records"] += 1
                _console_history["dropped_bytes"] += len(data)
            else:
                with _console_sink.condition:
                    _console_sink.dropped_records += 1
                    _console_sink.dropped_bytes += len(data)
            return 0
        if _console_sink is None:
            _console_generation += 1
            try:
                _console_sink = ConsoleSink(generation=_console_generation)
            except (OSError, RuntimeError):
                _console_sink = None
                _console_history["failed_records"] += 1
                _console_history["failed_bytes"] += len(data)
                return 0
        return _console_sink.submit(data)


def wait_console(ticket, deadline):
    with _console_lock:
        sink = _console_sink
    return sink is not None and sink.wait(ticket, deadline)


def console_delivery(ticket):
    with _console_lock:
        sink = _console_sink
    return sink.delivery(ticket) if sink is not None else dict(
        state="UNAVAILABLE", console_writer_retired=True, error_type=None)


def finish_console(deadline):
    """Stop admission and bound retirement; a surviving writer keeps its FD."""
    global _console_closed
    with _console_lock:
        # Closing is permanent for this worker, including a not-yet-created sink.
        # A late phase reader must not reopen console admission after the receipt.
        _console_closed = True
        sink = _console_sink
    if sink is None:
        with _console_lock:
            history = dict(_console_history)
        fault = any(history.values())
        return dict(status="FAIL" if fault else "PASS", console_writer_retired=True,
                    console_delivery_complete=not fault,
                    **{field: 0 for field in _console_history}, historical_faults=history)
    receipt = sink.finish(deadline)
    with _console_lock:
        history = dict(_console_history)
    receipt["historical_faults"] = history
    if any(history.values()):
        receipt["console_delivery_complete"] = False
        if receipt["status"] == "PASS":
            receipt["status"] = "FAIL"
    return receipt


class ProgressDecoder:
    """Accept selected records from the admitted process or declared worker phases."""

    def __init__(self, *, artifacts, source_roots, invocation, source_digest,
                 phases, direct_pid=None, direct_birth=None):
        self.artifacts = artifacts
        self.mapping = artifacts.SourceMap(source_roots)
        self.invocation = invocation
        self.source_digest = source_digest
        self.phases = frozenset(phases)
        self.direct_pid = direct_pid
        self.direct_birth = direct_birth
        self.sequences = {}
        self.testsets = {}
        self.accepted = 0
        self.rejected = 0

    def decode(self, line):
        if not line.startswith(PREFIX):
            return None
        try:
            record = self.artifacts.parse_json(line[len(PREFIX):].decode("utf-8"))
            if not isinstance(record, dict) or not self.artifacts.bounded_structure(record):
                raise ValueError("invalid progress structure")
            if (type(record.get("schema")) is not int or record["schema"] != 2
                    or record.get("event") not in EVENTS
                    or record.get("invocation") != self.invocation
                    or record.get("source_digest") != self.source_digest
                    or record.get("ci_phase") not in self.phases):
                raise ValueError("progress identity differs from admission")
            for field in ("pid", "thread", "seq"):
                if type(record.get(field)) is not int or record[field] <= 0:
                    raise ValueError("invalid process or sequence identity")
            if type(record.get("elapsed_ns")) is not int or record["elapsed_ns"] < 0:
                raise ValueError("invalid elapsed time")
            birth = record.get("process_birth_id")
            if not self.artifacts.IDENTIFIER.fullmatch(birth or ""):
                raise ValueError("invalid process birth identity")
            if (self.direct_pid is not None and record["pid"] != self.direct_pid
                    or self.direct_birth is not None and birth != self.direct_birth):
                raise ValueError("progress is not from the admitted direct process")
            identity = (record["ci_phase"], birth, record["pid"])
            if record["seq"] <= self.sequences.get(identity, 0):
                raise ValueError("progress sequence repeated or regressed")
            record = self.mapping.value(record)
            testset_id = record.get("testset_id")
            key = (*identity, testset_id) if type(testset_id) is int else None
            if record["event"] == "testset_start" and key is not None:
                self.testsets[key] = {field: record[field] for field in
                                     ("description", "file", "line", "parent_id") if field in record}
            elif key in self.testsets:
                record["testset_identity"] = self.testsets[key]
            record["observation_scope"] = ("admitted_direct_process" if self.direct_pid is not None
                                           else "forwarded_declared_worker_phase")
            self.sequences[identity] = record["seq"]
            self.accepted += 1
            return record
        except (ValueError, TypeError, UnicodeError, RecursionError):
            self.rejected += 1
            return None


class PhaseLogPump:
    """Tee exact merged output; retain honest evidence when a writer cannot retire."""

    def __init__(self, pipe, log_descriptor, *, started, decoder=None, forward=None,
                 on_progress=None):
        self.pipe = pipe
        self.log_descriptor = os.dup(log_descriptor)
        self.started = started
        self.decoder = decoder
        self.forward = write_console if forward is None else forward
        self.on_progress = on_progress
        self.wakeup_read, self.wakeup_write = socket.socketpair()
        self.wakeup_read.setblocking(False)
        self.wakeup_write.setblocking(False)
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._run, name="matrix-output", daemon=True)
        self.thread_started = False
        self.bytes = 0
        self.first_byte = None
        self.eof = False
        self.error_type = None
        self.partial_lines = 0
        self.oversized_lines = 0
        self.partial_progress_lines = 0
        self.oversized_progress_lines = 0
        self.forwarded = 0
        self.console_accepted = 0
        self.console_dropped_records = 0
        self.console_dropped_bytes = 0
        self.last_console_ticket = None
        self.work_seconds = 0.0
        self.cpu_seconds = 0.0
        self.pending = bytearray()
        self.discard_line = False

    def start(self):
        try:
            self.thread.start()
            self.thread_started = True
        except BaseException as error:
            self.error_type = type(error).__name__
            self._close()
            raise

    def _close(self):
        # Only the reader closes its descriptors after start; a blocked writer
        # retains its duplicate rather than later writing a reused descriptor.
        for resource in (self.pipe, self.wakeup_read, self.wakeup_write):
            try:
                resource.close()
            except OSError:
                pass
        try:
            os.close(self.log_descriptor)
        except OSError:
            pass

    def _lines(self, chunk):
        if self.decoder is None:
            return
        for segment in chunk.splitlines(keepends=True):
            # Only LF terminates the transport. Binary application data is kept
            # byte-for-byte in the log and never decoded as console output.
            complete = segment.endswith(b"\n")
            if not self.discard_line:
                self.pending.extend(segment)
                if len(self.pending) > MAX_LINE_BYTES:
                    if self.pending.startswith(PREFIX):
                        self.oversized_progress_lines += 1
                    self.pending.clear()
                    self.discard_line = True
                    self.oversized_lines += 1
            if complete:
                if not self.discard_line:
                    record = self.decoder.decode(bytes(self.pending[:-1]))
                    if record is not None:
                        data = PREFIX + json.dumps(record, ensure_ascii=True, sort_keys=True,
                                                   separators=(",", ":")).encode() + b"\n"
                        ticket = self.forward(data)
                        if ticket is None:
                            # Custom synchronous controls (e.g. list.append).
                            self.forwarded += 1
                        elif type(ticket) is int and ticket > 0:
                            self.last_console_ticket = ticket
                            self.console_accepted += 1
                        else:
                            self.console_dropped_records += 1
                            self.console_dropped_bytes += len(data)
                        if self.on_progress is not None:
                            self.on_progress(record)
                self.pending.clear()
                self.discard_line = False

    def _read(self):
        try:
            chunk = os.read(self.pipe.fileno(), READ_BYTES)
        except BlockingIOError:
            return False
        if not chunk:
            self.eof = True
            return False
        if self.first_byte is None:
            self.first_byte = time.monotonic() - self.started
        self.bytes += len(chunk)
        write_all(self.log_descriptor, chunk)
        self._lines(chunk)
        return True

    def _run(self):
        try:
            os.set_blocking(self.pipe.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(self.pipe, selectors.EVENT_READ, "output")
                selector.register(self.wakeup_read, selectors.EVENT_READ, "wakeup")
                while not self.eof:
                    ready = selector.select()
                    work_start, cpu_start = time.monotonic(), time.thread_time()
                    if any(key.data == "output" for key, _ in ready):
                        self._read()
                    if self.stopping.is_set():
                        # Drain a finite queued prefix even when another process
                        # still holds the pipe. EOF is never inferred from reap.
                        for _ in range(4):
                            if not self._read():
                                break
                        self.work_seconds += time.monotonic() - work_start
                        self.cpu_seconds += time.thread_time() - cpu_start
                        break
                    self.work_seconds += time.monotonic() - work_start
                    self.cpu_seconds += time.thread_time() - cpu_start
        except BaseException as error:
            self.error_type = type(error).__name__
        finally:
            if self.pending or self.discard_line:
                self.partial_lines += 1
                if self.pending.startswith(PREFIX) or (self.pending and PREFIX.startswith(self.pending)):
                    self.partial_progress_lines += 1
            self._close()

    def finish(self, deadline):
        self.stopping.set()
        try:
            self.wakeup_write.send(b"x")
        except (BlockingIOError, OSError):
            pass
        if self.thread_started:
            self.thread.join(timeout=max(0.0, deadline - time.monotonic()))
        retired = not self.thread.is_alive()
        delivery = dict(state="DELIVERED", console_writer_retired=None, error_type=None)
        if self.last_console_ticket is not None:
            wait_console(self.last_console_ticket, deadline)
            delivery = console_delivery(self.last_console_ticket)
        delivered = delivery["state"] == "DELIVERED"
        complete = delivered and not self.console_dropped_records
        first = dict(status="OBSERVED", seconds=self.first_byte) if self.first_byte is not None else dict(
            status="UNAVAILABLE", reason="empty output" if self.eof else "output observation incomplete")
        first.update(scope="combined_stdout_stderr_including_telemetry",
                     measurement="parent_read_observation", application_readiness="UNPROVED")
        return dict(status="UNRETIRED" if not retired or delivery["state"] == "PENDING" else
                    "FAIL" if self.error_type or not complete else
                    "PASS" if self.eof else "PARTIAL", reader_retired=retired,
                    eof_observed=self.eof, bytes=self.bytes, first_output_byte=first,
                    error_type=self.error_type,
                    forwarded_records=self.forwarded + self.console_accepted if delivered else None,
                    synchronous_forwarded_records=self.forwarded,
                    console_accepted_records=self.console_accepted,
                    console_dropped_records=self.console_dropped_records,
                    console_dropped_bytes=self.console_dropped_bytes,
                    console_delivery_complete=complete,
                    console_delivery_state=delivery["state"],
                    console_writer_retired=delivery["console_writer_retired"],
                    console_error_type=delivery["error_type"],
                    console_delivery_scope="own_admitted_packets_not_global_writer_retirement",
                    rejected_records=self.decoder.rejected if self.decoder is not None else 0,
                    oversized_lines=self.oversized_lines, partial_lines=self.partial_lines,
                    oversized_progress_lines=self.oversized_progress_lines,
                    partial_progress_lines=self.partial_progress_lines,
                    work_seconds=self.work_seconds, cpu_seconds=self.cpu_seconds,
                    work_scope="inclusive_read_write_decode_forward_overlapping_command")


def self_test(artifacts, root):
    """Prove transport identity, byte preservation and bounded reader retirement."""
    from pathlib import Path
    import tempfile

    def decoder():
        return ProgressDecoder(artifacts=artifacts, source_roots=[(root, "repository")],
                               invocation="stream-control", source_digest="a" * 64,
                               phases=("core-normal",), direct_pid=123, direct_birth="control-123")

    def record(sequence=1, **changes):
        return dict(schema=2, event="testset_start", invocation="stream-control", source_digest="a" * 64,
                    ci_phase="core-normal", pid=123, thread=1, seq=sequence, elapsed_ns=0,
                    process_birth_id="control-123", testset_id=1, description="nested control",
                    file="test/control.jl", line=5) | changes

    def encode(value):
        return PREFIX + json.dumps(value).encode() + b"\n"

    bound = decoder()
    started = bound.decode(encode(record()).rstrip(b"\n"))
    assert started["description"] == "nested control"
    finalized = bound.decode(encode(record(9, event="testset_finalize", description=None,
        native_finish="threw", body_outcome="returned", counts=dict(passed=2, failed=1, errored=0, broken=0))).rstrip(b"\n"))
    assert finalized["testset_identity"]["description"] == "nested control"
    assert finalized["counts"]["failed"] == 1 and finalized["native_finish"] == "threw"
    assert finalized["observation_scope"] == "admitted_direct_process"
    assert bound.decode(encode(record(9)).rstrip(b"\n")) is None
    for change in (dict(invocation="stale"), dict(source_digest="b" * 64), dict(ci_phase="outer"),
                   dict(pid=124), dict(process_birth_id="other-123"), dict(seq=True),
                   dict(thread=0), dict(schema=2.0), dict(elapsed_ns=-1), dict(event=[])):
        assert decoder().decode(encode(record(**change)).rstrip(b"\n")) is None
    for invalid in (b'{"schema":2,"schema":2}', b'{"schema":NaN}', b'{"text":"\xff"}'):
        assert decoder().decode(PREFIX + invalid) is None
    safe = decoder().decode(encode(record(description=str(root / "private-file") + "\x1b[31m")).rstrip(b"\n"))
    assert str(root) not in json.dumps(safe) and "\x1b" not in json.dumps(safe)
    forwarded = ProgressDecoder(artifacts=artifacts, source_roots=[(root, "repository")],
                                invocation="stream-control", source_digest="a" * 64, phases=("core-normal",))
    assert forwarded.decode(encode(record()).rstrip(b"\n"))["observation_scope"] == "forwarded_declared_worker_phase"

    with tempfile.TemporaryDirectory(prefix="ltj-stream-control-") as temporary:
        directory = Path(temporary)

        def pump_for(name, *, decode=None, forward=None):
            read_fd, write_fd = os.pipe()
            with (directory / name).open("wb", buffering=0) as output:
                pump = PhaseLogPump(os.fdopen(read_fd, "rb", buffering=0), output.fileno(),
                                    started=time.monotonic(), decoder=decode, forward=forward)
            return pump, write_fd

        displayed = []
        pump, writer = pump_for("bytes", decode=decoder(), forward=displayed.append)
        raw = bytes((0, 127, 255, 10)) + encode(record()) + encode(record(2, invocation="stale"))
        pump.start()
        try:
            write_all(writer, raw)
        finally:
            os.close(writer)
        receipt = pump.finish(time.monotonic() + 0.5)
        assert receipt["status"] == "PASS" and receipt["eof_observed"]
        assert receipt["first_output_byte"]["status"] == "OBSERVED"
        assert receipt["first_output_byte"]["application_readiness"] == "UNPROVED"
        assert (directory / "bytes").read_bytes() == raw
        assert len(displayed) == 1 and receipt["rejected_records"] == 1

        pump, writer = pump_for("fragments", decode=decoder(), forward=displayed.append)
        marker = encode(record())
        pump._lines(marker[:7])
        pump._lines(marker[7:-2])
        assert pump.forwarded == 0
        pump._lines(marker[-2:])
        assert pump.forwarded == 1
        pump._lines(b"x" * (MAX_LINE_BYTES + 1) + b"\n")
        assert pump.oversized_lines == 1 and not pump.pending
        pump._lines(encode(record(3))[:-1])
        pump.start()
        os.close(writer)
        receipt = pump.finish(time.monotonic() + 0.5)
        assert receipt["status"] == "PASS" and receipt["partial_lines"] == 1
        assert receipt["partial_progress_lines"] == 1

        pump, writer = pump_for("held-open")
        pump.start()
        started = time.monotonic()
        receipt = pump.finish(started + 0.1)
        os.close(writer)
        assert receipt["reader_retired"] and receipt["status"] == "PARTIAL"
        assert not receipt["eof_observed"] and time.monotonic() - started < 0.2

        entered, release = threading.Event(), threading.Event()
        def blocked_forward(_):
            entered.set()
            release.wait()
        pump, writer = pump_for("blocked-forward", decode=decoder(), forward=blocked_forward)
        pump.start()
        write_all(writer, marker)
        os.close(writer)
        try:
            assert entered.wait(0.5)
            receipt = pump.finish(time.monotonic() + 0.025)
            assert receipt["status"] == "UNRETIRED" and not receipt["reader_retired"]
            assert os.fstat(pump.log_descriptor).st_size == len(marker)
        finally:
            release.set()
            pump.thread.join(timeout=0.5)
        assert not pump.thread.is_alive() and (directory / "blocked-forward").read_bytes() == marker

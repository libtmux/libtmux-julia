"""Critical console controls; application protocol pipes are never replaced."""

import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import threading
import time
import tempfile
import unittest


def streams():
    specification = importlib.util.spec_from_file_location(
        "console_controls", Path(__file__).with_name("ci-streams.py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def read_exact(descriptor, size):
    data = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(descriptor, selectors.EVENT_READ)
        deadline = time.monotonic() + .75
        while len(data) < size:
            if not selector.select(max(0, deadline - time.monotonic())):
                raise AssertionError("console did not deliver its admitted bytes")
            chunk = os.read(descriptor, min(65536, size - len(data)))
            if not chunk:
                raise AssertionError("console ended before its admitted bytes")
            data.extend(chunk)
    return bytes(data)


class ConsoleControls(unittest.TestCase):
    def test_status_submission_cannot_block_hard_cancellation(self):
        module = streams()
        read_fd, write_fd = os.pipe()
        original = os.dup(1)
        packet = b"soft-limit " + b"x" * 100000 + b"\n"
        completed, failures = threading.Event(), []
        child = subprocess.Popen([
            sys.executable, "-c",
            "import signal,sys; signal.signal(signal.SIGINT,lambda *_:sys.exit(23)); "
            "sys.stdout.buffer.write(b'R'); sys.stdout.buffer.flush(); signal.pause()"],
            stdout=subprocess.PIPE, start_new_session=True)
        self.assertEqual(read_exact(child.stdout.fileno(), 1), b"R")
        os.dup2(write_fd, 1)
        os.close(write_fd)

        def supervise():
            try:
                module.write_console(packet)
                os.killpg(child.pid, signal.SIGINT)
                child.wait(timeout=.25)
            except BaseException as error:
                failures.append(error)
            finally:
                completed.set()

        supervisor = threading.Thread(target=supervise, daemon=True)
        supervisor.start()
        try:
            self.assertTrue(completed.wait(.25),
                            "soft status write blocked the hard cancellation path")
            self.assertEqual(child.returncode, 23)
            self.assertFalse(failures)
        finally:
            try:
                captured = read_exact(read_fd, len(packet))
            finally:
                supervisor.join(timeout=.5)
                try:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=.5)
                    if hasattr(module, "finish_console"):
                        module.finish_console(time.monotonic() + .5)
                finally:
                    os.dup2(original, 1)
                    os.close(original)
                    os.close(read_fd)
                    child.stdout.close()
        self.assertEqual(captured, packet)
        self.assertFalse(supervisor.is_alive())

    def test_active_packet_owns_bound_and_fd_until_retirement(self):
        module = streams()
        read_fd, write_fd = os.pipe()
        packet, tail = b"a" * 100000, b"b" * 64
        sink = module.ConsoleSink(write_fd, generation=7,
                                  maximum_bytes=len(packet) + len(tail), maximum_records=2)
        duplicate = sink.descriptor
        os.close(write_fd)
        ticket = sink.submit(packet)
        with selectors.DefaultSelector() as selector:
            selector.register(read_fd, selectors.EVENT_READ)
            self.assertTrue(selector.select(.25))
        tail_ticket = sink.submit(tail)
        self.assertGreater(tail_ticket, ticket)
        self.assertEqual(sink.submit(b"overflow"), 0)
        self.assertFalse(sink.wait(ticket, time.monotonic()))
        started = time.monotonic()
        receipt = sink.finish(started + .025)
        try:
            self.assertLess(time.monotonic() - started, .1)
            self.assertEqual(receipt["status"], "UNRETIRED")
            self.assertEqual(receipt["in_flight_bytes"], len(packet))
            self.assertEqual(receipt["cancelled_bytes"], len(tail))
            self.assertEqual(receipt["cancelled_records"], 1)
            self.assertEqual(receipt["dropped_records"], 1)
            self.assertEqual(receipt["delivered_records"], 0)
            os.fstat(duplicate)
            self.assertFalse(sink.wait(tail_ticket, time.monotonic() + .025))
            self.assertEqual(sink.submit(b"after stop"), 0)
        finally:
            captured = read_exact(read_fd, len(packet))
            final = sink.finish(time.monotonic() + .25)
            os.close(read_fd)
        self.assertEqual(captured, packet)
        self.assertTrue(sink.wait(ticket, time.monotonic()))
        self.assertEqual(final["status"], "FAIL")
        self.assertTrue(final["console_writer_retired"])
        with self.assertRaises(OSError):
            os.fstat(duplicate)
        self.assertFalse(sink.wait((8 << 32) | 1, time.monotonic()))
        self.assertFalse(sink.wait(ticket + 100, time.monotonic()))

    def test_concurrent_packets_are_full_fifo_records(self):
        module = streams()
        read_fd, write_fd = os.pipe()
        sink = module.ConsoleSink(write_fd)
        os.close(write_fd)
        packets = [(json.dumps(dict(worker=worker, detail=worker * 100000)) + "\n").encode()
                   for worker in ("A", "B")]
        admitted, gate = [], threading.Barrier(3)

        def submit(packet):
            gate.wait(timeout=.25)
            admitted.append((sink.submit(packet), packet))

        senders = [threading.Thread(target=submit, args=(packet,), daemon=True) for packet in packets]
        for sender in senders:
            sender.start()
        gate.wait(timeout=.25)
        try:
            for sender in senders:
                sender.join(timeout=.25)
                self.assertFalse(sender.is_alive())
            self.assertEqual(len(admitted), 2)
            self.assertTrue(all(ticket > 0 for ticket, _ in admitted))
            captured = read_exact(read_fd, sum(map(len, packets)))
        finally:
            receipt = sink.finish(time.monotonic() + .25)
            os.close(read_fd)
        self.assertEqual(captured, b"".join(packet for _, packet in sorted(admitted)))
        self.assertEqual(sorted(json.loads(line)["worker"] for line in captured.splitlines()), ["A", "B"])
        self.assertEqual(receipt["status"], "PASS")
        self.assertEqual(receipt["delivered_records"], 2)

    def test_write_fault_and_queue_rejection_latch_failure(self):
        module = streams()
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        sink = module.ConsoleSink(write_fd, maximum_bytes=8, maximum_records=1)
        os.close(write_fd)
        self.assertEqual(sink.submit(b"too large"), 0)
        ticket = sink.submit(b"error")
        self.assertGreater(ticket, 0)
        receipt = sink.finish(time.monotonic() + .25)
        self.assertEqual(receipt["status"], "FAIL")
        self.assertEqual(receipt["error_type"], "BrokenPipeError")
        self.assertEqual(receipt["failed_records"], 1)
        self.assertEqual(receipt["dropped_records"], 1)
        self.assertFalse(sink.wait(ticket, time.monotonic() + .25))

    def test_final_receipt_stops_admission_even_without_a_writer(self):
        module = streams()
        self.assertEqual(module.finish_console(time.monotonic())["status"], "PASS")
        self.assertEqual(module.write_console(b"late status"), 0)
        self.assertIsNone(module._console_sink)
        receipt = module.finish_console(time.monotonic())
        self.assertEqual(receipt["status"], "FAIL")
        self.assertTrue(receipt["console_writer_retired"])
        self.assertEqual(receipt["historical_faults"]["dropped_records"], 1)

    def test_pump_retired_broken_pipe_reports_failure(self):
        module = streams()
        original = os.dup(1)
        console_read, console_write = os.pipe()
        os.close(console_read)
        os.dup2(console_write, 1)
        os.close(console_write)
        seen = threading.Event()

        class Decoder:
            rejected = 0

            def decode(self, line):
                return json.loads(line[len(module.PREFIX):])

        packet = module.PREFIX + b'{"event":"profile_checkpoint"}\n'
        try:
            with tempfile.TemporaryDirectory(prefix="ltj-console-fault-") as directory:
                log = Path(directory) / "phase.log"
                read_fd, write_fd = os.pipe()
                with log.open("wb", buffering=0) as output:
                    pump = module.PhaseLogPump(os.fdopen(read_fd, "rb", buffering=0), output.fileno(),
                                               started=time.monotonic(), decoder=Decoder(),
                                               on_progress=lambda _: seen.set())
                pump.start()
                module.write_all(write_fd, packet)
                os.close(write_fd)
                self.assertTrue(seen.wait(.25))
                module._console_sink.thread.join(timeout=.25)
                self.assertFalse(module._console_sink.thread.is_alive())
                receipt = pump.finish(time.monotonic() + .25)
                self.assertTrue(receipt["reader_retired"])
                self.assertEqual(receipt["status"], "FAIL")
                self.assertFalse(receipt["console_delivery_complete"])
                self.assertEqual(receipt["console_delivery_state"], "FAILED")
                self.assertTrue(receipt["console_writer_retired"])
                self.assertEqual(receipt["console_error_type"], "BrokenPipeError")
                self.assertEqual(log.read_bytes(), packet)
        finally:
            module.finish_console(time.monotonic() + .25)
            os.dup2(original, 1)
            os.close(original)

    def test_pump_preserves_journal_and_notifies_when_console_drops(self):
        module = streams()
        original = os.dup(1)
        console_read, console_write = os.pipe()
        os.dup2(console_write, 1)
        os.close(console_write)
        module.MAX_CONSOLE_BYTES = 100064
        # Constructor defaults are bound at definition; install a smaller sink.
        module._console_generation = 1
        module._console_sink = module.ConsoleSink(maximum_bytes=100064, maximum_records=1)
        admitted = module.write_console(b"occupied" + b"x" * 100000)
        seen = threading.Event()

        class Decoder:
            rejected = 0

            def decode(self, line):
                return json.loads(line[len(module.PREFIX):])

        packet = module.PREFIX + json.dumps(dict(event="profile_checkpoint", detail="kept")).encode() + b"\n"
        read_fd, write_fd = os.pipe()
        with tempfile.TemporaryDirectory(prefix="ltj-console-journal-") as directory:
            log = Path(directory) / "phase.log"
            with log.open("wb", buffering=0) as output:
                pump = module.PhaseLogPump(os.fdopen(read_fd, "rb", buffering=0), output.fileno(),
                                           started=time.monotonic(), decoder=Decoder(),
                                           on_progress=lambda _: seen.set())
            pump.start()
            module.write_all(write_fd, packet)
            os.close(write_fd)
            try:
                self.assertTrue(seen.wait(.25), "queue rejection prevented checkpoint notification")
                receipt = pump.finish(time.monotonic() + .25)
                self.assertEqual(receipt["status"], "FAIL")
                self.assertTrue(receipt["reader_retired"])
                self.assertTrue(receipt["eof_observed"])
                self.assertFalse(receipt["console_delivery_complete"])
                self.assertEqual(receipt["console_dropped_records"], 1)
                self.assertEqual(receipt["forwarded_records"], 0)
                self.assertEqual(log.read_bytes(), packet)
            finally:
                try:
                    captured = read_exact(console_read, len(b"occupied") + 100000)
                finally:
                    final = module.finish_console(time.monotonic() + .25)
                    os.dup2(original, 1)
                    os.close(original)
                    os.close(console_read)
        self.assertTrue(module.wait_console(admitted, time.monotonic()))
        self.assertEqual(captured, b"occupied" + b"x" * 100000)
        self.assertEqual(final["status"], "FAIL")
        pump_sink = module._console_sink
        self.assertEqual(module.write_console(b"late after retirement"), 0)
        self.assertIs(module._console_sink, pump_sink)
        self.assertFalse(pump_sink.thread.is_alive())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Run unchanged exported examples with an audited tmux executable boundary."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys


FAULT = "libtmux-example-injected-command-failure"


def _ps_process_identity(pid):
    import subprocess
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


_DARWIN_PROC_PIDINFO = None
if sys.platform == "darwin":
    import ctypes
    try:
        class _DarwinBSDInfo(ctypes.Structure):
            _fields_ = [
                ("flags", ctypes.c_uint32),
                ("status", ctypes.c_uint32),
                ("exit_status", ctypes.c_uint32),
                ("pid", ctypes.c_uint32),
                ("parent_pid", ctypes.c_uint32),
                ("uid", ctypes.c_uint32),
                ("gid", ctypes.c_uint32),
                ("real_uid", ctypes.c_uint32),
                ("real_gid", ctypes.c_uint32),
                ("saved_uid", ctypes.c_uint32),
                ("saved_gid", ctypes.c_uint32),
                ("reserved", ctypes.c_uint32),
                ("command", ctypes.c_char * 16),
                ("name", ctypes.c_char * 32),
                ("files", ctypes.c_uint32),
                ("process_group", ctypes.c_uint32),
                ("job_control", ctypes.c_uint32),
                ("terminal_device", ctypes.c_uint32),
                ("terminal_group", ctypes.c_uint32),
                ("nice", ctypes.c_int32),
                ("start_seconds", ctypes.c_uint64),
                ("start_microseconds", ctypes.c_uint64),
            ]

        _DARWIN_PROC_PIDINFO = ctypes.CDLL(
            "/usr/lib/libproc.dylib",
            use_errno=True,
        ).proc_pidinfo
        _DARWIN_PROC_PIDINFO.argtypes = (
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        )
        _DARWIN_PROC_PIDINFO.restype = ctypes.c_int
    except (AttributeError, OSError):
        pass


def _darwin_process_identity(pid, *, fallback=True):
    if _DARWIN_PROC_PIDINFO is None:
        return _ps_process_identity(pid) if fallback else None
    info = _DarwinBSDInfo()
    result = _DARWIN_PROC_PIDINFO(
        pid,
        3,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if result == ctypes.sizeof(info):
        return f"{info.start_seconds}:{info.start_microseconds}"
    if result == 0 or not fallback:
        return None
    return _ps_process_identity(pid)


def process_identity(pid):
    if sys.platform.startswith("linux"):
        try:
            return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
        except (FileNotFoundError, ProcessLookupError):
            return None
    if sys.platform == "darwin":
        return _darwin_process_identity(pid)
    return _ps_process_identity(pid)


def process_identity_self_test():
    import subprocess
    current = process_identity(os.getpid())
    if current is None:
        raise AssertionError("current process has no identity")
    if sys.platform == "darwin":
        if _DARWIN_PROC_PIDINFO is None:
            raise AssertionError("proc_pidinfo is unavailable")
        native = _darwin_process_identity(os.getpid(), fallback=False)
        if native is None or current != native:
            raise AssertionError("proc_pidinfo did not identify the current process")
    child = subprocess.Popen([sys.executable, "-c", ""])
    child.wait()
    if process_identity(child.pid) is not None:
        raise AssertionError("reaped child remains identifiable")
    if current != process_identity(os.getpid()):
        raise AssertionError("current identity changed")
    print("PASS process identity lookup")


def tmux_boundary(config_path, arguments):
    config = json.loads(Path(config_path).read_text())
    root = Path(config_path).parent
    socket = arguments[arguments.index("-S") + 1] if "-S" in arguments else None
    if socket is not None and root not in Path(socket).parents:
        raise ValueError("example attempted a tmux socket outside its owned directory")
    if socket is None and arguments != ["-V"]:
        raise ValueError("example attempted tmux without an explicit owned socket")
    daemon = "-D" in arguments
    started = process_identity(os.getpid())
    if started is None:
        raise RuntimeError("could not identify tmux boundary process")
    record = dict(pid=os.getpid(), started=started, daemon=daemon, socket=socket)
    if daemon:
        record["owner"] = (Path(socket).parent / "owner").read_text()
    (root / f"process-{os.getpid()}.json").write_text(json.dumps(record))
    inject = False
    if config["fault"] and socket is not None and not daemon:
        try:
            (root / "armed").unlink()
            inject = True
        except FileNotFoundError:
            pass
    if inject:
        import subprocess
        # Confirm a real session exists before failing the subsequent request.
        result = subprocess.run([config["tmux"], "-N", "-S", socket,
                                 "list-sessions", "-F", "#{session_id}"],
                                capture_output=True, check=True, timeout=0.9)
        if not result.stdout.startswith(b"$"):
            raise AssertionError("failure injection did not follow session creation")
        (root / "fault.json").write_text(json.dumps(dict(
            sessions=result.stdout.decode(), client=os.getpid(), exit=86)))
        print(FAULT, file=sys.stderr)
        return 86
    if config["fault"] and "new-session" in arguments and not (root / "fault.json").exists():
        (root / "armed").touch()
    os.execv(config["tmux"], [config["tmux"], *arguments])


def terminate_record(record):
    """Rescue only the recorded process instance after reporting a failed audit."""
    import select
    import signal
    pid = record["pid"]
    if process_identity(pid) != record["started"]:
        return
    if hasattr(os, "pidfd_open"):
        try:
            descriptor = os.pidfd_open(pid)
        except ProcessLookupError:
            return
        try:
            if process_identity(pid) != record["started"]:
                return
            signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            if not select.select([descriptor], [], [], 0.9)[0]:
                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                if not select.select([descriptor], [], [], 0.9)[0]:
                    raise AssertionError("owned example process did not exit after rescue")
        finally:
            os.close(descriptor)
    else:
        watcher = select.kqueue()
        try:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                 fflags=select.KQ_NOTE_EXIT)
            try:
                watcher.control([event], 0, 0)
                if process_identity(pid) != record["started"]:
                    return
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            if not watcher.control(None, 1, 0.9):
                os.kill(pid, signal.SIGKILL)
                if not watcher.control(None, 1, 0.9):
                    raise AssertionError("owned example process did not exit after rescue")
        finally:
            watcher.close()


def run_example(command, *, tmux, env, cwd, fault=False, diagnostics=True):
    import subprocess
    import tempfile
    import time
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="ltj-ex-", dir="/tmp") as directory:
        root = Path(directory)
        config = root / "config.json"
        config.write_text(json.dumps(dict(tmux=str(Path(tmux).resolve()), fault=fault)))
        wrapper = root / "tmux"
        wrapper.write_text(f"#!{sys.executable} -S\nimport sys\n"
                           f"sys.argv = [{str(Path(__file__).resolve())!r}, '--tmux-boundary', "
                           f"{str(config)!r}, *sys.argv[1:]]\n"
                           f"__file__ = {str(Path(__file__).resolve())!r}\n"
                           "exec(compile(open(__file__).read(), __file__, 'exec'))\n")
        wrapper.chmod(0o700)
        child_env = dict(env, LIBTMUX_TEST_TMUX=str(wrapper), TMPDIR=directory)
        child_env.pop("TMUX", None)
        child_env.pop("TMUX_PANE", None)
        records, problems = [], []
        try:
            result = subprocess.run(command, cwd=cwd, env=child_env, capture_output=True,
                                    timeout=60, check=False)
            records = [json.loads(path.read_text()) for path in root.glob("process-*.json")]
            daemons = [item for item in records if item["daemon"]]
            injected = (root / "fault.json").exists()
            if fault:
                if result.returncode == 0 or not injected:
                    problems.append("example did not propagate the injected command failure")
            elif result.returncode != 0:
                problems.append(f"example exited {result.returncode}")
            for record in records:
                if process_identity(record["pid"]) == record["started"]:
                    problems.append("example left a daemon or client process alive or unreaped")
            for record in daemons:
                if Path(record["socket"]).parent.exists():
                    problems.append("example left its owned socket directory")
            if problems:
                # Child environments stay private; print only their own diagnostics.
                if diagnostics:
                    sys.stdout.buffer.write(result.stdout)
                    sys.stderr.buffer.write(result.stderr)
                raise AssertionError("; ".join(dict.fromkeys(problems)))
            return dict(fault=fault, daemons=len(daemons), clients=len(records)-len(daemons),
                        exit=result.returncode, seconds=time.monotonic()-started,
                        injected=injected)
        finally:
            # Also covers checker timeouts. No borrowed/default endpoint is contacted.
            records = [json.loads(path.read_text()) for path in root.glob("process-*.json")]
            for record in records:
                terminate_record(record)


def main():
    if sys.argv[1:2] == ["--tmux-boundary"]:
        return tmux_boundary(sys.argv[2], sys.argv[3:])
    import argparse
    import shutil
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tmux", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--negative-control", action="store_true")
    parser.add_argument("--identity-self-test", action="store_true")
    parser.add_argument("--pure", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.identity_self_test:
        process_identity_self_test()
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("an example command is required")
    tmux = shutil.which(args.tmux)
    if tmux is None:
        parser.error("tmux executable is unavailable")
    if args.negative_control:
        program = '''using LibTmux
        owned = open_server(; tmux=ENV["LIBTMUX_TEST_TMUX"])
        new_session(owned.server; name="missing-close", command=["/bin/cat"])
        '''
        try:
            run_example([*command, "-e", program], tmux=tmux, env=os.environ,
                        cwd=args.cwd, diagnostics=False)
        except AssertionError as error:
            assert "process alive or unreaped" in str(error), str(error)
            assert "socket directory" in str(error), str(error)
        else:
            raise AssertionError("cleanup audit accepted a real missing close")
        print("PASS negative control rejects a real daemon and socket-directory leak")
        return 0
    success = run_example(command, tmux=tmux, env=os.environ, cwd=args.cwd)
    if bool(success["daemons"]) == args.pure:
        raise AssertionError("example ownership differs from its declared runtime class")
    print("PASS example success and independent cleanup " + json.dumps(success), flush=True)
    if success["daemons"]:
        failure = run_example(command, tmux=tmux, env=os.environ, cwd=args.cwd, fault=True)
        print("PASS example failure after session creation and independent cleanup " +
              json.dumps(failure), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

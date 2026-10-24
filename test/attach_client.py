"""Attach a tmux client through a pty and report its pid.

usage: attach_client.py TMUX SOCKET SESSION PIDFILE
"""

import os
import pty
import sys
import time
from pathlib import Path

tmux, socket, session, pidfile = sys.argv[1:5]
env = dict(os.environ, TERM="xterm-256color")
pid, _ = pty.fork()
if pid == 0:
    os.execve(tmux, [tmux, "-S", socket, "attach", "-t", session], env)
staging = Path(pidfile + ".tmp")
with staging.open("w") as handle:
    handle.write(str(pid))
staging.rename(pidfile)
time.sleep(120)

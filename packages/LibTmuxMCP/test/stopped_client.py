"""Attach a second tmux client through a pty and report its pid.

usage: stopped_client.py TMUX SOCKET SESSION PIDFILE (pty|control)

The test stops this client with SIGSTOP so tmux keeps a killed server alive
until the client is removed.
"""

import os
import pty
import sys
import time
from pathlib import Path

tmux, socket, session, pidfile, mode = sys.argv[1:6]
pid, _ = pty.fork()
if pid == 0:
    if mode == "control":
        attach = ["-C", "attach", "-t", session]
    else:
        attach = ["attach", "-t", session]
    os.execv(tmux, [tmux, "-S", socket, *attach])
staging = Path(pidfile + ".tmp")
with staging.open("w") as handle:
    handle.write(str(pid))
staging.rename(pidfile)
time.sleep(120)

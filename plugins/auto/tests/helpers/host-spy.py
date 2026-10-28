"""Run a script with every host-binary spawn recorded: usage host-spy.py <log> <script> [args...].

Each line of the log is "<kind> <binary> via-host|direct": via-host when a host_*.py frame is on
the call stack, direct when auto code spawned the host binary on its own.
"""
import os
import runpy
import shutil
import subprocess
import sys
import traceback

LOG = sys.argv[1]
HOSTS = {"herdr", "rex", "osascript"}


def note(kind, name):
    via = any(os.path.basename(f.filename).startswith("host_") for f in traceback.extract_stack())
    with open(LOG, "a") as fh:
        fh.write(f"{kind} {name} {'via-host' if via else 'direct'}\n")


_init = subprocess.Popen.__init__


def init(self, args, *a, **k):
    argv = args if isinstance(args, (list, tuple)) else [args]
    name = os.path.basename(str(argv[0])) if argv else ""
    if name in HOSTS:
        note("run", name)
    return _init(self, args, *a, **k)


subprocess.Popen.__init__ = init
_which = shutil.which


def which(cmd, *a, **k):
    if os.path.basename(cmd) in HOSTS:
        note("which", cmd)
    return _which(cmd, *a, **k)


shutil.which = which
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")

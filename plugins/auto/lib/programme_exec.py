#!/usr/bin/env python3
"""Bounded child processes for the programme's source reads."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_sanitize = load_lib_module("programme_sanitize")

TIMEOUT_ENV = "CLAUDE_AUTO_SOURCE_TIMEOUT"


def seconds(env_name, default) -> float:
    try:
        value = float(os.environ.get(env_name) or "")
    except ValueError:
        return default
    return value if value > 0 else default


def source_timeout(default) -> float:
    return seconds(TIMEOUT_ENV, default)


def _kill(proc) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        proc.communicate(timeout=1)
    except (subprocess.SubprocessError, OSError, ValueError):
        pass


def bounded(argv, timeout, stdin_text=None) -> dict:
    out = {"ran": False, "code": None, "stdout": "", "stderr": "", "timed_out": False, "error": None,
           "missing": False}
    path = argv[0] if os.path.isabs(argv[0]) else shutil.which(argv[0])
    if not path:
        out.update(error=f"{argv[0]} not found on PATH", missing=True)
        return out
    try:
        proc = subprocess.Popen(
            [path] + list(argv[1:]), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            text=True, errors="replace", start_new_session=True)
    except OSError as exc:
        out["error"] = f"could not run {argv[0]}: {exc}"
        return out
    try:
        stdout, stderr = proc.communicate(stdin_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        # A killed child's grandchildren keep the pipes open; kill the whole group.
        _kill(proc)
        out.update(timed_out=True, error=f"{' '.join(argv[:3])} timed out after {timeout:g}s")
        return out
    out.update(ran=True, code=proc.returncode, stdout=stdout or "", stderr=stderr or "")
    return out


def parse_json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def failure(result, what) -> str:
    if not result["ran"]:
        return result["error"]
    detail = programme_sanitize.clean(result["stderr"] or result["stdout"], 200)
    return f"{what} exited {result['code']}" + (f": {detail}" if detail else "")

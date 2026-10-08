#!/usr/bin/env python3
"""PreCompact: mark each programme this session drives as compacted.

While `<home>/.compact-flag` exists, the programme's write verbs refuse and print
the rules in force until the PM runs `programme.py rules --ack`. Never blocks
compaction. Always exits 0.
"""

from __future__ import annotations

import datetime
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402



def hook_input(raw) -> dict:
    try:
        data = json.loads(raw or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def main_thread_session(data):
    if data.get("agent_id"):
        return None
    sid = data.get("session_id")
    return sid if isinstance(sid, str) and sid else None


def driven_programmes(session_id) -> list:
    if not session_id:
        return []
    return load_lib_module("programme_home").driven_runs(session_id)


def _set_flag(home, session_id, data) -> None:
    body = json.dumps({
        "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session_id": session_id,
        "trigger": data.get("trigger"),
    })
    flag = os.path.join(home, load_lib_module("programme_home").COMPACT_FLAG)
    fd = os.open(flag, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(body + "\n")


def mark_compacted(raw) -> list:
    data = hook_input(raw)
    sid = main_thread_session(data)
    marked = []
    for hold in driven_programmes(sid):
        try:
            _set_flag(hold["home"], sid, data)
            marked.append(hold["run"])
        except OSError:
            continue
    return marked


def _cli() -> int:
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        mark_compacted(raw)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

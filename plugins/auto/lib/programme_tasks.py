#!/usr/bin/env python3
"""The tasks source: Claude Code task lists of the sessions in the remit. Read-only."""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_sanitize = load_lib_module("programme_sanitize")

TASKS_ENV = "CLAUDE_AUTO_TASKS_DIR"
DEFAULT_ROOT = "~/.claude/tasks"
STATUSES = ("pending", "in_progress", "completed")
FILE_CAP = 200
BYTES_CAP = 65536
NOW_CAP = 120
SESSION_CAP = 64


def root() -> str:
    return os.path.expanduser(os.environ.get(TASKS_ENV) or DEFAULT_ROOT)


def _empty() -> dict:
    return {"counts": {s: 0 for s in STATUSES}, "total": 0, "now": None}


def _order(name):
    stem = name[:-len(".json")]
    return (0, int(stem), name) if stem.isdigit() else (1, 0, name)


def _load(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.loads(fh.read(BYTES_CAP + 1)[:BYTES_CAP])
    except (OSError, ValueError):
        return None


def read_session(session_id) -> dict:
    out = _empty()
    sid = programme_sanitize.token(session_id)
    if not sid or "/" in sid or sid.startswith("."):
        return out
    folder = os.path.join(root(), sid)
    try:
        names = sorted((n for n in os.listdir(folder) if n.endswith(".json")), key=_order)[:FILE_CAP]
    except OSError:
        return out
    for name in names:
        task = _load(os.path.join(folder, name))
        if not isinstance(task, dict) or task.get("status") not in STATUSES:
            continue
        out["counts"][task["status"]] += 1
        out["total"] += 1
        if task["status"] == "in_progress" and out["now"] is None:
            out["now"] = programme_sanitize.clean(task.get("activeForm") or task.get("subject"), NOW_CAP) or None
    return out


def read(session_ids) -> dict:
    base = root()
    if os.path.exists(base) and not os.path.isdir(base):
        return {"state": "unavailable", "unavailable": True, "reason": f"{base} is not a folder",
                "sessions": {}, "with_lists": 0}
    sessions = {sid: read_session(sid) for sid in sorted(s for s in session_ids if s)[:SESSION_CAP]}
    return {"state": "available", "unavailable": False, "reason": None, "sessions": sessions,
            "with_lists": sum(1 for s in sessions.values() if s["total"])}

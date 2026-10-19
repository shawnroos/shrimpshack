#!/usr/bin/env python3
"""Read Claude Code's own permission rulings from a session transcript.

Each Bash result row carries the runtime's decision (permissionDecision) and the
layer that made it (reasonType). This is the only denial evidence Programme trusts.
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

programme_sanitize = load_lib_module("programme_sanitize")
session_registry = load_lib_module("session_registry")

TRANSCRIPT_CAP = 64 * 1024 * 1024
# reasonType on a reject row → the layer that refused. subcommandResults on a reject is a deny rule.
LAYERS = {"mode": "mode", "classifier": "classifier", "subcommandResults": "deny rule", "hook": "hook"}
# An allow rule in a settings file lifts only these refusals.
PROPOSABLE = ("mode", "classifier")
NEXT_ACTION = {
    "deny rule": "remove or narrow the deny rule that matches the command",
    "mode": "the session's permission mode refuses commands no allow rule covers; check managed settings "
            "or a --settings flag on that session",
    "classifier": "the auto-mode classifier refused it; an allow rule in a file it reads would skip it",
    "hook": "a PreToolUse hook refused it; an allow rule does not override a hook",
}


def path_for(sid):
    # The registry's path, never one a caller supplies: a forged path could name a transcript its author wrote.
    row = session_registry.lookup(sid, include_headless=True) or {} if sid else {}
    path = row.get("transcript_path")
    return path if isinstance(path, str) and os.path.basename(path) == f"{sid}.jsonl" else None


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def rows(path, start=0):
    """(byte offset, row) pairs from start, and the offset just past the last complete line.

    None when the rest of the file is over the cap, so a caller never mistakes it for a transcript with no rows.
    """
    with open(path, "rb") as fh:
        fh.seek(start)
        data = fh.read(TRANSCRIPT_CAP + 1)
    if len(data) > TRANSCRIPT_CAP:
        return None
    out, at = [], start
    for line in data.splitlines(keepends=True):
        if not line.endswith(b"\n"):
            break
        try:
            row = json.loads(line)
        except ValueError:
            row = None
        if isinstance(row, dict):
            out.append((at, row))
        at += len(line)
    return out, at


def _blocks(row, kind) -> list:
    content = (row.get("message") or {}).get("content") if isinstance(row.get("message"), dict) else None
    return [b for b in content if isinstance(b, dict) and b.get("type") == kind] if isinstance(content, list) else []


def _when(value):
    # Transcript timestamps carry milliseconds ("2026-10-18T14:44:19.552Z"); compare whole seconds.
    if not isinstance(value, str) or len(value) < 19:
        return None
    try:
        return datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def runtime_ruling(row) -> dict:
    found = row.get("permissionDecision") if isinstance(row.get("permissionDecision"), dict) else {}
    ruling = found.get("decision")
    return {"ruling": ruling if ruling in ("accept", "reject") else None,
            "reason_type": programme_sanitize.token(found.get("reasonType")),
            "denial_kind": programme_sanitize.token(row.get("toolDenialKind")),
            "at": _when(row.get("timestamp"))}


def layer(use) -> str:
    return LAYERS.get(use.get("reason_type"), "unknown")


def tool_uses(path, offset=0):
    try:
        found = rows(path, offset)
    except OSError:
        return None
    if found is None:
        return None
    pairs, read_to = found
    uses, order = {}, []
    for pos, row in pairs:
        if row.get("type") == "assistant":
            for block in _blocks(row, "tool_use"):
                command = (block.get("input") or {}).get("command")
                if block.get("name") == "Bash" and isinstance(command, str) and isinstance(block.get("id"), str):
                    uses[block["id"]] = {"tool_use_id": block["id"], "command": command, "ruling": None,
                                         "reason_type": None, "denial_kind": None, "at": None, "offset": pos,
                                         "answered": False}
                    order.append(block["id"])
        elif row.get("type") == "user":
            ruling = runtime_ruling(row)
            for block in _blocks(row, "tool_result"):
                use = uses.get(block.get("tool_use_id"))
                if use is not None:
                    use.update(ruling, answered=True)
    return [uses[i] for i in order], read_to

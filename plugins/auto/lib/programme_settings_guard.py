#!/usr/bin/env python3
"""Refuse a programme session's write to a settings file a permission proposal targets.

Best effort: the driving session and the sessions of unfinished items are refused
Write, Edit, MultiEdit or Bash calls that name that settings.local.json. Only Shawn applies rules.
While the programme's record cannot be read, the driver and every session in its space are
refused any .claude/settings.local.json: which one a proposal targets cannot be known.
"""

from __future__ import annotations

import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
session_registry = load_lib_module("session_registry")
rules = load_lib_module("programme_permission_rules")

SETTINGS_FILE = rules.DESTINATION_FILE
_TOOLS = ("Bash", "Write", "Edit", "MultiEdit")
_TOKEN = re.compile(r"[^\s;&|<>()`]*\.claude/settings\.local\.json(?![\w.-])", re.IGNORECASE)
_HIDING_CHARS = re.compile(r"[\"'\\\\]")


def _space_run(session_id, env):
    space = session_registry.space_of_session(session_id, env)
    if not space:
        return None
    try:
        lease = programme_home.read_lease(programme_home.lease_path(*space))
    except programme_home.ProgrammeHomeError:
        return None
    if not lease:
        return None
    status, read = programme_home.lease_state(lease)
    if status not in programme_home.HELD_LEASE_STATES or read is None:
        return None
    record, hold = read
    if hold is not None:
        return lease.get("run"), None
    return (lease["run"], record) if isinstance(record, dict) else None


def _item_ids(programme, session_id) -> list:
    found = []
    for item_id, item in sorted((programme.get("items") or {}).items()):
        if not isinstance(item, dict) or item.get("state") in programme_home.FINISHED_ITEM_STATES:
            continue
        if session_id in programme_home.session_ids(item):
            found.append(item_id)
    return found


def scope(session_id, env):
    """(run_id, programme, item_ids), or (run_id, None, []) when the run's record cannot be read."""
    if not isinstance(session_id, str) or not session_id:
        return None
    driven = programme_home.driven_runs(session_id)
    held = [d["run"] for d in driven if d.get("hold") is not None]
    if held:
        return held[0], None, []
    driven = [d for d in driven if isinstance(d.get("record"), dict)]
    found = (driven[0]["run"], driven[0]["record"]) if driven else _space_run(session_id, env)
    if found is None:
        return None
    run_id, record = found
    if record is None:
        return run_id, None, []
    programme = record.get("programme")
    if not isinstance(programme, dict) or programme.get("ended"):
        return None
    item_ids = _item_ids(programme, session_id)
    return (run_id, programme, item_ids) if driven or item_ids else None


def _expanded(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path))


def _resolved(path: str, cwd: str) -> str:
    path = _expanded(path)
    return os.path.realpath(path if os.path.isabs(path) else os.path.join(cwd, path))


def _any_settings_file(path: str) -> bool:
    parent, name = os.path.split(path)
    return name.casefold() == "settings.local.json" and os.path.basename(parent).casefold() == ".claude"


def _target(tool_name, tool_input, cwd, destinations):
    """destinations None means any .claude/settings.local.json: the proposals cannot be read."""
    # Casefolded: the macOS file system is case-insensitive, so .claude/Settings.local.json is the same file.
    guarded = {os.path.realpath(os.path.join(d, SETTINGS_FILE)).casefold() for d in destinations or ()}

    def hit(path):
        return _any_settings_file(path) if destinations is None else path.casefold() in guarded

    if tool_name != "Bash":
        path = tool_input.get("file_path")
        path = _resolved(path, cwd) if isinstance(path, str) else None
        return path if path and hit(path) else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = _HIDING_CHARS.sub("", command)
    tokens = _TOKEN.findall(text)
    for token in tokens:
        if hit(_resolved(token, cwd)):
            return _resolved(token, cwd)
    if destinations is None:
        return None
    # A relative name after a cd elsewhere resolves against the wrong folder; best effort.
    if any(not os.path.isabs(_expanded(t)) for t in tokens):
        folded = _expanded(text).casefold()
        for dest in destinations:
            if dest.casefold() in folded or os.path.realpath(dest).casefold() in folded:
                return os.path.realpath(os.path.join(dest, SETTINGS_FILE))
    return None


def decision(stdin_raw: str):
    """(deny, journal_row) or None. The caller emits the deny before it journals the row."""
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in _TOOLS:
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if "settings.local.json" not in json.dumps(tool_input).casefold():
        return None
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    found = scope(session_id, os.environ)
    if found is None:
        return None
    run_id, programme, item_ids = found
    destinations = None if programme is None else [
        p.get("destination") for p in programme.get("permission_proposals") or []
        if isinstance(p, dict) and isinstance(p.get("destination"), str) and os.path.isabs(p["destination"])]
    if destinations == []:
        return None
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    target = _target(tool_name, tool_input, cwd, destinations)
    if target is None:
        return None
    if programme is None:
        return _deny(
            f"auto: this call names {target}, and the record of programme {run_id!r} cannot be read "
            "right now, so no settings file can be cleared. Only Shawn applies permission rules; "
            "retry once the programme is readable, or continue the work that does not need this."), None
    payload = {"tool": tool_name, "path": target, "item_ids": item_ids}
    if tool_name == "Bash":
        payload["command"] = tool_input.get("command")
    return _deny(
        f"auto: this call names {target}, the settings file a permission proposal of "
        f"programme {run_id!r} targets. Only Shawn applies permission rules; continue the "
        "work that does not need this. This attempt is journaled."), \
        (run_id, "blocked_settings_write", session_id, payload)


def _deny(reason: str) -> dict:
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}

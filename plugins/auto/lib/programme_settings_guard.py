#!/usr/bin/env python3
"""Refuse a programme session's write to a settings file a permission proposal targets.

Best effort: the driving session and the sessions of unfinished items are refused
Write, Edit, MultiEdit or Bash calls that name that settings.local.json. Only Shawn applies rules.
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
programme_journal = load_lib_module("programme_journal")
session_registry = load_lib_module("session_registry")
rules = load_lib_module("programme_permission_rules")

SETTINGS_FILE = rules.DESTINATION_FILE
_TOOLS = ("Bash", "Write", "Edit", "MultiEdit")
_TOKEN = re.compile(r"[^\s;&|<>()`]*\.claude/settings\.local\.json(?![\w.-])")
_HIDING_CHARS = re.compile(r"[\"'\\\\]")


def _space_run(session_id, env):
    space = session_registry.space_of_session(session_id, env)
    if not space:
        return None
    try:
        lease = programme_home.read_lease(programme_home.lease_path(*space))
    except programme_home.ProgrammeHomeError:
        return None
    if not lease or lease.get("corrupt") or \
            programme_home.lease_status(lease) not in programme_home.HELD_LEASE_STATES:
        return None
    record = programme_home._read_record(lease.get("run"))
    return (lease["run"], record) if isinstance(record, dict) else None


def _item_ids(programme, session_id) -> list:
    found = []
    for item_id, item in sorted((programme.get("items") or {}).items()):
        if not isinstance(item, dict) or item.get("state") in programme_home.FINISHED_ITEM_STATES:
            continue
        sids = [(item.get("owner") or {}).get("session_id")]
        sids += [s.get("session_id") for s in item.get("sessions") or [] if isinstance(s, dict)]
        if session_id in sids:
            found.append(item_id)
    return found


def scope(session_id, env):
    if not isinstance(session_id, str) or not session_id:
        return None
    driven = programme_home.driven_runs(session_id)
    found = (driven[0]["run"], driven[0]["record"]) if driven else _space_run(session_id, env)
    if found is None:
        return None
    run_id, record = found
    programme = record.get("programme")
    if not isinstance(programme, dict) or programme.get("ended"):
        return None
    item_ids = _item_ids(programme, session_id)
    return (run_id, programme, item_ids) if driven or item_ids else None


def _resolved(path: str, cwd: str) -> str:
    path = os.path.expanduser(path)
    return os.path.realpath(path if os.path.isabs(path) else os.path.join(cwd, path))


def _target(tool_name, tool_input, cwd, destinations):
    guarded = {os.path.realpath(os.path.join(d, SETTINGS_FILE)) for d in destinations}
    if tool_name != "Bash":
        path = tool_input.get("file_path")
        hit = _resolved(path, cwd) if isinstance(path, str) else None
        return hit if hit in guarded else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = _HIDING_CHARS.sub("", command)
    tokens = _TOKEN.findall(text)
    for token in tokens:
        if _resolved(token, cwd) in guarded:
            return _resolved(token, cwd)
    # A relative name after a cd elsewhere resolves against the wrong folder; best effort.
    if any(not os.path.isabs(os.path.expanduser(t)) for t in tokens):
        for dest in destinations:
            if dest in text or os.path.realpath(dest) in text:
                return os.path.realpath(os.path.join(dest, SETTINGS_FILE))
    return None


def denial(stdin_raw: str) -> dict | None:
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in _TOOLS:
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if "settings.local.json" not in json.dumps(tool_input):
        return None
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    found = scope(session_id, os.environ)
    if found is None:
        return None
    run_id, programme, item_ids = found
    destinations = [p.get("destination") for p in programme.get("permission_proposals") or []
                    if isinstance(p, dict) and isinstance(p.get("destination"), str)
                    and os.path.isabs(p["destination"])]
    if not destinations:
        return None
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    target = _target(tool_name, tool_input, cwd, destinations)
    if target is None:
        return None
    try:
        payload = {"tool": tool_name, "path": target, "item_ids": item_ids}
        if tool_name == "Bash":
            payload["command"] = programme_journal.redact(tool_input.get("command"))[:rules.COMMAND_CAP]
        programme_journal.append(run_id, "blocked_settings_write", session_id, payload)
    except Exception:
        pass
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"auto: this call names {target}, the settings file a permission proposal of "
            f"programme {run_id!r} targets. Only Shawn applies permission rules; report the "
            "block through the programme instead. This attempt is journaled."),
    }}

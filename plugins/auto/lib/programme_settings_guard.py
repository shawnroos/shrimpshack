#!/usr/bin/env python3
"""Refuse the PM's write to a settings file a permission proposal targets.

Best effort: the driving session is refused Write, Edit, MultiEdit or Bash calls that name
that settings.local.json. Only `answer-permission <id> allow` writes it, after Shawn's pick;
workers are not checked. While the programme's record cannot be read, the driver is refused any
.claude/settings.local.json: which one a proposal targets cannot be known.
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
rules = load_lib_module("programme_permission_rules")

SETTINGS_FILE = rules.DESTINATION_FILE
_TOOLS = ("Bash", "Write", "Edit", "MultiEdit")
_TOKEN = re.compile(r"[^\s;&|<>()`]*\.claude/settings\.local\.json(?![\w.-])", re.IGNORECASE)
_HIDING_CHARS = re.compile(r"[\"'\\\\]")
_ONLY_THE_VERB = "Only `programme.sh answer-permission <perm-id> allow` writes this file, after Shawn's pick."


def _held_read(lease):
    """(run_id, record) for a lease that holds its space; record None when it cannot be read."""
    if not lease or lease.get("corrupt") or not isinstance(lease.get("run"), str):
        return None
    status, read = programme_home.lease_state(lease)
    if status not in programme_home.HELD_LEASE_STATES:
        return None
    record, _ = read or programme_home.read_programme(lease["run"])
    return lease["run"], record if isinstance(record, dict) else None


def scope(session_id):
    """(run_id, programme), or (run_id, None) when the run's record cannot be read; None when this session drives nothing."""
    if not isinstance(session_id, str) or not session_id:
        return None
    unreadable = [r for r in map(_held_read, programme_home.leases_for_session(session_id))
                  if r is not None and r[1] is None]
    if unreadable:
        return unreadable[0][0], None
    driven = [d for d in programme_home.driven_runs(session_id) if isinstance(d.get("record"), dict)]
    if not driven:
        return None
    programme = driven[0]["record"].get("programme")
    return None if not isinstance(programme, dict) or programme.get("ended") else (driven[0]["run"], programme)


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

    def hit(path, raw):
        if destinations is not None:
            return path.casefold() in guarded
        # A symlinked .claude folder resolves to a path without the settings name; check the name as written too.
        written = os.path.normpath(os.path.join(cwd, _expanded(raw)))
        return _any_settings_file(path) or _any_settings_file(written)

    if tool_name != "Bash":
        raw = tool_input.get("file_path")
        path = _resolved(raw, cwd) if isinstance(raw, str) else None
        return path if path and hit(path, raw) else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = _HIDING_CHARS.sub("", command)
    tokens = _TOKEN.findall(text)
    for token in tokens:
        if hit(_resolved(token, cwd), token):
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
    found = scope(session_id)
    if found is None:
        return None
    run_id, programme = found
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
            f"right now, so no settings file can be cleared. {_ONLY_THE_VERB} "
            "Retry once the programme is readable, or continue the work that does not need this."), None
    payload = {"tool": tool_name, "path": target}
    if tool_name == "Bash":
        payload["command"] = tool_input.get("command")
    return _deny(
        f"auto: this call names {target}, the settings file a permission proposal of "
        f"programme {run_id!r} targets. {_ONLY_THE_VERB} Offer that answer and wait for his pick, or continue the "
        "work that does not need this. The attempt is journaled once the programme is free."), \
        (run_id, "blocked_settings_write", session_id, payload)


def _deny(reason: str) -> dict:
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}

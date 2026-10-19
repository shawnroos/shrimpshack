#!/usr/bin/env python3
"""PermissionDenied, PostToolUse and PostToolUseFailure: journal permission records.

Each auto-mode denial, and each gh run while a permission proposal is unresolved,
is journaled for a programme's driving session and for the owners and listed
sessions of its unfinished items. Prints nothing and always exits 0.
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
programme_sanitize = load_lib_module("programme_sanitize")
session_registry = load_lib_module("session_registry")

DENIED_EVENT = "PermissionDenied"
POST_TOOL_EVENTS = ("PostToolUse", "PostToolUseFailure")
REASON_CAP = 300
COMMAND_CAP = 2000
FIELD_CAP = 200

_GH = re.compile(r"(?:^|[^\w.-])gh(?=\s|$)")
_CLASSIFIER_TAG = re.compile(r"^\s*\[[^\]\n]+\]")
# U7 observed no PermissionDenied payload; these phrases are the documented reasons.
_LAYER_PHRASES = (
    ("auto mode could not evaluate this action", "classifier_no_verdict"),
    ("classifier unavailable", "classifier_unavailable"),
)


def layer_of(reason) -> str:
    text = reason.casefold() if isinstance(reason, str) else ""
    for phrase, layer in _LAYER_PHRASES:
        if phrase in text:
            return layer
    return "classifier" if _CLASSIFIER_TAG.match(text) else "unknown"


def runs_gh(command) -> bool:
    return isinstance(command, str) and _GH.search(command) is not None


def _driving_run(session_id):
    for lease in programme_home.leases_for_session(session_id):
        if programme_home.lease_status(lease) not in programme_home.HELD_LEASE_STATES:
            continue
        record = programme_home._read_record(lease.get("run"))
        if session_registry.caller_drives(record, session_id=session_id):
            return lease["run"], record
    return None


def _space_run(session_id, env):
    space = session_registry.space_of_session(session_id, env)
    if not space:
        return None
    try:
        lease = programme_home.read_lease(programme_home.lease_path(*space))
    except programme_home.ProgrammeHomeError:
        return None
    if not lease or lease.get("corrupt"):
        return None
    if programme_home.lease_status(lease) not in programme_home.HELD_LEASE_STATES:
        return None
    record = programme_home._read_record(lease.get("run"))
    return (lease["run"], record) if isinstance(record, dict) else None


def _working_items(programme, session_id) -> list:
    items = programme.get("items")
    found = []
    for item_id, item in sorted(items.items()) if isinstance(items, dict) else ():
        if not isinstance(item, dict) or item.get("state") in programme_home.FINISHED_ITEM_STATES:
            continue
        owner = item.get("owner") if isinstance(item.get("owner"), dict) else {}
        listed = [s.get("session_id") for s in item.get("sessions") or [] if isinstance(s, dict)]
        if owner.get("session_id") == session_id or session_id in listed:
            found.append(item_id)
    return found


def scope(session_id, env):
    if not isinstance(session_id, str) or not session_id:
        return None
    found = _driving_run(session_id)
    driving = found is not None
    found = found or _space_run(session_id, env)
    if found is None:
        return None
    run_id, record = found
    programme = record.get("programme")
    if not isinstance(programme, dict) or programme.get("ended"):
        return None
    item_ids = _working_items(programme, session_id)
    if not driving and not item_ids:
        return None
    return run_id, programme, item_ids


def proposals(programme) -> list:
    found = programme.get("permission_proposals")
    return [p for p in found if isinstance(p, dict)] if isinstance(found, list) else []


def _transcript(session_id) -> dict:
    row = session_registry.lookup(session_id, include_headless=True) or {}
    path = row.get("transcript_path")
    if not isinstance(path, str):
        return {"transcript_path": None, "transcript_bytes": None}
    try:
        size = os.path.getsize(path)
    except OSError:
        size = None
    return {"transcript_path": path, "transcript_bytes": size}


def _field(value):
    return programme_sanitize.clean(value, FIELD_CAP) or None if isinstance(value, str) else None


def handle(raw: str, env) -> None:
    data = json.loads(raw) if raw else None
    if not isinstance(data, dict):
        return
    event = data.get("hook_event_name")
    if event != DENIED_EVENT and event not in POST_TOOL_EVENTS:
        return
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    command = tool_input.get("command") if data.get("tool_name") == "Bash" else None
    command = command if isinstance(command, str) else ""
    if event in POST_TOOL_EVENTS and not runs_gh(command):
        return
    session_id = data.get("session_id")
    found = scope(session_id, env)
    if found is None:
        return
    run_id, programme, item_ids = found
    if event == DENIED_EVENT:
        kind = "permission_denied"
    elif any(p.get("state") != "resolved" for p in proposals(programme)):
        kind = "permission_tool_ran"
    else:
        return
    # Built from named fields only: tool_response and error carry command output.
    payload = {"event": event, "tool": _field(data.get("tool_name")),
               "tool_use_id": _field(data.get("tool_use_id")), "item_ids": item_ids}
    payload.update(_transcript(session_id))
    if command:
        payload["command"] = programme_journal.redact(command)[:COMMAND_CAP]
    if kind == "permission_denied":
        reason = data.get("reason") if isinstance(data.get("reason"), str) else ""
        payload["reason"] = programme_sanitize.clean(programme_journal.redact(reason), REASON_CAP)
        payload["layer"] = layer_of(reason)
    programme_journal.append(run_id, kind, session_id, payload)


def _cli() -> int:
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        handle(raw, os.environ)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

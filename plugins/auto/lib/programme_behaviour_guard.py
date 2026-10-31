#!/usr/bin/env python3
"""Refuse a programme session's direct write to the personal behaviours folder or behaviours.json.

Best effort, in the same scope as the settings guard: the driving session and the sessions
of unfinished items are refused Write, Edit, MultiEdit or Bash calls that name either target.
The sanctioned way to change them is a programme.py verb that Shawn approves.
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

settings_guard = load_lib_module("programme_settings_guard")
programme_behaviours = load_lib_module("programme_behaviours")
programme_protocol = load_lib_module("programme_protocol")

DIR_ENV = "CLAUDE_AUTO_BEHAVIOURS_DIR"
_TOOLS = ("Bash", "Write", "Edit", "MultiEdit")
_TOKEN = re.compile(r"[^\s;&|<>()`]*behaviours[^\s;&|<>()`]*", re.IGNORECASE)


def _folder() -> str:
    return os.environ.get(DIR_ENV) or os.path.join(
        os.path.dirname(programme_protocol.personal_path()), "behaviours")


def _guard() -> tuple:
    # Casefolded: the macOS file system is case-insensitive, so Behaviours/ is the same folder.
    return (os.path.realpath(_folder()).casefold(),
            os.path.realpath(programme_behaviours.store_path()).casefold())


def _hit(path: str, folder: str, store: str) -> bool:
    folded = path.casefold()
    return folded == store or folded == folder or folded.startswith(folder + os.sep)


def _target(tool_name, tool_input, cwd):
    folder, store = _guard()
    if tool_name != "Bash":
        raw = tool_input.get("file_path")
        path = settings_guard._resolved(raw, cwd) if isinstance(raw, str) else None
        return path if path and _hit(path, folder, store) else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = settings_guard._HIDING_CHARS.sub("", command)
    for token in _TOKEN.findall(text):
        bases = [cwd]
        if not os.path.isabs(settings_guard._expanded(token)):
            # A relative name after a cd elsewhere resolves against the wrong folder; best effort.
            bases += [os.path.dirname(folder), os.path.dirname(store)]
        for base in bases:
            path = settings_guard._resolved(token, base)
            if _hit(path, folder, store):
                return path
    return None


def decision(stdin_raw: str):
    """(deny, journal_row) or None. The caller emits the deny before it journals the row."""
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in _TOOLS:
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if "behaviours" not in json.dumps(tool_input).casefold():
        return None
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    found = settings_guard.scope(session_id, os.environ)
    if found is None:
        return None
    run_id, _programme, item_ids = found
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    target = _target(tool_name, tool_input, cwd)
    if target is None:
        return None
    payload = {"tool": tool_name, "path": target, "item_ids": item_ids}
    if tool_name == "Bash":
        payload["command"] = tool_input.get("command")
    return settings_guard._deny(
        f"auto: this call names {target}, a behaviours file of the personal protocol. "
        "Only Shawn changes behaviours; use the programme verbs that ask him to approve, "
        "and continue the work that does not need this. The attempt is journaled once "
        "the programme is free."), (run_id, "blocked_behaviours_write", session_id, payload)

#!/usr/bin/env python3
"""Refuse the PM's direct write to the personal behaviours folder or behaviours.json.

Best effort, in the same scope as the settings guard: the driving session is refused Write,
Edit, MultiEdit or Bash calls that name either target; workers are not checked. The PM's way
to change them is a programme.py verb that Shawn approves.
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

_TOOLS = ("Bash", "Write", "Edit", "MultiEdit")
_TOKEN = re.compile(r"[^\s;&|<>()`]*(?:behaviours|behaviour-files)[^\s;&|<>()`]*", re.IGNORECASE)
_ENV_REDIRECT = re.compile(r"CLAUDE_AUTO_(?:SHIPPED_)?BEHAVIOURS_(?:DIR|STORE)", re.IGNORECASE)
# A separator-free blob this long is not a command Shawn's session typed; bounding it keeps the
# token regex from stalling every PreToolUse call.
_MAX_COMMAND = 20000


def _guard() -> tuple:
    # Loaded here, not at the top: the hook loads this module on every PreToolUse call, and
    # programme_behaviours pulls in many modules that only a "behaviours" call needs.
    programme_behaviours = load_lib_module("programme_behaviours")
    programme_behaviour_files = load_lib_module("programme_behaviour_files")
    programme_home = load_lib_module("programme_home")
    # Casefolded: the macOS file system is case-insensitive, so Behaviours/ is the same folder.
    files = {os.path.realpath(programme_behaviours.store_path()).casefold(),
             os.path.realpath(programme_behaviour_files.seen_path()).casefold(),
             os.path.realpath(os.path.join(programme_home.programmes_dir(),
                                           programme_behaviour_files.LOCK_NAME)).casefold()}
    return os.path.realpath(programme_behaviour_files.personal_dir()).casefold(), files


def _hit(path: str, folder: str, files) -> bool:
    folded = path.casefold()
    return folded in files or folded == folder or folded.startswith(folder + os.sep)


def _examined(command: str) -> str:
    if len(command) <= _MAX_COMMAND:
        return command
    # Head and tail, so padding in front of the target cannot push it out of view.
    return command[:_MAX_COMMAND] + " " + command[-_MAX_COMMAND:]


def _target(tool_name, tool_input, cwd):
    folder, files = _guard()
    if tool_name != "Bash":
        raw = tool_input.get("file_path")
        path = settings_guard._resolved(raw, cwd) if isinstance(raw, str) else None
        return path if path and _hit(path, folder, files) else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = _examined(settings_guard._HIDING_CHARS.sub("", command))
    # Setting these redirects what counts as Shawn's files, so naming one is refused outright.
    redirect = _ENV_REDIRECT.search(text)
    if redirect:
        return redirect.group(0)
    for token in _TOKEN.findall(text):
        bases = [cwd]
        # A bare word such as `grep -rn behaviours lib` names no file; only a path or a dotted
        # name is worth resolving against the folders a cd could have left behind.
        if (os.sep in token or "." in token) and not os.path.isabs(settings_guard._expanded(token)):
            bases += [os.path.dirname(folder), *(os.path.dirname(f) for f in files)]
        for base in bases:
            path = settings_guard._resolved(token, base)
            if _hit(path, folder, files):
                return path
    return None


def decision(stdin_raw: str):
    """(deny, journal_row) or None. The caller emits the deny before it journals the row."""
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in _TOOLS:
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    named = json.dumps(tool_input).casefold()
    if "behaviours" not in named and "behaviour-files" not in named:
        return None
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    found = settings_guard.scope(session_id)
    if found is None:
        return None
    run_id, _programme = found
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    target = _target(tool_name, tool_input, cwd)
    if target is None:
        return None
    payload = {"tool": tool_name, "path": target}
    if tool_name == "Bash":
        payload["command"] = tool_input.get("command")
    return settings_guard._deny(
        f"auto: this call names {target}, a behaviours file of the personal protocol. "
        "Only Shawn changes behaviours; use the programme verbs that ask him to approve, "
        "and continue the work that does not need this. The attempt is journaled once "
        "the programme is free."), (run_id, "blocked_behaviours_write", session_id, payload)

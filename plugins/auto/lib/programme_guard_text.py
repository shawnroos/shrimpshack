#!/usr/bin/env python3
"""What the PreToolUse guards share: reading a path or a command the way the shell would, and the deny."""

from __future__ import annotations

import os
import re

HIDING_CHARS = re.compile(r"[\"'\\\\]")
# A separator-free blob this long is not a command Shawn's session typed; bounding it keeps a
# guard's regex from stalling every PreToolUse call.
MAX_COMMAND = 20000


def expanded(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path))


def resolved(path: str, cwd: str) -> str:
    path = expanded(path)
    return os.path.realpath(path if os.path.isabs(path) else os.path.join(cwd, path))


def examined(command: str) -> str:
    if len(command) <= MAX_COMMAND:
        return command
    # Head and tail, so padding in front of the target cannot push it out of view.
    return command[:MAX_COMMAND] + " " + command[-MAX_COMMAND:]


def deny(reason: str) -> dict:
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}

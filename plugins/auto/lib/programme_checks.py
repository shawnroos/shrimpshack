#!/usr/bin/env python3
"""``record-hook-patch``: the PM's record that it changed hook code, and the notice that tells Shawn."""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_record = load_lib_module("programme_record")
programme_sanitize = load_lib_module("programme_sanitize")

PATCHED = "hook_patched"
WHY_CAP = 300
FILE_CAP = 400
PR_CAP = 300

_PICKER = "Auto writing the picker's text from the command"
_PICK = "approvals that need a pick"
_PREFILL = "the pre-filled answer refusal"
_LINEAR = "the Linear done, cancelled and root-cause rule"

# Keyed by file name without extension, so a hook's .py and its .claude/hooks wrapper .sh count as one.
# A new file that implements one of these rules must be added here, or its patch notice stays silent.
PROTECTED = {
    "programme_approval": (_PICKER, _PICK),
    "programme_pick_source": (_PICKER, _PICK),
    "on-posttooluse-askuser": (_PICKER, _PICK),
    "on-pretooluse-askuser": (_PREFILL,),
    "on-pretooluse-action": (_LINEAR,),
    "programme_evidence": (_LINEAR,),
    "hooks": (_PICKER, _PICK, _PREFILL, _LINEAR),
}


def _protects(path) -> list:
    return list(PROTECTED.get(os.path.splitext(os.path.basename(path))[0], ()))


def _notice(path, why, pr, protects) -> str:
    held = f" It holds {', '.join(protects)}." if protects else ""
    return f"The PM patched {os.path.basename(path)}: {why}. PR: {pr}.{held}"


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "why", "pr"))
    path = programme_sanitize.clean(positional[0], FILE_CAP) if len(positional) == 1 else ""
    why = programme_sanitize.clean(opts.get("why") or "", WHY_CAP)
    pr = programme_sanitize.clean(opts.get("pr") or "", PR_CAP)
    if not (path and why and pr):
        raise ValueError("usage: record-hook-patch <file> --why <line> --pr <url or number> [--run <id>]")
    protects = _protects(path)

    def change(_programme, _prompt, _rec):
        return {"file": path, "why": why, "pr": pr, "protects": protects,
                "text": _notice(path, why, pr, protects)}

    def notify(payload):
        return {"notified": programme_record.notify_host("auto: hook code patched", payload["text"])}

    return host._write(opts, change, PATCHED, verb="record-hook-patch", target=path, after=notify)


_SPECS = (
    ("record-hook-patch", _h_record, "<file> --why <line> --pr <url or number> [--run <id>]",
     "a session that does not drive the programme; a missing file, --why or --pr. Journals hook_patched with the "
     "file, the why, the PR and the protected rules the file holds, sends Shawn the notice through the terminal "
     "host, and prints it as text for the PM to post. It needs no prompt, because it records what the PM did and "
     "approves nothing."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

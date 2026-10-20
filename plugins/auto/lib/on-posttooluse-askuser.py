#!/usr/bin/env python3
"""PostToolUse AskUserQuestion: journal a picker answer given in a programme's driving session.

The row is stored with origin unknown and a pick source record; it reads as picked only
after programme_pick_source verifies the transcript. Always exits 0.
"""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_pick_source = load_lib_module("programme_pick_source")
on_user_prompt = load_lib_module("on-user-prompt")

DATA_TAG = on_user_prompt.DATA_TAG


def handle(raw: str) -> dict | None:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict) or data.get("tool_name") != programme_pick_source.TOOL:
        return None
    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    run, _record, _lease, _held = on_user_prompt._driving_run(session_id)
    if not run:
        return None
    source = programme_pick_source.capture(data)
    if source is None:
        return None
    answers = data["tool_response"]["answers"]
    entry = programme_journal.append_prompt(run, session_id, programme_pick_source.summary(answers),
                                            "unknown", source=source)
    payload = {"run": run, "prompt_id": entry["prompt_id"], "kind": "pick", "answers": source["answers"]}
    text = ("auto journaled this picker answer. Cite its prompt_id in setup verbs that take a pick; "
            "it counts only once the transcript shows Shawn picked it.\n" + json.dumps(payload, sort_keys=True))
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                   "additionalContext": f"<{DATA_TAG}>\n{text}\n</{DATA_TAG}>"}}


def _cli() -> int:
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        out = handle(raw)
    except Exception:
        out = None
    if out is not None:
        sys.stdout.write(json.dumps(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

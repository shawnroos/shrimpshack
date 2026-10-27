#!/usr/bin/env python3
"""PostToolUse AskUserQuestion: journal a picker answer given in a programme's driving session,
or in any session of a herdr space a programme leases.

The row is stored with origin unknown and a pick source record; it reads as picked only
after programme_pick_source verifies the transcript. A row from a session that does not
drive carries driving false and serves only a takeover. Always exits 0.
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


_DRIVING_NOTE = ("auto journaled this picker answer. Cite its prompt_id with --pick in setup verbs, or with "
                 "--prompt in an approval verb on the pick list when the answer is that command's "
                 "`approval-label`; it counts only once the transcript shows Shawn picked it.")
_TAKEOVER_NOTE = ("auto journaled this picker answer against the programme leased in this session's herdr "
                  "space. This session does not drive it, so the pick can serve only a takeover; no other "
                  "approval or setup verb accepts it, even after this session takes over. It counts only once "
                  "the transcript shows Shawn picked it.")


def handle(raw: str, env=None) -> dict | None:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict) or data.get("tool_name") != programme_pick_source.TOOL:
        return None
    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    run, _record, _lease, held = on_user_prompt._driving_run(session_id)
    if held is not None:
        return None
    driving = run is not None
    if not driving:
        lease, _status = on_user_prompt.request_lease(session_id, env if env is not None else os.environ)
        run = lease and lease.get("run")
    if not run:
        return None
    source = programme_pick_source.capture(data)
    if source is None:
        return None
    answers = data["tool_response"]["answers"]
    entry = programme_journal.append_prompt(run, session_id, programme_pick_source.summary(answers),
                                            "unknown", source=source, driving=driving)
    payload = {"run": run, "prompt_id": entry["prompt_id"], "kind": "pick", "answers": source["answers"]}
    text = (_DRIVING_NOTE if driving else _TAKEOVER_NOTE) + "\n" + json.dumps(payload, sort_keys=True)
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                   "additionalContext": f"<{DATA_TAG}>\n{text}\n</{DATA_TAG}>"}}


def _cli() -> int:
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        out = handle(raw, os.environ)
    except Exception:
        out = None
    if out is not None:
        sys.stdout.write(json.dumps(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

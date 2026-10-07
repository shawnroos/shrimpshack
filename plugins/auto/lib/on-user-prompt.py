#!/usr/bin/env python3
"""UserPromptSubmit: journal prompts typed into a programme's driving session.

A request typed in a driving session is journaled into the run it drives, citing
the prompt. Takeover, handover and end requests from any other session go into
the home of the lease for that session's herdr space. Always exits 0.
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

DATA_TAG = "auto-data"
_REQUEST = re.compile(r"^\s*/auto:programme-(takeover|handover|end)(?=\s|$)")


def _normalised(text) -> str:
    return " ".join(text.split()) if isinstance(text, str) else ""


def classify_origin(text: str, record: dict) -> str:
    watchers = ((record or {}).get("programme") or {}).get("watchers") or {}
    wanted = _normalised(text)
    for watcher in watchers.values() if isinstance(watchers, dict) else ():
        prompt = watcher.get("prompt") if isinstance(watcher, dict) else None
        if wanted and _normalised(prompt) == wanted:
            return "cron"
    return "typed"


def _driving_run(session_id):
    for lease in programme_home.leases_for_session(session_id):
        if programme_home.lease_status(lease) not in programme_home.HELD_LEASE_STATES:
            continue
        record = programme_home._read_record(lease.get("run"))
        if session_registry.caller_drives(record, session_id=session_id):
            return lease["run"], record, lease
    return None, None, None


def _space_lease(session_id, env):
    space = session_registry.space_of_session(session_id, env)
    if not space:
        return None
    try:
        lease = programme_home.read_lease(programme_home.lease_path(*space))
    except programme_home.ProgrammeHomeError:
        return None
    if not lease or lease.get("corrupt"):
        return None
    return lease


def _journal_request(verb, session_id, text, env, origin, prompt_id, driving_lease):
    lease = driving_lease or _space_lease(session_id, env)
    if lease is None:
        return
    status = programme_home.lease_status(lease)
    if status not in programme_home.HELD_LEASE_STATES:
        return
    driving = driving_lease is not None
    programme_journal.append(
        lease["run"], f"{verb}_request", session_id,
        {"verb": verb, "text": programme_journal.redact(text), "origin": origin,
         "space": programme_home.space_key(lease.get("server"), lease.get("workspace")),
         "lease_status": status, "driving": driving},
        cites=[prompt_id] if driving and prompt_id else None,
    )


def handle(raw: str, env) -> dict | None:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict):
        return None
    session_id = data.get("session_id")
    text = data.get("prompt")
    if not isinstance(session_id, str) or not session_id or not isinstance(text, str):
        return None
    run, record, driving_lease = _driving_run(session_id)
    entry = None
    origin = "typed"
    if run:
        origin = classify_origin(text, record)
        entry = programme_journal.append_prompt(run, session_id, text, origin)
    request = _REQUEST.match(text)
    if request:
        try:
            _journal_request(request.group(1), session_id, text, env, origin,
                             entry and entry["prompt_id"], driving_lease)
        except Exception:
            pass
    if not entry:
        return None
    payload = {"run": run, "prompt_id": entry["prompt_id"], "origin": origin}
    context = (
        f"<{DATA_TAG}>\n"
        "auto journaled this prompt. Cite its prompt_id in programme approval verbs.\n"
        f"{json.dumps(payload, sort_keys=True)}\n"
        f"</{DATA_TAG}>"
    )
    return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                   "additionalContext": context}}


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

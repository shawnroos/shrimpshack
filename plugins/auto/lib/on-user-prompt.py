#!/usr/bin/env python3
"""UserPromptSubmit: journal prompts typed into a programme's driving session.

A request typed in a driving session is journaled into the run it drives, citing
the prompt. Takeover, handover and end requests from any other session go into
the home of the lease for that session's herdr space. A prompt in another session
of a space whose PM stopped (lease orphaned, or driver gone) is journaled with
driving false, so it can serve only as Shawn's ask for a takeover. Always exits 0.
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
programme_prompt_source = load_lib_module("programme_prompt_source")

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
    return "unknown"


def _driving_run(session_id):
    held = None
    for lease in programme_home.leases_for_session(session_id):
        status, read = programme_home.lease_state(lease)
        if status not in programme_home.HELD_LEASE_STATES:
            continue
        record, hold = read or programme_home.read_programme(lease.get("run"))
        if hold is not None:
            held = held or dict(hold, run=lease.get("run"))
            continue
        if session_registry.caller_drives(record, session_id=session_id):
            return lease["run"], record, lease, None
    return None, None, None, held


def _closing_runs(session_id) -> list:
    # After end the leases are gone, but the driving session (or the one that ended it) still
    # types the approvals its closure needs; a sealed archive takes nothing.
    found = []
    for run in programme_home.closing_runs(session_id):
        record, hold = programme_home.read_programme(run)
        programme = (record or {}).get("programme") or {}
        if hold is not None or not programme.get("ended") or programme_home.sealed(programme):
            continue
        if session_id in (record.get("driving_session_id"), (programme.get(programme_home.CLOSURE) or {}).get("ended_by")):
            found.append((run, record))
    return found


def _closing_context(session_id, text, closing, notes, source) -> dict | None:
    journaled = []
    for run, record in closing:
        origin = classify_origin(text, record)
        entry = programme_journal.append_prompt(run, session_id, text, origin, source=source)
        journaled.append({"run": run, "prompt_id": entry["prompt_id"], "origin": origin})
    return _context(
        "auto journaled this prompt into each ended programme this session is closing. Cite the "
        "prompt_id for that run in its closure verbs.\n"
        f"{json.dumps(journaled, sort_keys=True)}" + "".join(f"\n{note}" for note in notes))


def _held_context(held) -> dict:
    return _context(
        f"auto did not journal this prompt: programme {held['run']}'s authority is "
        f"{held['outcome']} ({held['detail']}). Nothing typed here can approve a change "
        "until it is repaired.")


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


def request_lease(session_id, env, driving_lease=None, replace=None):
    lease = driving_lease or programme_home.lease_driven_by(replace) or _space_lease(session_id, env)
    if lease is None:
        return None, None
    status = programme_home.lease_status(lease)
    if status not in programme_home.HELD_LEASE_STATES:
        return None, None
    return lease, status


def _ask_to_replace(session_id, text, env, source) -> dict | None:
    # Only a stopped PM's space journals another session's prompts: a live PM's lease never collects them.
    lease, status = request_lease(session_id, env)
    if status == "live":
        presence = load_lib_module("programme_lifecycle")._presence(lease, lease["run"])
        if presence.get("state") != "gone":
            return None
    elif status != "orphaned":
        return None
    run = lease["run"]
    record, hold = programme_home.read_programme(run)
    if hold is not None:
        return None
    origin = classify_origin(text, record)
    entry = programme_journal.append_prompt(run, session_id, text, origin, source=source, driving=False)
    return {"run": run, "prompt_id": entry["prompt_id"], "origin": origin, "lease_status": status}


def _journal_request(verb, session_id, text, env, origin, prompt_id, driving_lease, source):
    replace = programme_home.replace_name(text) if verb == "takeover" else None
    lease, status = request_lease(session_id, env, driving_lease, replace)
    if lease is None:
        return
    driving = driving_lease is not None
    programme_journal.append(
        lease["run"], f"{verb}_request", session_id,
        {"verb": verb, "text": programme_journal.redact(text), "origin": origin,
         "space": programme_home.space_key(lease.get("server"), lease.get("workspace")),
         "lease_status": status, "driving": driving, "source": source},
        cites=[prompt_id] if driving and prompt_id else None,
    )
    return lease["run"]


def handle(raw: str, env) -> dict | None:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict):
        return None
    session_id = data.get("session_id")
    text = data.get("prompt")
    if not isinstance(session_id, str) or not session_id or not isinstance(text, str):
        return None
    source = programme_prompt_source.capture(data)
    run, record, driving_lease, held = _driving_run(session_id)
    if held is not None:
        return _held_context(held)
    closing = _closing_runs(session_id) if run is None else []
    entry = None
    origin = "unknown"
    if run:
        origin = classify_origin(text, record)
        entry = programme_journal.append_prompt(run, session_id, text, origin, source=source)
    request = _REQUEST.match(text)
    lost = None
    received = None
    if request:
        try:
            received = _journal_request(request.group(1), session_id, text, env, origin,
                                        entry and entry["prompt_id"], driving_lease, source)
        except Exception as exc:
            lost = _lost_request(request.group(1), exc)
    if closing:
        notes = [lost] if lost else []
        if received:
            notes.append(f"auto journaled this /auto:programme-{request.group(1)} request into programme "
                         f"{received}, the programme leased in this session's space.")
        return _closing_context(session_id, text, closing, notes, source)
    if not entry:
        asked = None if lost else _ask_to_replace(session_id, text, env, source)
        if asked:
            return _context(
                "auto journaled this prompt as a possible ask from Shawn to replace the stopped PM of the "
                "programme leased in this session's space. It serves only `programme.sh takeover --prompt "
                "<prompt_id>`; if Shawn asked this session to be the PM, run `programme.sh become-pm` first.\n"
                f"{json.dumps(asked, sort_keys=True)}")
        return _context(lost) if lost else None
    payload = {"run": run, "prompt_id": entry["prompt_id"], "origin": origin}
    return _context(
        "auto journaled this prompt. Cite its prompt_id in programme approval verbs.\n"
        f"{json.dumps(payload, sort_keys=True)}" + (f"\n{lost}" if lost else ""))


def _lost_request(verb, exc) -> str:
    outcome = getattr(exc, "outcome", None)
    why = f"its authority is {outcome} ({getattr(exc, 'detail', None) or exc})" if outcome else str(exc)
    return (f"auto did not journal this /auto:programme-{verb} request: {why}. The {verb} verb will "
            "refuse without it, and nothing here changed the programme. Tell Shawn.")


def _context(text) -> dict:
    return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
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

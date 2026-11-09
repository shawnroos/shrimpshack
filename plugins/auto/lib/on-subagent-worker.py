#!/usr/bin/env python3
"""Record a PM's background sub-agent as a worker item, and hand the item back to the PM when it stops.

PostToolUse on Agent: when the session drives a programme and the agent went to the background, a description
of the form "<label> / <title>" names the item: `linear:<KEY>` when the label is an issue key, otherwise
`study:<slug>`. The hook records it with `add-item` and `set-waiting`. SubagentStop: an item still waiting on
that agent waits on the PM for review. Writes go through the verbs, never the store. Silent on success; a failed
verb is journaled as subagent_record_failed. Always exits 0.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_home = load_lib_module("programme_home")
on_user_prompt = load_lib_module("on-user-prompt")

PYTHON3 = os.environ.get("CLAUDE_AUTO_PYTHON3") or "/usr/bin/python3"
VERB_TIMEOUT_SECONDS = 8
SLUG_CAP = 60
TITLE_CAP = 200
KIND_BY_TYPE = {"coder": "flagged_code", "investigator": "fix_only", "tester": "fix_only", "planner": "fix_only"}
# The PM's own readers and packagers are dispatched as auto:* agents; they read, they are not workers.
SKIP_TYPE_PREFIX = "auto:"
_LABEL_TITLE = re.compile(r"^\s*(\S[^/]*?)\s+/\s+(\S.*)$", re.S)
# Same bounds as the Linear key check in on-pretooluse-action.py.
_ISSUE_KEY = re.compile(r"[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}")
_HAND_BACK = ("--who", "pm", "--reporter", "pm")


def _slug(text) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(slug) <= SLUG_CAP:
        return slug
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]
    return slug[:SLUG_CAP - 9].strip("-") + "-" + digest


def item_for(description):
    """(item id, title) for "<label> / <title>", or None for any other description."""
    shaped = _LABEL_TITLE.match(description or "")
    if not shaped:
        return None
    label, title = shaped.group(1).strip(), shaped.group(2).strip()
    if _ISSUE_KEY.fullmatch(label):
        return f"linear:{label}", title
    slug = _slug(description.strip())
    return (f"study:{slug}", title) if slug else None


def _worker_type(agent_type) -> str | None:
    agent_type = str(agent_type or "general-purpose")
    return None if agent_type.startswith(SKIP_TYPE_PREFIX) else agent_type.rsplit(":", 1)[-1]


def _items(record) -> dict:
    return ((record or {}).get("programme") or {}).get("items") or {}


def _exists(record, item_id) -> bool:
    items = _items(record)
    return item_id in items or any(item_id in (i.get("aliases") or []) for i in items.values() if isinstance(i, dict))


def _record(run, session_id, step, item_id, argv) -> bool:
    """Run one programme verb as the driving session; journal the failure. True on success."""
    env = dict(os.environ, CLAUDE_CODE_SESSION_ID=session_id)
    try:
        done = subprocess.run([PYTHON3, os.path.join(_LIB_DIR, "programme.py"), *argv, "--run", run],
                              env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=VERB_TIMEOUT_SECONDS, check=False)
        reason = None if done.returncode == 0 else \
            (done.stderr or done.stdout or f"exit {done.returncode}").strip()[-400:]
    except (OSError, subprocess.TimeoutExpired) as exc:
        reason = type(exc).__name__
    if reason is not None:
        _journal(run, session_id, "subagent_record_failed",
                 {"step": step, "item": item_id, "reason": programme_journal.redact(reason)})
    return reason is None


def _journal(run, session_id, kind, payload) -> None:
    # A journal failure has nowhere left to go; the hook must still exit quietly and finish its work.
    try:
        programme_journal.append(run, kind, session_id, payload)
    except Exception:  # noqa: BLE001
        pass


def _stopped(run, agent) -> bool:
    try:
        rows = programme_journal.read(run)
    except Exception:  # noqa: BLE001
        return False
    return any(r.get("kind") == "subagent_stopped" and (r.get("payload") or {}).get("agent") == agent for r in rows)


def on_start(data, run, record, session_id) -> None:
    tool_input, response = data.get("tool_input"), data.get("tool_response")
    if not (isinstance(tool_input, dict) and isinstance(response, dict)
            and response.get("status") == "async_launched"):
        return
    worker = _worker_type(tool_input.get("subagent_type"))
    found = item_for(tool_input.get("description"))
    if worker is None or found is None:
        return
    item_id, title = found
    agent = programme_sanitize.token(response.get("agentId")) if isinstance(response.get("agentId"), str) else None
    if agent is None:
        _journal(run, session_id, "subagent_record_failed",
                 {"step": "start", "item": item_id, "reason": "the Agent result carried no agentId"})
        return
    if not _exists(record, item_id):
        argv = ["add-item", item_id, "--title", programme_sanitize.clean(title, TITLE_CAP)]
        if worker in KIND_BY_TYPE:
            argv += ["--kind", KIND_BY_TYPE[worker]]
        if not _record(run, session_id, "add-item", item_id, argv):
            return
    who = programme_sanitize.token(worker) or "agent"
    if not _record(run, session_id, "set-waiting", item_id,
                   ["set-waiting", item_id, "--who", who, "--reporter", agent]):
        return
    # The two hooks run async, so a fast agent's stop can land first; on_stop journals before it reads the items.
    if _stopped(run, agent):
        _record(run, session_id, "review", item_id, ["set-waiting", item_id, *_HAND_BACK])


def on_stop(data, run, _record_at_start, session_id) -> None:
    agent = programme_sanitize.token(data.get("agent_id"))
    if not agent or _worker_type(data.get("agent_type")) is None:
        return
    # Journal before reading the items: a start that sets its wait after this read finds the row instead.
    _journal(run, session_id, "subagent_stopped", {"agent": agent})
    record, _hold = programme_home.read_programme(run)
    for key, item in sorted(_items(record).items()):
        if (isinstance(item, dict) and item.get("state") == "waiting"
                and (item.get("waiting_on") or {}).get("reporter") == agent):
            _record(run, session_id, "review", key, ["set-waiting", key, *_HAND_BACK])


def handle(raw: str) -> None:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict):
        return
    event, session_id = data.get("hook_event_name"), data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return
    if event == "PostToolUse":
        # A sub-agent's own Agent call carries agent_id; only the PM's starts are its workers.
        if data.get("agent_id") or data.get("tool_name") not in ("Agent", "Task"):
            return
        handler = on_start
    elif event == "SubagentStop":
        handler = on_stop
    else:
        return
    run, record, _lease, held = on_user_prompt._driving_run(session_id)
    if run is not None and held is None:
        handler(data, run, record, session_id)


def _cli() -> int:
    try:
        handle(sys.stdin.read() if not sys.stdin.isatty() else "")
    except Exception:  # noqa: BLE001 — rel-001: a hook failure must never reach the PM's session
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

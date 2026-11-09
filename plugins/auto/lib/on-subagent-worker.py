#!/usr/bin/env python3
"""Record a PM's background sub-agent as a worker item, and hand the item back to the PM when it stops.

PostToolUse on Agent: when the session drives a programme and the agent went to the background, find the item
from an issue key (or a "<label> / <title>" description) and record it with `add-item` and `set-waiting`.
SubagentStop: an item still waiting on that agent waits on the PM for review. Writes go through the verbs,
never the store. Silent on success; a failed verb is journaled as subagent_record_failed. Always exits 0.
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
_KEY = r"([A-Z][A-Z0-9]{1,9})-([0-9]+)"
_DESC_KEY = re.compile(rf"^\s*{_KEY}(?:\s*[/:|—–]\s*|\s+-\s+|\s+|$)(.*)$", re.S)
_PROMPT_KEY = re.compile(rf"^\s*(?i:ticket|issue)\s*[:#]?\s*{_KEY}(?![A-Za-z0-9-]|\.[A-Za-z0-9])")
_LABEL_TITLE = re.compile(r"^\s*([^/]+?)\s+/\s+(\S.*)$", re.S)


def _first_line(text) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line
    return ""


def _team_keys(record) -> set:
    tracker = (((record or {}).get("programme") or {}).get("remit") or {}).get("tracker") or {}
    return {t["key"] for t in tracker.get("teams") or [] if isinstance(t, dict) and isinstance(t.get("key"), str)}


def _key_ok(team, teams) -> bool:
    # With no teams in the remit any key shape counts, so a description like "UTF-8 parsing" needs a separator.
    return team in teams if teams else True


def _slug(text) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(slug) <= SLUG_CAP:
        return slug
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]
    return slug[:SLUG_CAP - 9].strip("-") + "-" + digest


def item_for(description, prompt, teams=frozenset()):
    """(item id, title) for an agent start, or None when it names no issue and has no label / title shape."""
    description = (description or "").strip()
    found = _DESC_KEY.match(description)
    if found and _key_ok(found.group(1), teams):
        separated = description[found.end(2):found.start(3)].strip() != "" or not found.group(3)
        if teams or separated:
            return f"linear:{found.group(1)}-{found.group(2)}", found.group(3).strip() or description
    found = _PROMPT_KEY.match(_first_line(prompt))
    if found and _key_ok(found.group(1), teams):
        return f"linear:{found.group(1)}-{found.group(2)}", description or None
    shaped = _LABEL_TITLE.match(description)
    if shaped:
        slug = _slug(description)
        if slug:
            return f"study:{slug}", shaped.group(2).strip()
    return None


def agent_id_of(response) -> str | None:
    if isinstance(response, dict):
        for key in ("agentId", "agent_id"):
            if isinstance(response.get(key), str):
                return programme_sanitize.token(response[key])
        return None
    text = response if isinstance(response, str) else json.dumps(response or "")
    found = re.search(r"agentId[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9_-]+)", text)
    return found.group(1) if found else None


def _backgrounded(tool_input, response) -> bool:
    if isinstance(response, dict) and response.get("status"):
        return response["status"] == "async_launched"
    return tool_input.get("run_in_background") is True


def _items(record) -> dict:
    return ((record or {}).get("programme") or {}).get("items") or {}


def _exists(record, item_id) -> bool:
    items = _items(record)
    return item_id in items or any(item_id in (i.get("aliases") or []) for i in items.values() if isinstance(i, dict))


def _verb(run, session_id, argv) -> tuple:
    env = dict(os.environ, CLAUDE_CODE_SESSION_ID=session_id)
    try:
        done = subprocess.run([PYTHON3, os.path.join(_LIB_DIR, "programme.py"), *argv, "--run", run],
                              env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=VERB_TIMEOUT_SECONDS, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, type(exc).__name__
    if done.returncode == 0:
        return True, None
    return False, (done.stderr or done.stdout or f"exit {done.returncode}").strip()[-400:]


def _failed(run, session_id, step, item_id, reason) -> None:
    # A journal failure here has nowhere left to go; the hook must still exit quietly.
    try:
        programme_journal.append(run, "subagent_record_failed", session_id,
                                 {"step": step, "item": item_id, "reason": programme_journal.redact(reason)})
    except Exception:
        pass


def on_start(data, run, record, session_id) -> list:
    tool_input = data.get("tool_input") or {}
    response = data.get("tool_response")
    if not isinstance(tool_input, dict) or not _backgrounded(tool_input, response):
        return []
    subagent_type = str(tool_input.get("subagent_type") or "general-purpose")
    if subagent_type.startswith(SKIP_TYPE_PREFIX):
        return []
    found = item_for(tool_input.get("description"), tool_input.get("prompt"), _team_keys(record))
    agent = agent_id_of(response)
    if found is None:
        return []
    item_id, title = found
    if agent is None:
        _failed(run, session_id, "start", item_id, "the Agent result carried no agent id")
        return [("start", item_id, False)]
    base_type = subagent_type.rsplit(":", 1)[-1]
    who = programme_sanitize.token(base_type) or "agent"
    steps = []
    if not _exists(record, item_id):
        argv = ["add-item", item_id]
        if title:
            argv += ["--title", programme_sanitize.clean(title, TITLE_CAP)]
        kind = KIND_BY_TYPE.get(base_type)
        if kind:
            argv += ["--kind", kind]
        ok, reason = _verb(run, session_id, argv)
        steps.append(("add-item", item_id, ok))
        if not ok:
            _failed(run, session_id, "add-item", item_id, reason)
            return steps
    ok, reason = _verb(run, session_id, ["set-waiting", item_id, "--who", who, "--reporter", agent])
    steps.append(("set-waiting", item_id, ok))
    if not ok:
        _failed(run, session_id, "set-waiting", item_id, reason)
        return steps
    # The two hooks run async, so a fast agent's stop can land first; on_stop journals before it reads the items.
    if _stopped(run, agent):
        ok, reason = _verb(run, session_id, ["set-waiting", item_id, "--who", "pm", "--reporter", "pm"])
        steps.append(("review", item_id, ok))
        if not ok:
            _failed(run, session_id, "review", item_id, reason)
    return steps


def _stopped(run, agent) -> bool:
    try:
        rows = programme_journal.read(run)
    except Exception:
        return False
    return any(r.get("kind") == "subagent_stopped" and (r.get("payload") or {}).get("agent") == agent for r in rows)


def on_stop(data, run, record, session_id) -> list:
    agent = programme_sanitize.token(data.get("agent_id"))
    if not agent:
        return []
    # Journal before reading the items: a start that sets its wait after this read finds the row instead.
    try:
        programme_journal.append(run, "subagent_stopped", session_id, {"agent": agent})
    except Exception:  # noqa: BLE001 — the hand-back below must still run; only the race recovery is lost
        pass
    record, _hold = programme_home.read_programme(run)
    steps = []
    for key, item in sorted(_items(record).items()):
        if not isinstance(item, dict) or item.get("state") != "waiting":
            continue
        if (item.get("waiting_on") or {}).get("reporter") != agent:
            continue
        ok, reason = _verb(run, session_id, ["set-waiting", key, "--who", "pm", "--reporter", "pm"])
        steps.append(("review", key, ok))
        if not ok:
            _failed(run, session_id, "review", key, reason)
    return steps


def handle(raw: str) -> list:
    data = json.loads(raw) if raw else {}
    if not isinstance(data, dict):
        return []
    event = data.get("hook_event_name")
    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return []
    if event == "PostToolUse":
        # A sub-agent's own Agent call carries agent_id; only the PM's starts are its workers.
        if data.get("agent_id") or data.get("tool_name") not in ("Agent", "Task"):
            return []
        handler = on_start
    elif event == "SubagentStop":
        handler = on_stop
    else:
        return []
    run, record, _lease, held = on_user_prompt._driving_run(session_id)
    if run is None or held is not None:
        return []
    return handler(data, run, record, session_id)


def _cli() -> int:
    try:
        handle(sys.stdin.read() if not sys.stdin.isatty() else "")
    except Exception:  # noqa: BLE001 — rel-001: a hook failure must never reach the PM's session
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli())

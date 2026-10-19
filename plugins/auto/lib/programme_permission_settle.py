#!/usr/bin/env python3
"""Verify an applied permission proposal, reserve one retry, and settle it from transcripts.

Settings files are only ever opened for reading. Settlement trusts the blocked
session's own transcript, found through the session registry, never a journal row alone.
"""

from __future__ import annotations

import functools
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_record = load_lib_module("programme_record")
programme_sanitize = load_lib_module("programme_sanitize")
programme_sources = load_lib_module("programme_sources")
rules = load_lib_module("programme_permission_rules")
state = load_lib_module("programme_permission_state")
transcript = load_lib_module("permission_transcript")
session_registry = load_lib_module("session_registry")

RecordError = programme_record.RecordError
USER_SETTINGS_ENV = "CLAUDE_AUTO_TEST_USER_SETTINGS"
SETTINGS_CAP = 1024 * 1024
WORKTREE_FILE = os.path.join(".claude", "settings.json")
WORST = ("covered", "not_covered", "blocked_elsewhere")
OUTCOME_STATE = {"covered": state.RETRYING, "not_covered": state.OPEN, "blocked_elsewhere": state.INEFFECTIVE}


def user_settings_path() -> str:
    override = os.environ.get(USER_SETTINGS_ENV)
    if override and os.environ.get("CLAUDE_AUTO_TEST_HARNESS") == "1":
        return override
    return os.path.join(os.path.expanduser("~"), ".claude", "settings.json")


def read_settings(path, label) -> dict:
    out = {"file": path, "label": label, "state": "read", "why": None,
           "allow": [], "ask": [], "deny": [], "classify_all_shell": False}
    try:
        with open(path, "rb") as fh:
            data = fh.read(SETTINGS_CAP + 1)
    except FileNotFoundError:
        out["state"] = "absent"
        return out
    except OSError as exc:
        return dict(out, state="unknown", why=type(exc).__name__)
    if len(data) > SETTINGS_CAP:
        return dict(out, state="unknown", why="larger than 1 MiB")
    try:
        doc = json.loads(data)
    except ValueError:
        return dict(out, state="unknown", why="not valid JSON")
    if not isinstance(doc, dict):
        return dict(out, state="unknown", why="not a JSON object")
    perms = doc.get("permissions") if isinstance(doc.get("permissions"), dict) else {}
    for layer in ("allow", "ask", "deny"):
        found = perms.get(layer)
        out[layer] = [r for r in found if isinstance(r, str)] if isinstance(found, list) else []
    auto = doc.get("autoMode") if isinstance(doc.get("autoMode"), dict) else {}
    out["classify_all_shell"] = auto.get("classifyAllShell") is True
    return out


def _registry(sid) -> dict:
    return session_registry.lookup(sid, include_headless=True) or {} if sid else {}


def _commands(proposal) -> list:
    seen, out = set(), []
    for entry in proposal.get("evidence") or []:
        key = (entry.get("session_id"), entry.get("command"))
        if isinstance(entry.get("command"), str) and key not in seen:
            seen.add(key)
            out.append({"command": entry["command"], "session_id": entry.get("session_id"),
                        "operations": entry.get("operations") or []})
    return out


def _layers(files) -> dict:
    return {k: [{"rule": r, "source": f["file"]} for f in files if f["state"] == "read" for r in f[k]]
            for k in ("allow", "ask", "deny")}


def verify(proposal) -> dict:
    user = read_settings(user_settings_path(), "user")
    local = read_settings(proposal.get("settings_file") or "", "local")
    files, notes, results = {user["file"]: user, local["file"]: local}, [], []
    for cmd in _commands(proposal):
        using = [user, local]
        cwd = _registry(cmd["session_id"]).get("cwd")
        if isinstance(cwd, str) and os.path.isabs(cwd):
            path = os.path.join(cwd, WORKTREE_FILE)
            if path not in files:
                files[path] = read_settings(path, "worktree")
            using.append(files[path])
        else:
            notes.append(f"worktree settings for session {cmd['session_id']} not read: the registry has no cwd")
        layers = _layers(using)
        cov = rules.coverage(cmd["command"], layers["allow"], layers["ask"], layers["deny"],
                             classify_all_shell=user["classify_all_shell"])
        source = user["file"] if cov["rule"] == "autoMode.classifyAllShell" else cov["source"]
        results.append(dict(cmd, outcome=cov["outcome"], rule=cov["rule"], source=source,
                            layer=cov["layer"], note=cov["note"]))
    outcome = max((r["outcome"] for r in results), key=WORST.index, default="not_covered")
    return {"outcome": outcome, "commands": results, "notes": list(dict.fromkeys(notes)),
            "files": [{k: f[k] for k in ("file", "label", "state", "why")} for f in files.values()],
            "uncovered": sorted({op for r in results if r["outcome"] == "not_covered" for op in r["operations"]}),
            "reach": [r["note"] for r in results if r["outcome"] == "covered" and r["note"]],
            "unseen": rules.UNSEEN}


def explain(check) -> str:
    worst = next((r for r in check["commands"] if r["outcome"] == check["outcome"]), None)
    if check["outcome"] == "blocked_elsewhere" and worst:
        text = f"still blocked: {worst['layer']} {worst['rule']} in {worst['source'] or 'user settings'}"
    elif check["outcome"] == "covered" and worst:
        text = f"covered by {worst['rule']} in {worst['source']}" + "".join(f"; {r}" for r in check["reach"])
    else:
        text = f"not covered yet: no allow rule for {', '.join(check['uncovered']) or 'the blocked command'}"
    read = [f["file"] for f in check["files"] if f["state"] != "unknown"]
    unknown = [f"{f['file']} ({f['why']})" for f in check["files"] if f["state"] == "unknown"]
    text += f". Read: {', '.join(read)}."
    if unknown:
        text += f" unknown, could not read: {', '.join(unknown)}."
    for note in check["notes"]:
        text += f" {note}."
    return f"{text} {check['unseen']}"


def _call_for(proposal, key):
    ops = set(proposal.get("operations") or [])
    for entry in proposal.get("evidence") or []:
        if key not in (entry.get("items") or []):
            continue
        verdict = rules.eligibility(entry.get("command") or "")
        for call in verdict.get("calls") or []:
            if call["op"] in ops:
                return call
    return None


def live_item(record, proposal_id):
    programme = programme_home.normalize_programme(record.get("programme") or {})
    proposal = state.find(programme, proposal_id)
    for key in (proposal or {}).get("items") or []:
        owner = (programme["items"].get(key) or {}).get("owner") or {}
        if not (owner.get("session_id") and transcript.path_for(owner["session_id"]) and _call_for(proposal, key)):
            continue
        if programme_sources.check_target(owner, record)["ok"]:
            return key
    return None


def _reserve(programme, proposal, key):
    item = programme["items"].get(key)
    call = _call_for(proposal, key) if item and key in (proposal.get("items") or []) else None
    sid = ((item or {}).get("owner") or {}).get("session_id")
    path = transcript.path_for(sid)
    offset = transcript.size(path) if path else None
    if call is None or offset is None:
        return None
    return {"item": key, "session_id": sid, "operation": call["op"], "target": call["target"],
            "normalized": call["normalized"], "at": run_record_core.now_iso(), "transcript_offset": offset}


def retry_text(proposal_id, reservation) -> str:
    return f"Permission {proposal_id} is applied. Run this once, exactly as written: {reservation['normalized']}"


def apply_answer(programme, proposal, choice, prompt, live) -> dict:
    check = verify(proposal)
    target = OUTCOME_STATE[check["outcome"]]
    reservation = _reserve(programme, proposal, live) if target == state.RETRYING and live else None
    if target == state.RETRYING and reservation is None:
        target = state.RETRY_UNOBSERVED
        check["notes"].append("covered, but no linked item's owner pane has a live agent, so nothing was "
                              f"retried; type applied {proposal['id']} again once a worker is running")
    out = state.record_answer(proposal, choice, prompt, target)
    proposal.update(explanation=explain(check), reservation=reservation, pending_answer=None,
                    verified={"at": run_record_core.now_iso(), "outcome": check["outcome"], "files": check["files"]})
    if reservation:
        proposal["attempts"] = proposal.get("attempts", 0) + 1
    state.note_items(programme, proposal, f"verify_{check['outcome']}", proposal["explanation"])
    out.update(verify=check, reservation=reservation, retry_item=reservation and reservation["item"],
               retry_text=reservation and retry_text(proposal["id"], reservation))
    return out


def _calls(command) -> list:
    return rules.eligibility(command).get("calls") or []


def _hits(command, reservation) -> bool:
    return any(c["op"] == reservation["operation"] and c["target"] == reservation["target"]
               for c in _calls(command))


def _diagnose(use) -> str:
    layer = transcript.layer(use)
    text = (f"the retry was refused: {layer} (reasonType {use['reason_type'] or 'none'}, "
            f"toolDenialKind {use['denial_kind'] or 'none'})")
    return text + (f"; next: {transcript.NEXT_ACTION[layer]}" if layer in transcript.NEXT_ACTION else "")


def _pane_status(snap, pane):
    if snap is None:
        return None
    row = next((p for p in snap.get("panes") or [] if isinstance(p, dict) and p.get("pane_id") == pane), None)
    if row is None:
        return "gone"
    agent = next((a for a in snap.get("agents") or [] if isinstance(a, dict) and a.get("pane_id") == pane), None)
    return programme_sanitize.token((agent or row).get("agent_status")) or "unknown"


def _sent_after(journal, item, at) -> bool:
    since = run_record_core.parse_iso(at)
    for row in journal:
        if row.get("kind") != "prompt_sent" or (row.get("payload") or {}).get("item") != item:
            continue
        when = run_record_core.parse_iso(row.get("at"))
        if (row.get("payload") or {}).get("sent") and when and since and when >= since:
            return True
    return False


def _observe_retry(programme, proposal, journal, snap) -> dict:
    res = proposal["reservation"]
    base = {"proposal": proposal["id"], "reservation_at": res["at"]}
    path = transcript.path_for(res["session_id"])
    if path is None:
        return dict(base, pending=f"no registry transcript for session {res['session_id']}")
    matches = [u for u in transcript.tool_uses(path, res.get("transcript_offset") or 0) if _hits(u["command"], res)]
    decided = next((u for u in matches if u["ruling"]), None)
    if decided and decided["ruling"] == "accept":
        return dict(base, state=state.RESOLVED, confirmed=True, tool_use_id=decided["tool_use_id"],
                    detail=f"the retry ran: {res['normalized']}")
    if decided:
        return dict(base, state=state.INEFFECTIVE, tool_use_id=decided["tool_use_id"],
                    detail=_diagnose(decided))
    unconfirmed = len(matches)
    if snap is None:
        return dict(base, pending="herdr is unavailable, so the owner pane cannot be seen", unconfirmed=unconfirmed)
    if not _sent_after(journal, res["item"], res["at"]):
        return dict(base, pending=f"retry not sent: prompt-item {res['item']} with the retry text",
                    unconfirmed=unconfirmed)
    pane = ((programme["items"].get(res["item"]) or {}).get("owner") or {}).get("pane")
    status = _pane_status(snap, pane)
    if status in ("idle", "gone"):
        return dict(base, state=state.RETRY_UNOBSERVED, unconfirmed=unconfirmed,
                    detail=f"the retry was sent, the owner pane is {status}, and its transcript shows no run; "
                           f"type applied {proposal['id']} to arm one more attempt")
    return dict(base, pending=f"owner pane {pane} is {status}", unconfirmed=unconfirmed)


def _observe_open(proposal) -> dict | None:
    wanted = set(proposal.get("operations") or [])
    seen, last = set(), {}
    for entry in proposal.get("evidence") or []:
        last[entry.get("session_id")] = entry.get("tool_use_id")
    for sid, tool_use_id in last.items():
        path = transcript.path_for(sid)
        uses = transcript.tool_uses(path) if path else []
        start = next((i for i in range(len(uses) - 1, -1, -1) if uses[i]["tool_use_id"] == tool_use_id), None)
        if start is None:
            continue
        for use in uses[start + 1:]:
            if use["ruling"] == "accept":
                seen |= {c["op"] for c in _calls(use["command"])} & wanted
    if not wanted or not wanted <= seen:
        return None
    check = verify(proposal)
    covering = next(({"rule": r["rule"], "source": r["source"]} for r in check["commands"]
                     if r["outcome"] == "covered" and r["rule"]), None)
    detail = "resolved without your confirmation: the blocked reads ran in an affected session"
    detail += (f"; covered by {covering['rule']} in {covering['source']}" if covering
               else "; no covering rule in the files read")
    return {"proposal": proposal["id"], "state": state.RESOLVED, "confirmed": False, "covering": covering,
            "detail": f"{detail}. {rules.UNSEEN}", "reservation_at": None}


def _unblock(programme, proposal) -> None:
    for key in proposal.get("items") or []:
        item = programme["items"].get(key)
        if item and item.get("state") == "waiting" and (item.get("waiting_on") or {}).get("permission") == proposal["id"]:
            item.update(state="open", waiting_on=None)
            programme_record._history(item, "open", permission=proposal["id"])


def _apply(programme, proposal, seen) -> dict:
    before = proposal["state"]
    state.move(proposal, state.step(proposal, seen["state"]))
    proposal.update(explanation=seen["detail"],
                    outcome={**{k: seen.get(k) for k in ("state", "tool_use_id", "detail")},
                             "at": run_record_core.now_iso()})
    if seen["state"] == state.RESOLVED:
        proposal.update(confirmed=seen["confirmed"], covering=seen.get("covering"))
        _unblock(programme, proposal)
    state.note_items(programme, proposal, seen["state"], seen["detail"])
    out = {"proposal": proposal["id"], "from": before, "state": seen["state"], "detail": seen["detail"],
           "confirmed": proposal.get("confirmed"), "tool_use_id": seen.get("tool_use_id")}
    pending, proposal["pending_answer"] = proposal.get("pending_answer"), None
    if pending:
        after = state.TRANSITIONS.get((proposal["state"], pending["choice"]))
        if after:
            state.move(proposal, after)
            out.update(state=after, deferred_answer={"choice": pending["choice"], "applied": True})
        else:
            out["deferred_answer"] = {"choice": pending["choice"], "applied": False,
                                      "why": "the retry ran, so the outcome stands"}
    return out


def observe(run_id, record) -> list:
    programme = programme_home.normalize_programme(record.get("programme") or {})
    proposals = state.proposals(programme)
    retrying = [p for p in proposals if p.get("state") == state.RETRYING and isinstance(p.get("reservation"), dict)]
    opened = [p for p in proposals if p.get("state") == state.OPEN]
    if not retrying and not opened:
        return []
    journal = programme_journal.read(run_id) if retrying else []
    snap = programme_sources.read_herdr()[0] if retrying else None
    seen = [_observe_retry(programme, p, journal, snap) for p in retrying]
    return seen + [s for s in map(_observe_open, opened) if s]


def _h_settle_permissions(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if positional:
        raise ValueError("usage: settle-permissions [--run <id>]")
    run_id, home, record = host._locate(opts)
    host._guard(home, record)
    seen = observe(run_id, record)
    pending = [s for s in seen if "pending" in s]
    decided = [s for s in seen if "state" in s]
    if not decided:
        host._emit({"ok": True, "run": run_id, "kind": "permission_settled", "settled": [], "pending": pending})
        return 0

    def change(programme, prompt, rec):
        settled = []
        for s in decided:
            proposal = state.find(programme, s["proposal"])
            if proposal is None or (proposal["state"], s["state"]) not in state.TRANSITIONS:
                continue
            res_at = (proposal.get("reservation") or {}).get("at") if proposal["state"] == state.RETRYING else None
            if res_at != s["reservation_at"]:
                continue
            settled.append(_apply(programme, proposal, s))
        return {"settled": settled, "pending": pending}

    return host._write(opts, change, "permission_settled")


_SPECS = (
    ("settle-permissions", _h_settle_permissions, "[--run <id>]",
     "any session but the driving one; an ended programme. Settles a retrying proposal only from the "
     "reserved session's transcript after the reservation, for the reserved operation and target; an idle "
     "owner after the retry was sent gives retry_unobserved. Resolves an open proposal unconfirmed when an "
     "affected session's transcript shows every operation ran. Never retries."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

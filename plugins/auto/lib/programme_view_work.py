#!/usr/bin/env python3
"""The view's work, contract and re-read parts: what the band, tree and contract view draw."""

from __future__ import annotations

import datetime
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_predicate = load_lib_module("programme_predicate")

FADE_FLOOR_SECONDS = 1800
NO_DESCRIPTION = "no description"
NO_CLAUSE = "no clause"
WORK_STATES = ("waiting", "open")
REREAD_KINDS = ("rules_acked", "rules_loaded")


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def _section(out, title, lines, empty) -> None:
    out.append({"style": "head", "text": title})
    out.extend(lines or [{"style": "dim", "text": f"  {empty}"}])


def _row(text, style="text") -> dict:
    return {"style": style, "text": text}


def _time(value):
    if isinstance(value, datetime.datetime):
        return value
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=datetime.timezone.utc)


def _seconds_between(earlier, later):
    earlier, later = _time(earlier), _time(later)
    if earlier is None or later is None:
        return None
    return int((later - earlier).total_seconds())


def _newer(a, b) -> bool:
    ta, tb = _time(a), _time(b)
    return ta is not None and (tb is None or ta > tb)


def fade_after_seconds(block, cadence_seconds) -> int:
    cadence = _dict(_dict(_dict(block.get("agreement")).get("terms")).get("cadence"))
    if cadence.get("value") == "fixed":
        return max(2 * cadence_seconds, FADE_FLOOR_SECONDS)
    sweeps = block.get("trajectory_sweeps") or []
    gap = _seconds_between(sweeps[-2], sweeps[-1]) if len(sweeps) >= 2 else None
    return max(2 * gap, FADE_FLOOR_SECONDS) if gap else FADE_FLOOR_SECONDS


def clause_label(clause) -> str:
    if not isinstance(clause, str) or ":" not in clause:
        return NO_CLAUSE
    kind, name = clause.split(":", 1)
    return name.replace("_", " ") if kind == "term" else f"{kind} {name}"


def _step(raw, kind) -> dict:
    raw = _dict(raw)
    clause = raw.get("clause")
    return {"kind": kind, "title": raw.get("title") or "", "clause": clause,
            "clause_label": clause_label(clause), "no_clause": not clause, "note": raw.get("note")}


def _steps(trajectory, waiting) -> list:
    steps = [_step(s, "done") for s in trajectory.get("done") or []]
    if trajectory.get("current"):
        steps.append(_step(trajectory["current"], "waiting" if waiting else "current"))
    return steps + [_step(s, "planned") for s in trajectory.get("planned") or []]


def _location(trajectory):
    location = _dict(trajectory.get("location"))
    parts = [location.get(k) for k in ("tab", "pane") if location.get(k)]
    return " › ".join(parts) or None


def _changes(journal_entries) -> dict:
    newest = {}
    for row in journal_entries:
        row = _dict(row)
        if row.get("kind") == "trajectory_changed":
            payload = _dict(row.get("payload"))
            if isinstance(payload.get("item"), str):
                newest[payload["item"]] = payload.get("new_hash")
    return newest


def watch_state(item_id, item, watchers, now, cadence) -> dict:
    waiting_on = _dict(item.get("waiting_on"))
    named = waiting_on.get("watcher")
    candidates = [_dict(w) for key, w in sorted(_dict(watchers).items())
                  if key == named or _dict(w).get("item") == item_id]
    for watcher in candidates:
        if programme_predicate.watcher_live(watcher, now, cadence):
            cron = programme_home.watcher_kind(watcher) == "cron"
            return {"state": "watcher_live", "interval_seconds": cadence if cron else None,
                    "beat_age_seconds": None if cron else _seconds_between(watcher.get("last_beat_at"), now)}
    for watcher in candidates:
        if watcher.get("retry") and not (watcher.get("process_id") or watcher.get("task_id")) \
                and not watcher.get("last_beat_at"):
            return {"state": "retry_never_started"}
    reporter = waiting_on.get("reporter")
    if isinstance(reporter, str) and reporter.strip():
        return {"state": "reporter_only", "reporter": reporter}
    return {"state": "nothing_watching"}


def _work_entry(item_id, item, state, ctx) -> dict:
    trajectory = _dict(item.get("trajectory"))
    recorded_at = trajectory.get("recorded_at")
    age = _seconds_between(recorded_at, ctx["now"]) if trajectory else None
    change_hash = ctx["changes"].get(item_id)
    return {
        "id": item_id,
        "title": item.get("title") or "",
        "state": state,
        "joined_at": item.get("joined_at"),
        "location": _location(trajectory),
        "session_id": _dict(item.get("owner")).get("session_id"),
        "no_plan": not trajectory,
        "steps": _steps(trajectory, state == "waiting"),
        "finish": trajectory.get("finish"),
        "recorded_at": recorded_at,
        "age_seconds": age,
        "fade_after_seconds": ctx["fade_after"],
        "faded": age is not None and age > ctx["fade_after"],
        "hash": trajectory.get("hash"),
        "change_hash": change_hash,
        "changed_since_first": item_id in ctx["changes"],
        "watch": watch_state(item_id, item, ctx["watchers"], ctx["now"], ctx["cadence"])
        if state == "waiting" else None,
    }


def work(block, journal_entries, now, cadence) -> list:
    ctx = {"now": now, "cadence": cadence, "changes": _changes(journal_entries),
           "watchers": block.get("watchers"), "fade_after": fade_after_seconds(block, cadence)}
    out = []
    for item_id, item in _dict(block.get("items")).items():
        state = item.get("state")
        # effective_state reads an unproven "done" claim as open; the claim still takes it off the band.
        if state in WORK_STATES and programme_predicate.effective_state(item) != "done":
            out.append(_work_entry(item_id, item, state, ctx))
    out.sort(key=lambda w: (w["state"] != "waiting", not w["changed_since_first"],
                            w["joined_at"] or "", w["id"]))
    return out


def reliant_counts(entries) -> dict:
    counts = {}
    for entry in entries:
        for step in entry["steps"]:
            if step["kind"] != "done" and step["clause"]:
                counts[step["clause"]] = counts.get(step["clause"], 0) + 1
    return counts


def _value_text(term) -> str:
    value = term.get("value")
    if isinstance(value, list):
        value = ", ".join(str(v) for v in value) or "none"
    extras = [f"{name} {term[name]}" for name in ("until", "seconds") if term.get(name) is not None]
    return str(value) + "".join(f", {e}" for e in extras)


def _options(term, guide) -> list:
    value = term.get("value")
    described = {**_dict(term.get("option_descriptions")), **_dict(guide.get("options"))}
    return [{"name": name, "description": described.get(name) or NO_DESCRIPTION,
             "active": name in value if isinstance(value, list) else name == value}
            for name in term.get("options") or []]


def _refusal(journal_entries, key):
    for row in reversed(journal_entries):
        row = _dict(row)
        if row.get("kind") == "approval_refused" and _dict(row.get("payload")).get("target") == key:
            return row
    return None


def _proposal(term, key, journal_entries):
    proposal = term.get("proposal")
    if not isinstance(proposal, dict):
        return None
    out = {k: proposal.get(k) for k in ("value", "extras", "at", "origin", "state", "settled_at")}
    refusal = _refusal(journal_entries, key) if proposal.get("state") == "pending" else None
    if refusal and _newer(refusal.get("at"), proposal.get("at")):
        out.update(state="refused", reason=_dict(refusal.get("payload")).get("reason"), refused_at=refusal.get("at"))
    return out


def _term(key, term, counts, journal_entries) -> dict:
    guide = _dict(programme_home.TERM_GUIDE.get(key))
    return {
        "key": key,
        "label": key.replace("_", " "),
        "value": term.get("value"),
        "value_text": _value_text(term),
        "description": guide.get("description") or NO_DESCRIPTION,
        "binding": guide.get("binding") or "none",
        "editor": guide.get("editor") or "choice",
        "reliant_steps": counts.get(f"term:{key}", 0),
        "set_by": term.get("set_by"),
        "set_at": term.get("set_at"),
        "why": term.get("why"),
        "notes": [_dict(n) for n in term.get("notes") or []],
        "proposal": _proposal(term, key, journal_entries),
        "options": _options(term, guide),
    }


def _ordered_terms(terms) -> list:
    known = [k for k in programme_home.TERM_GUIDE if k in terms]
    return known + sorted(k for k in terms if k not in programme_home.TERM_GUIDE)


def contract(block, journal_entries, entries, rulings, behaviours=None) -> dict:
    counts = reliant_counts(entries)
    terms = _dict(_dict(block.get("agreement")).get("terms"))
    out_terms = [_term(key, _dict(terms[key]), counts, journal_entries) for key in _ordered_terms(terms)]
    out_rulings = []
    for entry in rulings or []:
        entry = _dict(entry)
        rid = entry.get("id")
        applies_to = list(entry.get("applies_to") or ["programme"])
        reliant = counts.get(f"ruling:{rid}", 0) + counts.get(f"instruction:{rid}", 0)
        out_rulings.append({
            "id": rid, "quote": entry.get("quote") or entry.get("scope"), "applies_to": applies_to,
            "scope": "inherited" if applies_to == ["programme"] else "own", "until": entry.get("until"),
            "effect": entry.get("effect") or "decided", "kind": entry.get("kind"), "legacy": entry.get("legacy"),
            "at": entry.get("at"), "reliant_steps": reliant})
    return {"accepted": _dict(block.get("agreement")).get("accepted"), "terms": out_terms,
            "rulings": out_rulings, "behaviours": [_dict(b) for b in behaviours or []]}


def reread(block, journal_entries) -> dict:
    last, requested_at = None, None
    for row in journal_entries:
        row = _dict(row)
        if row.get("kind") in REREAD_KINDS and _newer(row.get("at"), last):
            last = row.get("at")
        elif row.get("kind") == "reread_requested" and _newer(row.get("at"), requested_at):
            requested_at = row.get("at")
    terms = _dict(_dict(block.get("agreement")).get("terms"))
    changed = sorted(k for k, t in terms.items() if last and _newer(_dict(t).get("set_at"), last))
    requested = bool(requested_at) and _newer(requested_at, last)
    return {"last_at": last, "changed_since": changed, "requested": requested,
            "requested_at": requested_at if requested else None}


def build(record, block, journal_entries, now, rulings, behaviours=None) -> dict:
    journal_entries = list(journal_entries or [])
    entries = work(block, journal_entries, now, programme_home.cadence_seconds(record))
    return {"work": entries, "contract": contract(block, journal_entries, entries, rulings, behaviours),
            "reread": reread(block, journal_entries)}


def work_texts(entries) -> list:
    out = []
    for entry in entries:
        current = next((s for s in entry["steps"] if s["kind"] in ("current", "waiting")), None)
        doing = "no plan yet" if entry["no_plan"] else (current["title"] if current else "no current step")
        age = f" ({entry['age_seconds'] // 60}m old{', faded' if entry['faded'] else ''})" \
            if entry["age_seconds"] is not None else ""
        finish = f" → {entry['finish']}" if entry.get("finish") else ""
        out.append((f"{entry['title']}: {doing}{finish}{age}", "dim" if entry["faded"] else "text"))
    return out

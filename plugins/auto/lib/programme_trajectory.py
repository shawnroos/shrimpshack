#!/usr/bin/env python3
"""Programme trajectory verbs: each open item's done, current and planned steps.

``programme.py`` registers these through ``build_verbs(host)``, passing itself as
``host`` so the verbs share its locate, guard, rules-in-force and write path.
"""

from __future__ import annotations

import functools
import hashlib
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
programme_sanitize = load_lib_module("programme_sanitize")
programme_record = load_lib_module("programme_record")
driver_session = load_lib_module("driver_session")

TITLE_CAP = 120
FINISH_CAP = 200
LOCATION_CAP = 80
STEPS_CAP = 30
UNKNOWN_CLAUSE = "unknown_clause"


class SkipEntry(Exception):
    pass


def allowed_clauses(rules, rulings) -> set:
    allowed = {f"term:{key}" for key in (rules["agreement"].get("terms") or {})}
    allowed.update(f"rule:{rule['id']}" for rule in rules["rules"])
    allowed.update(f"ruling:{r['id']}" for r in rulings)
    allowed.update(f"instruction:{r['id']}" for r in rulings if r["legacy"] == "instruction")
    return allowed


def _step(raw, allowed):
    if not isinstance(raw, dict):
        raise SkipEntry("each step must be {title, clause}")
    title = programme_sanitize.clean(raw.get("title"), TITLE_CAP)
    if not title:
        raise SkipEntry("each step needs a title")
    clause = raw.get("clause")
    step = {"title": title, "clause": None}
    if clause is None:
        return step
    if isinstance(clause, str) and clause in allowed:
        step["clause"] = clause
    else:
        step["note"] = UNKNOWN_CLAUSE
    return step


def _steps(raw, allowed, field) -> list:
    if raw is None:
        return []
    if not isinstance(raw, list) or len(raw) > STEPS_CAP:
        raise SkipEntry(f"{field} must be a list of at most {STEPS_CAP} steps")
    return [_step(s, allowed) for s in raw]


def _location(raw):
    if not isinstance(raw, dict):
        return None
    location = {key: programme_sanitize.clean(raw.get(key), LOCATION_CAP) or None for key in ("tab", "pane")}
    return location if any(location.values()) else None


def _fold(title) -> str:
    return " ".join(title.split()).casefold()


def path_hash(trajectory) -> str:
    current = [trajectory["current"]] if trajectory["current"] else []
    titles = [_fold(s["title"]) for s in trajectory["done"] + current + trajectory["planned"]]
    return hashlib.sha256(json.dumps(titles).encode()).hexdigest()[:16]


def _trajectory(entry, allowed, at, sid) -> dict:
    current = entry.get("current")
    trajectory = {
        "done": _steps(entry.get("done"), allowed, "done"),
        "current": _step(current, allowed) if current is not None else None,
        "planned": _steps(entry.get("planned"), allowed, "planned"),
        "finish": programme_sanitize.clean(entry.get("finish"), FINISH_CAP) or None,
        "location": _location(entry.get("location")),
        "recorded_at": at,
        "session_id": sid,
    }
    trajectory["hash"] = path_hash(trajectory)
    return trajectory


def _read_batch() -> list:
    cap = programme_record.RECORD_INPUT_CAP
    raw = sys.stdin.read(cap + 1) if not sys.stdin.isatty() else ""
    if len(raw) > cap:
        raise ValueError(f"record-trajectories input is larger than {cap} bytes")
    try:
        doc = json.loads(raw)
    except ValueError:
        raise ValueError("record-trajectories reads a JSON list of trajectories on stdin") from None
    rows = doc.get("trajectories") if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        raise ValueError("record-trajectories reads a JSON list of trajectories on stdin")
    return rows


def _record_one(programme, entry, allowed, at, sid):
    if not isinstance(entry, dict):
        raise SkipEntry("each entry must be an object")
    try:
        key = programme_record._resolve(programme, programme_record.check_item_id(entry.get("item")))
    except programme_record.RecordError as exc:
        raise SkipEntry(str(exc)) from None
    item = programme["items"][key]
    if item["state"] in programme_home.FINISHED_ITEM_STATES:
        raise SkipEntry(f"item {key!r} is {item['state']}")
    trajectory = _trajectory(entry, allowed, at, sid)
    old = item.get("trajectory") or {}
    first = not old or old.get("session_id") != sid
    item["trajectory"] = trajectory
    if first or old.get("hash") == trajectory["hash"]:
        return key, None
    programme_record._history(item, "trajectory_changed", old_hash=old.get("hash"), new_hash=trajectory["hash"])
    return key, {"item": key, "old_hash": old.get("hash"), "new_hash": trajectory["hash"]}


def _h_record_trajectories(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if positional:
        raise ValueError("usage: record-trajectories [--run <id>] < trajectories.json")
    rows = _read_batch()
    sid = driver_session.driving_session_id()
    run_id, home, record = host._locate(opts)
    if not rows:
        host._guard(home, record)
        host._emit({"ok": True, "stored": [], "changed": [], "skipped": []})
        return 0

    def change(programme, prompt, rec):
        allowed = allowed_clauses(host.rules_in_force(rec, changes=False), host.active_rulings(programme))
        at = run_record_core.now_iso()
        stored, changes, skipped = [], [], []
        for entry in rows:
            try:
                key, changed = _record_one(programme, entry, allowed, at, sid)
            except SkipEntry as exc:
                item = entry.get("item") if isinstance(entry, dict) else None
                skipped.append({"item": programme_sanitize.clean(item, programme_record.ID_CAP) or None,
                                "reason": str(exc)})
                continue
            stored.append(key)
            if changed:
                changes.append(changed)
        if stored:
            sweeps = programme.get("trajectory_sweeps") or []
            programme["trajectory_sweeps"] = sweeps[-1:] + [at]
        return {"stored": stored, "changed": changes, "skipped": skipped, "at": at}

    def after(payload):
        # A non-empty return is journaled as effects_recorded, so an unchanged sweep must return nothing.
        for row in payload["changed"]:
            programme_journal.append(run_id, "trajectory_changed", sid, row)
        return {"changed": [row["item"] for row in payload["changed"]]} if payload["changed"] else None

    return host._write(opts, change, "trajectory_changed", journal=False, after=after)


_SPECS = (
    ("record-trajectories", _h_record_trajectories,
     "[--run <id>] < JSON list of {item, done: [step], current: step|null, planned: [step], finish, "
     "location?: {tab, pane}} where step is {title, clause: term:<key>|rule:<id>|ruling:<id>|null}",
     "input that is not a JSON list or is over 1 MB. An entry for an unknown, done, handed or dropped "
     "item, or with a step that has no title, is skipped with a reason; the rest are stored. An unknown "
     "clause is stored as null with an unknown_clause note. Only a changed path under the same driving "
     "session is journaled (trajectory_changed); empty input writes nothing."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

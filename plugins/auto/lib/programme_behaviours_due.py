#!/usr/bin/env python3
"""The behaviours the PM owes an answer for, per item: a trigger passed and nothing was sent or skipped.

Level-triggered on purpose: a behaviour stays due until the item holds an answer, however many sweeps
ago the trigger passed, so a missed or compacted sweep cannot lose it. Pure over the record, the
behaviours store and the journal, so ``sweep-inputs`` can put it in the verdict.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviours = load_lib_module("programme_behaviours")
programme_home = load_lib_module("programme_home")
run_record_core = load_lib_module("run_record_core")

CAP = 20
ANSWERS = ("relevant", "sent_back", "skipped", "applied_by_pm")
TEXT_CAP = 160


def _answered(item, entry, trigger) -> bool:
    reasons = {d.get("reason") for d in item.get("behaviour_deliveries") or []
               if isinstance(d, dict) and d.get("id") == entry["id"]}
    return bool(reasons & set(ANSWERS)) or (trigger == "start" and "brief" in reasons)


def _in_force_when(entry, passed) -> bool:
    """A trigger that passed before the behaviour was recorded is history; an unknown start counts as in force."""
    start = run_record_core.parse_iso(programme_behaviours.since(entry) or "")
    stamp = run_record_core.parse_iso(passed)
    return start is None or stamp is None or start <= stamp


def _pm_only_untriggered(entry) -> bool:
    """Measured on the Studio programme: defaulting these to claim listed 123 of 176 due lines, so a sweep never cleared."""
    return entry["applies_to"] == "pm" and "trigger" not in entry["when"]


def _mark(entry, pm_checks, agent_checks):
    if entry["applies_to"] == "pm":
        return "pm_applies"
    return "judge" if agent_checks and not pm_checks else None


def _row(key, entry, trigger, passed):
    checks = entry["when"].get("checks") or []
    pm = [c["text"] for c in checks if c["by"] == "pm"]
    agent = [c["text"] for c in checks if c["by"] == "agent"]
    when = " ".join(entry["when"]["text"].split())
    return {"item": key, "behaviour": entry["id"], "trigger": trigger, "trigger_at": passed,
            "when": when if len(when) <= TEXT_CAP else when[:TEXT_CAP - 1] + "…",
            "pm_checks": pm, "agent_checks": agent, "mark": _mark(entry, pm, agent)}


def due(record, run_id, *, lookup=None, store=None, cap=CAP) -> dict:
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    scoped = dict(record or {}, programme=programme)
    loaded = store if store is not None else programme_behaviours.load_store(lookup)
    rows = []
    for key, item in sorted((programme.get("items") or {}).items()):
        if item.get("state") in programme_home.CLOSED_ITEM_STATES:
            continue
        times = programme_behaviours.trigger_times(run_id, key, item)
        for entry in programme_behaviours.in_force(scoped, item, store=loaded):
            if _pm_only_untriggered(entry):
                continue
            trigger = programme_behaviours.trigger_of(entry)
            passed = times.get(trigger)
            if passed and _in_force_when(entry, passed) and not _answered(item, entry, trigger):
                rows.append(_row(key, entry, trigger, passed))
    rest = rows[cap:]
    return {"total": len(rows), "rows": rows[:cap], "overflow": len(rest),
            "overflow_ids": [f"{r['item']}/{r['behaviour']}" for r in rest]}

#!/usr/bin/env python3
"""The rituals the PM owes: due, missed, or in flight, computed from the record, the store and the journal.

Level-triggered on purpose, like the behaviours due list: a ritual stays pending until an answer row
follows its trigger, however many sweeps ago the trigger passed, so a dead PM session loses nothing.
A pending ritual is due for two cadence periods (the lease's own orphan threshold) and missed after
that; a missed ritual is only ever offered, never run silently late. Pure over its inputs.
"""

from __future__ import annotations

import datetime
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_rituals = load_lib_module("programme_rituals")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
run_record_core = load_lib_module("run_record_core")

CAP = 20
ANSWERS = ("ritual_ran", "ritual_skipped")
ENDS_FLIGHT = ANSWERS + ("ritual_failed",)
GATE_FIX = ("run it (start-ritual <id>, perform its steps, run-ritual <id>) or skip it with Shawn's answer, then "
            "retry; --without-rituals goes ahead and leaves it missed for whoever drives next")
PRE_VERB = ("handover", "end")
MOVES = ("programme_started", "taken_over", "handed_over")
TEXT_CAP = 160
FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def _rows_for(rows, kinds, rid):
    return [r for r in rows if r.get("kind") in kinds and (r.get("payload") or {}).get("ritual") == rid]


def _latest(rows):
    stamps = [run_record_core.parse_iso(r.get("at")) for r in rows]
    return max((s for s in stamps if s), default=None)


def _event_time(rows, trigger):
    kind = programme_rituals.EVENT_ROWS[trigger]
    hits = [r for r in rows if r.get("kind") == kind
            and (trigger != "resume" or (r.get("payload") or {}).get("trigger") == "resume")]
    return _latest(hits)


def _tenure_start(rows, before=None):
    """When the current PM's tenure began: the latest start, takeover or handover row, optionally before a given time."""
    stamps = [run_record_core.parse_iso(r.get("at")) for r in rows if r.get("kind") in MOVES]
    stamps = [s for s in stamps if s and (before is None or s < before)]
    return max(stamps, default=None)


def _calendar_time(programme, entry):
    """The pending time of a calendar ritual: this programme's clock, else the first slot after the ritual came into force."""
    clock = ((programme.get("ritual_clock") or {}).get(entry["id"]) or {}).get("next_due_at")
    stamp = run_record_core.parse_iso(clock)
    if stamp is None:
        began = run_record_core.parse_iso(programme_rituals.since(entry) or "") \
            or run_record_core.parse_iso(programme.get("created_at") or "")
        if began is None:
            return None
        stamp = programme_rituals.next_after(entry["when"]["schedule"], began)
    return stamp


def _pending_time(programme, entry, rows):
    trigger = entry["when"]["trigger"]
    if trigger == "calendar":
        return _calendar_time(programme, entry)
    happened = _event_time(rows, trigger)
    began = run_record_core.parse_iso(programme_rituals.since(entry) or "")
    if happened is None or (began is not None and began > happened):
        return None
    return happened


def _offered(rows, rid, pending):
    for row in rows:
        if row.get("kind") != "ritual_offered":
            continue
        for item in (row.get("payload") or {}).get("offered") or []:
            if item.get("ritual") == rid and item.get("pending_at") == pending:
                return True
    return False


def _row(entry, state, pending):
    text = " ".join(entry["when"]["text"].split())
    stamp = pending.strftime(FORMAT)
    return {"ritual": entry["id"], "layer": entry["layer"], "trigger": entry["when"]["trigger"], "state": state,
            "pending_at": stamp, "when": text if len(text) <= TEXT_CAP else text[:TEXT_CAP - 1] + "…",
            "steps": list(entry["steps"])}


def waiting_before(record, run_id, trigger, *, lookup=None, store=None, rows=None) -> list:
    """Active rituals for a handover or end that no one has answered in the tenure that is ending."""
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    scoped = dict(record or {}, programme=programme)
    journal = rows if rows is not None else programme_journal.read(run_id)
    began = _tenure_start(journal)
    loaded = store if store is not None else programme_rituals.load_store(lookup)
    waiting = []
    for entry in programme_rituals.in_force(scoped, store=loaded):
        if entry["when"]["trigger"] != trigger:
            continue
        answered = _latest(_rows_for(journal, ANSWERS, entry["id"]))
        if answered is None or (began is not None and answered < began):
            waiting.append(entry["id"])
    return waiting


def due(record, run_id, *, now=None, lookup=None, store=None, rows=None, cap=CAP) -> dict:
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    scoped = dict(record or {}, programme=programme)
    loaded = store if store is not None else programme_rituals.load_store(lookup)
    journal = rows if rows is not None else programme_journal.read(run_id)
    clock_now = now or datetime.datetime.now(datetime.timezone.utc)
    grace = datetime.timedelta(seconds=programme_home.ORPHAN_CADENCE_PERIODS * programme_home.cadence_seconds(scoped))
    out = {"due": [], "missed": [], "in_flight": []}
    for entry in programme_rituals.in_force(scoped, store=loaded):
        rid = entry["id"]
        answered = _latest(_rows_for(journal, ANSWERS, rid))
        started = _latest(_rows_for(journal, (programme_rituals.STARTED,), rid))
        ended = _latest(_rows_for(journal, ENDS_FLIGHT, rid))
        pending = _pending_time(programme, entry, journal)
        if pending is None:
            continue
        if started and (ended is None or started > ended):
            out["in_flight"].append(_row(entry, "in_flight", pending))
            continue
        # A handover or end ritual runs before the verb, in the tenure that is ending, so an answer
        # anywhere in that tenure answers it.
        cut = pending
        if entry["when"]["trigger"] in PRE_VERB:
            cut = _tenure_start(journal, before=pending) or pending
        if clock_now < pending or (answered and answered >= cut):
            continue
        if clock_now - pending <= grace:
            out["due"].append(_row(entry, "due", pending))
            continue
        row = _row(entry, "missed", pending)
        row["offered"] = _offered(journal, rid, row["pending_at"])
        out["missed"].append(row)
    total = sum(len(v) for v in out.values())
    for bucket in out:
        out[bucket] = out[bucket][:cap]
    out.update(total=total, error="; ".join(loaded["notices"]) or None)
    return out

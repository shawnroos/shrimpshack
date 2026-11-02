#!/usr/bin/env python3
"""The rituals the PM owes: due, missed, or in flight, computed from the record, the store and the journal.

Level-triggered on purpose, like the behaviours due list: a ritual stays pending until an answer row
follows its trigger, however many sweeps ago the trigger passed, so a dead PM session loses nothing.
A pending ritual is due for two cadence periods (the lease's own orphan threshold) and missed after
that; a missed ritual is only ever offered, never run silently late. Pure over its inputs.
"""

from __future__ import annotations

import datetime
import re
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_rituals = load_lib_module("programme_rituals")
programme_ritual_checks = load_lib_module("programme_ritual_checks")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
run_record_core = load_lib_module("run_record_core")

CAP = 20
ANSWERS = (programme_rituals.RAN, programme_rituals.SKIPPED)
ENDS_FLIGHT = ANSWERS + (programme_rituals.FAILED,)
GATE_FIX = ("run it (start-ritual <id>, perform its steps, run-ritual <id>) or skip it with Shawn's answer, then "
            "retry; --without-rituals goes ahead and leaves it missed for whoever drives next")
PRE_VERB = ("handover", "end")
MOVES = ("programme_started", "taken_over", "handed_over")
TEXT_CAP = 160
# Rows a quiet programme writes about itself. A quiet ritual's own rows are among them: running it is not activity.
QUIET_BOOKKEEPING = ("stop_quiet", "prompts_pruned", "working_now", "focus_noted", programme_rituals.OFFERED,
                     programme_rituals.STARTED, programme_rituals.RAN, programme_rituals.FAILED,
                     programme_rituals.SKIPPED)
_TRIGGER_OF_ROW ={kind: trigger for trigger, kind in programme_rituals.EVENT_ROWS.items()}


def _later(table, key, at) -> None:
    if key not in table or at > table[key]:
        table[key] = at


class _Index:
    """One pass over the journal. The journal only grows, so each ritual must not rescan it."""

    def __init__(self, rows):
        self.answered, self.started, self.ended, self.events = {}, {}, {}, {}
        self.moves, self.offered, self.checked = [], {}, {}
        active_since_quiet = True
        for row in rows:
            at = run_record_core.parse_iso(row.get("at"))
            if at is None:
                continue
            kind, payload = row.get("kind"), row.get("payload") or {}
            rid = payload.get("ritual")
            # The Stop hook writes a stop_quiet row on every repeated stop, but going quiet is one change.
            if kind == "stop_quiet":
                if active_since_quiet:
                    _later(self.events, "quiet", at)
                active_since_quiet = False
            elif kind not in QUIET_BOOKKEEPING and not (
                    kind == programme_rituals.CHECKED and payload.get("result") == "pass"):
                active_since_quiet = True
            if kind == programme_rituals.CHECKED and rid:
                self.checked[(rid, payload.get("pending_at"))] = payload
            if kind in ANSWERS:
                _later(self.answered, rid, at)
            if kind == programme_rituals.STARTED:
                _later(self.started, rid, at)
            if kind in ENDS_FLIGHT:
                _later(self.ended, rid, at)
            if kind in MOVES:
                self.moves.append(at)
            if kind == programme_rituals.OFFERED:
                for item in payload.get("offered") or []:
                    _later(self.offered, (item.get("ritual"), item.get("pending_at")), at)
            trigger = _TRIGGER_OF_ROW.get(kind)
            if trigger and trigger != "quiet" and (trigger != "resume" or payload.get("trigger") == "resume"):
                _later(self.events, trigger, at)

    def was_offered(self, rid, pending_at) -> bool:
        """An offer from an earlier tenure does not count: the PM that made it may have died before Shawn saw it."""
        at = self.offered.get((rid, pending_at))
        began = self.tenure_start()
        return at is not None and (began is None or at >= began)

    def tenure_start(self, before=None):
        return max((m for m in self.moves if before is None or m < before), default=None)


def _calendar_time(programme, entry):
    """This programme's clock, else the first slot after the ritual came into force."""
    clock = ((programme.get("ritual_clock") or {}).get(entry["id"]) or {}).get("next_due_at")
    stamp = run_record_core.parse_iso(clock)
    if stamp is None:
        # A stored ritual can be older than this programme: its pending slot starts at whichever came later.
        began = [t for t in (run_record_core.parse_iso(programme_rituals.since(entry) or ""),
                             run_record_core.parse_iso(programme.get("created_at") or "")) if t]
        if not began:
            return None
        stamp = programme_rituals.next_after(entry["when"]["schedule"], max(began))
    return stamp


def _pending_time(programme, entry, index):
    trigger = entry["when"]["trigger"]
    if trigger == "calendar":
        return _calendar_time(programme, entry)
    happened = index.events.get(trigger)
    began = run_record_core.parse_iso(programme_rituals.since(entry) or "")
    if happened is None or (began is not None and began > happened):
        return None
    return happened


def _cap(text):
    return text if len(text) <= TEXT_CAP else text[:TEXT_CAP - 1] + "…"


_PLUGIN_NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def _check_summary(entry, index, pending_at):
    """Only fixed words and validated plugin names reach the PM; the journal row is data, not text to relay."""
    if not entry.get("check"):
        return None
    return _summarize(entry["check"]["name"], index.checked.get((entry["id"], pending_at)))


def last_check(entry, rows):
    """The newest ``ritual_checked`` row for a ritual, as the same safe summary; None when it never ran."""
    if not entry.get("check"):
        return None
    latest = None
    for row in rows:
        if row.get("kind") == programme_rituals.CHECKED and (row.get("payload") or {}).get("ritual") == entry["id"]:
            latest = row
    if latest is None:
        return None
    return dict(_summarize(entry["check"]["name"], latest["payload"]), at=latest.get("at"),
                pending_at=latest["payload"].get("pending_at"))


def _summarize(name, got):
    summary = {"name": name, "result": "not_run"}
    if got is None:
        return summary
    result, reason = got.get("result"), got.get("reason")
    summary["result"] = result if result in programme_ritual_checks.RESULTS else "error"
    summary["reason"] = reason if reason in programme_ritual_checks.REASONS else "internal"
    summary["checked"] = got.get("checked") if type(got.get("checked")) is int else None
    summary["failed"] = [{"plugin": f["plugin"], "reason": f.get("reason") if f.get("reason") in programme_ritual_checks.REASONS else "internal"}
                         for f in (got.get("failed") or [])[:10]
                         if isinstance(f, dict) and isinstance(f.get("plugin"), str) and _PLUGIN_NAME.match(f["plugin"])]
    if type(got.get("ref_age_seconds")) is int:
        summary["ref_age_seconds"] = got["ref_age_seconds"]
    return summary


def _row(entry, state, pending, index=None):
    text = " ".join(entry["when"]["text"].split())
    row = {"ritual": entry["id"], "layer": entry["layer"], "trigger": entry["when"]["trigger"], "state": state,
           "pending_at": pending.strftime(programme_rituals.TIME_FORMAT),
           "when": text if len(text) <= TEXT_CAP else text[:TEXT_CAP - 1] + "…", "steps": list(entry["steps"]),
           **({"offers": [_cap(o) for o in entry["offers"]], "offers_rule": programme_rituals.OFFERS_RULE}
              if entry.get("offers") else {})}
    if index is not None and entry.get("check"):
        row["check"] = _check_summary(entry, index, row["pending_at"])
    return row


def _context(record, run_id, lookup, store, rows):
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    scoped = dict(record or {}, programme=programme)
    loaded = store if store is not None else programme_rituals.load_store(lookup)
    index = _Index(rows if rows is not None else programme_journal.read(run_id))
    return programme, scoped, loaded, index


def waiting_before(record, run_id, trigger, *, lookup=None, store=None, rows=None) -> list:
    """Active rituals for a handover or end that no one has answered in the tenure that is ending."""
    _, scoped, loaded, index = _context(record, run_id, lookup, store, rows)
    began = index.tenure_start()
    waiting = []
    for entry in programme_rituals.in_force(scoped, store=loaded):
        if entry["when"]["trigger"] != trigger:
            continue
        answered = index.answered.get(entry["id"])
        if answered is None or (began is not None and answered < began):
            waiting.append(entry["id"])
    return waiting


def gate(run_id, trigger, status, opts, refused) -> None:
    """Raise ``refused`` (the lifecycle's refusal class) while a ritual for a handover or end is unanswered in the tenure."""
    waiting = [] if opts.get("without-rituals") else waiting_before(programme_home._read_record(run_id) or {}, run_id, trigger)
    if waiting:
        raise refused(f"{trigger} ritual {', '.join(waiting)} has not run in this tenure", status, fix=GATE_FIX)


def due(record, run_id, *, now=None, lookup=None, store=None, rows=None, cap=CAP) -> dict:
    programme, scoped, loaded, index = _context(record, run_id, lookup, store, rows)
    clock_now = now or datetime.datetime.now(datetime.timezone.utc)
    grace = datetime.timedelta(seconds=programme_home.ORPHAN_CADENCE_PERIODS * programme_home.cadence_seconds(scoped))
    out = {"due": [], "missed": [], "in_flight": []}
    for entry in programme_rituals.in_force(scoped, store=loaded):
        rid = entry["id"]
        pending = _pending_time(programme, entry, index)
        if pending is None:
            continue
        started, ended = index.started.get(rid), index.ended.get(rid)
        if started and (ended is None or started > ended):
            row = _row(entry, "in_flight", pending, index)
            row["offered"] = index.was_offered(rid, row["pending_at"])
            out["in_flight"].append(row)
            continue
        # A handover or end ritual runs before the verb, in the tenure that is ending, so an answer
        # anywhere in that tenure answers it.
        cut = pending
        if entry["when"]["trigger"] in PRE_VERB:
            cut = index.tenure_start(before=pending) or pending
        answered = index.answered.get(rid)
        if clock_now < pending or (answered and answered >= cut):
            continue
        if clock_now - pending <= grace:
            out["due"].append(_row(entry, "due", pending, index))
            continue
        row = _row(entry, "missed", pending, index)
        row["offered"] = index.was_offered(rid, row["pending_at"])
        out["missed"].append(row)
    total = sum(len(v) for v in out.values())
    for bucket in out:
        out[bucket] = out[bucket][:cap]
    out.update(total=total, error="; ".join(loaded["notices"]) or None)
    return out

#!/usr/bin/env python3
"""Done and may-stop for a programme run, computed from its record at a given time.

``compute`` is pure: it reads the record plus the size of the worker claims inbox
and returns a fresh status. Watcher heartbeats age and a set stop time passes with
no write, so the Stop hook and the read model call it with ``now``; the copy that
``_atomic_write`` stores under ``programme_status`` is for display only.
"""

from __future__ import annotations

import datetime
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")

SOURCE_OUTAGE_PERIODS = 2
REASON_KINDS = (
    "corrupt_record", "never_stop", "not_done", "until_time", "unproven_done",
    "no_rule_proposed", "undebugged_blocker", "ownerless_item", "open_item",
    "unwatched_wait", "queued_action", "unread_claim", "source_unavailable",
)


def _off(name: str) -> bool:
    return run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_NO_" + name)


def _age(stamp, now) -> float | None:
    when = run_record_core.parse_iso(stamp) if isinstance(stamp, str) else None
    return None if when is None else (now - when).total_seconds()


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def evidence_complete(item: dict) -> bool:
    deliverables = item.get("deliverables")
    if not item.get("matched_rule") or not isinstance(deliverables, dict) or not deliverables:
        return False
    return all(_dict(d).get("result") == "confirmed" for d in deliverables.values())


def effective_state(item: dict) -> str:
    state = item.get("state")
    if state in ("handed", "dropped"):
        return state
    if evidence_complete(item) or (state == "done" and _off("EVIDENCE_CHECK")):
        return "done"
    return "waiting" if state == "waiting" else "open"


def watcher_live(watcher, now, cadence: int) -> bool:
    watcher = _dict(watcher)
    if not (watcher.get("process_id") or watcher.get("task_id")):
        return False
    if _off("WATCHER_STALENESS"):
        return True
    age = _age(watcher.get("last_beat_at"), now)
    return age is not None and age < cadence


def _watched(item_id: str, waiting_on: dict, watchers: dict, now, cadence: int) -> bool:
    reporter = waiting_on.get("reporter")
    if isinstance(reporter, str) and reporter.strip():
        return True
    named = waiting_on.get("watcher")
    for key, watcher in watchers.items():
        if key == named or _dict(watcher).get("item") == item_id:
            if watcher_live(watcher, now, cadence):
                return True
    return False


def _proposed_for(block: dict) -> set:
    out = set()
    for rule in block.get("proposed_rules") or []:
        out.update(i for i in _dict(rule).get("items") or [] if isinstance(i, str))
    return out


def _queued_starts(queue: list) -> set:
    return {_dict(e).get("item") for e in queue if _dict(e).get("action") == "start_worker"}


def _item_reasons(item_id, item, ctx) -> list:
    state = effective_state(item)
    if state in programme_home.FINISHED_ITEM_STATES:
        return []
    out = []
    waiting_on = _dict(item.get("waiting_on"))
    if item.get("state") == "done":
        out.append({"kind": "unproven_done", "item": item_id})
    if not item.get("matched_rule") and item_id not in ctx["proposed"] and not _off("RULE_CHECK"):
        out.append({"kind": "no_rule_proposed", "item": item_id})
    if (waiting_on.get("kind") == "blocker" and not waiting_on.get("trace_id")
            and not waiting_on.get("job_id") and not _off("UNDEBUGGED_BLOCKER")):
        out.append({"kind": "undebugged_blocker", "item": item_id})
    if state == "open" and item.get("state") != "done":
        pane = _dict(item.get("owner")).get("pane")
        if not pane and item_id not in ctx["starts"] and not _off("OWNERLESS_ITEM"):
            out.append({"kind": "ownerless_item", "item": item_id})
        if not _off("OPEN_ITEM"):
            out.append({"kind": "open_item", "item": item_id})
    if state == "waiting" and not ctx["watched"][item_id] and not _off("UNWATCHED_WAIT"):
        out.append({"kind": "unwatched_wait", "item": item_id, "who": waiting_on.get("who")})
    return out


def _source_status(block: dict, now, cadence: int):
    reasons, waits = [], []
    for name, source in sorted(_dict(block.get("sources")).items()):
        source = _dict(source)
        if "unavailable_since" not in source or source["unavailable_since"] is None:
            continue
        age = _age(source["unavailable_since"], now)
        if age is not None and age >= SOURCE_OUTAGE_PERIODS * cadence:
            waits.append({"system": name, "since": source["unavailable_since"],
                          "watcher": source.get("watcher")})
        elif not _off("SOURCE_OUTAGE"):
            reasons.append({"kind": "source_unavailable", "system": name})
    return reasons, waits


def _start_iso(block: dict):
    accepted = _dict(_dict(block.get("agreement")).get("accepted"))
    return accepted.get("at") or block.get("created_at")


def _scan(block: dict, now, inbox_size, cadence: int) -> dict:
    items = block["items"]
    watchers = _dict(block.get("watchers"))
    queue = [e for e in _dict(block.get("working_model")).get("queue") or []]
    ctx = {"proposed": _proposed_for(block), "starts": _queued_starts(queue), "watched": {}}
    floor, waits, new_items = [], [], []
    counts = {"total": 0, "finished": 0, "open": 0, "waiting": 0}
    start = run_record_core.parse_iso(_start_iso(block))
    for item_id in sorted(items):
        item = items[item_id]
        if not isinstance(item, dict):
            floor.append({"kind": "corrupt_record", "item": item_id})
            continue
        counts["total"] += 1
        state = effective_state(item)
        counts["finished" if state in programme_home.FINISHED_ITEM_STATES else state] += 1
        joined = run_record_core.parse_iso(item.get("joined_at"))
        if start is not None and joined is not None and joined > start:
            new_items.append(item_id)
        waiting_on = _dict(item.get("waiting_on"))
        ctx["watched"][item_id] = _watched(item_id, waiting_on, watchers, now, cadence)
        if state == "waiting":
            waits.append({"item": item_id, "who": waiting_on.get("who"),
                          "reporter": waiting_on.get("reporter"),
                          "watched": ctx["watched"][item_id]})
        floor.extend(_item_reasons(item_id, item, ctx))
    if queue and not _off("QUEUED_ACTION"):
        floor.append({"kind": "queued_action", "count": len(queue)})
    offset = _int(block.get("inbox_offset")) or 0
    if inbox_size is not None and inbox_size > offset and not _off("UNREAD_CLAIM"):
        floor.append({"kind": "unread_claim", "count": inbox_size - offset})
    source_reasons, source_waits = _source_status(block, now, cadence)
    floor.extend(source_reasons)
    finished = counts["finished"] == counts["total"] and len(items) == counts["total"]
    return {"done": finished or _off("DONE_CHECK"), "floor": floor,
            "waits": waits + source_waits, "new_items": new_items, "items": counts}


def _stop_decision(rule: str, until, done: bool, floor: list, now):
    if rule == "never_stop" and not _off("NEVER_STOP"):
        return False, [{"kind": "never_stop"}]
    if rule == "only_when_done" and not _off("ONLY_WHEN_DONE"):
        return done, [] if done else [{"kind": "not_done"}]
    if rule == "until_time" and not _off("UNTIL_TIME"):
        until_at = run_record_core.parse_iso(until) if isinstance(until, str) else None
        if until_at is not None and now < until_at:
            return False, [{"kind": "until_time", "until": until}]
    return not floor, floor


def _corrupt(now) -> dict:
    return {"done": False, "may_stop": False, "stop_rule": None, "ended": False,
            "reasons": [{"kind": "corrupt_record"}], "waits": [], "unwatched_waits": [],
            "new_items": [], "items": {"total": 0, "finished": 0, "open": 0, "waiting": 0},
            "inbox_checked": False, "computed_at": _iso(now)}


def _iso(now) -> str:
    return now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _compute(record: dict, now, inbox_size) -> dict:
    block = record.get("programme")
    if not isinstance(block, dict) or not isinstance(block.get("items"), dict):
        return _corrupt(now)
    inbox_size = _int(inbox_size)
    cadence = programme_home.cadence_seconds(record)
    scan = _scan(block, now, inbox_size, cadence)
    stop_term = _dict(_dict(_dict(block.get("agreement")).get("terms")).get("stop_rule"))
    rule = stop_term.get("value") or "nothing_it_can_act_on"
    ended = run_record_core._lazy_load("phase-grammar").current_phase(record) == "done"
    if ended:
        may_stop, reasons = True, []
    else:
        may_stop, reasons = _stop_decision(rule, stop_term.get("until"), scan["done"],
                                           scan["floor"], now)
    return {
        "done": bool(scan["done"]),
        "may_stop": bool(may_stop),
        "stop_rule": rule,
        "ended": ended,
        "reasons": reasons,
        "waits": scan["waits"],
        "unwatched_waits": [r["item"] for r in scan["floor"] if r["kind"] == "unwatched_wait"],
        "new_items": scan["new_items"],
        "items": scan["items"],
        "inbox_checked": inbox_size is not None,
        "computed_at": _iso(now),
    }


def compute(record: dict, now=None, inbox_size=None) -> dict:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    try:
        return _compute(record, now, inbox_size)
    # Deliberate swallow: _atomic_write calls this on every write, so a raise on a
    # malformed field would lock the record against the write that repairs it.
    except Exception:
        return _corrupt(now)

#!/usr/bin/env python3
"""Synergy rows for the record-time check: how a new behaviour should fit with a listed one. Code picks the
candidates and the target of an offered edit; it writes no wording, the PM does.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

behaviour_check = load_lib_module("programme_behaviour_check")

KINDS = ("shared_moment", "shared_tool", "ending_rule")
ENDING_WORDS = frozenset((
    "stop", "stops", "stopped", "retire", "retires", "retired", "close", "closes", "closed", "end", "ends", "ended",
))
# Only a reason that rests on overlapping situation words can say two behaviours speak of the same work.
SITUATION_REASONS = ("shared_when", "instruction_touches_situation")
ROUTE_EDIT = "programme_edit"
ROUTE_COPY = "copy_default_then_settle"
ROUTE_OVERRIDE = "record_with_conflicts_with"
ROUTE_REDRAFT = "redraft"


def ends_work(entry) -> bool:
    return any(w in ENDING_WORDS for line in entry.get("do") or [] for w in behaviour_check.tokens(line))


def _route(other) -> str:
    if other.get("layer") == "shipped" or other.get("source") == "file":
        return ROUTE_COPY
    return ROUTE_EDIT if other.get("layer") == "programme" else ROUTE_OVERRIDE


def _ending_offer(entry, other):
    if ends_work(entry) == ends_work(other):
        return None
    ender, other_side = (entry, other) if ends_work(entry) else (other, entry)
    if other_side is entry:
        return {"action": "adjust_new", "target": entry["id"], "field": "do", "route": ROUTE_REDRAFT,
                "ending_ref": ender["id"]}
    return {"action": "edit", "target": other["id"], "field": "do", "route": _route(other),
            "ending_ref": ender["id"]}


def _row(base, kind, because, offer) -> dict:
    return {"ref": base["ref"], "kind": kind, "layer": base["layer"], "text": base["text"], "because": because,
            "offer": offer, "lines": base["lines"]}


def classify(entry, others, rows) -> list:
    """Classify only over ``rows``, the pairs the conflict check already listed, so no new pair is ever raised."""
    by_id = {o["id"]: o for o in others}
    out = []
    for base in rows:
        other = by_id[base["ref"]]
        reasons = {r["reason"]: r["detail"] for r in base["reasons"]}
        link = {"action": "link", "target": other["id"], "route": "relates_to"}
        moment = reasons.get("same_trigger") or reasons.get("shared_when")
        if moment:
            out.append(_row(base, "shared_moment", moment, link))
        if "shared_tool" in reasons:
            out.append(_row(base, "shared_tool", reasons["shared_tool"], link))
        situation = [w for r in SITUATION_REASONS for w in reasons.get(r, ())]
        offer = _ending_offer(entry, other) if situation else None
        if offer:
            out.append(_row(base, "ending_rule", sorted(set(situation)), offer))
    return out

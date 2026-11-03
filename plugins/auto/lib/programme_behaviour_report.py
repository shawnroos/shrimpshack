#!/usr/bin/env python3
"""The record-time check result: both comparisons, the answers Shawn or the PM gave, and what is left unanswered."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

behaviour_check = load_lib_module("programme_behaviour_check")
behaviour_synergy = load_lib_module("programme_behaviour_synergy")
contract_check = load_lib_module("programme_contract_check")
programme_sanitize = load_lib_module("programme_sanitize")


def answers(opts) -> tuple:
    related = list(dict.fromkeys(opts.get("relates-to") or []))
    unrelated = []
    for raw in opts.get("unrelated") or []:
        ref, sep, reason = raw.partition("=")
        if not sep or not reason.strip() or not ref.strip():
            raise behaviour_check.BehaviourError(f"--unrelated needs <id>=<reason>, got {raw!r}")
        unrelated.append({"id": ref.strip(), "reason": programme_sanitize.clean(reason)})
    return related, unrelated


def _without_lines(rows) -> list:
    return [{k: v for k, v in r.items() if k != "lines"} for r in rows]


def report(host, rec, entry, others, *, lines, given=((), ())) -> dict:
    snapshot = contract_check.snapshot(host, rec)
    peers = behaviour_check.check(entry, others)
    contract = contract_check.check(entry, snapshot)
    known = {o["id"] for o in others} | contract_check.refs(snapshot) | {r["ref"] for r in peers + contract}
    related, unrelated = given
    for ref in list(related) + [u["id"] for u in unrelated]:
        if ref not in known:
            raise behaviour_check.BehaviourError(f"no behaviour or contract part {ref!r} to answer for")
    answered = set(related) | {u["id"] for u in unrelated}
    synergies = behaviour_synergy.classify(entry, others, peers)
    for r in peers + contract + synergies:
        r["answered"] = r["ref"] in answered
    if not lines:
        peers, synergies = _without_lines(peers), _without_lines(synergies)
    return {"behaviours": peers, "contract": contract, "synergies": synergies,
            "unanswered": sum(r["ref"] not in answered for r in peers + contract),
            "checked": {"reasons": list(behaviour_check.REASONS), "synergies": list(behaviour_synergy.KINDS),
                        "not_detected": behaviour_check.NOT_DETECTED}}

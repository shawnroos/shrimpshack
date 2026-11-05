#!/usr/bin/env python3
"""The tail a worker brief or prompt carries: settled decisions, Rulings, restrictions, behaviours and limits."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_context = load_lib_module("programme_context")
programme_behaviours = load_lib_module("programme_behaviours")

REOPEN_CLAUSE = ("Proceed under this decision. Do not reopen it: if you find new evidence that it cannot "
                 "hold, stop and state that evidence in your pane.")


def _ruling_line(ruling) -> str:
    label = programme_context.ruling_kind_label(ruling)
    limits = "; ".join(ruling.get("limits") or []) or "none"
    until = f"; until {ruling['until']}" if ruling.get("until") else ""
    return (f"- ruling:{ruling['id']} ({label}, {ruling.get('effect')}): {ruling.get('scope')}; "
            f"reason: {ruling.get('reason') or 'none'}; limits: {limits}{until}")


def _decision_line(decision_id, logged, records) -> str:
    entry = logged.get(decision_id)
    if entry is not None:
        return (f"- {decision_id} ({entry.get('kind')}, decided by {entry.get('by') or 'unknown'}): "
                f"{entry.get('why') or 'no text recorded'}")
    current = programme_context.in_force(records.get(decision_id))
    if current is None:
        return None
    if programme_context.is_ruling(records.get(decision_id)):
        return _ruling_line(dict(current, id=decision_id))
    limits = "; ".join(current.get("limits") or []) or "none"
    return (f"- decision:{decision_id}@{current.get('rev')} (decision record): {current.get('scope')}; "
            f"reason: {current.get('reason')}; limits: {limits}")


def brief_tail(host, programme, key, decision_ids, restrictions, behaviours=(), *, rulings=False, limits=None,
               fills=None) -> str:
    """``limits`` defaults to ``rulings``: a start with no brief file has nowhere to put the limit lines."""
    logged = {d.get("id"): d for d in programme.get("decisions") or [] if isinstance(d, dict)}
    try:
        records = programme_context.block(programme)["decisions"]
    except programme_context.ContextError as exc:
        raise host.ProgrammeError(str(exc)) from None
    voided = [d for d in decision_ids if (logged.get(d) or {}).get("voided_at")]
    if voided:
        raise host.ProgrammeError(f"decision {', '.join(voided)} was voided when its ask's facts changed; "
                                  "cite the answer Shawn gave after the change")
    found = {d: _decision_line(d, logged, records) for d in decision_ids}
    unknown = [d for d, line in found.items() if line is None]
    if unknown:
        raise host.ProgrammeError(f"unknown decision id {', '.join(unknown)}: not in the decision log and no "
                                  "accepted decision record")
    now = run_record_core.parse_iso(run_record_core.now_iso())
    ended = [d for d in decision_ids if d not in logged and programme_context.is_ruling(records.get(d))
             and programme_context.ruling_state(records.get(d), now) == "expired"]
    if ended:
        raise host.ProgrammeError(f"Ruling {', '.join(ended)} is past its end date and settles nothing now; drop "
                                  "it from --decision or ask Shawn for a new Ruling")
    active = host.active_rulings(programme, run_record_core.now_iso()) if rulings else []
    carried = {r["id"]: r for r in active
               if r["id"] not in found and (key in r["applies_to"] or "programme" in r["applies_to"])}
    cited = {d: programme_context.in_force(records.get(d)) for d in decision_ids
             if d not in logged and programme_context.is_ruling(records.get(d))}
    levels = host.programme_protocol.AuthorityLevels(host.prompt_lookup)
    repos = host.programme_rulings.repos_for(programme, [key])
    conflicted = [rid for rid, r in {**cited, **carried}.items() if levels.conflicted(r, repos)]
    lines = []
    settled = [found[d] for d in decision_ids if d not in conflicted]
    settled += [_ruling_line(r) for rid, r in carried.items() if rid not in conflicted]
    if settled:
        lines.append("Settled decisions this work carries:")
        lines += settled
        lines.append(REOPEN_CLAUSE)
    if conflicted:
        lines.append("Rulings Authority now holds narrower than when Shawn gave them (do not act on these):")
        lines += [f"{found[rid] if rid in found else _ruling_line(carried[rid])}; conflicted: wait for Shawn"
                  for rid in conflicted]
    if restrictions:
        lines.append("Restrictions on this work:")
        lines += [f"- {r['text']} (source: {r['source']})" for r in restrictions]
    lines += programme_behaviours.brief_lines(behaviours, fills)
    if limits or (limits is None and rulings):
        lines += load_lib_module("programme_checks").brief_lines(programme, key)
    return "\n\n" + "\n".join(lines) if lines else ""

#!/usr/bin/env python3
"""Which parts of the programme contract a new behaviour touches, and which it may contradict.

The input is the ``rules_in_force`` snapshot. A behaviour carries no authority, so a row is
information for the PM and Shawn: ``may_contradict`` marks a structural clash, never a refusal.
The operating contract line is read but never becomes a row, because it applies to every behaviour.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

behaviour_check = load_lib_module("programme_behaviour_check")

# A level of "act" lets the PM decide, so only a stricter level reserves the kind for Shawn.
PM_DECIDES = "act"
NEGATIONS = ("not", "never", "avoid", "dont", "no")
SKIPS = ("skip", "without", "ignore", "omit")
CADENCE_WORDS = ("sweep", "every", "cadence", "wake")
STEM = 6
# A kind such as merge_at_gate drops "at": a two-letter stem would match any word that starts with it.
MIN_KIND_WORD = 3
CLAUSE_BREAKS = ",;.:"


def _row(ref, kind, reason, detail, text, flag=False, **extra) -> dict:
    out = {"ref": ref, "kind": kind, "reasons": [{"reason": reason, "detail": detail}], "text": text, **extra}
    if flag:
        out["flag"] = "may_contradict"
    return out


def _instruction_text(entry) -> str:
    return " ".join((entry.get("do") or []) + (entry.get("dont") or []) + [entry.get("stop") or ""])


def _starts(words, stem) -> bool:
    return any(w.startswith(stem) for w in words)


def _touches_kind(kind, words) -> bool:
    stems = [w[:STEM] for w in str(kind).split("_") if len(w) >= MIN_KIND_WORD]
    return bool(stems) and all(_starts(words, s) for s in stems)


def _clauses(text) -> list:
    clean = text
    for mark in CLAUSE_BREAKS:
        clean = clean.replace(mark, "|")
    return [behaviour_check.tokens(c) for c in clean.split("|") if c.strip()]


def _terms(entry, snapshot) -> list:
    terms = ((snapshot.get("agreement") or {}).get("terms")) or {}
    words = set(behaviour_check.tokens(_instruction_text(entry) + " " + entry["when"]["text"]))
    rows = []
    for key in ("cadence", "remit"):
        hit = [w for w in words if any(w.startswith(c) for c in (CADENCE_WORDS if key == "cadence" else ("remit",)))]
        if key in terms and hit:
            rows.append(_row("term:" + key, "term", "names_subject", sorted(hit), f"{key}: {terms[key].get('value')}"))
    stop_rule = terms.get("stop_rule")
    if stop_rule and entry.get("stop"):
        rule_words = behaviour_check.content_words(str(stop_rule.get("value")).replace("_", " "))
        shared = sorted(behaviour_check.content_words(entry["stop"]) & rule_words)
        rows.append(_row("term:stop_rule", "term", "names_subject", ["stop"], f"stop rule: {stop_rule.get('value')}",
                         flag=len(shared) >= behaviour_check.WORD_FLOOR))
    of_record = terms.get("tools_of_record")
    if of_record:
        named = set(behaviour_check._named(entry))
        hit = sorted(named & {" ".join(behaviour_check.tokens(t)) for t in of_record.get("value") or []})
        if hit:
            rows.append(_row("term:tools_of_record", "term", "names_tool", hit, f"tools of record: {of_record.get('value')}"))
    return rows


def _preferred_tools(entry, snapshot) -> list:
    rows = []
    named = behaviour_check._named(entry)
    for term in ((snapshot.get("operating_contract") or {}).get("project_terms")) or []:
        clauses = _clauses(str(term.get("value")))
        hit, flagged = [], False
        for key, label in named.items():
            needed = set(key.split())
            for clause in clauses:
                if needed <= set(clause):
                    hit.append(label)
                    flagged = flagged or bool(set(clause) & set(NEGATIONS))
        if hit:
            rows.append(_row("tool:" + str(term.get("id")), "preferred_tool", "names_tool", sorted(set(hit)),
                             f"{term.get('area')}: {term.get('value')}", flag=flagged))
    return rows


def _rulings(entry, snapshot) -> list:
    words = set(behaviour_check.tokens(" ".join(entry.get("do") or [])))
    rows = []
    for ruling in snapshot.get("rulings") or []:
        if ruling.get("kind") and _touches_kind(ruling["kind"], words):
            rows.append(_row("ruling:" + str(ruling["id"]), "ruling", "reserved_kind", [ruling["kind"]],
                             f"{ruling.get('effect')} {ruling['kind']}: {ruling.get('quote') or ruling.get('scope')}",
                             flag=ruling.get("effect") == "restrict"))
    return rows


def _authority(entry, snapshot) -> list:
    words = set(behaviour_check.tokens(" ".join(entry.get("do") or [])))
    return [_row("authority:" + a["action"], "authority", "reserved_kind", [a["action"]],
                 f"{a['action']}: {a['level']}", flag=True)
            for a in snapshot.get("autonomy") or []
            if a.get("level") != PM_DECIDES and _touches_kind(a["action"], words)]


def _done_standards(entry, snapshot) -> list:
    lines = (entry.get("do") or []) + (entry.get("dont") or [])
    clauses = [c for line in lines for c in _clauses(line)]
    by_deliverable = {}
    for rule in snapshot.get("rules") or []:
        for deliverable in rule.get("requires") or []:
            by_deliverable.setdefault(deliverable, []).append(rule["id"])
    rows = []
    for deliverable, ids in sorted(by_deliverable.items()):
        stem = deliverable[:5]
        hit = [c for c in clauses if _starts(c, stem)]
        if hit:
            skipped = any(set(c) & set(SKIPS) for c in hit)
            rows.append(_row("done:" + deliverable, "done", "names_deliverable", [deliverable],
                             f"{len(ids)} Done standard(s) require {deliverable}", flag=skipped, ids=sorted(ids)))
    return rows


def check(entry, snapshot) -> list:
    return (_terms(entry, snapshot) + _preferred_tools(entry, snapshot) + _rulings(entry, snapshot)
            + _authority(entry, snapshot) + _done_standards(entry, snapshot))


def refs(snapshot) -> set:
    """Every contract ref the snapshot can produce, so an answer can name a part the check did not list."""
    out = {"term:" + k for k in ((snapshot.get("agreement") or {}).get("terms")) or {}}
    out |= {"tool:" + str(t.get("id")) for t in ((snapshot.get("operating_contract") or {}).get("project_terms")) or []}
    out |= {"ruling:" + str(r["id"]) for r in snapshot.get("rulings") or []}
    out |= {"authority:" + a["action"] for a in snapshot.get("autonomy") or []}
    out |= {"done:" + d for r in snapshot.get("rules") or [] for d in r.get("requires") or []}
    return out

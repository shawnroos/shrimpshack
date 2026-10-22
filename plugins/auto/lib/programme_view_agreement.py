#!/usr/bin/env python3
"""The agreement page: Scope and Rulings for this programme, beside the shared Authority and Done standards."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_context = load_lib_module("programme_context")
programme_decisions = load_lib_module("programme_decisions")
programme_journal = load_lib_module("programme_journal")
programme_protocol = load_lib_module("programme_protocol")
programme_protocol_changes = load_lib_module("programme_protocol_changes")
programme_terms = load_lib_module("programme_terms")
programme_view_work = load_lib_module("programme_view_work")

SCOPE_TERMS = (("remit", "remit"), ("stop_rule", "stop rule"), ("cadence", "cadence and budget"),
               ("tools_of_record", "sources watched"))
RULING_STATES = ("active", "pending", "carried", "expired")
CHANGES_LIMIT = 20
CHANGE_KINDS = (programme_terms.EDITED, programme_terms.AMENDED)

_dict = programme_view_work._dict
_section = programme_view_work._section
_row = programme_view_work._row


def _scope_text(key, term) -> str:
    text = programme_view_work._value_text(term)
    if key == "cadence" and term.get("eval_budget_usd_per_day") is not None:
        text += f", eval budget {term['eval_budget_usd_per_day']} USD a day"
    return text


def _scope(block) -> list:
    terms = _dict(_dict(block.get("agreement")).get("terms"))
    return [{"key": key, "label": label, "value_text": _scope_text(key, _dict(terms[key]))}
            for key, label in SCOPE_TERMS if key in terms]


def _preferred_tools(block) -> list:
    return [{k: e.get(k) for k in ("id", "area", "value", "source")} for e in programme_home.project_terms(block)]


def _state(revisions, now) -> str:
    state = programme_context.ruling_state(revisions, now)
    last = _dict((revisions or [None])[-1])
    return "carried" if state == "pending" and last.get("carried") else state


def rulings(block, now=None) -> list:
    try:
        decisions = programme_context.block(block)["decisions"]
    except programme_context.ContextError:
        return []
    when = run_record_core.parse_iso(now) if isinstance(now, str) else now
    out = []
    for rid, revisions in decisions.items():
        state = _state(revisions, when)
        if state not in RULING_STATES:
            continue
        shown = programme_context.in_force(revisions) or programme_context.pending(revisions)
        carried = _dict(_dict((revisions or [None])[-1]).get("carried"))
        waiting = programme_context.pending(revisions) if state == "active" else None
        out.append({"id": rid, "state": state, "effect": shown.get("effect") or "decided", "kind": shown.get("kind"),
                    "legacy": shown.get("legacy"), "quote": shown.get("quote") or shown.get("scope"),
                    "applies_to": list(shown.get("applies_to") or []), "until": shown.get("until"),
                    "carried": {k: carried.get(k) for k in ("from", "run_id")} if carried else None,
                    "pending_rev": _dict(waiting).get("rev")})
    return sorted(out, key=lambda r: (RULING_STATES.index(r["state"]), r["id"]))


def _authority(protocol) -> list:
    protected = programme_decisions.PROTECTED_KINDS
    out = [{"kind": kind, "level": "never", "layer": "code", "fixed": True} for kind in protected]
    out += [{"kind": kind, "level": _dict(entry).get("level"), "layer": _dict(entry).get("layer"),
             "adopted_on": _dict(entry).get("adopted_on"), "fixed": False}
            for kind, entry in sorted(_dict(protocol.get("autonomy")).items()) if kind not in protected]
    return out


def _done_standards(rules, protocol) -> list:
    if rules.get("rules"):
        return [{k: _dict(r).get(k) for k in ("id", "layer", "requires", "adopted_on")} for r in rules["rules"]]
    return [{"id": rid, "layer": _dict(r).get("layer"), "requires": list(_dict(r).get("requires") or []),
             "adopted_on": _dict(r).get("adopted_on")} for rid, r in sorted(_dict(protocol.get("rules")).items())]


def ruling_label(ruling) -> str:
    kind = ruling.get("kind")
    if kind:
        head = f"{ruling['effect']} {kind}"
    else:
        head = f"{ruling['effect']}, no kind ({programme_context.ruling_kind_label(ruling, 'decision record')})"
    return f"{head} \"{ruling.get('quote')}\""


def _labels(block, shown) -> dict:
    labels = {r["id"]: ruling_label(r) for r in shown}
    for t in programme_home.project_terms(block):
        labels.setdefault(t.get("id"), f"preferred tool {t.get('area')}: {t.get('value')}")
    for key in _dict(_dict(block.get("agreement")).get("terms")):
        labels.setdefault(key, f"term {key.replace('_', ' ')}")
    return labels


def _by_ruling(block, shown) -> list:
    labels = _labels(block, shown)
    groups = {}
    for entry in block.get("decisions") or []:
        entry = _dict(entry)
        cited = None if entry.get("silent") else entry.get("term")
        groups.setdefault(cited, []).append({k: entry.get(k) for k in ("id", "at", "kind", "by", "item", "ask", "why")})
    order = [rid for rid in labels if rid in groups] + sorted(r for r in groups if r is not None and r not in labels)
    out = [{"ruling": rid, "label": labels.get(rid, "not in the record"), "decisions": groups[rid]} for rid in order]
    if None in groups:
        out.append({"ruling": None, "label": "no Ruling applied", "decisions": groups[None]})
    return out


def _changes(journal_entries) -> list:
    out = []
    for row in journal_entries:
        if not isinstance(row, dict) or row.get("kind") not in CHANGE_KINDS:
            continue
        p = _dict(row.get("payload"))
        was = f"{p['previous']} -> " if p.get("previous") else ""
        prompt_id = p.get("prompt_id")
        out.append({"at": row.get("at"), "kind": row["kind"], "term": p.get("term_id"),
                    "text": f"{p.get('area')}: {was}{p.get('value')}",
                    "source": p.get("source") or (f"typed prompt {prompt_id}" if prompt_id else "the PM"),
                    "prompt_id": prompt_id, "quote": programme_journal.redact(p["quote"]) if p.get("quote") else None})
    return out[::-1]


def build(block, journal_entries, rules, protocol=None, now=None) -> dict:
    if protocol is None:
        protocol = programme_protocol.load()
    agreement = _dict(block.get("agreement"))
    shown = rulings(block, now)
    changes = _changes(journal_entries or [])
    return {
        "accepted": _dict(agreement.get("accepted")).get("at"),
        "contract_version": agreement.get(programme_decisions.STAMP_KEY),
        "scope": _scope(block),
        "preferred_tools": _preferred_tools(block),
        "rulings": shown,
        "authority": _authority(protocol),
        "done_standards": _done_standards(_dict(rules), protocol),
        "protocol_changes": programme_protocol_changes.lines(_dict(rules).get("protocol_changes")),
        "decisions_by_ruling": _by_ruling(block, shown),
        "changes": changes[:CHANGES_LIMIT],
        "changes_total": len(changes),
    }


def _applies(ruling) -> str:
    if ruling["state"] == "carried":
        c = _dict(ruling.get("carried"))
        return f"from {c.get('run_id')} under {c.get('from')}; names no items yet"
    text = f"applies to {', '.join(ruling['applies_to']) or 'no items'}"
    text += f", until {ruling['until']}" if ruling.get("until") else ""
    return text + (f"; revision {ruling['pending_rev']} pending" if ruling.get("pending_rev") else "")


def _authority_row(a) -> dict:
    if a["fixed"]:
        return _row(f"  {a['kind']}: never (fixed in code)", "dim")
    adopted = f", adopted on {a['adopted_on']}" if a.get("adopted_on") else ""
    return _row(f"  {a['kind']}: {a['level']} ({a['layer']}{adopted})")


def _change_row(c) -> dict:
    quote = f" · Shawn: \"{c['quote']}\"" if c.get("quote") else ""
    return _row(f"  {c['at']} {c['kind']} {c['term']}: {c['text']} · source {c['source']}{quote}", "dim")


def rows(page, remit_lines=()) -> list:
    version = page.get("contract_version")
    head = "Agreement" + (f" (operating contract v{version})" if version else "")
    out = [_row(f"{head}: " + (f"accepted {page['accepted']}" if page.get("accepted") else "not accepted"), "title")]
    scope = []
    for s in page["scope"]:
        scope.append(_row(f"  {s['label']}: {s['value_text']}"))
        scope += [_row(f"    {text}", "dim") for text in (remit_lines if s["key"] == "remit" else ())]
    scope += [_row(f"  preferred tool {t['id']} {t['area']}: {t['value']} (source {t.get('source') or 'none recorded'})")
              for t in page["preferred_tools"]]
    _section(out, "Scope", scope, "no terms")
    _section(out, "Rulings", [_row(f"  {r['state']} {r['id']}: {ruling_label(r)} ({_applies(r)})",
                                   "text" if r["state"] == "active" else "warn" if r["state"] != "expired" else "dim")
                              for r in page["rulings"]], "no Rulings")
    _section(out, "Authority", [_authority_row(a) for a in page["authority"]], "none")
    _section(out, "Done standards", [_row(f"  {d['id']}: requires {', '.join(d.get('requires') or []) or 'nothing'} "
                                          f"({d.get('layer')})") for d in page["done_standards"]], "none")
    if page["protocol_changes"]:
        _section(out, "Protocol changes", [_row(f"  {line}", "warn") for line in page["protocol_changes"]], "none")
    _section(out, "Decisions by Ruling",
             [line for g in page["decisions_by_ruling"] for line in
              [_row(f"  {g['ruling'] + ' ' if g['ruling'] else ''}{g['label']}")]
              + [_row(f"    {d['id']} {d['kind']} by {d['by']}" + (f" (ask {d['ask']})" if d.get("ask") else "")
                      + f": {d['why']}", "dim") for d in g["decisions"]]],
             "none recorded")
    hidden = page["changes_total"] - len(page["changes"])
    _section(out, "Recent term changes", [_change_row(c) for c in page["changes"]]
             + ([_row(f"  {hidden} older changes not shown", "dim")] if hidden else []), "none")
    return out

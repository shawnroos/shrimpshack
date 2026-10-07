#!/usr/bin/env python3
"""The programme read model: one build feeds `status`, views/view.json and the mod."""

from __future__ import annotations

import datetime
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_predicate = load_lib_module("programme_predicate")
programme_sanitize = load_lib_module("programme_sanitize")
session_registry = load_lib_module("session_registry")

VIEW_FORMAT = 1
JUST_DID_LIMIT = 8
HIDDEN_KINDS = ("prompt",)
SUMMARY_KEYS = ("text", "question", "term", "value", "rule", "deliverable", "result",
                "action", "op", "choice", "reason", "source", "instruction")


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def _iso(now) -> str:
    return now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clean(value):
    if isinstance(value, str):
        return programme_sanitize.clean(value)
    if isinstance(value, dict):
        return {programme_sanitize.clean(k, cap=0): _clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    return value


def _stopped_unwatched(journal_entries) -> set:
    items = set()
    for row in journal_entries:
        if _dict(row).get("kind") == "stopped_unwatched":
            items.update(i for i in _dict(row.get("payload")).get("items") or [] if isinstance(i, str))
    return items


def _session_state(owner) -> str:
    sid = owner.get("session_id")
    if not sid:
        return "session unknown"
    try:
        row = session_registry.lookup(sid, include_headless=True)
    except Exception:
        row = None
    if not row:
        return f"session {sid} not seen"
    return f"session {sid} seen {row.get('at')} in pane {row.get('pane_id')}"


def _evidence(item) -> str:
    deliverables = _dict(item.get("deliverables"))
    if not item.get("matched_rule"):
        return "no rule matched"
    if not deliverables:
        return "no deliverables"
    confirmed = sum(1 for d in deliverables.values() if _dict(d).get("result") == "confirmed")
    return f"{confirmed} of {len(deliverables)} confirmed"


def _item_view(item_id, item, status, flagged) -> dict:
    owner = _dict(item.get("owner"))
    marks = []
    if item_id in status["new_items"]:
        marks.append("new")
    stopped = item_id in flagged and item_id in status["unwatched_waits"]
    if stopped:
        marks.append("stopped unwatched")
    handed = _dict(item.get("handed"))
    effective = programme_predicate.effective_state(item)
    return {
        "id": item_id,
        "title": item.get("title") or "",
        "state": item.get("state"),
        "effective_state": effective,
        "owner_pane": owner.get("pane"),
        "session": _session_state(owner),
        "deliverables": [{"name": name, "result": _dict(d).get("result"), "ref": _dict(d).get("ref"),
                          "checked_at": _dict(d).get("checked_at"), "misses": _dict(d).get("misses")}
                         for name, d in sorted(_dict(item.get("deliverables")).items())],
        "evidence": _evidence(item),
        "waiting_on": item.get("waiting_on") if effective == "waiting" else None,
        "question": handed.get("question") if effective == "handed" else None,
        "marks": marks,
        "needs_shawn": stopped or (effective == "handed" and not handed.get("answered")),
    }


def _watching(block, status, now, cadence) -> list:
    out = []
    for watcher_id, watcher in sorted(_dict(block.get("watchers")).items()):
        watcher = _dict(watcher)
        retry = _dict(watcher.get("retry"))
        why = f"retries {retry.get('deliverable')}" if retry else "watches its item"
        out.append({"watcher": watcher_id, "item": watcher.get("item"),
                    "live": programme_predicate.watcher_live(watcher, now, cadence),
                    "last_beat_at": watcher.get("last_beat_at"), "why": why})
    for item_id in status["unwatched_waits"]:
        out.append({"watcher": None, "item": item_id, "live": False, "last_beat_at": None,
                    "why": "nothing watches this wait"})
    for name, source in sorted(_dict(block.get("sources")).items()):
        since = _dict(source).get("unavailable_since")
        if since:
            out.append({"watcher": _dict(source).get("watcher"), "item": None, "source": name,
                        "live": False, "last_beat_at": None, "why": f"{name} unavailable since {since}"})
    return out


def _decisions(block, items) -> list:
    out = [{"kind": "handed", "item": i["id"], "question": i["question"]}
           for i in items if i["effective_state"] == "handed" and i["needs_shawn"]]
    out += [{"kind": "stopped_unwatched", "item": i["id"],
             "question": "the PM stopped while this wait had no watcher"}
            for i in items if "stopped unwatched" in i["marks"]]
    for rule in block.get("proposed_rules") or []:
        rule = _dict(rule)
        out.append({"kind": "proposed_rule", "item": None, "rule": rule.get("id"),
                    "question": f"adopt rule {rule.get('id')}?"})
    if not block.get("ended") and not _dict(block.get("agreement")).get("accepted"):
        out.append({"kind": "agreement", "item": None, "question": "accept the agreement?"})
    return out


def _just_did(journal_entries) -> list:
    rows = [r for r in journal_entries if isinstance(r, dict) and r.get("kind") not in HIDDEN_KINDS]
    out = []
    for row in reversed(rows[-JUST_DID_LIMIT:]):
        payload = _dict(row.get("payload"))
        item = payload.get("item") or (payload.get("items") or [None])[0]
        bits = [f"{k}={payload[k]}" for k in SUMMARY_KEYS
                if isinstance(payload.get(k), (str, int, float)) and not isinstance(payload.get(k), bool)]
        doing = _dict(payload.get("doing"))
        if doing.get("text"):
            bits.insert(0, doing["text"])
        entry = {"at": row.get("at"), "kind": row.get("kind"), "item": item,
                 "summary": "; ".join(bits), "repeats": 1}
        last = out[-1] if out else {}
        if all(last.get(k) == entry[k] for k in ("kind", "item", "summary")):
            last["repeats"] += 1
            continue
        out.append(entry)
    return out


def _rules(block, rules) -> dict:
    if rules is not None:
        return rules
    terms = _dict(_dict(block.get("agreement")).get("terms"))
    return {"agreement": {"accepted": _dict(block.get("agreement")).get("accepted"),
                          "terms": {k: {"value": _dict(t).get("value"), "set_by": _dict(t).get("set_by")}
                                    for k, t in sorted(terms.items())}},
            "rules": [], "rejected_rules": [], "instructions": []}


def build(record, journal_entries, now=None, *, inbox_size=None, rules=None) -> dict:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    block = programme_home.normalize_programme(_dict(record.get("programme")))
    status = programme_predicate.compute(record, now, inbox_size)
    flagged = _stopped_unwatched(journal_entries or [])
    items = [_item_view(i, block["items"][i], status, flagged) for i in sorted(block["items"])]
    waits = [{"item": w.get("item"), "system": w.get("system"), "who": w.get("who") or "system",
              "reporter": w.get("reporter"), "watched": bool(w.get("watched"))}
             for w in status["waits"]]
    working = _dict(block.get("working_model"))
    offset = block.get("inbox_offset") or 0
    model = {
        "programme": {
            "run": record.get("run_id"),
            "ended": block.get("ended"),
            "done": status["done"],
            "may_stop": status["may_stop"],
            "stop_rule": status["stop_rule"],
            "reasons": [r.get("kind") for r in status["reasons"]],
            "counts": status["items"],
            "unread_claims": max(inbox_size - offset, 0) if isinstance(inbox_size, int) else None,
        },
        "doing_now": working.get("doing"),
        "queue": [_dict(e) for e in working.get("queue") or []],
        "watching": _watching(block, status, now, programme_home.cadence_seconds(record)),
        "waiting_on_whom": waits,
        "decisions_for_shawn": _decisions(block, items),
        "just_did": _just_did(journal_entries or []),
        "rules_in_force": _rules(block, rules),
        "items": items,
    }
    model = _clean(model)
    return {"view_format": VIEW_FORMAT, "run": model["programme"]["run"], "generated_at": _iso(now),
            "model": model, "rows": rows(model)}


def _yes(flag) -> str:
    return "yes" if flag else "no"


def _section(out, title, lines, empty) -> None:
    out.append({"style": "head", "text": title})
    out.extend(lines or [{"style": "dim", "text": f"  {empty}"}])


def _row(text, style="text") -> dict:
    return {"style": style, "text": text}


def _header(p) -> dict:
    stop = f"may stop: {_yes(p['may_stop'])}"
    if p["reasons"]:
        stop += f" ({', '.join(p['reasons'])})"
    text = f"Programme {p['run']} · done: {_yes(p['done'])} · {stop}"
    if p["ended"]:
        text += f" · ended: {_dict(p['ended']).get('reason')}"
    return _row(text, "title")


def _rule_lines(r) -> list:
    out = []
    for key, term in sorted(_dict(_dict(r.get("agreement")).get("terms")).items()):
        term = _dict(term)
        why = f" — {term['why']}" if term.get("why") else ""
        out.append(_row(f"  {key}: {term.get('value')} ({term.get('set_by')}){why}"))
    for rule in r.get("rules") or []:
        out.append(_row(f"  rule {rule.get('id')}: {rule.get('autonomy')}, requires "
                        f"{', '.join(rule.get('requires') or []) or 'nothing'}"))
    for rule in r.get("rejected_rules") or []:
        out.append(_row(f"  rejected rule {rule.get('id')}: {rule.get('reason')}", "warn"))
    for entry in r.get("instructions") or []:
        out.append(_row(f"  instruction {entry.get('id')} ({entry.get('applies_to')}): "
                        f"\"{entry.get('quote')}\""))
    return out


def _item_lines(item) -> list:
    marks = "".join(f" [{m}]" for m in item["marks"])
    out = [_row(f"  {item['id']}  {item['effective_state']}  {item['title']}{marks}",
                "warn" if item["needs_shawn"] else "text")]
    detail = [f"owner {item['owner_pane'] or 'none'}", item["session"], f"evidence {item['evidence']}"]
    if item["needs_shawn"]:
        detail.insert(0, "needs Shawn")
    out.append(_row("    " + " · ".join(detail), "dim"))
    for d in item["deliverables"]:
        ref = f" {d['ref']}" if d.get("ref") else ""
        out.append(_row(f"    {d['name']}: {d['result']}{ref}", "dim"))
    return out


def rows(model) -> list:
    out = [_header(model["programme"])]
    doing = model["doing_now"]
    _section(out, "Doing now", doing and [_row(f"  {doing.get('text')}"
                                               + (f" ({doing['item']})" if doing.get("item") else ""))],
             "nothing")
    _section(out, "Queue", [_row(f"  {e.get('action')} {e.get('item') or ''}".rstrip()
                                 + (f": {e['why']}" if e.get("why") else ""))
                            for e in model["queue"]], "empty")
    _section(out, "Watching", [_row(f"  {w.get('item') or w.get('source')}: "
                                    f"{w['watcher'] or 'no watcher'}"
                                    f"{' (live)' if w['live'] else ''} — {w['why']}",
                                    "text" if w["live"] else "warn")
                               for w in model["watching"]], "nothing")
    _section(out, "Who waits on whom", [_row(f"  {w['item'] or w['system']} waits on {w['who']} "
                                             f"({'watched' if w['watched'] else 'unwatched'})",
                                             "text" if w["watched"] else "warn")
                                        for w in model["waiting_on_whom"]], "nobody")
    _section(out, "Decisions for Shawn", [_row(f"  {d.get('item') or d['kind']}: {d['question']}", "warn")
                                          for d in model["decisions_for_shawn"]], "none")
    _section(out, "Just did", [_row(f"  {j['at']} {j['kind']}"
                                    + (f" {j['item']}" if j.get("item") else "")
                                    + (f": {j['summary']}" if j.get("summary") else "")
                                    + (f" (x{j['repeats']})" if j["repeats"] > 1 else ""), "dim")
                               for j in model["just_did"]], "nothing yet")
    _section(out, "Rules in force", _rule_lines(model["rules_in_force"]), "none")
    _section(out, "Items", [line for item in model["items"] for line in _item_lines(item)], "no items")
    return out


def render_text(view) -> str:
    return "\n".join(r["text"] for r in view["rows"])

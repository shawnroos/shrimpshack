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
programme_tasks = load_lib_module("programme_tasks")
session_registry = load_lib_module("session_registry")

VIEW_FORMAT = 1
JUST_DID_LIMIT = 8
HIDDEN_KINDS = ("prompt",)
REMIT_WATCHER = "remit"
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


def _sessions(items) -> dict:
    if not any(_dict(_dict(item).get("owner")).get("session_id") for item in items.values()):
        return {}
    try:
        return session_registry.latest_rows(include_headless=True)
    except Exception:
        return {}


def _session_state(owner, sessions) -> str:
    sid = owner.get("session_id")
    if not sid:
        return "session unknown"
    try:
        row = sessions.get(sid)
    except TypeError:
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


def _tasks_now(owner, tasks_on):
    if not tasks_on or not owner.get("session_id"):
        return None
    summary = programme_tasks.read_session(owner["session_id"])
    if not summary["total"]:
        return None
    counts = summary["counts"]
    tally = f"{counts['completed']}/{summary['total']} tasks done"
    return f"now: {summary['now']} ({tally})" if summary["now"] else tally


def _item_view(item_id, item, status, flagged, sessions, tasks_on=False) -> dict:
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
        "session": _session_state(owner, sessions),
        "deliverables": [{"name": name, "result": _dict(d).get("result"), "ref": _dict(d).get("ref"),
                          "checked_at": _dict(d).get("checked_at"), "misses": _dict(d).get("misses")}
                         for name, d in sorted(_dict(item.get("deliverables")).items())],
        "evidence": _evidence(item),
        "waiting_on": item.get("waiting_on") if effective == "waiting" else None,
        "question": handed.get("question") if effective == "handed" else None,
        "now": _tasks_now(owner, tasks_on) if effective not in programme_home.FINISHED_ITEM_STATES else None,
        "marks": marks,
        "needs_shawn": stopped or (effective == "handed" and not handed.get("answered")),
    }


def _cadence_text(seconds) -> str:
    if seconds == 3600:
        return "hourly"
    if seconds % 3600 == 0:
        return f"every {seconds // 3600} hours"
    if seconds % 60 == 0:
        return f"every {seconds // 60} minutes"
    return f"every {seconds}s"


def _watches(watcher_id, watcher, sources, cadence) -> str:
    retry = _dict(watcher.get("retry"))
    if retry:
        return f"retries {retry.get('deliverable')}"
    if watcher.get("item"):
        return "watches its item"
    if watcher_id == REMIT_WATCHER:
        return "watches the space"
    named = [name for name, source in sorted(sources.items()) if _dict(source).get("watcher") == watcher_id]
    if named:
        return "watches source " + ", ".join(named)
    if programme_home.watcher_kind(watcher) == "cron":
        return f"{_cadence_text(cadence)} fallback"
    return "watches nothing recorded"


def _watching(block, status, now, cadence) -> list:
    out = []
    watchers = _dict(block.get("watchers"))
    sources = _dict(block.get("sources"))
    for watcher_id, watcher in sorted(watchers.items()):
        watcher = _dict(watcher)
        out.append({"watcher": watcher_id, "item": watcher.get("item"),
                    "live": programme_predicate.watcher_live(watcher, now, cadence),
                    "last_beat_at": watcher.get("last_beat_at"),
                    "why": _watches(watcher_id, watcher, sources, cadence)})
    for item_id in status["unwatched_waits"]:
        out.append({"watcher": None, "item": item_id, "live": False, "last_beat_at": None,
                    "why": "nothing watches this wait"})
    enabled = programme_home.enabled_sources(block)
    for name in programme_home.SWEEP_SOURCES:
        source = _dict(sources.get(name))
        if name not in enabled:
            out.append(_source_row(name, "off: turned off in the agreement", style="dim"))
        elif source.get("unsupported_since"):
            out.append(_source_row(name, "not available on this machine", style="dim"))
        elif not source.get("unavailable_since"):
            via = f" via {source['provider']}" if source.get("provider") else ""
            out.append(_source_row(name, f"available{via}" if source else "not read yet", style="text"))
    for name, source in sorted(sources.items()):
        source = _dict(source)
        sweep_source = name in programme_home.SWEEP_SOURCES
        if sweep_source and (name not in enabled or source.get("unsupported_since")):
            continue
        if source.get("unsupported_since"):
            out.append({"watcher": None, "item": None, "source": name, "live": False, "last_beat_at": None,
                        "unsupported": True, "why": "not available on this machine"})
            continue
        since = source.get("unavailable_since")
        if since:
            named = source.get("watcher")
            out.append({"watcher": named, "item": None, "source": name,
                        "live": bool(named) and programme_predicate.watcher_live(watchers.get(named), now, cadence),
                        "last_beat_at": None, "why": f"{name} unavailable since {since}"})
    return out


def _source_row(name, why, style) -> dict:
    return {"watcher": None, "item": None, "source": name, "live": False, "last_beat_at": None,
            "state_only": style, "why": why}


def _watching_row(w) -> dict:
    live = " (live)" if w["live"] else ""
    if w.get("state_only"):
        return _row(f"  {w['source']}: {w['why']}", w["state_only"])
    if w.get("unsupported"):
        return _row(f"  {w['source']}: {w['why']}", "dim")
    if w.get("item") or w.get("source"):
        text = f"  {w.get('item') or w.get('source')}: {w['watcher'] or 'no watcher'}{live} — {w['why']}"
    else:
        text = f"  {w['watcher']}{live} — {w['why']}"
    return _row(text, "text" if w["live"] else "warn")


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
            "rules": [], "autonomy": [], "rejected_rules": [], "instructions": []}


def build(record, journal_entries, now=None, *, inbox_size=None, rules=None) -> dict:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    block = programme_home.normalize_programme(_dict(record.get("programme")))
    status = programme_predicate.compute(record, now, inbox_size)
    flagged = _stopped_unwatched(journal_entries or [])
    sessions = _sessions(block["items"])
    tasks_on = "tasks" in programme_home.enabled_sources(block)
    items = [_item_view(i, block["items"][i], status, flagged, sessions, tasks_on) for i in sorted(block["items"])]
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
        "remit": {key: _dict(block["remit"]).get(key) for key in ("spaces", "repos", "tracker")},
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


def _adopted_on(entry) -> str:
    return f", adopted on {entry['adopted_on']}" if entry.get("adopted_on") else ""


def _term_text(key, term) -> str:
    extras = [f"{name} {term[name]}" for name in ("until", "seconds") if term.get(name) is not None]
    value = term.get("value")
    if isinstance(value, list):
        value = ", ".join(str(v) for v in value) or "none"
    return f"{key}: {value}" + "".join(f", {e}" for e in extras)


def _instruction_text(entry) -> str:
    scope = f"applies to {entry.get('applies_to') or 'programme'}"
    if entry.get("until"):
        scope += f", until {entry['until']}"
    return f"instruction {entry.get('id')}: \"{entry.get('quote')}\" ({scope})"


def _rule_text(rule) -> str:
    text = (f"rule {rule.get('id')}: {rule.get('autonomy')}, requires "
            f"{', '.join(rule.get('requires') or []) or 'nothing'}{_adopted_on(rule)}")
    return text + (f"; caveat: {rule['caveat']}" if rule.get("caveat") else "")


def rule_texts(r) -> list:
    agreement = _dict(r.get("agreement"))
    accepted = _dict(agreement.get("accepted"))
    out = [("agreement: " + (f"accepted {accepted.get('at')}" if accepted else "not accepted"), "text")]
    out += [(_term_text(key, _dict(term)), "text") for key, term in sorted(_dict(agreement.get("terms")).items())]
    out += [(_instruction_text(_dict(e)), "text") for e in r.get("instructions") or []]
    out += [(_rule_text(_dict(rule)), "text") for rule in r.get("rules") or []]
    out += [(f"autonomy {_dict(e).get('action')}: {_dict(e).get('level')}{_adopted_on(_dict(e))}", "text")
            for e in r.get("autonomy") or []]
    rejected = [str(_dict(rule).get("id")) for rule in r.get("rejected_rules") or []]
    if rejected:
        out.append((f"rejected rules: {len(rejected)} ({', '.join(rejected)})", "warn"))
    return [(programme_sanitize.clean(text, cap=0), style) for text, style in out]


def _item_lines(item) -> list:
    marks = "".join(f" [{m}]" for m in item["marks"])
    out = [_row(f"  {item['id']}  {item['effective_state']}  {item['title']}{marks}",
                "warn" if item["needs_shawn"] else "text")]
    detail = [f"owner {item['owner_pane'] or 'none'}", item["session"], f"evidence {item['evidence']}"]
    if item["needs_shawn"]:
        detail.insert(0, "needs Shawn")
    out.append(_row("    " + " · ".join(detail), "dim"))
    if item.get("now"):
        out.append(_row(f"    {item['now']}", "dim"))
    for d in item["deliverables"]:
        ref = f" {d['ref']}" if d.get("ref") else ""
        out.append(_row(f"    {d['name']}: {d['result']}{ref}", "dim"))
    return out


def _scope_names(entries) -> str:
    names = [str(_dict(e).get("key") or _dict(e).get("name") or _dict(e).get("id")) for e in entries or []]
    return ", ".join(names) or "none"


def remit_texts(remit) -> list:
    remit = _dict(remit)
    spaces = ", ".join(f"{_dict(s).get('server')}.{_dict(s).get('workspace')}" for s in remit.get("spaces") or [])
    repos = ", ".join(_dict(r).get("github") or os.path.basename(str(_dict(r).get("path") or ""))
                      for r in remit.get("repos") or [])
    tracker = _dict(remit.get("tracker"))
    scope = "; ".join(f"{part} {_scope_names(tracker.get(part))}" for part in programme_home.TRACKER_SCOPE_PARTS)
    return [f"spaces: {spaces or 'none'}", f"repos: {repos or 'any'}", f"tracker: {scope}"]


def rows(model) -> list:
    out = [_header(model["programme"])]
    _section(out, "Remit", [_row(f"  {text}") for text in remit_texts(model.get("remit"))], "none")
    doing = model["doing_now"]
    _section(out, "Doing now", doing and [_row(f"  {doing.get('text')}"
                                               + (f" ({doing['item']})" if doing.get("item") else ""))],
             "nothing")
    _section(out, "Queue", [_row(f"  {e.get('action')} {e.get('item') or ''}".rstrip()
                                 + (f": {e['why']}" if e.get("why") else ""))
                            for e in model["queue"]], "empty")
    _section(out, "Watching", [_watching_row(w) for w in model["watching"]], "nothing")
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
    _section(out, "Rules in force", [_row(f"  {text}", style) for text, style in rule_texts(model["rules_in_force"])],
             "none")
    _section(out, "Items", [line for item in model["items"] for line in _item_lines(item)], "no items")
    return out


def render_text(view) -> str:
    return "\n".join(r["text"] for r in view["rows"])

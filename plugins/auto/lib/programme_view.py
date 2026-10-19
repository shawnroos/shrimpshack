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
programme_journal = load_lib_module("programme_journal")
programme_decisions = load_lib_module("programme_decisions")
programme_predicate = load_lib_module("programme_predicate")
programme_sanitize = load_lib_module("programme_sanitize")
programme_tasks = load_lib_module("programme_tasks")
programme_terms = load_lib_module("programme_terms")
session_registry = load_lib_module("session_registry")

VIEW_FORMAT = 1
JUST_DID_LIMIT = 8
HIDDEN_KINDS = ("prompt",)
REMIT_WATCHER = "remit"
TERM_CHANGES_LIMIT = 20
TERM_CHANGE_KINDS = (programme_terms.EDITED, programme_terms.AMENDED,
                     programme_terms.CORRECTED, programme_terms.UNDONE)
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
        "ask_kind": programme_decisions.ask_kind(item) if effective == "handed" else None,
        "ask_id": programme_decisions.ask_id(item) if effective == "handed" else None,
        "now": _tasks_now(owner, tasks_on) if effective not in programme_home.FINISHED_ITEM_STATES else None,
        "restrictions": [{"text": _dict(r).get("text"), "source": _dict(r).get("source")}
                         for r in item.get("restrictions") or []],
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


def _context_decisions(acceptance) -> list:
    acceptance = _dict(acceptance)
    out = []
    for row in acceptance.get("pending") or []:
        added = _dict(row.get("delta")).get("added")
        widens = f", which adds {', '.join(added)}" if added else ""
        out.append({"kind": "context_pending", "item": None, "id": row.get("id"),
                    "question": f"accept {row.get('kind')} {row.get('id')} revision {row.get('rev')}{widens}?"})
    for pause in acceptance.get("safety_pauses") or []:
        held = ", ".join(pause.get("items") or []) or "the whole programme"
        out.append({"kind": "safety_pause", "item": None, "pause": pause.get("id"),
                    "question": f"safety pause {pause.get('id')} ({pause.get('risk')}) holds {held}: "
                                f"{pause.get('reason')}"})
    return out


def _decisions(block, items) -> list:
    out = [{"kind": "handed", "item": i["id"], "question": i["question"], "ask_kind": i["ask_kind"],
            "ask_id": i["ask_id"]}
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


def _change_text(kind, p) -> tuple:
    if kind == programme_terms.CORRECTED:
        return p.get("correction"), f"{p.get('kind')} now decided by {p.get('to')} (was {programme_terms.owner_text(p.get('previous'))})"
    if kind == programme_terms.UNDONE:
        return p.get("correction"), f"{p.get('kind')} back to {programme_terms.owner_text(p.get('restored'))}"
    was = f"{p['previous']} -> " if p.get("previous") else ""
    return p.get("term_id"), f"{p.get('area')}: {was}{p.get('value')}"


def _term_changes(journal_entries) -> list:
    out = []
    for row in journal_entries:
        if not isinstance(row, dict) or row.get("kind") not in TERM_CHANGE_KINDS:
            continue
        payload = _dict(row.get("payload"))
        term, text = _change_text(row["kind"], payload)
        prompt_id = payload.get("prompt_id")
        source = payload.get("source") or (f"typed prompt {prompt_id}" if prompt_id else "the PM")
        quote = programme_journal.redact(payload["quote"]) if payload.get("quote") else None
        out.append({"at": row.get("at"), "kind": row["kind"], "term": term, "text": text, "source": source,
                    "prompt_id": prompt_id, "quote": quote})
    return out[::-1]


def _terms(block, journal_entries) -> dict:
    entries = programme_home.project_terms(block)
    corrections = programme_terms.active_corrections(block)
    labels = {e.get("id"): f"{e.get('area')}: {e.get('value')}" for e in entries}
    labels.update((c.get("id"), f"correction: {c.get('kind')} decided by {c.get('to')}"
                   + (" (undone)" if c.get("undone") else "")) for c in programme_terms.corrections(block))
    groups = {}
    for entry in block.get("decisions") or []:
        entry = _dict(entry)
        term = None if entry.get("silent") else entry.get("term")
        groups.setdefault(term, []).append({k: entry.get(k) for k in ("id", "at", "kind", "by", "item", "ask", "why")})
    order = [t for t in labels if t in groups] + sorted(t for t in groups if t is not None and t not in labels)
    by_term = [{"term": t, "label": labels.get(t, "not in the record"), "decisions": groups[t]} for t in order]
    if None in groups:
        by_term.append({"term": None, "label": "no term", "decisions": groups[None]})
    changes = _term_changes(journal_entries)
    return {
        "contract_version": _dict(block.get("agreement")).get(programme_decisions.STAMP_KEY),
        "project_terms": [{k: e.get(k) for k in ("id", "area", "value", "reserved", "source", "set_by")}
                          for e in entries],
        "corrections": [{"id": c.get("id"), "kind": c.get("kind"), "to": c.get("to"),
                         "previous": c.get("previous"), "prompt_id": c.get("prompt_id"),
                         "quote": programme_journal.redact(c.get("quote")), "pm_reading": c.get("pm_reading")}
                        for c in corrections],
        "by_term": by_term,
        "changes": changes[:TERM_CHANGES_LIMIT],
        "changes_total": len(changes),
    }


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
        "decisions_for_shawn": _decisions(block, items) + _context_decisions(status["acceptance"]),
        "acceptance": status["acceptance"],
        "lifecycle": _lifecycle(block),
        "just_did": _just_did(journal_entries or []),
        "rules_in_force": _rules(block, rules),
        "items": items,
        "terms": _terms(block, journal_entries or []),
    }
    model = _clean(model)
    return {"view_format": VIEW_FORMAT, "run": model["programme"]["run"], "generated_at": _iso(now),
            "model": model, "rows": rows(model)}


def _lifecycle(block) -> dict:
    closure = _dict(block.get("closure"))
    resources = _dict(closure.get("resources"))
    states = {}
    for rid, res in sorted(resources.items()):
        states.setdefault(_dict(res).get("state") or "pending", []).append(rid)
    archive = _dict(block.get("archive"))
    attempts = archive.get("attempts") or []
    last = _dict(attempts[-1]) if attempts else {}
    return {
        "ended": _dict(block.get("ended")).get("reason") if block.get("ended") else None,
        "resources": states,
        "dispositions": sorted(_dict(closure.get("dispositions"))),
        "sealed_at": archive.get("sealed_at"),
        "sealed_revision": archive.get("sealed_revision"),
        "manifest": _dict(archive.get("manifest")).get("digest"),
        "failed_checks": [] if archive.get("sealed_at") else [_dict(c).get("check") for c in last.get("failed") or []],
        "attempts": len(attempts),
        "predecessor": _dict(block.get("predecessor")).get("run"),
    }


def _lifecycle_lines(life) -> list:
    life = _dict(life)
    out = []
    if life.get("predecessor"):
        out.append(_row(f"  successor of archived programme {life['predecessor']}"))
    if not life.get("ended"):
        return out
    out.append(_row(f"  ended: {life['ended']}", "text"))
    for state, ids in sorted(_dict(life.get("resources")).items()):
        out.append(_row(f"  resources {state}: {', '.join(ids)}", "text" if state == "released" else "warn"))
    if life.get("dispositions"):
        out.append(_row(f"  dispositions recorded: {', '.join(life['dispositions'])}", "dim"))
    if life.get("sealed_at"):
        out.append(_row(f"  archived {life['sealed_at']} at revision {life.get('sealed_revision')}; "
                        f"manifest {life.get('manifest')}; read-only"))
    elif life.get("failed_checks"):
        out.append(_row(f"  not archived: the last archive attempt failed {', '.join(life['failed_checks'])}; "
                        "run check-archive for each remedy", "warn"))
    else:
        out.append(_row("  not archived: run check-archive, then archive", "warn"))
    return out


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


def rules_texts(r) -> list:
    out = rule_texts(r)
    if r.get("operating_contract"):
        out += [(text, "text") for text in programme_terms.contract_lines(r["operating_contract"])]
    return out + [(text, "text") for text in programme_terms.correction_lines(r.get("corrections") or [])]


def _blocker_text(waiting_on) -> str:
    if waiting_on.get("kind") != "blocker":
        return ""
    if waiting_on.get("safety"):
        return "safety or data-loss pause"
    parts = [f"{label} {waiting_on[key]}" for key, label in
             (("serves", "serves"), ("evidence", "evidence"), ("unblocks_when", "unblocks when"))
             if waiting_on.get(key)]
    return " · ".join(parts) or "no serves, evidence or unblock condition recorded"


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
    blocker = _blocker_text(_dict(item.get("waiting_on")))
    if blocker:
        out.append(_row(f"    blocker: {blocker}", "dim"))
    for r in item.get("restrictions") or []:
        out.append(_row(f"    restriction ({r['source']}): {r['text']}", "dim"))
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


def _acceptance_lines(acceptance) -> list:
    if not isinstance(acceptance, dict):
        return [_row("  the context block is unreadable", "warn")]
    out = []
    for req in acceptance.get("requirements") or []:
        checks = ", ".join(f"{c['check']} {c['result']}" for c in req.get("checks") or [])
        pending_rev = f", revision {req['pending_rev']} pending" if req.get("pending_rev") else ""
        out.append(_row(f"  {req['id']} rev {req.get('rev')}: {req['state']}{pending_rev}"
                        + (f" ({checks})" if checks else ""), "text" if req["state"] == "satisfied" else "warn"))
    for b in acceptance.get("blockers") or []:
        out.append(_row(f"  blocker {b.get('id')}: {b.get('check')} waits on {b.get('dependency')} "
                        f"({b.get('evidence')}); unblocks when {b.get('unblock')}", "warn"))
    for p in acceptance.get("safety_pauses") or []:
        out.append(_row(f"  safety pause {p.get('id')} ({p.get('risk')}): {p.get('reason')}", "warn"))
    for d in acceptance.get("denials") or []:
        out.append(_row(f"  denied {_dict(d).get('action')} by {_dict(d).get('tool')}"
                        + (f" for {d['item']}" if _dict(d).get("item") else "") + f": {_dict(d).get('reason')}", "warn"))
    if out and acceptance.get("followups"):
        out.append(_row(f"  follow-ups (no requirement gates on them): {', '.join(acceptance['followups'])}", "dim"))
    return out


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
    _section(out, "Decisions for Shawn", [_row(f"  {d.get('item') or d['kind']}"
                                               + (f" (ask {d['ask_id']})" if d.get("ask_id") else "")
                                               + f": {d['question']}", "warn")
                                          for d in model["decisions_for_shawn"]], "none")
    _section(out, "Just did", [_row(f"  {j['at']} {j['kind']}"
                                    + (f" {j['item']}" if j.get("item") else "")
                                    + (f": {j['summary']}" if j.get("summary") else "")
                                    + (f" (x{j['repeats']})" if j["repeats"] > 1 else ""), "dim")
                               for j in model["just_did"]], "nothing yet")
    _section(out, "Acceptance", _acceptance_lines(model.get("acceptance")), "no requirements")
    life = _lifecycle_lines(model.get("lifecycle"))
    if life:
        _section(out, "End and archive", life, "active")
    _section(out, "Rules in force", [_row(f"  {text}", style) for text, style in rules_texts(model["rules_in_force"])],
             "none")
    _section(out, "Items", [line for item in model["items"] for line in _item_lines(item)], "no items")
    return out


def render_text(view) -> str:
    return "\n".join(r["text"] for r in view["rows"])


def _project_term_text(t) -> str:
    notes = (["reserved for Shawn"] if t.get("reserved") else []) + [f"source {t.get('source') or 'none recorded'}"]
    return f"  {t.get('id')} {t.get('area')}: {t.get('value')} ({'; '.join(notes)})"


def _change_row(c) -> dict:
    quote = f" · Shawn: \"{c['quote']}\"" if c.get("quote") else ""
    return _row(f"  {c['at']} {c['kind']} {c['term']}: {c['text']} · source {c['source']}{quote}", "dim")


def terms_rows(terms) -> list:
    out = []
    version = terms.get("contract_version")
    _section(out, "Project terms" + (f" (operating contract v{version})" if version else ""),
             [_row(_project_term_text(t)) for t in terms["project_terms"]]
             + [_row(f"  {c['id']} {c['kind']} decided by {c['to']} (Shawn: \"{c['quote']}\"; "
                     f"PM's reading: \"{c['pm_reading']}\")") for c in terms["corrections"]],
             "no project terms")
    _section(out, "Decisions by term",
             [line for g in terms["by_term"] for line in
              [_row(f"  {g['term'] + ' ' if g['term'] else ''}{g['label']}")]
              + [_row(f"    {d['id']} {d['kind']} by {d['by']}" + (f" (ask {d['ask']})" if d.get("ask") else "")
                      + f": {d['why']}", "dim") for d in g["decisions"]]],
             "none recorded")
    hidden = terms["changes_total"] - len(terms["changes"])
    _section(out, "Recent term changes", [_change_row(c) for c in terms["changes"]]
             + ([_row(f"  {hidden} older changes not shown", "dim")] if hidden else []), "none")
    return out


def render_terms(view) -> str:
    return "\n".join(r["text"] for r in terms_rows(view["model"]["terms"]))

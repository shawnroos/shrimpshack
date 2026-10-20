#!/usr/bin/env python3
"""Structured asks to Shawn: their facts, fingerprint, exact replies and shown/relayed marks.

``hand-item`` builds the ask here; ``update-ask``, ``ask-shown`` and ``ask-relayed`` are
registered through ``build_verbs(host)``. The view reads ``view_asks`` and ``detail_lines``.
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_decisions = load_lib_module("programme_decisions")
programme_naming = load_lib_module("programme_naming")
programme_sanitize = load_lib_module("programme_sanitize")
run_record_core = load_lib_module("run_record_core")

REPLY_CHOICES = ("ship", "decline")
# Every cap stays at or under programme_sanitize.DEFAULT_CAP: the view model re-cleans its strings at that cap.
TEXT_CAPS = {"question": 500, "if-nothing": 500, "recommend": 300, "recommend-why": 500,
             "pr-url": 300, "pr-title": 200, "issue-url": 300, "issue-title": 200}
LIST_CAPS = {"risk": (300, 10), "evidence": (400, 12)}
OPTION_CAPS = (40, 400, 300)
OPTIONS_MAX = 6
FACT_VALUES = tuple(TEXT_CAPS) + ("readiness",)
FACT_MULTI = ("option",) + tuple(LIST_CAPS)
FACT_KEYS = ("question", "options", "if_nothing", "recommendation", "recommendation_why", "risks",
             "evidence", "pr", "issue", "readiness")
FACT_USAGE = ("[--option '<label> | <effect> [| <cost>]']... [--if-nothing <text>] [--recommend <text>] "
              "[--recommend-why <text>] [--risk <text>]... [--evidence <text>]... [--pr-url <url>] "
              "[--pr-title <text>] [--issue-url <url>] [--issue-title <text>] [--readiness <fingerprint>]")


def _capped(value, flag, cap):
    text = programme_sanitize.clean(value, cap=0)
    if len(text) > cap:
        raise ValueError(f"--{flag} is {len(text)} characters; its cap is {cap}")
    return text or None


def _option(raw) -> dict:
    parts = [p.strip() for p in str(raw).split("|")]
    if len(parts) not in (2, 3) or not parts[0] or not parts[1]:
        raise ValueError(f"--option must be '<label> | <effect> [| <cost>]': {raw!r}")
    label, effect, cost = OPTION_CAPS
    return {"label": _capped(parts[0], "option label", label),
            "effect": _capped(parts[1], "option effect", effect),
            "cost": _capped(parts[2], "option cost", cost) if len(parts) == 3 else None}


def _link(opts, prefix):
    url, title = opts.get(f"{prefix}-url"), opts.get(f"{prefix}-title")
    if url is None and title is None:
        return None
    return {"url": _capped(url, f"{prefix}-url", TEXT_CAPS[f"{prefix}-url"]) if url else None,
            "title": _capped(title, f"{prefix}-title", TEXT_CAPS[f"{prefix}-title"]) if title else None}


def parse_facts(opts) -> dict:
    facts = {}
    for flag, key in (("question", "question"), ("if-nothing", "if_nothing"), ("recommend", "recommendation"),
                      ("recommend-why", "recommendation_why")):
        if opts.get(flag) is not None:
            facts[key] = _capped(opts[flag], flag, TEXT_CAPS[flag])
    if opts.get("option"):
        if len(opts["option"]) > OPTIONS_MAX:
            raise ValueError(f"at most {OPTIONS_MAX} --option values")
        facts["options"] = [_option(raw) for raw in opts["option"]]
    for flag, key in (("risk", "risks"), ("evidence", "evidence")):
        cap, most = LIST_CAPS[flag]
        if opts.get(flag):
            if len(opts[flag]) > most:
                raise ValueError(f"at most {most} --{flag} values")
            facts[key] = [t for t in (_capped(raw, flag, cap) for raw in opts[flag]) if t]
    for prefix in ("pr", "issue"):
        link = _link(opts, prefix)
        if link is not None:
            facts[prefix] = link
    if opts.get("readiness") is not None:
        token = programme_sanitize.token(opts["readiness"], cap=64)
        if token is None:
            raise ValueError(f"--readiness must be one fingerprint with no spaces: {opts['readiness']!r}")
        facts["readiness"] = token
    return facts


def fingerprint(ask) -> str:
    basis = {k: ask.get(k) for k in FACT_KEYS + ("kind", "op")}
    return hashlib.sha256(json.dumps(basis, sort_keys=True).encode("utf-8")).hexdigest()[:16]


def new_ask(kind, facts, op=None) -> dict:
    ask = programme_decisions.new_ask(kind, facts["question"])
    if op is not None:
        ask["op"] = op
    ask.update({"options": [], "if_nothing": None, "recommendation": None, "recommendation_why": None,
                "risks": [], "evidence": [], "pr": None, "issue": None, "readiness": None})
    ask.update(facts)
    ask.update(facts_at=ask["at"], shown=None, superseded_answers=[], replies=None)
    ask["fingerprint"] = fingerprint(ask)
    return ask


def structured(ask) -> bool:
    return isinstance(ask, dict) and "facts_at" in ask


def item_name(key, item) -> str:
    sessions = [s.get("name") for s in item.get("sessions") or [] if isinstance(s, dict) and s.get("name")]
    return programme_naming.label(item.get("title") or (sessions[-1] if sessions else None), key)


def replies(items, key) -> dict:
    live = {k: i for k, i in items.items()
            if i.get("state") not in programme_naming.FINAL_ITEM_STATES or k == key}
    return {choice: programme_naming.reply(live, key, choice) for choice in REPLY_CHOICES}


def refresh_replies(programme) -> None:
    items = programme.get("items") or {}
    for key, item in items.items():
        ask = item.get("handed")
        if structured(ask) and item.get("state") == "handed" and not ask.get("answered"):
            ask["replies"] = replies(items, key)


def _open(item) -> bool:
    return item.get("state") == "handed" and not programme_decisions.handed(item).get("answered")


def _unrelayed(item) -> bool:
    ask = programme_decisions.handed(item)
    answered = ask.get("answered")
    return structured(ask) and isinstance(answered, dict) and not answered.get("relayed_at")


def _clean_deep(value):
    if isinstance(value, str):
        return programme_sanitize.clean(value, cap=0)
    if isinstance(value, dict):
        return {k: _clean_deep(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_clean_deep(v) for v in value]
    return value


def view_asks(items) -> list:
    out = []
    for key in sorted(items):
        item = items[key]
        if not (_open(item) or _unrelayed(item)):
            continue
        ask = programme_decisions.handed(item)
        shown = ask.get("shown") if isinstance(ask.get("shown"), dict) else None
        entry = {"item": key, "name": item_name(key, item), "title": item.get("title") or "",
                 "status": "open" if _open(item) else "answered", "ask_id": ask.get("id"),
                 "kind": programme_decisions.ask_kind(item), "op": ask.get("op"),
                 "at": ask.get("at"), "facts_at": ask.get("facts_at") or ask.get("at"),
                 "fingerprint": ask.get("fingerprint"), "shown": shown,
                 "shown_current": bool(shown and ask.get("fingerprint")
                                       and shown.get("fingerprint") == ask.get("fingerprint")),
                 "replies": replies(items, key), "answered": ask.get("answered"),
                 "superseded_answers": ask.get("superseded_answers") or []}
        entry.update({k: ask.get(k) for k in FACT_KEYS})
        entry["options"] = entry["options"] or []
        entry["risks"] = entry["risks"] or []
        entry["evidence"] = entry["evidence"] or []
        out.append(_clean_deep(entry))
    return out


def detail_lines(items, key) -> list:
    ask = programme_decisions.handed(items[key])
    out = []
    for option in ask.get("options") or []:
        cost = f" (cost: {option['cost']})" if option.get("cost") else ""
        out.append(f"option {option.get('label')}: {option.get('effect')}{cost}")
    if ask.get("recommendation"):
        why = f": {ask['recommendation_why']}" if ask.get("recommendation_why") else ""
        out.append(f"recommend {ask['recommendation']}{why}")
    if ask.get("if_nothing"):
        out.append(f"if nothing: {ask['if_nothing']}")
    out += [f"risk: {r}" for r in ask.get("risks") or []]
    out += [f"evidence: {e}" for e in ask.get("evidence") or []]
    for name in ("pr", "issue"):
        link = ask.get(name) if isinstance(ask.get(name), dict) else None
        if link:
            out.append(f"{name.upper() if name == 'pr' else name}: "
                       + " ".join(v for v in (link.get("title"), link.get("url")) if v))
    reply = replies(items, key)
    out.append(f'reply: "{reply["ship"]}" or "{reply["decline"]}"')
    return [programme_sanitize.clean(line, cap=0) for line in out]


def _ask_on(record, programme, item_id):
    key = record._resolve(programme, item_id)
    item = programme["items"][key]
    ask = item.get("handed")
    if not isinstance(ask, dict) or not ask:
        raise record.RecordError(f"item {key!r} has no ask to Shawn")
    return key, item, ask


def _void(programme, item, ask, now) -> dict:
    answered = ask["answered"]
    for decision in programme.get("decisions") or []:
        if isinstance(decision, dict) and decision.get("id") == answered.get("decision_id"):
            decision["voided_at"] = now
    item.update(state="handed", waiting_on=None, dropped_reason=None)
    return dict(answered, voided_at=now, fingerprint=ask.get("fingerprint"))


def _h_update_ask(host, argv):
    positional, opts = host._parse(argv, values=("run",) + FACT_VALUES, multi=FACT_MULTI)
    if len(positional) != 1:
        raise ValueError("usage: update-ask <id> " + FACT_USAGE)
    record = host.programme_record
    item_id = record.check_item_id(positional[0])
    facts = parse_facts(opts)
    if not facts:
        raise ValueError("update-ask needs at least one fact to replace")
    run_id, _, current = host._locate(opts)
    try:
        programme = current.get("programme") or {}
        _, _, ask = _ask_on(record, programme, item_id)
        same = structured(ask) and fingerprint(dict(ask, **facts)) == ask.get("fingerprint")
    except record.RecordError:
        same = False
    if same:
        # A sweep re-checks every open ask; unchanged facts write no row, so a quiet sweep stays one row.
        host._emit({"ok": True, "run": run_id, "item": item_id, "ask": ask.get("id"),
                    "fingerprint": ask["fingerprint"], "changed": False, "voided": None})
        return 0

    def change(programme, prompt, rec):
        key, item, ask = _ask_on(record, programme, item_id)
        if not structured(ask):
            raise record.RecordError(f"item {key!r} has an ask with no structured facts; hand it again")
        answered = ask.get("answered")
        if isinstance(answered, dict) and answered.get("relayed_at"):
            raise record.RecordError(f"the ask on {key!r} was answered and relayed; hand a new ask instead")
        if not answered and item["state"] != "handed":
            raise record.RecordError(f"item {key!r} is {item['state']}, not handed")
        new = dict(ask, **facts)
        new["fingerprint"] = fingerprint(new)
        out = {"item": key, "ask": ask.get("id"), "fingerprint": new["fingerprint"],
               "changed": new["fingerprint"] != ask.get("fingerprint"), "voided": None}
        if not out["changed"]:
            return out
        now = run_record_core.now_iso()
        new["facts_at"] = now
        if answered:
            new["superseded_answers"] = list(ask.get("superseded_answers") or []) + [
                _void(programme, item, ask, now)]
            new["answered"] = None
            out["voided"] = answered.get("decision_id")
            record._history(item, "ask_answer_voided", ask=ask.get("id"), decision_id=out["voided"])
        item["handed"] = new
        refresh_replies(programme)
        out["replies"] = new.get("replies")
        record._history(item, "ask_updated", ask=ask.get("id"), fingerprint=new["fingerprint"])
        return out

    return host._write(opts, change, lambda p: "ask_answer_voided" if p.get("voided") else "ask_updated")


def _h_ask_shown(host, argv):
    positional, opts = host._parse(argv, values=("run", "fingerprint"))
    if len(positional) != 1 or not opts.get("fingerprint"):
        raise ValueError("usage: ask-shown <id> --fingerprint <fingerprint>")
    record = host.programme_record
    item_id = record.check_item_id(positional[0])

    def change(programme, prompt, rec):
        key, item, ask = _ask_on(record, programme, item_id)
        if not _open(item):
            raise record.RecordError(f"item {key!r} has no open ask to show")
        if opts["fingerprint"] != ask.get("fingerprint"):
            raise record.RecordError(f"fingerprint {opts['fingerprint']!r} is not the ask's current one "
                                     f"({ask.get('fingerprint')!r}); show the current facts")
        ask["shown"] = {"at": run_record_core.now_iso(), "fingerprint": ask["fingerprint"]}
        return {"item": key, "ask": ask.get("id"), "fingerprint": ask["fingerprint"]}

    return host._write(opts, change, "ask_shown")


def _h_ask_relayed(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 1:
        raise ValueError("usage: ask-relayed <id>")
    record = host.programme_record
    item_id = record.check_item_id(positional[0])

    def change(programme, prompt, rec):
        key, item, ask = _ask_on(record, programme, item_id)
        answered = ask.get("answered")
        if not isinstance(answered, dict):
            raise record.RecordError(f"the ask on {key!r} has no recorded answer; record it with "
                                     "answer-handed before relaying it")
        if answered.get("relayed_at"):
            raise record.RecordError(f"the answer on {key!r} was already relayed at {answered['relayed_at']}")
        answered["relayed_at"] = run_record_core.now_iso()
        return {"item": key, "ask": ask.get("id"), "choice": answered.get("choice"),
                "decision_id": answered.get("decision_id")}

    return host._write(opts, change, "ask_relayed")


_SPECS = (
    ("update-ask", _h_update_ask, "<id> " + FACT_USAGE + " [--run <id>]",
     "no fact flag; a field over its cap; an option that is not '<label> | <effect> [| <cost>]'; an item "
     "with no structured ask; an answered ask already relayed. Given fields replace the stored ones and "
     "the rest are kept. Facts that hash to the current fingerprint change nothing. New facts move "
     "facts_at; on an answered, unrelayed ask they void the answer into superseded_answers, journal "
     "ask_answer_voided and hand the item again."),
    ("ask-shown", _h_ask_shown, "<id> --fingerprint <fingerprint> [--run <id>]",
     "an item with no open ask; a fingerprint that is not the ask's current one."),
    ("ask-relayed", _h_ask_relayed, "<id> [--run <id>]",
     "an ask with no recorded answer (run answer-handed first); an answer already relayed."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

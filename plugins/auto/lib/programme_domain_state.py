#!/usr/bin/env python3
"""Programme-level state for the domain scan: the recommended sessions and the PM behaviours owed on the domain.

Both live under ``programme["domain"]``, because neither belongs to an item. ``P sweep --record-sources``
records the scan; ``recommendations-shown`` and ``answer-domain-behaviour`` are the two answers.
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

programme_behaviours = load_lib_module("programme_behaviours")
programme_behaviours_due = load_lib_module("programme_behaviours_due")
programme_home = load_lib_module("programme_home")
run_record_core = load_lib_module("run_record_core")

DOMAIN_TRIGGER = "domain"
ANSWERS = ("applied_by_pm", "skipped")
TEXT_CAP = 160


def _digest(parts) -> str:
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:16]


def recommendation_set(result) -> list:
    return sorted(result.get("domain") or [], key=lambda r: r["pane"])


def recommendations_fingerprint(recs) -> str:
    return _digest([[r["pane"], r.get("workspace_id")] for r in recs])


def domain_fingerprint(result) -> str:
    """Which sessions exist and which have lost their folder. Agent status is left out: it flips every minute."""
    remit = [p["pane_id"] for p in result.get("panes") or [] if p.get("agent")]
    gone = [e["pane"] for e in result.get("folder_gone") or []]
    return _digest({"remit": sorted(remit), "outside": [r["pane"] for r in recommendation_set(result)],
                    "gone": sorted(gone)})


def record_scan(programme, result, now=None) -> dict:
    """Store the scan on the programme. A result without a domain (the host was unreadable) changes nothing."""
    if result.get("domain") is None:
        return {"recorded": False}
    now = now or run_record_core.now_iso()
    state = programme.setdefault("domain", {})
    recs = recommendation_set(result)
    fp = recommendations_fingerprint(recs)
    box = state.setdefault("recommendations", {})
    if box.get("fingerprint") != fp:
        box.update(fingerprint=fp, set=recs, since=now, shown=None)
    dfp = domain_fingerprint(result)
    if state.get("fingerprint") != dfp:
        state.update(fingerprint=dfp, changed_at=now)
    return {"recorded": True, "recommendations": len(recs), "fingerprint": fp}


def recommendations(programme) -> dict:
    box = (programme.get("domain") or {}).get("recommendations") or {}
    recs = box.get("set") or []
    shown = box.get("shown") or {}
    return {"set": recs, "fingerprint": box.get("fingerprint"),
            "shown_current": bool(shown and shown.get("fingerprint") == box.get("fingerprint"))}


def unshown(programme) -> bool:
    info = recommendations(programme)
    return bool(info["set"]) and not info["shown_current"]


def _answered_since(state, behaviour_id, changed_at) -> bool:
    start = run_record_core.parse_iso(changed_at)
    for row in state.get("behaviour_deliveries") or []:
        stamp = run_record_core.parse_iso(row.get("at"))
        if row.get("id") == behaviour_id and row.get("reason") in ANSWERS and (start is None or (stamp and stamp >= start)):
            return True
    return False


def domain_due(record, *, lookup=None, store=None) -> dict:
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    state = programme.get("domain") or {}
    changed = state.get("changed_at")
    loaded = store if store is not None else programme_behaviours.load_store(lookup)
    rows = []
    if changed:
        scoped = dict(record or {}, programme=programme)
        for entry in programme_behaviours.in_force(scoped, None, audience="pm", store=loaded):
            if programme_behaviours.trigger_of(entry) != DOMAIN_TRIGGER:
                continue
            if not programme_behaviours_due._in_force_when(entry, changed) or _answered_since(state, entry["id"], changed):
                continue
            when = " ".join(entry["when"]["text"].split())
            rows.append({"behaviour": entry["id"], "trigger": DOMAIN_TRIGGER, "trigger_at": changed,
                         "when": when if len(when) <= TEXT_CAP else when[:TEXT_CAP - 1] + "…",
                         "pm_checks": [c["text"] for c in entry["when"].get("checks") or [] if c["by"] == "pm"],
                         "mark": "pm_applies"})
    return {"total": len(rows), "rows": rows, "error": "; ".join(loaded["notices"]) or None}


def _h_recommendations_shown(host, argv):
    _, opts = host._parse(argv, values=("run", "fingerprint"))
    if not opts.get("fingerprint"):
        raise ValueError("usage: recommendations-shown --fingerprint <fingerprint> [--run <id>]")

    def change(programme, prompt, rec):
        box = (programme.get("domain") or {}).get("recommendations") or {}
        if not box.get("set"):
            raise host.programme_record.RecordError("there are no recommended sessions to show")
        if opts["fingerprint"] != box.get("fingerprint"):
            raise host.programme_record.RecordError(
                f"fingerprint {opts['fingerprint']!r} is not the current set's ({box.get('fingerprint')!r}); show the current list")
        box["shown"] = {"at": run_record_core.now_iso(), "fingerprint": box["fingerprint"]}
        return {"fingerprint": box["fingerprint"], "sessions": len(box["set"])}

    return host._write(opts, change, "recommendations_shown")


def _h_answer_domain_behaviour(host, argv):
    positional, opts = host._parse(argv, values=("run", "as", "why"))
    if len(positional) != 1 or opts.get("as") not in ANSWERS or not (opts.get("why") or "").strip():
        raise ValueError("usage: answer-domain-behaviour <behaviour-id> --as applied_by_pm|skipped --why <text> [--run <id>]")
    bid = positional[0]

    def change(programme, prompt, rec):
        state = programme.setdefault("domain", {})
        state.setdefault("behaviour_deliveries", []).append(
            {"id": bid, "reason": opts["as"], "at": run_record_core.now_iso(), "why": " ".join(opts["why"].split())[:400]})
        return {"behaviour": bid, "answer": opts["as"]}

    return host._write(opts, change, "domain_behaviour_answered")


_SPECS = (
    ("recommendations-shown", _h_recommendations_shown, "--fingerprint <fingerprint> [--run <id>]",
     "a fingerprint that is not the current recommended set's; no recommended sessions."),
    ("answer-domain-behaviour", _h_answer_domain_behaviour,
     "<behaviour-id> --as applied_by_pm|skipped --why <text> [--run <id>]",
     "an answer other than applied_by_pm or skipped; a missing --why."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

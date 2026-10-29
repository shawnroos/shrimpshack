#!/usr/bin/env python3
"""``sweep-inputs``: the read side of a sweep as data, with a verdict computed from the store.

The PM saves it to ``<home>/sweep-inputs.json`` and a Haiku agent with no Bash reads that file, so
the agent never touches the programme and the verdict never rests on a model's reading of prose.
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_resume = load_lib_module("programme_resume")
programme_readiness = load_lib_module("programme_readiness")
programme_sources = load_lib_module("programme_sources")
programme_predicate = load_lib_module("programme_predicate")

INPUTS_NAME = "sweep-inputs.json"
DIGEST_NAME = "sweep-digest.md"
STOP_RULE_REASONS = ("never_stop", "not_done", "until_time")
WATCHERS = ("remit", "cron")
ROW_CAP = 300
PR_CAP = 8
TEXT_CAP = 240
# The sweep's own bookkeeping, written on every pass; a row of one of these kinds changes nothing.
BOOKKEEPING_KINDS = ("stop_quiet", "prompts_pruned", "working_now", "focus_noted")


def _quiet_row(row) -> bool:
    kind, payload = row.get("kind"), row.get("payload") or {}
    if kind in BOOKKEEPING_KINDS:
        return True
    if kind == "prompt":
        return programme_journal.prompt_origin(row) == "cron"
    if kind == "validate_pass":
        return not payload.get("refuted")
    if kind == "permission_proposed":
        return not payload.get("proposals")
    if kind == "effects_recorded":
        return not payload.get("notify")
    return False


def _when(stamp):
    try:
        return datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return None


def _clip(text) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= TEXT_CAP else text[:TEXT_CAP - 1] + "…"


def _last_index(rows, kinds):
    for at in range(len(rows) - 1, -1, -1):
        if rows[at].get("kind") in kinds:
            return at
    return None


def _open_prs(programme):
    refs = []
    for key, item in sorted((programme.get("items") or {}).items()):
        for name, entry in sorted((item.get("deliverables") or {}).items()):
            ref = (entry or {}).get("ref")
            if not ref or (entry or {}).get("result") == "confirmed":
                continue
            try:
                refs.append((key, name, programme_readiness.canonical_ref(ref)))
            except Exception:  # noqa: BLE001 — a ref that is not a PR is not a merge to watch
                continue
    return refs


def _readiness(programme, refs):
    repos = list((programme.get("remit") or {}).get("repos") or [])
    checked = []
    for key, name, ref in refs[:PR_CAP]:
        verdict = programme_readiness.check_mergeable(ref, repos)
        gates = verdict.get("gates") or []
        merged_or_closed = bool(verdict.get("ended"))
        checked.append({"item": key, "deliverable": name, "pr": ref, "result": verdict["result"],
                        "ends": merged_or_closed, "note": _clip(verdict.get("note") or "; ".join(map(str, gates)))})
    return checked


def _stalled(programme):
    """Worker-owned items whose pane is not working. Herdr is read only when such an item exists."""
    waiting = [(key, (item.get("owner") or {}).get("pane")) for key, item in sorted((programme.get("items") or {}).items())
               if programme_predicate.effective_state(item) == "waiting"
               and (item.get("waiting_on") or {}).get("who") == "worker"]
    if not waiting:
        return []
    snap, _ = programme_sources.read_herdr()
    panes = programme_sources.pane_views(snap, programme_sources.remit(programme)) if snap is not None else None
    status = {p["pane_id"]: p.get("agent_status") for p in panes or []}
    return [{"item": key, "pane": pane, "agent_status": (status.get(pane) if panes is not None else None) or "unknown"}
            for key, pane in waiting if panes is None or status.get(pane) != "working"]


def build(host, run_id, home, record):
    programme = programme_home.normalize_programme(record.get("programme") or {})
    view = host.build_view(run_id, home, record)
    rows = programme_journal.read(run_id)
    last = _last_index(rows, ("working_now",))
    last_at = _when(rows[last].get("at")) if last is not None else None
    since = [(n + 1, row) for n, row in enumerate(rows)][(last + 1) if last is not None else 0:]
    every = [r for r in (view["model"]["programme"].get("actionable_reasons") or []) if isinstance(r, dict)]
    reasons = [r for r in every if r.get("kind") not in STOP_RULE_REASONS]
    claim_rows, claim_offset, _ = programme_resume.claims_state(run_id, home, record)
    claims = [dict(row, index=n) for n, row in enumerate(claim_rows) if n >= claim_offset]
    asks = view.get("asks") or []
    why = []
    if last is None:
        why.append("no_prior_sweep")
    if reasons:
        why.append("actionable_reasons")
    if claims:
        why.append("unread_claims")
    if any(a.get("status") == "open" and not a.get("shown_current") for a in asks):
        why.append("ask_not_shown")
    if any(a.get("status") == "answered" for a in asks):
        why.append("ask_answered_unrelayed")
    loud = [(n, row) for n, row in since if not _quiet_row(row)]
    if loud:
        why.append("journal_rows")
    if len(since) > ROW_CAP:
        why.append("journal_overflow")
    moved = []
    for key, item in sorted((programme.get("items") or {}).items()):
        for event in item.get("history") or []:
            if event.get("kind") == "tracker_synced":
                continue
            stamp = _when(event.get("at"))
            if last_at is None or stamp is None or stamp > last_at:
                moved.append({"item": key, "kind": event.get("kind"), "at": event.get("at")})
    if moved:
        why.append("items_changed")
    refs = _open_prs(programme)
    prs = _readiness(programme, refs)
    if len(refs) > PR_CAP:
        why.append("pr_over_cap")
    for pr in prs:
        if pr["result"] == "unknown":
            why.append("pr_unknown")
        elif pr["result"] == "ready":
            why.append("pr_ready")
        elif pr["ends"]:
            why.append("pr_closed_or_merged")
    stalled = _stalled(programme)
    if stalled:
        why.append("worker_not_working")
    armed = {name: name in (programme.get("watchers") or {}) for name in WATCHERS}
    why.extend("watcher_missing:" + name for name, ok in armed.items() if not ok)
    reread = _last_index(rows, ("reread_requested",))
    acked = _last_index(rows, ("rules_acked", "rules_loaded"))
    reread_requested = reread is not None and (acked is None or reread > acked)
    if reread_requested:
        why.append("rules_reread_requested")
    why = list(dict.fromkeys(why))
    rules = (host.rules_in_force(record).get("rules") or [])
    return {
        "ok": True, "run": run_id, "home": home,
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": "changed" if why else "unchanged", "why": why,
        "claims": {"unread": len(claims), "next_offset": len(claim_rows)},
        "last_sweep": None if last is None else {"line": last + 1, "at": rows[last].get("at")},
        "actionable_reasons": every,
        "decisions_for_shawn": [{"item": d.get("item") or d.get("id"), "text": _clip(d.get("question") or d.get("text") or d)}
                                for d in (view["model"].get("decisions_for_shawn") or [])],
        "asks": [{"item": a.get("item"), "status": a.get("status"), "shown_current": a.get("shown_current"),
                  "fingerprint": a.get("fingerprint")} for a in asks],
        "unread_claims": [{"index": c["index"], "item": c.get("item"), "deliverable": c.get("deliverable"),
                           "ref": c.get("ref"), "text": _clip(c.get("text") or c.get("note"))} for c in claims],
        "items_changed": moved, "stalled": stalled,
        "prs": prs, "prs_unchecked": [ref for _, _, ref in refs[PR_CAP:]],
        "watchers_armed": armed,
        "rules": {"count": len(rules), "ids": [r.get("id") for r in rules if isinstance(r, dict)],
                  "reread_requested": reread_requested},
        "journal_since": [{"line": n, "kind": row.get("kind"), "at": row.get("at"),
                           "quiet": _quiet_row(row)} for n, row in since[:ROW_CAP]],
    }


def _save(home, inputs) -> str:
    path = os.path.join(home, INPUTS_NAME)
    fd, tmp = tempfile.mkstemp(prefix=INPUTS_NAME + ".", dir=home)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(inputs, handle, indent=1)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    # A digest from an earlier sweep is stale the moment new inputs exist: remove it so the packager
    # creates a fresh file (a Write over an existing file it has not read fails) and the PM cannot read an old one.
    try:
        os.unlink(os.path.join(home, DIGEST_NAME))
    except FileNotFoundError:
        pass
    return path


def verb(host, argv) -> int:
    positional, opts = host._parse(argv, values=("run",), flags=("save", "reasons"))
    if positional:
        raise ValueError("usage: sweep-inputs [--run <id>] [--save] [--reasons]")
    run_id, home, record = host._locate(opts)
    inputs = build(host, run_id, home, record)
    if opts.get("reasons"):
        host._emit({"ok": True, "run": run_id, "actionable_reasons": inputs["actionable_reasons"]})
        return 0
    if opts.get("save"):
        path = _save(home, inputs)
        host._emit({"ok": True, "run": run_id, "home": home, "verdict": inputs["verdict"], "why": inputs["why"],
                    "generated": inputs["generated"], "inputs": path, "unread_claims": inputs["claims"]["unread"],
                    "next_offset": inputs["claims"]["next_offset"]})
        return 0
    host._emit(inputs)
    return 0

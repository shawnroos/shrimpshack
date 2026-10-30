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

programme_behaviours_due = load_lib_module("programme_behaviours_due")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_resume = load_lib_module("programme_resume")
programme_readiness = load_lib_module("programme_readiness")
programme_sources = load_lib_module("programme_sources")
programme_predicate = load_lib_module("programme_predicate")
run_record_core = load_lib_module("run_record_core")

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


def _moved_items(programme, last_at):
    moved = []
    for key, item in sorted((programme.get("items") or {}).items()):
        for event in item.get("history") or []:
            if event.get("kind") == "tracker_synced":
                continue
            stamp = run_record_core.parse_iso(event.get("at"))
            if last_at is None or stamp is None or stamp > last_at:
                moved.append({"item": key, "kind": event.get("kind"), "at": event.get("at")})
    return moved


def _due(host, run_id, record):
    """What the PM owes an answer for. A failure is reported with its message, never raised: one bad file must not stop every sweep."""
    try:
        found = programme_behaviours_due.due(record, run_id, lookup=host.prompt_lookup)
    except Exception as exc:  # noqa: BLE001 — any failure here must degrade the sweep, not end it
        return {"total": 0, "rows": [], "overflow": 0, "overflow_ids": [], "error": f"{type(exc).__name__}: {exc}"}, True
    # load_store reports an unreadable file as a notice and returns the rest, so no exception reaches here.
    if found["store_notices"]:
        found["error"] = "; ".join(found["store_notices"])
    return found, bool(found["store_notices"])


def _armed(programme, record):
    """The remit watcher beats from its own process, so its heartbeat must be fresh; the cron has no process to beat."""
    watchers = programme.get("watchers") or {}
    now = datetime.datetime.now(datetime.timezone.utc)
    return {"remit": programme_predicate.watcher_live(watchers.get("remit"), now, programme_home.cadence_seconds(record)),
            "cron": "cron" in watchers}


def _facts(host, run_id, home, record):
    programme = programme_home.normalize_programme(record.get("programme") or {})
    view = host.build_view(run_id, home, record)
    rows = programme_journal.read(run_id)
    last = _last_index(rows, ("working_now",))
    last_at = run_record_core.parse_iso(rows[last].get("at")) if last is not None else None
    claim_rows, claim_offset, _ = programme_resume.claims_state(run_id, home, record)
    refs = _open_prs(programme)
    reread = _last_index(rows, ("reread_requested",))
    acked = _last_index(rows, ("rules_acked", "rules_loaded"))
    due, due_error = _due(host, run_id, record)
    return {
        "run": run_id, "home": home, "rows": rows, "last": last,
        "since": list(enumerate(rows, 1))[(last + 1) if last is not None else 0:],
        "reasons": [r for r in (view["model"]["programme"].get("actionable_reasons") or []) if isinstance(r, dict)],
        "decisions": view["model"].get("decisions_for_shawn") or [],
        "asks": view.get("asks") or [],
        "claim_total": len(claim_rows),
        "claims": [dict(row, index=n) for n, row in enumerate(claim_rows) if n >= claim_offset],
        "moved": _moved_items(programme, last_at), "stalled": _stalled(programme),
        "refs": refs, "prs": _readiness(programme, refs), "armed": _armed(programme, record),
        "reread_requested": reread is not None and (acked is None or reread > acked),
        "rules": host.rules_in_force(record).get("rules") or [],
        "due": due, "due_error": due_error,
    }


def _verdict(f):
    """Why the sweep is not quiet; an empty list is the unchanged verdict. Pure, so a table of facts can test it."""
    checks = (
        ("no_prior_sweep", f["last"] is None),
        ("actionable_reasons", any(r.get("kind") not in STOP_RULE_REASONS for r in f["reasons"])),
        ("unread_claims", bool(f["claims"])),
        ("ask_not_shown", any(a.get("status") == "open" and not a.get("shown_current") for a in f["asks"])),
        ("ask_answered_unrelayed", any(a.get("status") == "answered" for a in f["asks"])),
        ("journal_rows", any(not _quiet_row(row) for _, row in f["since"])),
        ("journal_overflow", len(f["since"]) > ROW_CAP),
        ("items_changed", bool(f["moved"])),
        ("pr_over_cap", len(f["refs"]) > PR_CAP),
        ("pr_unknown", any(p["result"] == "unknown" for p in f["prs"])),
        ("pr_ready", any(p["result"] == "ready" for p in f["prs"])),
        ("pr_closed_or_merged", any(p["ends"] for p in f["prs"])),
        ("worker_not_working", bool(f["stalled"])),
        ("rules_reread_requested", f["reread_requested"]),
        ("behaviours_due", bool(f["due"]["total"])),
        ("behaviours_store_unreadable", f["due_error"]),
    )
    return [code for code, hit in checks if hit] + ["watcher_missing:" + name for name, ok in f["armed"].items() if not ok]


def build(host, run_id, home, record):
    f = _facts(host, run_id, home, record)
    why = _verdict(f)
    last = f["last"]
    return {
        "ok": True, "run": run_id, "home": home,
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": "changed" if why else "unchanged", "why": why,
        "claims": {"unread": len(f["claims"]), "next_offset": f["claim_total"]},
        "last_sweep": None if last is None else {"line": last + 1, "at": f["rows"][last].get("at")},
        "actionable_reasons": f["reasons"],
        "decisions_for_shawn": [{"item": d.get("item") or d.get("id"), "text": _clip(d.get("question") or d.get("text") or d)}
                                for d in f["decisions"]],
        "asks": [{"item": a.get("item"), "status": a.get("status"), "shown_current": a.get("shown_current"),
                  "fingerprint": a.get("fingerprint")} for a in f["asks"]],
        "unread_claims": [{"index": c["index"], "item": c.get("item"), "deliverable": c.get("deliverable"),
                           "ref": c.get("ref"), "text": _clip(c.get("text") or c.get("note"))} for c in f["claims"]],
        "items_changed": f["moved"], "stalled": f["stalled"],
        "prs": f["prs"], "prs_unchecked": [ref for _, _, ref in f["refs"][PR_CAP:]],
        "watchers_armed": f["armed"], "behaviours_due": f["due"],
        "rules": {"count": len(f["rules"]), "ids": [r.get("id") for r in f["rules"] if isinstance(r, dict)],
                  "reread_requested": f["reread_requested"]},
        "journal_since": [{"line": n, "kind": row.get("kind"), "at": row.get("at"), "quiet": _quiet_row(row)}
                          for n, row in f["since"][:ROW_CAP]],
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
    except OSError:
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

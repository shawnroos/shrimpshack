#!/usr/bin/env python3
"""close-gone-pane: close a live pane whose folder is gone, or report why it stays.

A pane closes only when its folder is gone, its item's PR is merged and its agent is idle. Every other
answer, including an unknown one, leaves the pane open and says why.
"""

from __future__ import annotations

import copy
import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_authority = load_lib_module("programme_authority")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_remit_owned = load_lib_module("programme_remit_owned")
programme_readiness = load_lib_module("programme_readiness")
programme_sources = load_lib_module("programme_sources")
terminal_host = load_lib_module("terminal_host")

IDLE = "idle"
ALREADY_MERGED = "already merged"


def _merged(programme, item_key, check=None) -> tuple:
    """(True, why) only when the item's PR is read as merged; (False, why) for no item, no PR, closed or unknown."""
    item = (programme.get("items") or {}).get(item_key) if item_key else None
    if not item:
        return False, "no item owns this pane, so no merged PR is on record"
    merged = (item.get("deliverables") or {}).get("merged") or {}
    if merged.get("result") == "confirmed" and merged.get("confirmed_at"):
        return True, "the item's merged deliverable is confirmed"
    ref = merged.get("ref") or (merged.get("fields") or {}).get("pr")
    if not ref:
        return False, f"item {item_key} has no PR on record"
    check = check or programme_readiness.check_mergeable
    verdict = check(ref, list((programme.get("remit") or {}).get("repos") or []))
    if ALREADY_MERGED in (verdict.get("gates") or []):
        return True, f"{verdict.get('pr') or ref} is merged on GitHub"
    return False, f"{verdict.get('pr') or ref} is not read as merged ({'; '.join(verdict.get('gates') or []) or verdict.get('note') or verdict.get('result')})"


def decide(programme, entry, check=None) -> tuple:
    """(eligible, why) for one folder_gone entry."""
    status = entry.get("agent_status")
    if status != IDLE:
        return False, f"the agent is {status or 'in an unknown state'}, not idle"
    return _merged(programme, entry.get("item"), check)


def close_if_eligible(record, entry, *, check=None, host=None) -> dict:
    programme = record.get("programme") or {}
    eligible, why = decide(programme, entry, check)
    out = {"pane": entry["pane"], "item": entry.get("item"), "why": why}
    if not eligible:
        return dict(out, status="reported")
    closed = (host or terminal_host.current()).close_pane(entry["pane"])
    if not closed.ok:
        return dict(out, status="reported", why=f"{why}; but the host cannot close it: {closed.why}", fix=closed.fix)
    return dict(out, status="closed")


def _drop_remit_entry(host, run_id, home, record, sid, item) -> dict:
    """Drops the repo entry the PM created for this item. The pane is already closed, so a failure here is reported, not raised."""
    preview = programme_remit_owned.drop_for_item(
        copy.deepcopy(programme_home.normalize_programme(record.get("programme") or {})), item)
    if not preview["dropped"]:
        return preview
    seen = {}

    def mutate(rec):
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        seen.update(programme_remit_owned.drop_for_item(programme, item))

    def compose(_, rec):
        return programme_journal.entry("remit_worker_dropped", sid, dict(seen, item=item)) if seen.get("dropped") else None

    try:
        programme_authority.write(home, run_id, mutate, compose)
        host.refresh_view(run_id, home)
    except Exception as exc:  # noqa: BLE001 - the close already happened; say the entry stayed
        return {"dropped": None, "reason": f"the remit write failed: {exc}"}
    return dict(seen)


def _h_close_gone_pane(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 1:
        raise ValueError("usage: close-gone-pane <pane> [--run <id>]")
    run_id, home, record = host._locate(opts)
    sid = host._guard(home, record)
    swept = programme_sources.sweep(record)
    entry = next((e for e in swept.get("folder_gone") or [] if e["pane"] == positional[0]), None)
    if entry is None:
        raise ValueError(f"pane {positional[0]!r} is not in this sweep's folder_gone list; run `P sweep` and use a pane it lists")
    out = close_if_eligible(record, entry)
    if out["status"] == "closed" and entry.get("item"):
        out["remit"] = _drop_remit_entry(host, run_id, home, record, sid, entry["item"])
    programme_journal.append(run_id, "gone_pane_" + out["status"], sid, out)
    host._emit(out)
    return 0


_SPECS = (
    ("close-gone-pane", _h_close_gone_pane, "<pane> [--run <id>]",
     "a pane that is not in the current sweep's folder_gone list. Closes only when the folder is gone, the "
     "item's PR is merged and the agent is idle; otherwise it reports why and closes nothing."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

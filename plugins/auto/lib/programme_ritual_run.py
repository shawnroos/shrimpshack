#!/usr/bin/env python3
"""The verbs that run, skip, fail and offer a ritual.

They need the due computation, which needs the ritual store, so they sit in their own module: the
store module imports nothing from here.
"""

from __future__ import annotations

import contextlib
import functools
import io
import os
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_sanitize = load_lib_module("programme_sanitize")
programme_rituals = load_lib_module("programme_rituals")
programme_rituals_due = load_lib_module("programme_rituals_due")
programme_ritual_checks = load_lib_module("programme_ritual_checks")
programme_carryover = load_lib_module("programme_carryover")
programme_journal = load_lib_module("programme_journal")

RitualError = programme_rituals.RitualError


def _find(host, programme, rec, rid):
    entry = next((e for e in programme_rituals.in_force(dict(rec, programme=programme), lookup=host.prompt_lookup)
                  if e["id"] == rid), None)
    if entry is None:
        raise RitualError(f"ritual {rid!r} is not in force (unknown, retired or proposed)")
    return entry


def _due(host, programme, rec) -> dict:
    return programme_rituals_due.due(dict(rec, programme=programme), rec["run_id"], lookup=host.prompt_lookup)


def _state_of(host, programme, rec, rid) -> str | None:
    due = _due(host, programme, rec)
    for bucket in ("in_flight", "missed", "due"):
        if any(r["ritual"] == rid for r in due[bucket]):
            return bucket
    return None


def _needs_answer(host, opts, rid) -> bool:
    """A missed ritual runs, starts or is skipped only on Shawn's answer, so the prompt is demanded for exactly that state."""
    run_id, home, record = host._locate(opts)
    probe = programme_home.normalize_programme(record.get("programme") or {})
    return _state_of(host, probe, dict(record, run_id=run_id), rid) == "missed"


def _check_answer(host, programme, rec, rid, prompt) -> None:
    """The unlocked probe only decides whether a prompt is demanded; this decides again under the lock."""
    if prompt:
        host.require_named(prompt, rid)
    elif _state_of(host, programme, rec, rid) == "missed":
        raise RitualError(f"ritual {rid!r} is missed: it needs Shawn's answer to its offer (--prompt <id>)")


def _h_start(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: start-ritual <id> [--prompt <id>] [--run <id>]")
    rid = positional[0]
    needs = _needs_answer(host, opts, rid)

    def change(programme, prompt, rec):
        # Resolution re-validates every entry, so a ritual stored before a protected word was added is
        # rejected there and never reaches this point: that is the run-time refusal.
        entry = _find(host, programme, rec, rid)
        _check_answer(host, programme, rec, rid, prompt)
        out = {"ritual": rid, "trigger": entry["when"]["trigger"], "steps": entry["steps"]}
        if entry.get("offers"):
            out.update(offers=entry["offers"], offers_rule=programme_rituals.OFFERS_RULE)
        return out

    return host._write(opts, change, programme_rituals.STARTED, prompt_id=opts.get("prompt"), needs_prompt=needs,
                       verb="start-ritual", target=rid)


def _answer(host, argv, kind, verb, fields=(), typed=False):
    positional, opts = host._parse(argv, values=("run", "prompt") + fields)
    if len(positional) != 1:
        raise ValueError(f"usage: {verb} <id> {' '.join('[--' + f + ' <text>]' for f in fields)} [--prompt <id>] [--run <id>]")
    rid = positional[0]
    needs = typed or _needs_answer(host, opts, rid)

    def change(programme, prompt, rec):
        entry = _find(host, programme, rec, rid)
        _check_answer(host, programme, rec, rid, prompt)
        programme_rituals.advance_clock(programme, entry)
        extra = {f: programme_rituals._clean(opts[f], "--" + f) for f in fields if opts.get(f)}
        return dict({"ritual": rid, "trigger": entry["when"]["trigger"]}, **extra)

    return host._write(opts, change, kind, prompt_id=opts.get("prompt"), needs_prompt=needs, verb=verb, target=rid)


def _h_run(host, argv):
    return _answer(host, argv, programme_rituals.RAN, "run-ritual", ("outcome",))


def _h_skip(host, argv):
    # Skipping is Shawn's call in every state; an unprompted skip would also satisfy the handover and end gates.
    return _answer(host, argv, programme_rituals.SKIPPED, "skip-ritual", ("why",), typed=True)


def _h_fail(host, argv):
    positional, opts = host._parse(argv, values=("run", "why"))
    why = programme_sanitize.clean(opts.get("why") or "", 300)
    if len(positional) != 1 or not why:
        raise ValueError("usage: fail-ritual <id> --why <line> [--run <id>]")
    rid = positional[0]

    def change(programme, _prompt, rec):
        entry = _find(host, programme, rec, rid)
        return {"ritual": rid, "trigger": entry["when"]["trigger"], "why": why}

    return host._write(opts, change, programme_rituals.FAILED, verb="fail-ritual", target=rid)


def _h_offer(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if not positional:
        raise ValueError("usage: offer-rituals <id>... [--run <id>]")
    wanted = list(dict.fromkeys(positional))

    def change(programme, _prompt, rec):
        due = _due(host, programme, rec)
        waiting = {r["ritual"]: r for r in due["missed"] + due["in_flight"]}
        absent = [r for r in wanted if r not in waiting]
        if absent:
            raise RitualError(f"no missed or in-flight ritual {', '.join(absent)} to offer")
        return {"offered": [{"ritual": r, "pending_at": waiting[r]["pending_at"]} for r in wanted]}

    return host._write(opts, change, programme_rituals.OFFERED, verb="offer-rituals", target=",".join(wanted))


SWEEP_BUDGET_SECONDS = 90.0


class _NoLongerDue(RitualError):
    pass


def _remit_path(programme, key):
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(repo, dict) and repo.get("path") and programme_carryover.key_of(repo) == key:
            return repo["path"]
    return None


def _check_targets(host, record, run_id, only):
    """Due and missed calendar rituals that carry a check and have not been checked for this slot."""
    programme = programme_home.normalize_programme(record.get("programme") or {})
    scoped = dict(record, run_id=run_id, programme=programme)
    rows = programme_journal.read(run_id)
    slots = {(r.get("payload") or {}).get("ritual"): set() for r in rows if r.get("kind") == programme_rituals.CHECKED}
    for r in rows:
        if r.get("kind") == programme_rituals.CHECKED:
            slots[(r.get("payload") or {}).get("ritual")].add((r.get("payload") or {}).get("pending_at"))
    got = programme_rituals_due.due(scoped, run_id, rows=rows, lookup=host.prompt_lookup)
    entries = {e["id"]: e for e in programme_rituals.in_force(scoped, lookup=host.prompt_lookup)}
    targets = []
    for state in ("due", "missed"):
        for row in got[state]:
            entry = entries.get(row["ritual"])
            if entry is None or not entry.get("check") or entry["when"]["trigger"] != "calendar":
                continue
            if only and row["ritual"] != only:
                continue
            if not only and row["pending_at"] in slots.get(row["ritual"], ()):
                continue
            targets.append((entry, row))
    if only and not targets:
        raise RitualError(f"ritual {only!r} has no check that is due or missed")
    return targets


def _check_payload(entry, row, result) -> dict:
    keep = ("checked", "failed", "ref", "ref_sha", "ref_age_seconds")
    out = {"ritual": entry["id"], "check": entry["check"]["name"], "pending_at": row["pending_at"],
           "late": row["state"] == "missed", "result": result["result"], "reason": result["reason"]}
    out.update({k: result[k] for k in keep if k in result})
    return out


def _record_check(host, opts, entry, row, result) -> bool:
    rid = entry["id"]

    def change(programme, _prompt, rec):
        if not opts.get("ritual"):
            # Two sweeps can run the same check at once; the second to write finds the slot already recorded.
            for old in programme_journal.read(rec["run_id"]):
                body = old.get("payload") or {}
                if old.get("kind") == programme_rituals.CHECKED and body.get("ritual") == rid \
                        and body.get("pending_at") == row["pending_at"]:
                    raise _NoLongerDue(f"ritual {rid!r} was already checked for this slot")
        # The check ran outside the lock; decide again here that this slot is still waiting.
        again = {r["ritual"]: r for state in ("due", "missed") for r in _due(host, programme, rec)[state]}
        if rid not in again or again[rid]["pending_at"] != row["pending_at"]:
            raise _NoLongerDue(f"ritual {rid!r} is no longer waiting for the slot that was checked")
        if result["result"] == "pass":
            programme_rituals.advance_clock(programme, _find(host, programme, rec, rid))
        return _check_payload(entry, row, result)

    try:
        host._write(opts, change, programme_rituals.CHECKED, verb="run-ritual-checks", target=rid,
                    beat=False, names_change=False)
    except (host.ProgrammeError, RitualError):
        return False
    return True


def _h_checks(host, argv):
    positional, opts = host._parse(argv, values=("run", "ritual"))
    if positional:
        raise ValueError("usage: run-ritual-checks [--ritual <id>] [--run <id>]")
    run_id, home, record = host._locate(opts)
    targets = _check_targets(host, record, run_id, opts.get("ritual"))
    programme = programme_home.normalize_programme(record.get("programme") or {})
    # Refuse before any git read: a session that cannot write would run every check for nothing, and the
    # guard's own output (the compaction rules) must not be repeated once per ritual.
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            host._guard(home, dict(record, run_id=run_id))
    except host.ProgrammeError:
        host._emit({"ok": True, "kind": "ritual_checks", "run": run_id, "ran": 0, "passed": 0, "failed": 0,
                    "errors": 0, "not_recorded": [entry["id"] for entry, _ in targets], "left_over": []})
        return 0
    deadline = time.monotonic() + SWEEP_BUDGET_SECONDS
    counts = {"pass": 0, "fail": 0, "error": 0}
    not_recorded, left_over = [], []
    for entry, row in targets:
        left = deadline - time.monotonic()
        if left <= 0:
            left_over.append(entry["id"])
            continue
        check = entry["check"]
        key = check.get("repo_key") or entry.get("repo_key")
        path = _remit_path(programme, key)
        if path is None:
            result = {"result": "error", "reason": "repo_not_in_remit"}
        else:
            result = programme_ritual_checks.run_check(check["name"], path, check.get("base"),
                                                       budget_seconds=min(programme_ritual_checks.BUDGET_SECONDS, left))
        if _record_check(host, opts, entry, row, result):
            counts[result["result"]] += 1
        else:
            not_recorded.append(entry["id"])
    host._emit({"ok": True, "kind": "ritual_checks", "run": run_id, "ran": sum(counts.values()), "passed": counts["pass"],
                "failed": counts["fail"], "errors": counts["error"], "not_recorded": not_recorded,
                "left_over": left_over})
    return 0


_SPECS = (
    ("run-ritual-checks", _h_checks, "[--ritual <id>] [--run <id>]",
     "a session that does not drive the programme (the ritual stays due and is listed as not_recorded). Runs the "
     "named check of each due or missed calendar ritual that has not been checked for its slot, outside the "
     "programme lock; a pass moves the clock, a fail or error leaves the ritual due. --ritual re-runs one."),
    ("start-ritual", _h_start, "<id> [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force (a ritual whose step names a "
     "protected escalation is rejected on load, so it is never in force); a missed ritual with no prompt; typed words with no offer that do not name its id."),
    ("run-ritual", _h_run, "<id> [--outcome <text>] [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; a missed ritual with no prompt; typed words with no offer that do not name its id. Moves this programme's next-due time past now."),
    ("fail-ritual", _h_fail, "<id> --why <line> [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no --why. Ends the in-flight state "
     "without answering the ritual."),
    ("skip-ritual", _h_skip, "<id> --prompt <id> [--why <text>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no prompt, in any state; typed words with no offer that do not name its id. Moves this programme's next-due time past now."),
    ("offer-rituals", _h_offer, "<id>... [--run <id>]",
     "a session that does not drive the programme; an id that is not a missed or in-flight ritual. Records the "
     "offer once so an unanswered picker is not posted again."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

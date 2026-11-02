#!/usr/bin/env python3
"""The verbs that run, skip, fail and offer a ritual.

They need the due computation, which needs the ritual store, so they sit in their own module: the
store module imports nothing from here.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_sanitize = load_lib_module("programme_sanitize")
programme_rituals = load_lib_module("programme_rituals")
programme_rituals_due = load_lib_module("programme_rituals_due")

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
    """A missed ritual runs, starts or is skipped only on Shawn's typed answer, so the prompt is demanded for exactly that state."""
    run_id, home, record = host._locate(opts)
    probe = programme_home.normalize_programme(record.get("programme") or {})
    return _state_of(host, probe, dict(record, run_id=run_id), rid) == "missed"


def _check_answer(host, programme, rec, rid, prompt) -> None:
    """The unlocked probe only decides whether a prompt is demanded; this decides again under the lock."""
    if prompt:
        host.require_named(prompt, rid)
    elif _state_of(host, programme, rec, rid) == "missed":
        raise RitualError(f"ritual {rid!r} is missed: it needs Shawn's typed answer naming it (--prompt <id>)")


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
        return {"ritual": rid, "trigger": entry["when"]["trigger"], "steps": entry["steps"]}

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


_SPECS = (
    ("start-ritual", _h_start, "<id> [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force (a ritual whose step names a "
     "protected escalation is rejected on load, so it is never in force); a missed ritual without a typed "
     "prompt that names its id."),
    ("run-ritual", _h_run, "<id> [--outcome <text>] [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; a missed ritual without a typed "
     "prompt that names its id. Moves this programme's next-due time past now."),
    ("fail-ritual", _h_fail, "<id> --why <line> [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no --why. Ends the in-flight state "
     "without answering the ritual."),
    ("skip-ritual", _h_skip, "<id> --prompt <id> [--why <text>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no typed prompt that names the "
     "ritual id, in any state. Moves this programme's next-due time past now."),
    ("offer-rituals", _h_offer, "<id>... [--run <id>]",
     "a session that does not drive the programme; an id that is not a missed or in-flight ritual. Records the "
     "offer once so an unanswered picker is not posted again."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

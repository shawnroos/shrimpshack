#!/usr/bin/env python3
"""The focus budget: how much work a programme runs at once, and the size each item carries.

``focus_budget`` is a fixed agreement term. Its value is ``unlimited`` or ``limited``; the limits ride
as the extras ``points`` and ``agents`` (a whole number, or None for no limit) and ``scale`` (size name
to points), the way ``cadence`` carries ``seconds``. ``programme.py`` registers ``size-item`` and
``focus-recheck`` through ``build_verbs(host)`` and calls ``check_extras`` and ``apply`` from its term
writers. ``start-worker`` calls ``admit``, the firm gate.
"""

from __future__ import annotations

import functools
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")
programme_predicate = load_lib_module("programme_predicate")

KEY = "focus_budget"
LIMIT_NAMES = ("points", "agents")
EXTRA_NAMES = LIMIT_NAMES + ("scale",)
NO_LIMIT = "none"
OVERRIDE = "focus"
IN_PLAY_STATES = ("open", "waiting")
_SIZE_NAME = re.compile(r"^[a-z][a-z0-9_-]*$")


def _whole(host, text, what):
    text = str(text).strip()
    if not text.isdigit() or int(text) <= 0:
        raise host.ProgrammeError(f"{what} must be a positive whole number")
    return int(text)


def parse_scale(host, text) -> dict:
    scale = {}
    for part in str(text).split(","):
        name, sep, points = part.strip().partition("=")
        if not sep or not _SIZE_NAME.match(name):
            raise host.ProgrammeError(f"--scale needs name=points entries (name=1,name=3), got {part!r}")
        scale[name] = _whole(host, points, f"scale entry {name!r}: points")
    if not scale:
        raise host.ProgrammeError("--scale needs at least one name=points entry")
    return scale


def parse_extras(host, extra) -> dict:
    out = {}
    for name in LIMIT_NAMES:
        if extra.get(name) is None:
            continue
        raw = str(extra[name]).strip()
        out[name] = None if raw.casefold() == NO_LIMIT else _whole(host, raw, f"--{name}")
    if extra.get("scale") is not None:
        out["scale"] = extra["scale"] if isinstance(extra["scale"], dict) else parse_scale(host, extra["scale"])
    return out


def check_extras(host, term, value, extra) -> None:
    key = term.get("key")
    if key != KEY:
        stray = [name for name in EXTRA_NAMES if extra.get(name) is not None]
        if stray:
            raise host.ProgrammeError(f"--{stray[0]} applies to {KEY}, not {key!r}")
        return
    options = term.get("options") or []
    if value not in options:
        raise host.ProgrammeError(
            f"{value!r} fits no option of {KEY!r} (options: {options}); set a limit with "
            "`limited --points <n> [--agents <n>]`, or clear it with `unlimited`")
    given = parse_extras(host, extra)
    if value == "unlimited":
        if any(given.get(name) is not None for name in LIMIT_NAMES):
            raise host.ProgrammeError("unlimited takes no --points or --agents; use `limited` to set a limit")
        return
    merged = {name: given[name] if name in given else term.get(name) for name in LIMIT_NAMES}
    if all(merged[name] is None for name in LIMIT_NAMES):
        raise host.ProgrammeError("limited needs --points <n> or --agents <n> (a limit to hold)")


def apply(host, term, value, extra) -> None:
    if term.get("key") != KEY:
        return
    given = parse_extras(host, extra)
    if value == "unlimited":
        term.update(points=None, agents=None)
    else:
        term.update({name: given[name] for name in LIMIT_NAMES if name in given})
    if "scale" in given:
        term["scale"] = given["scale"]


def extras_of(host, key, opts) -> dict:
    return parse_extras(host, opts) if key == KEY else {}


def scale_of(programme) -> dict:
    term = programme["agreement"]["terms"].get(KEY) or {}
    return term.get("scale") if isinstance(term.get("scale"), dict) else {}


def points_of(item, scale):
    points = scale.get(item.get("size"))
    return points if isinstance(points, int) and not isinstance(points, bool) else None


def set_size(host, programme, item, size) -> None:
    scale = scale_of(programme)
    if size not in scale:
        raise host.ProgrammeError(f"size {size!r} is not in the scale (sizes: {', '.join(scale) or 'none'})")
    item["size"] = size
    item["history"].append({"at": run_record_core.now_iso(), "kind": "sized", "size": size})


def set_size_if(host, programme, item, size) -> None:
    if size is not None:
        set_size(host, programme, item, size)


def limits(programme) -> tuple:
    term = programme["agreement"]["terms"].get(KEY) or {}
    if term.get("value") != "limited":
        return None, None
    return term.get("points"), term.get("agents")


def census(programme, key, workers) -> dict:
    live = {w["pane_id"] for w in workers}
    scale = scale_of(programme)
    points = 0
    for other, item in programme["items"].items():
        if other == key or item.get("held"):
            continue
        if programme_predicate.effective_state(item) in IN_PLAY_STATES and item["owner"].get("pane") in live:
            points += points_of(item, scale) or 0
    return {"points": points, "agents": len(workers)}


def verdict(programme, key, counts):
    max_points, max_agents = limits(programme)
    if max_points is not None:
        scale = scale_of(programme)
        size = points_of(programme["items"][key], scale)
        if size is None:
            return f"unsized: size-item {key} <{'|'.join(scale) or 'size'}>"
        if counts["points"] + size > max_points:
            return f"over points: {counts['points']} of {max_points} in play (this item is {size})"
    if max_agents is not None and counts["agents"] >= max_agents:
        return f"agents at limit: {counts['agents']} of {max_agents}"
    return None


def reason_for(host, record, programme, key):
    if limits(programme) == (None, None):
        return None
    workers, why = host.programme_sources.worker_panes(programme, record)
    if workers is None:
        return f"count unavailable: herdr unreadable ({why})"
    return verdict(programme, key, census(programme, key, workers))


def _next_step(reason, key) -> str:
    if reason.startswith("unsized"):
        return f"Next: `size-item {key} <size>`, then start it again."
    if reason.startswith("count unavailable"):
        return f"Next: retry once herdr answers, or pass `--despite {OVERRIDE}`."
    return ("Next: leave it queued and run `focus-recheck` when room frees, ask Shawn for a swap, "
            f"or start it anyway with `--despite {OVERRIDE}`.")


def _commit(host, run_id, home, keys, change, kind=None, payload=None) -> None:
    seen = {}

    def mutate(rec):
        seen["sid"] = host._guard(home, rec)
        rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        for key in keys:
            change(rec["programme"]["items"][key])

    def compose(_, rec):
        return programme_journal.entry(kind, seen["sid"], payload) if kind else None

    programme_authority.write(home, run_id, mutate, compose, operation_id=None)


def _set_held(reason):
    def change(item):
        if not item.get("held"):
            item["held_at"] = run_record_core.now_iso()
        item["held"] = reason
    return change


def _clear_held(item) -> None:
    item["held"] = None
    item["held_at"] = None


def admit(host, run_id, home, record, programme, key, despite) -> None:
    item = programme["items"][key]
    reason = reason_for(host, record, programme, key)
    if reason is None:
        if item.get("held"):
            _commit(host, run_id, home, [key], _clear_held)
        return
    if OVERRIDE in despite:
        _commit(host, run_id, home, [key], _clear_held, "focus_overridden", {"item": key, "would_hold": reason})
        return
    _commit(host, run_id, home, [key], _set_held(reason), "item_held", {"item": key, "reason": reason})
    raise host.ProgrammeError(f"focus budget holds {key}: {reason}. {_next_step(reason, key)}")


def held_order(programme) -> list:
    held = [(item["held_at"] or "", key) for key, item in programme["items"].items()
            if item.get("held") and programme_predicate.effective_state(item) in IN_PLAY_STATES]
    return [key for _, key in sorted(held, key=lambda pair: pair[0])]


def _h_focus_recheck(host, argv):
    _, opts = host._parse(argv, values=("run",))
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    cleared, still, unavailable = [], [], None
    counts = None
    if limits(programme) != (None, None) and held_order(programme):
        workers, unavailable = host.programme_sources.worker_panes(programme, record)
        counts = census(programme, None, workers) if workers is not None else None
    for key in held_order(programme):
        if limits(programme) == (None, None):
            reason = None
        elif counts is None:
            reason = f"count unavailable: herdr unreadable ({unavailable})"
        else:
            reason = verdict(programme, key, counts)
        if reason is not None:
            still.append({"item": key, "reason": reason})
            continue
        cleared.append(key)
        if counts is not None:
            counts["points"] += points_of(programme["items"][key], scale_of(programme)) or 0
            counts["agents"] += 1
    if cleared:
        _commit(host, run_id, home, cleared, _clear_held)
    host._emit({"ok": True, "run": run_id, "kind": "focus_rechecked", "cleared": cleared, "held": still})
    return 0


def _h_size_item(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 2:
        raise ValueError("usage: size-item <item> <size> [--run <id>]")

    def change(programme, prompt, rec):
        key = host.programme_record._resolve(programme, positional[0])
        item = programme["items"][key]
        previous = item.get("size")
        set_size(host, programme, item, positional[1])
        return {"item": key, "size": positional[1], "previous": previous}

    return host._write(opts, change, "item_updated")


_SPECS = (
    ("size-item", _h_size_item, "<item> <size> [--run <id>]",
     "an unknown item; a size that is not a name in the agreement's focus_budget scale (the refusal lists "
     "the names)."),
    ("focus-recheck", _h_focus_recheck, "[--run <id>]",
     "any session but the driving one. Clears `held` on each held item that now fits the focus budget, in "
     "held order, counting the room each cleared item takes before testing the next; leaves the rest held "
     "and writes nothing else."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""The focus budget: how much work a programme runs at once, and the size each item carries.

``focus_budget`` is a fixed agreement term. Its value is ``unlimited`` or ``limited``; the limits ride
as the extras ``points`` and ``agents`` (a whole number, or None for no limit) and ``scale`` (size name
to points), the way ``cadence`` carries ``seconds``. ``programme.py`` registers ``size-item``,
``focus-recheck``, ``focus-note`` and ``swap-item`` through ``build_verbs(host)`` and calls ``check_extras``
and ``apply`` from its term writers. ``start-worker`` calls ``admit``, the firm gate. The status view reads
``usage`` and ``waiting``.
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
OLD_WORKER = "old worker"
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
    return {"points": points, "agents": len(workers), "live": live}


def old_worker(item, live):
    pane = item.get("parked_pane")
    if pane and pane in live:
        return (f"{OLD_WORKER} still live in pane {pane}: wait for the worker to stop, "
                f"or close the pane")
    return None


def verdict(programme, key, counts):
    stale = old_worker(programme["items"][key], counts.get("live") or ())
    if stale:
        return stale
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
    parked = programme["items"][key].get("parked_pane")
    if limits(programme) == (None, None) and not parked:
        return None
    workers, why = host.programme_sources.worker_panes(programme, record)
    if workers is None:
        if parked:
            return f"{OLD_WORKER} {parked} may still be live: herdr unreadable ({why}); retry once it answers"
        return f"count unavailable: herdr unreadable ({why})"
    return verdict(programme, key, census(programme, key, workers))


def _next_step(reason, key) -> str:
    if reason.startswith(OLD_WORKER):
        return f"Next: once the old worker has stopped, start {key} again."
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
    item.update(held=None, held_at=None, parked_pane=None)


def admit(host, run_id, home, record, programme, key, despite) -> None:
    item = programme["items"][key]
    reason = reason_for(host, record, programme, key)
    if reason is None:
        if item.get("held"):
            _commit(host, run_id, home, [key], _clear_held)
        return
    if OVERRIDE in despite and not reason.startswith(OLD_WORKER):
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
    order = held_order(programme)
    limited = limits(programme) != (None, None)
    parked = {key for key in order if programme["items"][key].get("parked_pane")}
    cleared, still, unavailable, counts = [], [], None, None
    if order and (limited or parked):
        workers, unavailable = host.programme_sources.worker_panes(programme, record)
        counts = census(programme, None, workers) if workers is not None else None
    for key in order:
        if not (limited or key in parked):
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


def usage(programme, workers) -> dict:
    max_points, max_agents = limits(programme)
    counts = census(programme, None, workers) if workers is not None else None
    noted = (programme.get("working_model") or {}).get("subagents")
    return {"points": {"limit": max_points, "used": counts and counts["points"]},
            "agents": {"limit": max_agents, "used": counts and counts["agents"]},
            "subagents": noted.get("count") if isinstance(noted, dict) else None}


def live_usage(host, record) -> dict:
    programme = programme_home.normalize_programme(record.get("programme") or {})
    if limits(programme) == (None, None):
        return usage(programme, None)
    workers, _ = host.programme_sources.worker_panes(programme, record)
    return usage(programme, workers)


def waiting(programme) -> list:
    scale = scale_of(programme)
    shown = limits(programme) != (None, None)
    out = []
    for key in held_order(programme):
        item = programme["items"][key]
        if shown or item.get("parked_pane"):
            out.append({"item": key, "size": item.get("size"), "points": points_of(item, scale),
                        "reason": item["held"], "held_at": item["held_at"],
                        "parked": bool(item.get("parked_pane"))})
    return out


def _limit_text(name, part) -> str:
    if part["limit"] is None:
        return f"{name} no limit"
    if part["used"] is None:
        return f"{name} unavailable (limit {part['limit']})"
    return f"{name} {part['used']} of {part['limit']}"


def focus_lines(focus) -> list:
    noted = focus.get("subagents")
    return [(f"  {_limit_text('points', focus['points'])} · {_limit_text('agents', focus['agents'])} · "
             f"subagents {noted if noted is not None else 'not noted'}", "text")]


def waiting_lines(entries) -> list:
    return [(f"  {n}. {e['item']}  size {e['size'] or 'unsized'}  {e['reason']}", "text")
            for n, e in enumerate(entries, 1)]


def _h_focus_note(host, argv):
    positional, opts = host._parse(argv, values=("run", "agents"))
    count = str(opts.get("agents", "")).strip()
    if positional or not count.isdigit():
        raise host.ProgrammeError("usage: focus-note --agents <n> [--run <id>] (n is a whole number, 0 or more)")

    def change(programme, prompt, rec):
        programme["working_model"]["subagents"] = {"count": int(count), "at": run_record_core.now_iso()}
        return {"subagents": int(count)}

    return host._write(opts, change, "focus_noted")


def stop_prompt(out, newcomer) -> str:
    return (f"The PM is parking this task ({out}) to make room for {newcomer}. Stop at the next safe point: "
            "commit or save what you have, say where you stopped, and then do nothing further until the PM "
            "restarts you.")


def _swap_refusal(programme, out, newcomer, workers):
    scale = scale_of(programme)
    item = programme["items"][out]
    pane = (item.get("owner") or {}).get("pane")
    live = {w["pane_id"] for w in workers}
    if programme_predicate.effective_state(item) not in IN_PLAY_STATES or item.get("held") or pane not in live:
        return f"{out} is not in play (no live worker holds it), so there is nothing to swap out"
    other = programme["items"][newcomer]
    if (programme_predicate.effective_state(other) in IN_PLAY_STATES and not other.get("held")
            and other["owner"].get("pane") in live):
        return f"{newcomer} is already in play"
    counts = census(programme, None, workers)
    freed = points_of(item, scale) or 0
    after = {"points": counts["points"] - freed, "agents": counts["agents"] - 1, "live": live - {pane}}
    reason = verdict(programme, newcomer, after)
    if reason is None:
        return None
    max_points, _ = limits(programme)
    size = points_of(programme["items"][newcomer], scale)
    if reason.startswith("over points") and size is not None:
        missing = after["points"] + size - max_points
        return (f"parking {out} frees {freed} point(s), but {newcomer} needs {missing} more point(s) "
                f"({reason}); pick a bigger item to swap out or queue {newcomer}")
    return f"parking {out} would not let {newcomer} start: {reason}"


def _h_swap_item(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 2 or not opts.get("prompt"):
        raise ValueError("usage: swap-item <out> <in> --prompt <pick id> [--run <id>]")
    run_id, home, record = host._locate(opts)
    workers, why = host.programme_sources.worker_panes(
        programme_home.normalize_programme(record.get("programme") or {}), record)

    def change(programme, prompt, rec):
        if prompt.get("origin") != "picked":
            raise host.ProgrammeError(
                f"swap-item needs a pick of its exact label, not typed or suggested text; run "
                f"`programme.sh approval-label swap-item {positional[0]} {positional[1]}`")
        if workers is None:
            raise host.ProgrammeError(f"swap refused: cannot count workers, herdr unreadable ({why}); retry")
        out = host.programme_record._resolve(programme, positional[0])
        newcomer = host.programme_record._resolve(programme, positional[1])
        if out == newcomer:
            raise host.ProgrammeError("swap-item needs two different items")
        if programme["items"][newcomer]["state"] in programme_home.FINISHED_ITEM_STATES:
            raise host.ProgrammeError(f"item {newcomer!r} is {programme['items'][newcomer]['state']}")
        refusal = _swap_refusal(programme, out, newcomer, workers)
        if refusal:
            raise host.ProgrammeError(f"swap refused: {refusal}")
        item = programme["items"][out]
        item.update(held=f"parked: swapped out for {newcomer}", held_at=run_record_core.now_iso(),
                    parked_pane=item["owner"]["pane"])
        item["history"].append({"at": item["held_at"], "kind": "parked", "for": newcomer,
                                "prompt_id": prompt["prompt_id"]})
        decision = host.programme_decisions.shawn_decision(
            programme, kind="work_sequencing", item=newcomer, prompt=prompt, out=out, **{"in": newcomer})
        text = stop_prompt(out, newcomer)
        return {"out": out, "in": newcomer, "parked_pane": item["parked_pane"], "decision_id": decision["id"],
                "stop_prompt": text,
                "next": f"programme.sh prompt-item {out} <stop_prompt>, then start-worker {newcomer}"}

    return host._write(opts, change, "item_swapped", prompt_id=opts["prompt"], needs_prompt=True,
                       verb="swap-item")


_SPECS = (
    ("size-item", _h_size_item, "<item> <size> [--run <id>]",
     "an unknown item; a size that is not a name in the agreement's focus_budget scale (the refusal lists "
     "the names)."),
    ("focus-note", _h_focus_note, "--agents <n> [--run <id>]",
     "a missing or non-numeric --agents. Records how many subagents the PM is running with, for the status "
     "view; the plugin cannot count them."),
    ("swap-item", _h_swap_item, "<out> <in> --prompt <pick id> [--run <id>]",
     "typed or suggested text (only a pick whose answer is exactly the approval-label for this command "
     "approves it); an <out> no live worker holds; an <in> that parking <out> would still not let start (the "
     "refusal names the missing points); herdr unreadable. Parks <out>: held with a reason, its old pane "
     "recorded, its points freed, and returns the stop prompt for its worker. Records a work_sequencing "
     "decision naming both items. <in> then starts through start-worker."),
    ("focus-recheck", _h_focus_recheck, "[--run <id>]",
     "any session but the driving one. Clears `held` on each held item that now fits the focus budget, in "
     "held order, counting the room each cleared item takes before testing the next; leaves the rest held "
     "and writes nothing else."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

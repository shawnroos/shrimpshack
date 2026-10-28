#!/usr/bin/env python3
"""The focus budget: how much work a programme runs at once, and the size each item carries.

``focus_budget`` is a fixed agreement term. Its value is ``unlimited`` or ``limited``; the limits ride
as the extras ``points`` and ``agents`` (a whole number, or None for no limit) and ``scale`` (size name
to points), the way ``cadence`` carries ``seconds``. ``programme.py`` registers ``size-item`` through
``build_verbs(host)`` and calls ``check_extras`` and ``apply`` from its term writers.
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

KEY = "focus_budget"
LIMIT_NAMES = ("points", "agents")
EXTRA_NAMES = LIMIT_NAMES + ("scale",)
NO_LIMIT = "none"
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
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

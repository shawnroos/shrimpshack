#!/usr/bin/env python3
"""Word matching for names: display labels, and whether a `pick-term` answer holds the value it sets."""

from __future__ import annotations

import functools
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")

_NAME_WORD = re.compile(r"[0-9a-z_\-]+")
_NAME_JOINERS = re.compile(r"[_\-]")
NEGATIONS = ("not", "never", "no", "dont", "t")


def label(name, ident) -> str:
    name = str(name or "").strip()
    return f"{name} ({ident})" if name and name != ident else str(ident)


def name_words(text) -> list:
    words = (_NAME_JOINERS.sub("", w) for w in _NAME_WORD.findall(str(text or "").casefold()))
    return [w for w in words if w]


@functools.lru_cache(maxsize=4096)
def _squash(text) -> str:
    return "".join(name_words(text))


def squash(text) -> str:
    return _squash(str(text or ""))


def runs(words, name) -> list:
    found = []
    for start in range(len(words)):
        joined = ""
        for end in range(start, len(words)):
            joined += words[end]
            if joined == name:
                found.append((start, end))
            if not name.startswith(joined) or joined == name:
                break
    return found


def affirmed(words, start) -> bool:
    return start == 0 or words[start - 1] not in NEGATIONS


def _levels_named(words) -> set:
    found, used = set(), set()
    for level in sorted(programme_home.AUTONOMY_LEVELS, key=lambda lv: -len(squash(lv))):
        for start, end in runs(words, squash(level)):
            span = set(range(start, end + 1))
            if span & used:
                continue
            used |= span
            if affirmed(words, start):
                found.add(level)
    return found


def _named(words, levels, option) -> bool:
    if option in programme_home.AUTONOMY_LEVELS:
        return option in levels
    return any(affirmed(words, start) for start, _ in runs(words, squash(option)))


def missing(quote, needs) -> list:
    words = name_words(quote)
    levels = _levels_named(words)
    out = []
    for need in needs:
        options = [o for o in (need if isinstance(need, (list, tuple)) else (need,)) if squash(o)]
        if not options:
            out.append(f"a usable name for {need!r}")
        elif not any(_named(words, levels, o) for o in options):
            out.append(" or ".join(repr(o) for o in options))
    return out


def item_name(key, item) -> str:
    sessions = [s.get("name") for s in item.get("sessions") or [] if isinstance(s, dict) and s.get("name")]
    return label(item.get("title") or (sessions[-1] if sessions else None), key)

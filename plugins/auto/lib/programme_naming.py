#!/usr/bin/env python3
"""Whether a typed prompt's words name what it approves.

``programme.py`` turns a non-empty result into its own refusal; this module never raises.
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

programme_home = load_lib_module("programme_home")
run_record_core = load_lib_module("run_record_core")

_NAME_WORD = re.compile(r"[0-9a-z_\-]+")
_NAME_JOINERS = re.compile(r"[_\-]")
NEGATIONS = ("not", "never", "no", "dont", "t")
ASK_CHOICES = ("ship", "decline")
CHOICE_WORDS = ASK_CHOICES + ("drop", "reopen")
FINAL_ITEM_STATES = tuple(s for s in programme_home.FINISHED_ITEM_STATES if s != "handed")
MIN_HUMAN_NAME = 6  # a shorter squashed title ("ok", "fix") turns up in ordinary replies


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


def _id_forms(key, item) -> list:
    return [form for item_id in [key, *(item.get("aliases") or [])]
            for form in (item_id.split(":", 1)[-1], item_id)]


def item_name(key, item) -> str:
    sessions = [s.get("name") for s in item.get("sessions") or [] if isinstance(s, dict) and s.get("name")]
    return label(item.get("title") or (sessions[-1] if sessions else None), key)


def live_items(items, key) -> dict:
    return {k: i for k, i in items.items() if i.get("state") not in FINAL_ITEM_STATES or k == key}


def _human_raw(item) -> list:
    raws = [item.get("title")] + [s.get("name") for s in item.get("sessions") or [] if isinstance(s, dict)]
    return [r for r in raws if len(squash(r)) >= MIN_HUMAN_NAME and squash(r) not in CHOICE_WORDS + NEGATIONS]


def _id_named(words, key, item) -> bool:
    return any(affirmed(words, start) for form in _id_forms(key, item) for start, _ in runs(words, squash(form)))


def _id_starts(words, key, item) -> list:
    return [start for form in _id_forms(key, item) for start, _ in runs(words, squash(form)) if affirmed(words, start)]


def _id_chosen(words, key, item, choice) -> bool:
    opposite = [c for c in ASK_CHOICES if c != choice]
    if any(w in opposite and affirmed(words, i) for i, w in enumerate(words)):
        return False
    return any(words[j] == choice and affirmed(words, j) for s in _id_starts(words, key, item) for j in range(s))


def _name_starts(words, item) -> list:
    return [start for raw in _human_raw(item) for start, _ in runs(words, squash(raw))]


def _chosen(words, start, choice) -> bool:
    return start > 0 and words[start - 1] == choice and affirmed(words, start - 1)


def _named_set(words, live, key, choice, fresh, asked=False) -> list:
    out = []
    for k, item in live.items():
        if k == key:
            # An ask's answer needs the same choice word and freshness whether it names the id or a name.
            by_id = (fresh and _id_chosen(words, k, item, choice)) if asked else _id_named(words, k, item)
            hit = by_id or (fresh and any(_chosen(words, s, choice) for s in _name_starts(words, item)))
        else:
            hit = _id_named(words, k, item) or any(affirmed(words, s) for s in _name_starts(words, item))
        if hit:
            out.append(k)
    return out


def reply(live, key, choice) -> str:
    for raw in _human_raw(live[key]):
        candidate = f"{choice} {raw}"
        if _named_set(name_words(candidate), live, key, choice, True, True) == [key]:
            return candidate
    return f"{choice} {key}"


def item_refusal(quote, items, key, choice, *, prompt_at=None, ask=None):
    words = name_words(quote)
    live = live_items(items, key)
    fresh = True
    if ask is not None:
        set_at = run_record_core.parse_iso(ask.get("facts_at") or ask.get("at"))
        typed_at = run_record_core.parse_iso(prompt_at)
        fresh = bool(set_at and typed_at and typed_at >= set_at)
    named = _named_set(words, live, key, choice, fresh, ask is not None)
    if named == [key]:
        return None
    if key in named:
        return ("its text names more than one open item; type one of "
                + ", ".join(repr(reply(live, k, choice)) for k in named))
    if not fresh and (any(_chosen(words, s, choice) for s in _name_starts(words, live[key]))
                      or _id_chosen(words, key, live[key], choice)):
        return f"it was typed before the ask's current facts were set; type {reply(live, key, choice)!r}"
    return f"its text does not name {key!r} after {choice!r}; type {reply(live, key, choice)!r}"


def missing_sources(quote, before, after) -> list:
    # A source is turned off in words like "no plans", so a negated name still counts here.
    words = set(name_words(quote))
    return [name for name in sorted(set(before) ^ set(after)) if squash(name) not in words]

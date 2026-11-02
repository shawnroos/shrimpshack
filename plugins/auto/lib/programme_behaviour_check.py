#!/usr/bin/env python3
"""Code cannot tell that two behaviours disagree in meaning, so every row names the closed-set reason that
listed it and carries both sides' lines for the PM to read; only the structural cases in ``FLAGGED`` are
marked ``may_contradict``.
"""

from __future__ import annotations

import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_naming = load_lib_module("programme_naming")

REASONS = ("same_trigger", "shared_when", "instruction_touches_situation", "shared_tool", "equal_do_dont",
           "tool_forbidden_in_dont")
FLAGGED = ("equal_do_dont", "tool_forbidden_in_dont")
MAY_CONTRADICT = "may_contradict"
NOT_DETECTED = "opposite meaning is not detected: read each listed pair, and note that a short list is not a pass"
# One shared word measured as noise: 43 of the 48 pairs the old rule listed shared exactly one.
WORD_FLOOR = 2
COMMON = ("stop", "the", "and", "for", "when", "with", "that", "this", "its", "from", "into", "are", "was",
          "not", "all", "any", "each", "work", "item")
NAMED = ("tools", "skills", "agents")
_REF_RE = re.compile(r"^[a-z][a-z0-9-]*(:[A-Za-z0-9_.-]+)?$")


def content_words(text) -> set:
    return {w for w in programme_naming.name_words(text or "") if len(w) >= 3 and w not in COMMON}


def tokens(text) -> list:
    return re.findall(r"[a-z0-9]+", (text or "").lower())


def phrase_key(text) -> str:
    return " ".join(tokens(text))


def _situation(entry) -> set:
    return content_words(entry["when"]["text"])


def _instructions(entry) -> set:
    return content_words(" ".join((entry.get("do") or []) + (entry.get("dont") or [])))


def named_tools(entry) -> dict:
    return {phrase_key(n): n for field in NAMED for n in entry.get(field) or [] if phrase_key(n)}


def _audiences(entry) -> set:
    return {"pm", "workers"} if entry["applies_to"] == "both" else {entry["applies_to"]}


def co_apply(entry, other) -> bool:
    if other["id"] == entry["id"] or other.get("state", "active") != "active":
        return False
    if not _audiences(entry) & _audiences(other):
        return False
    keys = {entry.get("repo_key"), other.get("repo_key")}
    return len(keys - {None}) < 2


def _forbids(entry, other) -> list:
    banned = [set(tokens(line)) for line in other.get("dont") or []]
    return sorted(name for key, name in named_tools(entry).items()
                  if any(set(key.split()) <= line for line in banned))


def _equal(entry, other) -> set:
    banned = {phrase_key(line) for line in other.get("dont") or []}
    return {key for key in map(phrase_key, entry.get("do") or []) if key in banned}


def _reasons(entry, other) -> list:
    out = []

    def add(reason, detail):
        out.append({"reason": reason, "detail": detail})

    trigger = entry["when"].get("trigger")
    if trigger and trigger == other["when"].get("trigger"):
        add("same_trigger", [trigger])
    shared = sorted(_situation(entry) & _situation(other))
    if len(shared) >= WORD_FLOOR:
        add("shared_when", shared)
    touches = sorted((_situation(entry) & _instructions(other)) | (_situation(other) & _instructions(entry)))
    if len(touches) >= WORD_FLOOR:
        add("instruction_touches_situation", touches)
    tools = sorted(set(named_tools(entry)) & set(named_tools(other)))
    if tools:
        add("shared_tool", tools)
    equal = sorted(_equal(entry, other) | _equal(other, entry))
    if equal:
        add("equal_do_dont", equal)
    forbidden = sorted(set(_forbids(entry, other)) | set(_forbids(other, entry)))
    if forbidden:
        add("tool_forbidden_in_dont", forbidden)
    return out


def answers_valid(entry, field) -> bool:
    rows = entry.get(field, [])
    if not isinstance(rows, list):
        return False
    if field == "relates_to":
        return all(isinstance(r, str) and _REF_RE.match(r) for r in rows)
    return all(isinstance(u, dict) and set(u) == {"id", "reason"} and _REF_RE.match(str(u["id"]))
               and isinstance(u["reason"], str) and u["reason"].strip() for u in rows)


def row(entry, reasons) -> dict:
    out = {"ref": entry["id"], "kind": "behaviour", "layer": entry["layer"], "text": entry["when"]["text"],
           "reasons": reasons,
           "lines": {"do": list(entry.get("do") or []), "dont": list(entry.get("dont") or []),
                     "stop": entry.get("stop")}}
    if any(r["reason"] in FLAGGED for r in reasons):
        out["flag"] = MAY_CONTRADICT
    return out


def check(entry, others) -> list:
    rows = []
    for other in others:
        if co_apply(entry, other):
            reasons = _reasons(entry, other)
            if reasons:
                rows.append(row(other, reasons))
    return rows

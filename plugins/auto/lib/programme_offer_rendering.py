#!/usr/bin/env python3
"""The parts of an offer's rendering that programme_offers and programme_offers_stores share."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")

LABEL_CAP = 80
# Room for a whole draft at the verbs' cap plus the facts around it: Shawn approves what he can read.
TEXT_CAP = 900
_FLAGS = ("ran-now", "widening", "without-rituals", "own")
# What one option's label can name in full.
MAX_SET = 4


class OfferError(Exception):
    pass


# Verbs clean free text to DEFAULT_CAP, so longer text would be shown whole and recorded cut.
def recorded_text(text, cap=programme_sanitize.DEFAULT_CAP) -> str:
    cleaned = programme_sanitize.clean(text, cap=0)
    if len(cleaned) > cap:
        raise OfferError(f"the draft is {len(cleaned)} characters and the record holds {cap}; "
                         "shorten it, since Shawn approves all of what is recorded")
    return programme_journal.redact(cleaned)


class Command:
    def __init__(self, argv, doc=None):
        self.verb = argv[0]
        self.doc = doc
        self.pos, self._given, self._read = [], {}, set()
        args = list(argv[1:])
        while args:
            arg = args.pop(0)
            if not arg.startswith("--"):
                self.pos.append(arg)
            elif arg[2:] in _FLAGS:
                self._given[arg[2:]] = True
            elif args and not args[0].startswith("--"):
                self._given.setdefault(arg[2:], []).append(args.pop(0))
            else:
                raise OfferError(f"{arg} needs a value that does not start with --")

    def opt(self, name, default="", cap=programme_sanitize.DEFAULT_CAP):
        self._read.add(name)
        value = self._given.get(name)
        if isinstance(value, list) and len(value) > 1:
            raise OfferError(f"--{name} is given {len(value)} times; the verb keeps only the last, so give it once")
        if isinstance(value, list):
            if cap is not None:
                recorded_text(value[0], cap)
            return value[0]
        return value if value is not None else default

    def many(self, name) -> list:
        self._read.add(name)
        values = list(self._given.get(name) or [])
        for value in values:
            recorded_text(value)
        return values

    def flag(self, name) -> bool:
        self._read.add(name)
        return name in self._given

    def first(self, verb_usage) -> str:
        if not self.pos:
            raise OfferError(f"usage: {self.verb} {verb_usage}")
        return self.pos[0]

    def one_of(self, name, allowed) -> str:
        value = self.opt(name)
        if value not in allowed:
            raise OfferError(f"{self.verb} needs --{name} {'|'.join(allowed)}")
        return value

    def extras(self, *used, multi=(), stored_whole=()) -> str:
        words = []
        for name in self._given:
            if name in used:
                continue
            if name in multi:
                value = " and ".join(self.many(name))
            else:
                value = self.opt(name, cap=None if name in stored_whole else programme_sanitize.DEFAULT_CAP)
            words.append(f"{name.replace('-', ' ')}: {value}.")
        return " ".join(words)

    def unread(self) -> list:
        return sorted(set(self._given) - self._read)


def _whole(text, cap, what) -> str:
    shown = programme_journal.redact(programme_sanitize.clean(text, cap=0))
    if len(shown) > cap:
        raise OfferError(f"the {what} is {len(shown)} characters and an option shows {cap}, and Shawn approves what he "
                         "can read, so it is never cut; split it across pickers, or shorten it")
    return shown


# Multi-select joins labels with ", ", so a label holding that text reads as two answers.
def _label(text) -> str:
    return _whole(str(text).replace(", ", " and "), LABEL_CAP, "label")


def fitting(label, shorter) -> str:
    return label if len(programme_sanitize.clean(label, cap=0)) <= LABEL_CAP else shorter


def rendered(label, description="", facts=None, authority=False, content=None, cap=TEXT_CAP) -> dict:
    return {"label": _label(label), "description": _whole(description, cap, "description"), "facts": facts,
            "authority": authority, "content": content}


def layered(module_name, programme, ident):
    module = load_lib_module(module_name)
    lookup = load_lib_module("programme_approval").prompt_lookup
    return module._programme_entry(programme, ident) or module._stored_entry(module.load_store(lookup), ident)


def whole_set(label, ids) -> str:
    if len(ids) > MAX_SET or len(label) > LABEL_CAP:
        raise OfferError(f"{len(ids)} ids do not fit one option; split them across pickers, one offer each")
    return label

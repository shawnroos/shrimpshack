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
TEXT_CAP = 300
_FLAGS = ("ran-now", "widening", "without-rituals")
# What one option can show in full: the label and the 300-character description hold about this many ids and scopes.
MAX_SET = 4
_CONTENT = {"doc": None}


class OfferError(Exception):
    pass


def note_content(doc) -> None:
    _CONTENT["doc"] = doc


def noted_content():
    return _CONTENT["doc"]


class Command:
    def __init__(self, argv):
        self.verb = argv[0]
        self.pos, self.opts = [], {}
        args = list(argv[1:])
        while args:
            arg = args.pop(0)
            if not arg.startswith("--"):
                self.pos.append(arg)
            elif arg[2:] in _FLAGS:
                self.opts[arg[2:]] = True
            elif args:
                self.opts.setdefault(arg[2:], []).append(args.pop(0))
            else:
                raise OfferError(f"{arg} needs a value")

    def opt(self, name, default=""):
        value = self.opts.get(name)
        return " and ".join(value) if isinstance(value, list) else (value if value is not None else default)

    def first(self, verb_usage) -> str:
        if not self.pos:
            raise OfferError(f"usage: {self.verb} {verb_usage}")
        return self.pos[0]

    def one_of(self, name, allowed) -> str:
        value = self.opt(name)
        if value not in allowed:
            raise OfferError(f"{self.verb} needs --{name} {'|'.join(allowed)}")
        return value

    def extras(self, *used) -> str:
        return " ".join(f"{name.replace('-', ' ')}: {self.opt(name)}." for name in self.opts if name not in used)


def _shown(text, cap=TEXT_CAP) -> str:
    return programme_journal.redact(programme_sanitize.clean(text, cap))


# Multi-select joins labels with ", ", so a label holding that text reads as two answers.
def _label(text) -> str:
    return _shown(str(text).replace(", ", " and "), LABEL_CAP)


def rendered(label, description="", facts=None, authority=False, content=None, cap=TEXT_CAP) -> dict:
    return {"label": _label(label), "description": _shown(description, cap), "facts": facts, "authority": authority,
            "content": content}


def layered(module_name, programme, ident):
    module = load_lib_module(module_name)
    lookup = load_lib_module("programme_approval").prompt_lookup
    return module._programme_entry(programme, ident) or module._stored_entry(module.load_store(lookup), ident)


def whole_set(label, ids) -> str:
    if len(ids) > MAX_SET or len(label) > LABEL_CAP:
        raise OfferError(f"{len(ids)} ids do not fit one option; split them across pickers, one offer each")
    return label

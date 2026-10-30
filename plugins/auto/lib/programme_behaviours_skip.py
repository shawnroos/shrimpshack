#!/usr/bin/env python3
"""``skip-behaviour``: the PM's answer to a due behaviour that is not sent to the worker.

It records the PM's own judgment, so it needs no typed prompt. Without ``--applied`` the row means
"does not apply to this item"; with it, the PM applied a PM-only behaviour itself.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviours = load_lib_module("programme_behaviours")
programme_record = load_lib_module("programme_record")
programme_sanitize = load_lib_module("programme_sanitize")

SKIPPED = "behaviour_skipped"
WHY_CAP = 300


def _h_skip(host, argv):
    positional, opts = host._parse(argv, values=("run", "why"), flags=("applied",))
    why = programme_sanitize.clean(opts.get("why") or "", WHY_CAP)
    if len(positional) != 2 or not why:
        raise ValueError("usage: skip-behaviour <item> <id> --why <line> [--applied] [--run <id>]")
    item_id, bid = programme_record.check_item_id(positional[0]), positional[1]
    reason = "applied_by_pm" if opts.get("applied") else "skipped"

    def change(programme, _prompt, rec):
        key = programme_record._resolve(programme, item_id)
        item = programme["items"][key]
        in_force = programme_behaviours.in_force(dict(rec, programme=programme), item, lookup=host.prompt_lookup)
        if not any(e["id"] == bid for e in in_force):
            raise programme_behaviours.BehaviourError(
                f"behaviour {bid!r} is not in force for {key!r} (unknown, retired or overridden)")
        programme_behaviours.record_delivery(item, bid, reason, "skip-behaviour", why=why)
        return {"item": key, "behaviour": bid, "reason": reason, "why": why}

    return host._write(opts, change, SKIPPED, verb="skip-behaviour", target=bid)


_SPECS = (
    ("skip-behaviour", _h_skip, "<item> <id> --why <line> [--applied] [--run <id>]",
     "a session that does not drive the programme; no --why; an unknown item; a behaviour not in force for the "
     "item (unknown, retired or overridden). Records the answer on the item (reason skipped, or applied_by_pm "
     "with --applied, for a PM-only behaviour the PM applied itself) and sends nothing to the worker."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

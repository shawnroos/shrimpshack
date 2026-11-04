#!/usr/bin/env python3
"""Shawn's answer to the picker of `end` or `handover`, the route beside their typed slash requests."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_offers = load_lib_module("programme_offers")
session_registry = load_lib_module("session_registry")


def approve(run, sid, argv, prompt_id, status, refused) -> dict:
    verb = argv[0]
    offer_fix = load_lib_module("programme_fixes").fix_for(verb)

    def error(reason, fix=None):
        return refused(reason, status, fix=offer_fix if fix is None or "approval-label" in fix else fix)

    record = programme_home._read_record(run) or {}
    if not session_registry.caller_drives(record, sid):
        raise error(f"only the driving session may {verb} through a picker")
    rows = programme_journal.read(run)
    row = programme_journal.find_prompt(run, prompt_id, rows)
    if row is not None and rows.index(row) <= load_lib_module("programme_lifecycle")._last_driver_change(rows):
        raise error(f"prompt {prompt_id!r} was given before the current PM took the programme")
    if row is not None and programme_journal.prompt_origin(row) == "picked" \
            and programme_offers.offer_for(rows, row) is None:
        raise error(f"pick {prompt_id!r} answers a picker no offer printed, so it approves nothing")
    approval = load_lib_module("programme_approval")
    found = approval.prompt(run, record, prompt_id, verb, error, approval.text_hash, argv)
    # Only an offer binds the command: the older checks stand a typed message with no named words, and these verbs have none.
    if not found.get("named"):
        raise error(f"prompt {prompt_id!r} answers no offer of this command, so it approves nothing")
    return {"request": None, "prompt_id": prompt_id, "quote": found["quote"], **found.get("reading", {}),
            "approval": {key: found[key] for key in ("origin", "answer") if key in found}}

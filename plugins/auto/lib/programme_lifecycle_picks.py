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
session_registry = load_lib_module("session_registry")


def approve(run, sid, argv, prompt_id, status, refused) -> dict:
    verb = argv[0]
    offer_fix = load_lib_module("programme_fixes").fix_for(verb)

    def error(reason, fix=None):
        return refused(reason, status, fix=fix or offer_fix)

    record = programme_home._read_record(run) or {}
    if not session_registry.caller_drives(record, sid):
        raise error(f"only the driving session may {verb} through a picker")
    rows = programme_journal.read(run)
    row = programme_journal.find_prompt(run, prompt_id, rows)
    if row is not None and rows.index(row) <= load_lib_module("programme_lifecycle")._last_driver_change(rows):
        raise error(f"prompt {prompt_id!r} was given before the current PM took the programme")
    approval = load_lib_module("programme_approval")
    found = approval.prompt(run, record, prompt_id, verb, error, approval.text_hash, argv)
    return {"request": None, "prompt_id": prompt_id, "quote": found["quote"], **programme_journal.reading_of(found),
            "approval": {key: found[key] for key in ("origin", "answer") if key in found}}

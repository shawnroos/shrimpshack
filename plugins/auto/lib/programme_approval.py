from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")

TYPED_ONLY = ("accept-agreement", "edit-project-term")


def prompt(run_id, record, prompt_id, verb, error, text_hash) -> dict:
    if not prompt_id:
        raise error("this approval needs --prompt <id> of a typed prompt or a pick")
    rows = programme_journal.read(run_id)
    row = programme_journal.find_prompt(run_id, prompt_id, rows)
    if row is None:
        raise error(f"no prompt {prompt_id!r} in this programme's journal")
    payload = row.get("payload") or {}
    if row.get("provenance") in programme_authority.UNVERIFIED:
        raise error(f"prompt {prompt_id!r} was imported from a legacy journal or appended by an "
                    "obsolete writer; its typed label is unverified, so it approves nothing new")
    origin = programme_journal.prompt_origin(row)
    if origin == "picked" and verb in TYPED_ONLY:
        raise error(f"{verb} needs a typed prompt; prompt {prompt_id!r} is a pick")
    if origin not in ("typed", "picked"):
        raise error(f"prompt {prompt_id!r} is not typed or a verified pick "
                    f"(origin {origin!r}; human source unverified)")
    if row.get("session_id") != record.get("driving_session_id"):
        raise error(f"prompt {prompt_id!r} was not typed in the driving session")
    approval = {"prompt_id": prompt_id, "quote": payload.get("text") or "", "origin": origin,
                "text_hash": text_hash(payload.get("text")), "at": row.get("at"), "origin_verified": True}
    if origin == "picked":
        approval["answer"] = programme_journal.pick_answer(rows, row)
    return approval

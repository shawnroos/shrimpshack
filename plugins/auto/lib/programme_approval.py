from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")
programme_protocol = load_lib_module("programme_protocol")
programme_naming = load_lib_module("programme_naming")

# Default-deny: a pick or an accepted suggestion approves only these verbs, each of which checks that the
# approval names its target. Verbs that record the prompt's words as content stay typed-only.
PICK_VERBS = frozenset((
    "adopt-rule", "adopt-autonomy", "adopt-check", "set-remit", "amend-term", "correct-term", "undo-correction",
    "keep-corrections", "promote-correction", "move-behaviour", "retire-behaviour", "keep-behaviours",
    "drop-item", "reopen-item", "answer-handed", "accept-context", "lift-pause", "answer-permission",
    "dispose-action"))


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
    if origin in ("picked", "suggested") and verb not in PICK_VERBS:
        raise error(f"{verb or 'this verb'} needs a typed prompt; prompt {prompt_id!r} is "
                    f"{'a pick' if origin == 'picked' else 'an accepted suggestion'}")
    if origin not in programme_protocol.HUMAN_ORIGINS:
        raise error(f"prompt {prompt_id!r} is not typed or a verified pick "
                    f"(origin {origin!r}; human source unverified)")
    if row.get("session_id") != record.get("driving_session_id"):
        raise error(f"prompt {prompt_id!r} was not typed in the driving session")
    approval = {"prompt_id": prompt_id, "quote": payload.get("text") or "", "origin": origin,
                "text_hash": text_hash(payload.get("text")), "at": row.get("at"), "origin_verified": True}
    if origin == "picked":
        approval["answer"] = programme_journal.pick_answer(rows, row)
        # Naming checks only look at the word before a name, so "No, do not adopt r1" would name r1.
        if set(programme_naming.name_words(approval["answer"])) & set(programme_naming.NEGATIONS):
            raise error(f"pick {prompt_id!r} answer {approval['answer']!r} is not a plain yes; "
                        "a pick approves only an answer with no negation")
    return approval

#!/usr/bin/env python3
"""Permission proposal states, the one table of moves between them, and the item notes they leave."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_record = load_lib_module("programme_record")
rules = load_lib_module("programme_permission_rules")

RecordError = programme_record.RecordError

OPEN, POSTPONED, REJECTED = "open", "postponed", "rejected"
RETRYING, RESOLVED = "retrying", "resolved"
INEFFECTIVE, RETRY_UNOBSERVED = "ineffective", "retry_unobserved"
ASKING_STATES = rules.ASKING_STATES
QUIET_STATES = (POSTPONED, REJECTED)
DECLINED_STATE = {"not-now": POSTPONED, "no": REJECTED}
# Not states: VERIFY lets the settings check pick the next state; DEFER holds a decline until the retry settles.
VERIFY, DEFER = "verify", "defer"

# (state, event) → next state. Events are Shawn's typed choices and settlement outcomes; a missing pair is refused.
TRANSITIONS = {
    **{(s, "applied"): VERIFY for s in (OPEN, POSTPONED, REJECTED, INEFFECTIVE, RETRY_UNOBSERVED)},
    (RETRYING, "applied"): RETRYING,
    **{(s, c): DECLINED_STATE[c] for s in ASKING_STATES for c in DECLINED_STATE},
    **{(s, c): s for s in QUIET_STATES for c in DECLINED_STATE},
    **{(RETRYING, c): DEFER for c in DECLINED_STATE},
    **{(RETRYING, seen): seen for seen in (RESOLVED, INEFFECTIVE, RETRY_UNOBSERVED)},
    (OPEN, RESOLVED): RESOLVED,
}


def step(proposal, event) -> str:
    found = TRANSITIONS.get((proposal.get("state"), event))
    if found is None:
        raise RecordError(f"{proposal.get('id')} is {proposal.get('state')}; Programme no longer asks about it")
    return found


def move(proposal, state) -> None:
    if proposal.get("state") != state:
        proposal.update(state=state, changed_at=run_record_core.now_iso())


def record_answer(proposal, choice, prompt, state) -> dict:
    before = proposal["state"]
    proposal.setdefault("answers", []).append({"at": run_record_core.now_iso(), "choice": choice,
                                               "prompt_id": prompt["prompt_id"], "from": before, "to": state})
    move(proposal, state)
    return {"proposal": proposal["id"], "choice": choice, "state": state, "from": before}


def proposals(programme) -> list:
    found = programme.get("permission_proposals")
    return [p for p in found if isinstance(p, dict)] if isinstance(found, list) else []


def find(programme, proposal_id):
    return next((p for p in proposals(programme) if p.get("id") == proposal_id), None)


def note(item, cause, detail, proposal=None) -> None:
    block = dict(item.get("permission_block") or {})
    linked = list(block.get("proposals") or [])
    if proposal and proposal not in linked:
        linked.append(proposal)
    block.update(cause=cause, detail=detail, at=run_record_core.now_iso(), proposals=linked)
    item["permission_block"] = block


def note_items(programme, proposal, cause, detail) -> None:
    for key in proposal.get("items") or []:
        if key in programme["items"]:
            note(programme["items"][key], cause, detail, proposal=proposal["id"])

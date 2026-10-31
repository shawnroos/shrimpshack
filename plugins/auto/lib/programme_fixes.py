#!/usr/bin/env python3
"""Default `fix:` line for each programme verb, printed when a refusal carries no fix of its own."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

FALLBACK = "programme.sh become-pm"

_WRITE = ("`programme.sh become-pm` if this session does not drive the programme; "
          "else `programme.sh status` for the current state and `programme.sh describe` for what {verb} refuses")
_ITEM = ("`programme.sh status` lists the items and their state; `programme.sh describe` names what {verb} "
         "needs, then rerun it")
_READ = "`programme.sh status` names the programme run ids; rerun `programme.sh {verb}` with --run <id>"
_PICKED = ("run `programme.sh approval-label {verb} <args>`, offer its output as one AskUserQuestion option, "
           "then rerun citing the pick with --prompt <pick id>")
_TYPED = "ask Shawn to type the approval for {verb} in this session, then rerun with --prompt <its id>"
_PICK_ID = "ask Shawn with an AskUserQuestion picker, then rerun citing the pick with --pick <pick id>"
_START = ("`programme.sh become-pm` if a programme already holds this space; else the refusal names what "
          "start needs, such as a herdr pane or --space <server.workspace>")
_LABEL = ("rerun `programme.sh approval-label <verb> <args>` with a verb a pick can approve "
          "(`programme.sh describe` lists them), or `approval-label takeover --replace <driving session id>`")
_ENDED = ("`programme.sh check-archive --run <id>` names each failed check and its remedy; "
          "`programme.sh status --run <id>` shows the end state")

FIXES = {
    "accept-agreement": load_lib_module("programme_approval").ACCEPT_FIX,
    "accept-context": _PICKED,
    "ack-protocol": _WRITE,
    "add-item": _ITEM,
    "adopt-autonomy": _PICKED,
    "adopt-check": _PICKED,
    "adopt-rule": _PICKED,
    "alias-item": _ITEM,
    "amend-term": _PICKED,
    "answer-handed": _PICKED,
    "answer-permission": _PICKED,
    "approval-label": _LABEL,
    "archive": _ENDED,
    "ask-relayed": _ITEM,
    "ask-shown": _ITEM,
    "assign-item": _ITEM,
    "beat": _WRITE,
    "carry-rulings": _TYPED,
    "become-pm": ("run Claude from a pane in the space the programme leases, "
                  "then rerun `programme.sh become-pm` there"),
    "check-archive": _ENDED,
    "check-deliverable": _ITEM,
    "check-mergeable": _ITEM,
    "claim": ("`programme.sh context --item <id> --run <id>` lists the item's deliverables; "
              "rerun `programme.sh claim` with one of them and a reference with no spaces"),
    "clear-blocker": _ITEM,
    "clear-proposal": _WRITE,
    "close-ruling": _TYPED,
    "collect-result": _ITEM,
    "context": _READ,
    "create-successor": _ENDED,
    "define-requirement": _TYPED,
    "describe": "rerun `programme.sh describe` with no arguments",
    "dispose-action": _PICKED,
    "dispose-item": _ENDED,
    "drop-item": _PICKED,
    "edit-project-term": _TYPED,
    "end": "ask Shawn to type /auto:programme-end in this session, then rerun `programme.sh end`",
    "expire": _ENDED,
    "focus-note": _WRITE,
    "focus-recheck": _WRITE,
    "hand-item": _ITEM,
    "handover": ("ask Shawn to type /auto:programme-handover <session-id> in the driving session, "
                 "then rerun `programme.sh handover`"),
    "inbox": _READ,
    "sweep-inputs": _READ,
    "keep-behaviours": _PICKED,
    "lift-pause": _PICKED,
    "log-decision": _ITEM,
    "mark-read": "`programme.sh inbox` prints the current offset; rerun `programme.sh mark-read` with it",
    "merge-item": _ITEM,
    "move-behaviour": _PICKED,
    "note-term": _WRITE,
    "pause": _WRITE,
    "pick-term": _PICK_ID,
    "preserve-code": _WRITE,
    "promote": _READ,
    "prompt-item": _ITEM,
    "propose-agreement": _WRITE,
    "propose-behaviour": _WRITE,
    "propose-permission": _WRITE,
    "propose-rule": _WRITE,
    "propose-term": _WRITE,
    "queue": _WRITE,
    "raise-blocker": _ITEM,
    "reconcile-leases": _WRITE,
    "reconcile-operations": _WRITE,
    "record-behaviour": _TYPED,
    "record-denial": _WRITE,
    "record-ruling": _TYPED,
    "record-issues": _WRITE,
    "record-tested-build": _WRITE,
    "record-trajectories": _WRITE,
    "recover": _READ,
    "release-resources": _ENDED,
    "remind-behaviour": _ITEM,
    "reopen-item": _PICKED,
    "request-reread": _WRITE,
    "retire-behaviour": _TYPED,
    "rules": ("`programme.sh rules` prints the rules in force and their context digest; "
              "then `programme.sh rules --ack`"),
    "set-now": _WRITE,
    "skip-behaviour": _ITEM,
    "set-remit": _TYPED,
    "set-source": _WRITE,
    "set-waiting": _ITEM,
    "settle-permissions": _WRITE,
    "setup-keep": _WRITE,
    "setup-seen": _WRITE,
    "setup-step": _WRITE,
    "size-item": _ITEM,
    "start": _START,
    "start-worker": _ITEM,
    "status": _READ,
    "override-focus": _PICKED,
    "swap-item": _PICKED,
    "sweep": _WRITE,
    "take-recommendations": _PICK_ID,
    "takeover": FALLBACK,
    "tracker-synced": _ITEM,
    "update-ask": _ITEM,
    "validate": _WRITE,
    "watcher-beat": _WRITE,
}


def fix_for(verb) -> str:
    return FIXES.get(verb, FALLBACK).format(verb=verb)

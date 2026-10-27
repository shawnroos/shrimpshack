#!/usr/bin/env python3
"""Default `fix:` line for each programme verb, printed when a refusal carries no fix of its own."""

from __future__ import annotations

FALLBACK = "programme.sh become-pm"

_WRITE = ("`programme.sh become-pm` if this session does not drive the programme; "
          "else `programme.sh status` for the current state and `programme.sh describe` for what {verb} refuses")
_ITEM = ("`programme.sh status` lists the items and their state; `programme.sh describe` names what {verb} "
         "needs, then rerun it")
_READ = "`programme.sh status` names the programme run ids; rerun `programme.sh {verb}` with --run <id>"
_PICKED = ("run `programme.sh approval-label {verb} <args>`, offer its output as one AskUserQuestion option, "
           "then rerun citing the pick with --prompt <pick id>")
_TYPED = "ask Shawn to type the approval for {verb} in this session, then rerun with --prompt <its id>"
_ACCEPT = ("run `programme.sh approval-label accept-agreement`, offer its output as one AskUserQuestion option, "
           "then rerun citing the pick with --prompt <pick id> --terms <the digest that label names>")
_PICK_ID = "ask Shawn with an AskUserQuestion picker, then rerun citing the pick with --pick <pick id>"
_ENDED = ("`programme.sh check-archive --run <id>` names each failed check and its remedy; "
          "`programme.sh status --run <id>` shows the end state")

FIXES = {
    "accept-agreement": _ACCEPT,
    "accept-context": _PICKED,
    "add-item": _ITEM,
    "adopt-autonomy": _PICKED,
    "adopt-check": _PICKED,
    "adopt-rule": _PICKED,
    "alias-item": _ITEM,
    "amend-term": _PICKED,
    "answer-handed": _PICKED,
    "answer-permission": _PICKED,
    "approval-label": _TYPED,
    "archive": _ENDED,
    "ask-relayed": _ITEM,
    "ask-shown": _ITEM,
    "assign-item": _ITEM,
    "beat": FALLBACK,
    "check-archive": _ENDED,
    "check-deliverable": _ITEM,
    "check-mergeable": _ITEM,
    "claim": ("`programme.sh context --item <id> --run <id>` lists the item's deliverables; "
              "rerun `programme.sh claim` with one of them and a reference with no spaces"),
    "clear-blocker": _ITEM,
    "clear-proposal": _WRITE,
    "close-instruction": _TYPED,
    "collect-result": _ITEM,
    "context": _READ,
    "correct-term": _TYPED,
    "create-successor": _ENDED,
    "define-requirement": _TYPED,
    "describe": "rerun `programme.sh describe` with no arguments",
    "dispose-action": _PICKED,
    "dispose-item": _ENDED,
    "drop-item": _PICKED,
    "edit-project-term": _TYPED,
    "end": "ask Shawn to type /auto:programme-end in this session, then rerun `programme.sh end`",
    "expire": _ENDED,
    "hand-item": _ITEM,
    "handover": ("ask Shawn to type /auto:programme-handover <session-id> in the driving session, "
                 "then rerun `programme.sh handover`"),
    "inbox": _READ,
    "keep-behaviours": _PICKED,
    "keep-corrections": _PICKED,
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
    "promote-correction": _TYPED,
    "prompt-item": _ITEM,
    "propose-agreement": _WRITE,
    "propose-behaviour": _WRITE,
    "propose-permission": _WRITE,
    "propose-rule": _WRITE,
    "propose-term": _WRITE,
    "queue": _WRITE,
    "raise-blocker": _ITEM,
    "reconcile-leases": FALLBACK,
    "reconcile-operations": FALLBACK,
    "record-behaviour": _TYPED,
    "record-decision": _TYPED,
    "record-denial": _WRITE,
    "record-instruction": _TYPED,
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
    "set-remit": _TYPED,
    "set-source": _WRITE,
    "set-waiting": _ITEM,
    "settle-permissions": _WRITE,
    "setup-keep": _WRITE,
    "setup-seen": _WRITE,
    "setup-step": _WRITE,
    "start": FALLBACK,
    "start-worker": _ITEM,
    "status": _READ,
    "sweep": _WRITE,
    "take-recommendations": _PICK_ID,
    "takeover": FALLBACK,
    "tracker-synced": _ITEM,
    "undo-correction": _TYPED,
    "update-ask": _ITEM,
    "validate": _WRITE,
    "watcher-beat": _WRITE,
}


def fix_for(verb) -> str:
    return FIXES.get(verb, FALLBACK).format(verb=verb)

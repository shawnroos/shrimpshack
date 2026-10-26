from __future__ import annotations

import functools
import os
import shlex
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
    "adopt-rule", "adopt-autonomy", "adopt-check", "set-remit", "amend-term", "keep-corrections",
    "move-behaviour", "keep-behaviours", "drop-item", "reopen-item", "answer-handed", "accept-context",
    "lift-pause", "answer-permission", "dispose-action"))
_NOT_APPROVED = ("--prompt", "--run")
_RECOMMENDED = " (recommended)"


def label(argv) -> str:
    """The exact picker option that approves this command: every argument except who approves and where."""
    kept, args = [], list(argv)
    while args:
        arg = args.pop(0)
        if arg in _NOT_APPROVED:
            args = args[1:]
            continue
        kept.append(arg)
    return "Approve " + shlex.join(kept)


def _picked_answer(rows, row, verb_argv, prompt_id, error) -> str:
    answer = programme_journal.pick_answer(rows, row)
    # Reading a decline's intent from free text leaked three review rounds running ("No", "Skip r1",
    # "Keep item-x" for drop-item); only the exact label the tool printed approves.
    if answer.casefold().endswith(_RECOMMENDED):
        answer = answer[:-len(_RECOMMENDED)]
    want = label(verb_argv) if verb_argv else None
    if answer != want:
        raise error(f"pick {prompt_id!r} answer {answer!r} is not the approval label for this command; "
                    f"the answer must be exactly {want!r} (`programme.sh approval-label ...` prints it)")
    return answer


def prompt(run_id, record, prompt_id, verb, error, text_hash, verb_argv=None) -> dict:
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
        approval["answer"] = _picked_answer(rows, row, verb_argv, prompt_id, error)
    # Naming checks only look at the word before a name, so "No, do not adopt r1" would name r1. This also
    # refuses "never" as a value; those changes need typed text.
    if origin == "suggested" and \
            set(programme_naming.name_words(approval["quote"])) & set(programme_naming.NEGATIONS):
        raise error(f"prompt {prompt_id!r} is not a plain yes; an accepted suggestion with a negation "
                    "approves nothing (type it instead)")
    return approval


def _h_approval_label(host, argv):
    if len(argv) < 2:
        raise ValueError("usage: approval-label <verb> <args...>")
    if argv[1] not in PICK_VERBS:
        raise host.ProgrammeError(f"{argv[1]} needs a typed prompt; a pick cannot approve it")
    print(label(argv[1:]))
    return 0


_SPECS = (
    ("approval-label", _h_approval_label, "<verb> <args...>",
     "a verb a pick cannot approve. Prints the exact picker option that approves that command; needs no "
     "prompt and writes nothing."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

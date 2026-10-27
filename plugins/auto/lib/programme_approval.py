from __future__ import annotations

import functools
import hashlib
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
programme_home = load_lib_module("programme_home")

# Default-deny: a pick or an accepted suggestion approves only these verbs, each of which checks that the
# approval names its target. Verbs that record the prompt's words as content stay typed-only.
PICK_VERBS = frozenset((
    "adopt-rule", "adopt-autonomy", "adopt-check", "set-remit", "amend-term", "keep-corrections",
    "move-behaviour", "keep-behaviours", "drop-item", "reopen-item", "answer-handed", "accept-context",
    "lift-pause", "answer-permission", "dispose-action", "accept-agreement"))
ACCEPT_VERB = "accept-agreement"
# The accept is the moment the PM gains authority: a pick must name the terms digest Shawn saw, and an
# accepted suggestion shows him no terms at all, so it never approves the accept.
_NO_SUGGESTION_VERBS = frozenset((ACCEPT_VERB,))
ACCEPT_FIX = (f"run `programme.sh approval-label {ACCEPT_VERB}`, offer its output as one AskUserQuestion option, "
              "then rerun citing the pick with --prompt <pick id> --terms <the digest that label names>")
# set-remit reads its change from stdin, which no label can show, so only typed text or a suggestion
# approves it.
_STDIN_VERBS = frozenset(("set-remit",))
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


def terms_digest(block) -> str:
    # Loaded here: programme_view loads programme_view_setup, which loads this module at import.
    lines = load_lib_module("programme_view").agreement_lines(block)
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()[:8]


def _block(record) -> dict:
    return programme_home.normalize_programme(record.get("programme") or {})


def accept_label(block) -> str:
    return label([ACCEPT_VERB, "--terms", terms_digest(block)])


def accept_fix(block) -> str:
    return (f"offer `{accept_label(block)}` as one AskUserQuestion option (`programme.sh approval-label "
            f"{ACCEPT_VERB}` prints it), then rerun citing the pick with --prompt <pick id> "
            f"--terms {terms_digest(block)}")


def check_terms(block, digest, error) -> None:
    if digest is not None and digest != terms_digest(block):
        raise error(f"--terms {digest} does not match the agreement terms now shown (digest "
                    f"{terms_digest(block)}); Shawn accepts the terms he last saw", fix=accept_fix(block))


def approval_fix(verb, verb_argv) -> str:
    if verb == ACCEPT_VERB:
        return ACCEPT_FIX
    if verb in PICK_VERBS and verb not in _STDIN_VERBS:
        command = label(verb_argv)[len("Approve "):] if verb_argv else f"{verb} <args>"
        return (f"run `programme.sh approval-label {command}`, offer its output as one AskUserQuestion "
                "option, then rerun citing the pick with --prompt <pick id>")
    return (f"ask Shawn to type the approval for {verb or 'this verb'} in this session, "
            "then rerun with --prompt <its id>")


def _picked_answer(rows, row, verb_argv, prompt_id, error) -> str:
    answer = programme_journal.pick_answer(rows, row)
    if verb_argv and verb_argv[0] in _STDIN_VERBS:
        raise error(f"{verb_argv[0]} reads its change from stdin, which a pick label cannot show; "
                    "it needs typed text", fix=approval_fix(verb_argv[0], verb_argv))
    # Reading a decline's intent from free text leaked three review rounds running ("No", "Skip r1",
    # "Keep item-x" for drop-item); only the exact label the tool printed approves.
    if answer.casefold().endswith(_RECOMMENDED):
        answer = answer[:-len(_RECOMMENDED)]
    want = label(verb_argv) if verb_argv else None
    if answer != want:
        raise error(f"pick {prompt_id!r} answer {answer!r} is not the approval label for this command; "
                    f"the answer must be exactly {want!r} (`programme.sh approval-label ...` prints it)",
                    fix=approval_fix(verb_argv[0] if verb_argv else None, verb_argv))
    return answer


def prompt(run_id, record, prompt_id, verb, error, text_hash, verb_argv=None) -> dict:
    if not prompt_id:
        raise error("this approval needs --prompt <id> of a typed prompt or a pick",
                    fix=approval_fix(verb, verb_argv))
    rows = programme_journal.read(run_id)
    row = programme_journal.find_prompt(run_id, prompt_id, rows)
    if row is None:
        raise error(f"no prompt {prompt_id!r} in this programme's journal",
                    fix=approval_fix(verb, verb_argv))
    payload = row.get("payload") or {}
    if row.get("provenance") in programme_authority.UNVERIFIED:
        raise error(f"prompt {prompt_id!r} was imported from a legacy journal or appended by an "
                    "obsolete writer; its typed label is unverified, so it approves nothing new",
                    fix=approval_fix(verb, verb_argv))
    if payload.get("driving") is False:
        raise error(f"prompt {prompt_id!r} was answered before this session drove the programme; "
                    "it can serve only a takeover", fix=approval_fix(verb, verb_argv))
    origin = programme_journal.prompt_origin(row)
    if origin in ("picked", "suggested") and verb not in PICK_VERBS:
        raise error(f"{verb or 'this verb'} needs a typed prompt; prompt {prompt_id!r} is "
                    f"{'a pick' if origin == 'picked' else 'an accepted suggestion'}",
                    fix=approval_fix(verb, verb_argv))
    if origin == "suggested" and verb in _NO_SUGGESTION_VERBS:
        raise error(f"{verb} needs a typed prompt or a pick of its terms-bound label; prompt {prompt_id!r} "
                    "is an accepted suggestion, which shows Shawn no terms", fix=accept_fix(_block(record)))
    if origin == "picked" and verb == ACCEPT_VERB and "--terms" not in (verb_argv or []):
        raise error(f"prompt {prompt_id!r} is a pick, so {ACCEPT_VERB} needs --terms <digest> naming the "
                    "terms Shawn picked", fix=accept_fix(_block(record)))
    if origin not in programme_protocol.HUMAN_ORIGINS:
        raise error(f"prompt {prompt_id!r} is not typed or a verified pick "
                    f"(origin {origin!r}; human source unverified)", fix=approval_fix(verb, verb_argv))
    if row.get("session_id") != record.get("driving_session_id"):
        raise error(f"prompt {prompt_id!r} was not typed in the driving session")
    approval = {"prompt_id": prompt_id, "quote": payload.get("text") or "", "origin": origin,
                "text_hash": text_hash(payload.get("text")), "at": row.get("at"), "origin_verified": True}
    if origin == "picked":
        approval["answer"] = _picked_answer(rows, row, verb_argv, prompt_id, error)
    # Naming checks only look at the word before a name, so "No, do not adopt r1" would name r1. This also
    # refuses "never" as a value; those changes need typed text.
    # Path tokens are skipped: "/T/" in a macOS temp path would read as the "t" of "don't".
    prose = " ".join(token for token in approval["quote"].split() if "/" not in token)
    if origin == "suggested" and set(programme_naming.name_words(prose)) & set(programme_naming.NEGATIONS):
        raise error(f"prompt {prompt_id!r} is not a plain yes; an accepted suggestion with a negation "
                    "approves nothing (type it instead)", fix=approval_fix(verb, verb_argv))
    return approval


def _h_approval_label(host, argv):
    if len(argv) < 2:
        raise ValueError("usage: approval-label <verb> <args...>")
    if argv[1] == "takeover":
        return _takeover_label_cli(argv)
    if argv[1] not in PICK_VERBS or argv[1] in _STDIN_VERBS:
        raise host.ProgrammeError(f"{argv[1]} needs a typed prompt; a pick cannot approve it",
                                  fix=approval_fix(argv[1], argv[1:]))
    if argv[1] == ACCEPT_VERB and "--terms" not in argv:
        _, opts = host._parse(argv[1:], values=("run",))
        print(accept_label(_block(host._locate(opts)[2])))
        return 0
    print(label(argv[1:]))
    return 0


_SPECS = (
    ("approval-label", _h_approval_label, "<verb> <args...>",
     "a verb a pick cannot approve. Prints the exact picker option that approves that command; needs no "
     "prompt and writes nothing. For takeover it takes only --replace <driving session id>."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}


def takeover_label(driver) -> str:
    return label(["takeover", "--replace", driver])


def _takeover_label_cli(argv) -> int:
    # takeover stays out of PICK_VERBS: its pick is checked by takeover itself, against the driver under the lock.
    if len(argv) != 4 or argv[2] != "--replace" or not argv[3] or argv[3].startswith("--"):
        raise ValueError("usage: approval-label takeover --replace <driving session id>")
    print(takeover_label(argv[3]))
    return 0


def _from_shawn(row, prompt_id, sid, error) -> str:
    if row is None:
        raise error(f"no prompt {prompt_id!r} in this programme's journal")
    if row.get("session_id") != sid:
        raise error(f"prompt {prompt_id!r} was not given in this session")
    origin = programme_journal.prompt_origin(row)
    if origin not in programme_protocol.HUMAN_ORIGINS:
        raise error(f"prompt {prompt_id!r} is not a verified typed prompt, accepted suggestion or pick "
                    f"(origin {origin!r})")
    return origin


def _takeover_answer(rows, row, prompt_id, driver, error) -> str:
    try:
        answer = programme_journal.pick_answer(rows, row)
    except ValueError as exc:
        raise error(str(exc)) from None
    if answer.casefold().endswith(_RECOMMENDED):
        answer = answer[:-len(_RECOMMENDED)]
    want = takeover_label(driver)
    if answer != want:
        raise error(f"pick {prompt_id!r} answer {answer!r} does not approve this takeover; "
                    f"the answer must be exactly {want!r}")
    return answer


def takeover_pick(rows, row, prompt_id, sid, driver, error) -> dict:
    if _from_shawn(row, prompt_id, sid, error) != "picked":
        raise error(f"the PM is live, so replacing it needs a pick of {takeover_label(driver)!r}; "
                    f"prompt {prompt_id!r} is not a pick")
    return {"origin": "picked", "answer": _takeover_answer(rows, row, prompt_id, driver, error)}


def cited_ask(rows, row, prompt_id, sid, driver, error) -> dict:
    origin = _from_shawn(row, prompt_id, sid, error)
    # A pick's question is PM-written, so a pick is Shawn's ask only when its answer names the takeover.
    if origin == "picked":
        return {"origin": origin, "answer": _takeover_answer(rows, row, prompt_id, driver, error)}
    return {"origin": origin}

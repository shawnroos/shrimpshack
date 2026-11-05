from __future__ import annotations

import hashlib
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")
programme_protocol = load_lib_module("programme_protocol")
programme_home = load_lib_module("programme_home")
programme_offers = load_lib_module("programme_offers")
programme_fixes = load_lib_module("programme_fixes")

# Default-deny: an approval binds only for these verbs. A test pins this set to the offer renderers.
PICK_VERBS = frozenset((
    "adopt-rule", "adopt-autonomy", "adopt-check", "close-ruling", "define-requirement", "edit-project-term",
    "record-ruling", "set-remit", "amend-term", "move-behaviour",
    "keep-behaviours", "drop-item", "reopen-item", "answer-handed", "accept-context", "lift-pause",
    "answer-permission", "dispose-action", "accept-agreement", "swap-item", "override-focus",
    "move-ritual", "keep-rituals", "retire-ritual", "start-ritual", "run-ritual", "skip-ritual",
    "adopt-behaviour-file", "adopt-ritual-file", "carry-rulings", "copy-default", "decline-ritual-file",
    "end", "handover", "record-behaviour", "record-ritual", "retire-behaviour", "settle-default-update"))
_RECOMMENDED = " (recommended)"
_READING = {"label": None}
CARRIED_KIND = "rulings_carried"
APPROVAL_KINDS = ("rule_adopted", CARRIED_KIND)


def take_reading(argv) -> list:
    argv = list(argv)
    _READING["label"] = None
    if "--reads-as" in argv[1:]:
        at = argv.index("--reads-as", 1)
        if at + 1 >= len(argv):
            raise ValueError("--reads-as needs the text of the option")
        if "--prompt" not in argv:
            raise ValueError("--reads-as goes with --prompt <id> of Shawn's own words")
        _READING["label"] = argv[at + 1]
        del argv[at:at + 2]
    return argv


def text_hash(text) -> str:
    return "sha256:" + hashlib.sha256(str(text or "").encode("utf-8")).hexdigest()


# An imported prompt approves nothing new, so only the approval rows imported with it count.
def _approved(rows, prompt_id, imported=False) -> list:
    out = []
    for row in rows:
        payload = row.get("payload") or {}
        if row.get("kind") not in APPROVAL_KINDS or (row.get("cites") or [None])[0] != prompt_id \
                or payload.get("prompt_id") != prompt_id or row.get("provenance") == programme_authority.FOREIGN \
                or (imported and row.get("provenance") != programme_authority.LEGACY):
            continue
        if row["kind"] == CARRIED_KIND:
            out.extend(programme_protocol.approval_key(programme_protocol.carryover_target(e.get("key"), e.get("id")),
                                                       e.get("hash"))
                       for e in payload.get("stored") or [] if isinstance(e, dict))
        else:
            out.append(programme_protocol.approval_key(payload.get("target"), payload.get("hash")))
    return out


def prompt_lookup(run_id, prompt_id, journals=None):
    try:
        run_id = programme_home.check_run_id(run_id)
        if journals is None:
            rows = programme_journal.read(run_id)
        else:
            if run_id not in journals:
                journals[run_id] = programme_journal.read(run_id)
            rows = journals[run_id]
        row = programme_journal.find_prompt(run_id, prompt_id, rows)
    except programme_home.ProgrammeHomeError:
        return None
    if row is None or row.get("provenance") == programme_authority.FOREIGN:
        return None
    payload = row.get("payload") or {}
    imported = row.get("provenance") == programme_authority.LEGACY
    return {"origin": programme_journal.adopted_origin(row), "text_hash": text_hash(payload.get("text")),
            "approved": _approved(rows, prompt_id, imported)}


def terms_digest(block) -> str:
    # Loaded here: programme_view loads programme_view_setup, which loads this module at import.
    lines = load_lib_module("programme_view").agreement_lines(block)
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()[:8]


def _block(record) -> dict:
    return programme_home.normalize_programme(record.get("programme") or {})


def _strip_recommended(answer) -> str:
    return answer[:-len(_RECOMMENDED)] if answer.casefold().endswith(_RECOMMENDED) else answer


def _picked(rows, row, record, verb_argv, prompt_id, error) -> dict:
    fix = programme_fixes.fix_for(verb_argv[0] if verb_argv else "offer")
    offer = programme_offers.offer_for(rows, row)
    if offer is None:
        raise error(f"pick {prompt_id!r} answers a picker no offer printed, so it approves nothing", fix=fix)
    try:
        pick = programme_journal.checked_pick(rows, row, own_words=True)
    except ValueError as exc:
        raise error(str(exc), fix=fix) from None
    return programme_offers.bind_pick(rows, row, offer, dict(pick, answer=_strip_recommended(pick["answer"])),
                                      _READING["label"], verb_argv or [], record, _block(record), error)


def prompt(run_id, record, prompt_id, verb, error, text_hash, verb_argv=None) -> dict:
    fix = programme_fixes.fix_for(verb or "offer")
    if not prompt_id:
        raise error("this approval needs --prompt <id> of Shawn's answer to `programme.sh offer`", fix=fix)
    rows = programme_journal.read(run_id)
    row = programme_journal.find_prompt(run_id, prompt_id, rows)
    if row is None:
        raise error(f"no prompt {prompt_id!r} in this programme's journal", fix=fix)
    payload = row.get("payload") or {}
    if row.get("provenance") in programme_authority.UNVERIFIED:
        raise error(f"prompt {prompt_id!r} was imported from a legacy journal or appended by an "
                    "obsolete writer; its source is unverified, so it approves nothing new", fix=fix)
    if payload.get("driving") is False:
        raise error(f"prompt {prompt_id!r} was answered before this session drove the programme; "
                    "it can serve only a takeover", fix=fix)
    origin = programme_journal.prompt_origin(row)
    if origin not in programme_protocol.HUMAN_ORIGINS:
        raise error(f"prompt {prompt_id!r} is not Shawn's words or a verified pick "
                    f"(origin {origin!r}; human source unverified)", fix=fix)
    if verb not in PICK_VERBS:
        raise error(f"{verb or 'this verb'} takes no approval, so prompt {prompt_id!r} approves nothing", fix=fix)
    if row.get("session_id") != record.get("driving_session_id"):
        raise error(f"prompt {prompt_id!r} was not given in the driving session")
    approval = {"prompt_id": prompt_id, "quote": payload.get("text") or "", "origin": origin,
                "text_hash": text_hash(payload.get("text")), "at": row.get("at"), "origin_verified": True}
    if origin == "picked":
        approval.update(_picked(rows, row, record, verb_argv, prompt_id, error))
    else:
        approval.update(programme_offers.bind_words(rows, row, origin, _READING["label"], verb_argv or [], record,
                                                    _block(record), error))
    return approval


def _from_shawn(row, prompt_id, sid, error) -> str:
    if row is None:
        raise error(f"no prompt {prompt_id!r} in this programme's journal")
    if row.get("session_id") != sid:
        raise error(f"prompt {prompt_id!r} was not given in this session")
    origin = programme_journal.prompt_origin(row)
    if origin not in programme_protocol.HUMAN_ORIGINS:
        raise error(f"prompt {prompt_id!r} is not Shawn's verified words, accepted suggestion or pick "
                    f"(origin {origin!r})")
    return origin


def _takeover_answer(rows, row, prompt_id, driver, error) -> str:
    try:
        pick = programme_journal.checked_pick(rows, row)
    except ValueError as exc:
        raise error(str(exc)) from None
    answer = _strip_recommended(pick["answer"])
    if not programme_offers.takeover_matches(pick["questions"], answer, driver):
        raise error(f"pick {prompt_id!r} answer {programme_journal.redact(answer)!r} does not approve this takeover; "
                    f"it needs a pick of {programme_offers.takeover_label(driver)!r} on the picker `become-pm` prints")
    return programme_journal.redact(answer)


def takeover_pick(rows, row, prompt_id, sid, driver, error, stopped=False) -> dict:
    # Typed or suggested text never approves a takeover: an instruction to a worker would hand it the PM role.
    if _from_shawn(row, prompt_id, sid, error) != "picked":
        why = "the PM stopped; replacing it still" if stopped else "the PM is live, so replacing it"
        raise error(f"{why} needs a pick of {programme_offers.takeover_label(driver)!r}; prompt {prompt_id!r} is not a pick")
    return {"origin": "picked", "answer": _takeover_answer(rows, row, prompt_id, driver, error)}

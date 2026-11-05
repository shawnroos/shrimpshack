from __future__ import annotations

import collections
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
programme_home = load_lib_module("programme_home")
programme_offers = load_lib_module("programme_offers")
programme_pick_source = load_lib_module("programme_pick_source")
programme_fixes = load_lib_module("programme_fixes")
programme_sanitize = load_lib_module("programme_sanitize")

# Default-deny: an approval binds only for a verb with a renderer.
PICK_VERBS = frozenset(programme_offers.RENDERERS)
# What the command asks to be approved. `content` is the JSON or draft the verb read, which the offer showed.
Asked = collections.namedtuple("Asked", "verb argv reading content", defaults=(None, None))
Binding = collections.namedtuple("Binding", "reading argv content record programme error")
_RECOMMENDED = " (recommended)"
CARRIED_KIND = "rulings_carried"
APPROVAL_KINDS = ("rule_adopted", CARRIED_KIND)


def take_reading(argv) -> tuple:
    argv = list(argv)
    if "--reads-as" not in argv[1:]:
        return argv, None
    at = argv.index("--reads-as", 1)
    if at + 1 >= len(argv):
        raise ValueError("--reads-as needs the text of the option")
    if "--prompt" not in argv:
        raise ValueError("--reads-as goes with --prompt <id> of Shawn's own words")
    return argv[:at] + argv[at + 2:], argv[at + 1]


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


def _binding(asked, record, error):
    return Binding(asked.reading, asked.argv or [], asked.content, record, _block(record), error)


def _redo(payload) -> str:
    return f"rerun `programme.sh offer {payload.get('question_key')} --command '<the command>'` and ask Shawn again"


def _check_driver(offer, binding, redo) -> None:
    if offer.get("session_id") != binding.record.get("driving_session_id"):
        raise binding.error("this picker was offered by another PM; a new driver offers it again", fix=redo)


def _check_rendered_now(option, binding, redo) -> None:
    error = binding.error
    doc = binding.content
    if option.get("content_hash") and (doc is None or programme_offers.content_hash(doc) != option["content_hash"]):
        raise error("the content on stdin differs from what this offer showed; Shawn approves what he saw", fix=redo)
    try:
        rendered = programme_offers.render(binding.argv, binding.programme, doc)
    except Exception as exc:
        raise error(f"the facts changed since the offer, so this pick no longer applies: {exc}", fix=redo) from None
    if programme_offers.subject(rendered) != option.get("subject"):
        raise error("the facts this picker showed changed since the offer, so Shawn has not seen them", fix=redo)


def _holding(payload, argv):
    want = programme_offers.argv_hash(argv)
    return next((option for option in payload.get("options") or [] if option.get("argv_hash") == want), None)


def _own_words(rows, row, offer, why, words, binding) -> dict:
    error = binding.error
    payload = offer["payload"]
    redo = _redo(payload)
    _check_driver(offer, binding, redo)
    option = _holding(payload, binding.argv)
    if option is None:
        raise error(f"{why}, but no open offer holds this command; the question just asked was "
                    f"{payload.get('question_key')!r}", fix=redo)
    label = option["label"]
    if option.get("authority"):
        raise error(f"{label!r} moves authority, so only a pick of that option approves it; {why}",
                    fix="relay his words, then ask again with the same picker; run the command only on a pick")
    if binding.reading != label:
        raise error(f"{why}, so the PM states what it read them as: rerun with --reads-as {label!r}",
                    fix=f"read his words first. If they decline or ask something, run nothing. If they approve, add "
                        f"--reads-as {shlex.quote(label)}")
    _check_rendered_now(option, binding, redo)
    newer = load_lib_module("programme_rulings").newer_words(rows, row["prompt_id"])
    if newer:
        raise error(f"prompt {row['prompt_id']!r} is older than {newer!r}, which nothing has cited yet; own words bind "
                    "only on Shawn's newest message", fix="read his newest message, then ask again if it is unclear")
    shown = programme_journal.redact(words)
    is_draft = "content" in option
    if is_draft:
        size = len(programme_sanitize.clean(shown, cap=0))
        if size > programme_sanitize.DEFAULT_CAP:
            raise error(f"his words are {size} characters and the record holds {programme_sanitize.DEFAULT_CAP}, and "
                        "they are never cut",
                        fix="draft a shorter text from his words and offer that draft again, or split it into "
                            "two Rulings")
    read_back = (f"Recorded your words as the text of: {label}. Say so if that is wrong." if is_draft
                 else f"Read your message as: {label}. Say so if that is wrong.")
    return {"quote": shown,
            "reading": {"read_as": label, "read_by": "pm", "offer_id": payload.get("offer_id"),
                        "wording": programme_journal.SHAWN, "read_back": read_back}}


def _bind_pick(rows, row, offer, pick, binding) -> dict:
    answer, error, payload = pick["answer"], binding.error, offer["payload"]
    option = programme_offers.chosen(payload, answer)
    if option is not None and "argv_hash" not in option:
        raise error("Shawn declined this offer; nothing runs", fix="do not run the command; ask Shawn what he wants")
    shown = programme_journal.redact(answer)
    if option is None or pick["noted"]:
        why = (f"pick {row['prompt_id']!r} carries a note, which counts as Shawn's own words" if pick["noted"]
               else f"answer {shown!r} is not one of the options this offer printed, so it is Shawn's own words")
        said = [] if answer == programme_pick_source.NOTES_ONLY or option is not None else [answer]
        words = " ".join([*said, *pick["notes"]]) or answer
        return dict(_own_words(rows, row, offer, why, words, binding), answer=shown)
    redo = _redo(payload)
    _check_driver(offer, binding, redo)
    if option["argv_hash"] != programme_offers.argv_hash(binding.argv):
        raise error(f"this pick approved a different command: {option.get('command')}", fix=redo)
    _check_rendered_now(option, binding, redo)
    return {"answer": shown, "quote": option.get("content") or option["label"],
            "reading": {"wording": programme_journal.PM_DRAFT, "offer_id": payload.get("offer_id")}}


def _open_offer(rows, row):
    """The offer this message answers: the newest one, whose picker is the newest in the transcript at the message's
    enqueue position, and which no pick answered. Journal order alone would let words sent between the offer row and
    the asking row bind to a question Shawn had not seen."""
    offers = [r for r in rows[:rows.index(row)] if r.get("kind") == programme_offers.OFFERED]
    if not offers:
        return None
    asked = programme_pick_source.question_before(row)
    if asked is None or programme_offers.asked_hash(asked[1]) != offers[-1]["payload"].get("asked_hash"):
        return None
    answered = any(r.get("kind") == "prompt"
                   and ((r.get("payload") or {}).get("source") or {}).get("tool_use_id") == asked[0] for r in rows)
    return None if answered else offers[-1]


def _no_offer(argv, prompt_id, error):
    return error(f"no open offer of this command asks the question prompt {prompt_id!r} would answer, so it approves "
                 "nothing", fix=programme_fixes.fix_for(argv[0] if argv else "offer"))


def _bind_words(rows, row, origin, binding) -> dict:
    error, argv = binding.error, binding.argv
    prompt_id = row["prompt_id"]
    at = rows.index(row)
    if any(_holding(r.get("payload") or {}, argv) for r in rows[at + 1:] if r.get("kind") == programme_offers.OFFERED):
        raise error(f"prompt {prompt_id!r} came before the offer of this command, so it does not answer that question",
                    fix="ask again, or wait for his answer to the picker")
    offer = _open_offer(rows, row)
    if origin == "suggested":
        raise error(f"prompt {prompt_id!r} is an accepted suggestion: the model wrote it, so it approves nothing",
                    fix="ask with the picker and wait for his pick or his own words")
    if offer is None or (binding.reading is None and _holding(offer["payload"], argv) is None):
        raise _no_offer(argv, prompt_id, error)
    if programme_journal.prompt_spent(rows, prompt_id):
        raise error(f"prompt {prompt_id!r} already approved a change; one message approves one change",
                    fix="ask Shawn about this one")
    why = f"prompt {prompt_id!r} is Shawn's own words"
    payload = row.get("payload") or {}
    return _own_words(rows, row, offer, why, payload.get("text") or "", binding)


def _picked(rows, row, record, asked, prompt_id, error) -> dict:
    fix = programme_fixes.fix_for(asked.argv[0] if asked.argv else "offer")
    read = programme_pick_source.read_pick(row)
    offer = read and programme_offers.newest_offer(rows[:rows.index(row)],
                                                   programme_offers.asked_hash(read["questions"]))
    if not offer:
        raise error(f"pick {prompt_id!r} answers a picker no offer printed, so it approves nothing", fix=fix)
    try:
        pick = programme_journal.judged_pick(rows, row, read, own_words=True)
    except ValueError as exc:
        raise error(str(exc), fix=fix) from None
    return _bind_pick(rows, row, offer, dict(pick, answer=_strip_recommended(pick["answer"])),
                      _binding(asked, record, error))


def prompt(run_id, record, prompt_id, asked, error) -> dict:
    verb = asked.verb
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
        approval.update(_picked(rows, row, record, asked, prompt_id, error))
    else:
        approval.update(_bind_words(rows, row, origin, _binding(asked, record, error)))
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
        raise error(f"{why} needs a pick of {programme_offers.takeover_label(driver)!r}; "
                    f"prompt {prompt_id!r} is not a pick")
    return {"origin": "picked", "answer": _takeover_answer(rows, row, prompt_id, driver, error)}

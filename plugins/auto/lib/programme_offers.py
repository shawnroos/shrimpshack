#!/usr/bin/env python3
"""Auto writes a picker's text from the commands it approves and stores each option's link to its command."""

from __future__ import annotations

import functools
import hashlib
import json
import os
import re
import shlex
import sys
import uuid

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_pick_source = load_lib_module("programme_pick_source")
programme_sanitize = load_lib_module("programme_sanitize")

OFFERED = "approval_offered"
DECLINED = "approval_declined"
DECLINE = "Not now"
_DECLINE_TEXT = "Approves nothing and runs nothing."
_PICK_PLACE = "--prompt <pick id>"
# A question holds 2 to 4 options, and the decline takes one.
MAX_COMMANDS = 3
# The AskUserQuestion schema caps a header at 12 characters.
HEADER_CAP = 12
LABEL_CAP = 80
TEXT_CAP = 300
_KEY = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
_FLAGS = ("widening",)
_NOT_BOUND = ("--prompt", "--run", "--op", "--reads-as")
STDIN_CAP = 256 * 1024
_CONTENT = {"doc": None}
_OWN_WORDS_NOTE = ("This answer is Shawn's own words. If they decline or ask something, run nothing. If they approve, "
                   "run the command with --reads-as <the option's text>. An authority move takes only a pick: relay "
                   "his words and ask again.")


class OfferError(Exception):
    pass


def _sha(text) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def asked_hash(questions) -> str:
    return _sha(_canonical(questions))


def content_hash(doc) -> str:
    return _sha(_canonical(doc))


def note_content(doc) -> None:
    _CONTENT["doc"] = doc


def bound_argv(argv) -> list:
    kept, args = [], list(argv)
    while args:
        arg = args.pop(0)
        if arg in _NOT_BOUND:
            args = args[1:]
        elif arg == "--terms" and kept[:1] == ["accept-agreement"]:
            # The offer's subject is the digest, so the flag adds nothing to what was approved.
            args = args[1:]
        else:
            kept.append(arg)
    return kept


def argv_hash(argv) -> str:
    return _sha(shlex.join(bound_argv(argv)))


class _Command:
    def __init__(self, argv):
        self.verb = argv[0]
        self.pos, self.opts = [], {}
        args = list(argv[1:])
        while args:
            arg = args.pop(0)
            if not arg.startswith("--"):
                self.pos.append(arg)
            elif arg[2:] in _FLAGS:
                self.opts[arg[2:]] = True
            elif args:
                self.opts.setdefault(arg[2:], []).append(args.pop(0))
            else:
                raise OfferError(f"{arg} needs a value")

    def opt(self, name, default=""):
        value = self.opts.get(name)
        return " and ".join(value) if isinstance(value, list) else (value if value is not None else default)

    def first(self, verb_usage) -> str:
        if not self.pos:
            raise OfferError(f"usage: {self.verb} {verb_usage}")
        return self.pos[0]

    def one_of(self, name, allowed) -> str:
        value = self.opt(name)
        if value not in allowed:
            raise OfferError(f"{self.verb} needs --{name} {'|'.join(allowed)}")
        return value

    def extras(self, *used) -> str:
        return " ".join(f"{name.replace('-', ' ')}: {self.opt(name)}." for name in self.opts if name not in used)


def _shown(text, cap=TEXT_CAP) -> str:
    return programme_journal.redact(programme_sanitize.clean(text, cap))


# Multi-select joins labels with ", ", so a label holding that text reads as two answers.
def _label(text) -> str:
    return _shown(str(text).replace(", ", " and "), LABEL_CAP)


def _rendered(label, description="", facts=None, authority=False, named=None) -> dict:
    return {"label": _label(label), "description": _shown(description), "facts": facts, "authority": authority,
            "named": named}


def _item(programme, ident) -> tuple:
    record = load_lib_module("programme_record")
    key = record._resolve(programme, ident)
    item = programme["items"][key]
    return key, item, {"title": item.get("title"), "state": item.get("state"), "handed": item.get("handed")}


def _about(key, item) -> str:
    name = load_lib_module("programme_naming").item_name(key, item)
    return f"{name}. It is {item.get('state')} now."


def _drop(cmd, programme) -> dict:
    key, item, facts = _item(programme, cmd.first("<id> --reason <text>"))
    return _rendered(f"Drop item {key}", f"{_about(key, item)} {cmd.extras()}", facts)


def _reopen(cmd, programme) -> dict:
    key, item, facts = _item(programme, cmd.first("<id>"))
    return _rendered(f"Reopen item {key}", _about(key, item), facts)


def _handed(cmd, programme) -> dict:
    key, item, facts = _item(programme, cmd.first("<id> --choice ship|decline"))
    choice = cmd.one_of("choice", ("ship", "decline"))
    return _rendered(f"{choice.capitalize()} item {key}", _about(key, item), facts, named=f"{choice} {key}")


def _swap(cmd, programme) -> dict:
    if len(cmd.pos) != 2:
        raise OfferError("usage: swap-item <out> <in>")
    out, out_item, out_facts = _item(programme, cmd.pos[0])
    into, in_item, in_facts = _item(programme, cmd.pos[1])
    return _rendered(f"Swap item {out} out for item {into}",
                     f"Out: {_about(out, out_item)} In: {_about(into, in_item)}", [out_facts, in_facts])


def _override(cmd, programme) -> dict:
    key, item, facts = _item(programme, cmd.first("<item>"))
    return _rendered(f"Break the focus budget for item {key}", _about(key, item), facts)


def _adopt_rule(cmd, programme) -> dict:
    rule_id = cmd.first("<rule-id>")
    hits = [r for r in programme.get("proposed_rules") or [] if isinstance(r, dict) and r.get("id") == rule_id]
    if not hits:
        raise OfferError(f"no proposed rule {rule_id!r}")
    return _rendered(f"Adopt rule {rule_id}", hits[0].get("why") or "", hits[0])


def _adopt_autonomy(cmd, _programme) -> dict:
    if len(cmd.pos) != 2:
        raise OfferError("usage: adopt-autonomy <action> <level> [--widening]")
    action, level = cmd.pos
    if cmd.opts.get("widening"):
        return _rendered(f"Widen autonomy for {action} to {level}",
                         "This widens what the PM may do without asking.", authority=True)
    return _rendered(f"Set autonomy for {action} to {level}")


def _adopt_check(cmd, _programme) -> dict:
    if len(cmd.pos) != 3:
        raise OfferError("usage: adopt-check <repo> <check> <argv-json>")
    repo, key, raw = cmd.pos
    return _rendered(f"Adopt check {key} for repo {repo}", f"It runs: {raw}")


def _amend_term(cmd, programme) -> dict:
    if len(cmd.pos) != 2:
        raise OfferError("usage: amend-term <key> <value>")
    key, value = cmd.pos
    term = ((programme.get("agreement") or {}).get("terms") or {}).get(key) or {}
    limits = " ".join(f"{name} {cmd.opt(name)}" for name in cmd.opts if name != "why")
    label = f"Set {key} to {value}" + (f" ({limits})" if limits else "")
    why = f" Why: {cmd.opt('why')}." if cmd.opt("why") else ""
    return _rendered(label, f"Now: {term.get('value')}.{why}", term.get("value"))


def _layered(module_name, programme, ident):
    module = load_lib_module(module_name)
    lookup = load_lib_module("programme_approval").prompt_lookup
    return module._programme_entry(programme, ident) or module._stored_entry(module.load_store(lookup), ident)


def _layer_words(cmd) -> str:
    to = cmd.one_of("to", ("programme", "repo", "personal"))
    repo = cmd.opt("repo")
    return f"the {to} layer" + (f" of repo {repo}" if repo else "")


def _mover(noun, module_name):
    def render(cmd, programme):
        ident = cmd.first("<id> --to <layer>")
        entry = _layered(module_name, programme, ident)
        return _rendered(f"Move {noun} {ident} to {_layer_words(cmd)}", (entry or {}).get("when") or "", entry)
    return render


def _keeper(noun, module_name):
    def render(cmd, programme):
        cmd.first("<id>... --to <layer>")
        entries = [_layered(module_name, programme, ident) for ident in cmd.pos]
        return _rendered(f"Keep {noun}s {' and '.join(cmd.pos)} in {_layer_words(cmd)}", "", entries)
    return render


def _ritual_step(words):
    def render(cmd, programme):
        ident = cmd.first("<id>")
        entry = _layered("programme_rituals", programme, ident)
        text = f"{(entry or {}).get('when') or ''}. {cmd.extras('as')}"
        chosen = words[cmd.one_of("as", tuple(words))] if isinstance(words, dict) else words
        return _rendered(f"{chosen} ritual {ident}", text, entry)
    return render


def _accept_context(cmd, programme) -> dict:
    context = load_lib_module("programme_context")
    ident = cmd.first("<id>")
    block = context.block(programme)
    if ident in block["decisions"]:
        raise OfferError(f"accepting Ruling {ident!r} needs a typed prompt; a pick cannot approve it")
    revision = context.pending(block["requirements"].get(ident))
    if revision is None:
        raise OfferError(f"no pending revision of {ident!r} to accept")
    delta = revision.get("delta") if isinstance(revision.get("delta"), dict) else {}
    wider = bool(delta.get("wider"))
    return _rendered(f"{'Widen by accepting' if wider else 'Accept'} requirement {ident}",
                     revision.get("text") or "", revision, authority=wider)


def _lift_pause(cmd, programme) -> dict:
    ident = cmd.first("<id>")
    entry = load_lib_module("programme_context").block(programme)["pauses"].get(ident)
    if not isinstance(entry, dict):
        raise OfferError(f"no pause {ident!r}")
    return _rendered(f"Lift pause {ident}", entry.get("reason") or "", entry)


_PERMISSION_WORDS = {"applied": "Allow permission", "not-now": "Hold permission", "no": "Refuse permission"}


def _permission(cmd, programme) -> dict:
    if len(cmd.pos) != 2 or cmd.pos[1] not in _PERMISSION_WORDS:
        raise OfferError("usage: answer-permission <perm-id> applied|not-now|no")
    ident, choice = cmd.pos
    proposal = load_lib_module("programme_permission_state").find(programme, ident)
    if proposal is None:
        raise OfferError(f"no permission proposal {ident!r}")
    allow = choice == "applied"
    rules = ", ".join(str(r) for r in proposal.get("rules") or [])
    text = f"Rules: {rules}." + (" This widens what the session may do." if allow else "")
    word = load_lib_module("programme_permission").CHOICE_WORDS[choice][0]
    return _rendered(f"{_PERMISSION_WORDS[choice]} {ident}", text,
                     {k: proposal.get(k) for k in ("rules", "state", "changed_at")}, authority=allow,
                     named=f"{word} {ident}")


def _dispose(cmd, _programme) -> dict:
    target = cmd.opt("attempt") or cmd.opt("resource")
    how = cmd.opt("as").replace("_", " ")
    if not target or not how:
        raise OfferError("usage: dispose-action (--attempt <id>|--resource <id>) --as <how>")
    return _rendered(f"Record {target} as {how}")


def _accept(_cmd, programme) -> dict:
    digest = load_lib_module("programme_approval").terms_digest(programme)
    return _rendered(f"Accept the agreement with terms {digest}",
                     "These are the terms status shows now. Accepting gives the PM its authority.", authority=True)


def _remit(_cmd, programme, doc=None) -> dict:
    if doc is None:
        raise OfferError("set-remit reads the remit as a JSON object on stdin")
    lifecycle = load_lib_module("programme_lifecycle")
    changes = lifecycle.remit_changes(programme["remit"], lifecycle.parse_remit(doc, programme["remit"]))
    names = [lifecycle._names(part, entry)[0] for part, _how, entry in changes]
    wider = any(how == "added" for _part, how, _entry in changes)
    shown = "; ".join(f"{how} {part}: {name}" for (part, how, _entry), name in zip(changes, names))
    digest = content_hash(doc)[len("sha256:"):][:6]
    return _rendered(f"{'Widen' if wider else 'Change'} the remit, change {digest}",
                     shown or "No change.", authority=wider,
                     named=" ".join(["Approve set-remit", *[str(name) for name in names]]))


# Default-deny: a verb with no entry here cannot be offered. A test pins the keys to PICK_VERBS.
RENDERERS = {
    "accept-agreement": _accept,
    "accept-context": _accept_context,
    "adopt-autonomy": _adopt_autonomy,
    "adopt-check": _adopt_check,
    "adopt-rule": _adopt_rule,
    "amend-term": _amend_term,
    "answer-handed": _handed,
    "answer-permission": _permission,
    "dispose-action": _dispose,
    "drop-item": _drop,
    "keep-behaviours": _keeper("behaviour", "programme_behaviours"),
    "keep-rituals": _keeper("ritual", "programme_rituals"),
    "lift-pause": _lift_pause,
    "move-behaviour": _mover("behaviour", "programme_behaviours"),
    "move-ritual": _mover("ritual", "programme_rituals"),
    "override-focus": _override,
    "reopen-item": _reopen,
    "retire-ritual": _ritual_step({"retired": "Retire", "undone": "Undo"}),
    "run-ritual": _ritual_step("Run"),
    "set-remit": _remit,
    "skip-ritual": _ritual_step("Skip"),
    "start-ritual": _ritual_step("Start"),
    "swap-item": _swap,
}
_CONTENT_VERBS = ("set-remit",)


def render(argv, programme, doc=None) -> dict:
    kept = bound_argv(argv)
    verb = kept[0] if kept else None
    if verb not in RENDERERS:
        raise OfferError(f"{verb} needs a typed prompt; a pick cannot approve it")
    cmd = _Command(kept)
    rendered = RENDERERS[verb](cmd, programme, doc) if verb in _CONTENT_VERBS else RENDERERS[verb](cmd, programme)
    if not rendered["named"]:
        rendered["named"] = "Approve " + shlex.join(kept)
    return rendered


def subject(rendered) -> str:
    return _sha(_canonical({key: rendered[key] for key in ("label", "description", "facts")}))


def _parse_commands(host, commands) -> list:
    if not 1 <= len(commands) <= MAX_COMMANDS:
        raise host.ProgrammeError(f"offer takes 1 to at most {MAX_COMMANDS} commands, one --command each: "
                                  "a question holds 4 options and one is the decline; split the rest across pickers")
    parsed = []
    for command in commands:
        argv = bound_argv(shlex.split(command))
        if argv[:1] == ["takeover"]:
            raise host.ProgrammeError("takeover is not offered: this session does not drive yet, so it has its own "
                                      "picker", fix="`programme.sh become-pm` prints it")
        for arg in argv:
            if arg.startswith("<") and arg.endswith(">"):
                raise host.ProgrammeError(f"{arg} is a placeholder; offer the command you will run")
        parsed.append(argv)
    return parsed


def _options(host, parsed, programme, doc) -> list:
    options = []
    for argv in parsed:
        try:
            rendered = render(argv, programme, doc if argv[0] in _CONTENT_VERBS else None)
        except Exception as exc:
            raise host.ProgrammeError(f"cannot offer {shlex.join(argv)}: {exc}",
                                      fix=host.programme_approval.approval_fix(argv[0], argv)) from None
        tail = " < the same JSON" if argv[0] in _CONTENT_VERBS else ""
        option = {"label": rendered["label"], "description": rendered["description"], "argv_hash": argv_hash(argv),
                  "subject": subject(rendered), "authority": rendered["authority"],
                  "command": programme_journal.redact(f"programme.sh {shlex.join(argv)} {_PICK_PLACE}{tail}")}
        if argv[0] in _CONTENT_VERBS:
            option["content_hash"] = content_hash(doc)
        options.append(option)
    labels = [option["label"] for option in options]
    if len(set(labels)) != len(labels):
        raise host.ProgrammeError("two options would show the same text; offer them in separate pickers")
    return options


def _question(key, labels) -> str:
    return f"{labels[0]}?" if len(labels) == 1 else f"Which of these? ({key})"


def _decline_option() -> dict:
    return {"label": DECLINE, "description": _DECLINE_TEXT}


def _picker(key, options) -> dict:
    shown = [{"label": option["label"], "description": option["description"]} for option in options]
    # Text and Enter sent into an open picker chooses the first option, and the transcript cannot tell that from Shawn.
    if any(option["authority"] for option in options):
        shown = [_decline_option(), *shown]
    else:
        shown = [*shown, _decline_option()]
    return {"questions": [{"question": _question(key, [o["label"] for o in options]), "header": key[:HEADER_CAP],
                           "multiSelect": False, "options": shown}]}


def _read_doc(parsed):
    if not any(argv[0] in _CONTENT_VERBS for argv in parsed):
        return None
    if sum(argv[0] in _CONTENT_VERBS for argv in parsed) > 1:
        raise ValueError("one offer holds one command that reads stdin")
    raw = sys.stdin.read(STDIN_CAP + 1) if not sys.stdin.isatty() else ""
    if len(raw) > STDIN_CAP:
        raise ValueError(f"the offer's stdin is larger than {STDIN_CAP} bytes")
    try:
        return json.loads(raw)
    except ValueError:
        raise ValueError("this command reads a JSON object on stdin; give the offer the same JSON") from None


def _h_offer(host, argv):
    positional, opts = host._parse(argv, values=("run",), multi=("command",))
    if len(positional) != 1 or not _KEY.fullmatch(positional[0]) or not opts["command"]:
        raise ValueError("usage: offer <question-key> --command '<verb> <args>' [--command ...] [--run <id>] "
                         "(the key is lowercase letters, digits and dashes)")
    key = positional[0]
    parsed = _parse_commands(host, opts["command"])
    doc = _read_doc(parsed)

    def change(programme, _prompt, _rec):
        options = _options(host, parsed, programme, doc)
        picker = _picker(key, options)
        return {"offer_id": "offer-" + uuid.uuid4().hex[:12], "question_key": key, "input": picker, "decline": DECLINE,
                "asked_hash": asked_hash(picker["questions"]),
                "options": [_decline_option(), *options]}

    return host._write(opts, change, OFFERED, verb="offer", target=key, beat=False, names_change=False)


def offer_for(rows, row):
    # None when no offer printed this exact picker; a pick that does not verify is refused later by pick_answer.
    pick = programme_pick_source.read_pick(row)
    if pick is None:
        return None
    want = asked_hash(pick["questions"])
    return next((r for r in reversed(rows[:rows.index(row)])
                 if r.get("kind") == OFFERED and (r.get("payload") or {}).get("asked_hash") == want), None)


def _chosen(payload, answer):
    return next((option for option in payload.get("options") or [] if option.get("label") == answer), None)


def _redo(payload) -> str:
    return f"rerun `programme.sh offer {payload.get('question_key')} --command '<the command>'` and ask Shawn again"


def _check_driver(offer, record, error, redo) -> None:
    if offer.get("session_id") != record.get("driving_session_id"):
        raise error("this picker was offered by another PM; a new driver offers it again", fix=redo)


def _rendered_now(option, argv, programme, error, redo) -> dict:
    doc = _CONTENT["doc"]
    if option.get("content_hash") and (doc is None or content_hash(doc) != option["content_hash"]):
        raise error("the content on stdin differs from what this offer showed; Shawn approves what he saw", fix=redo)
    try:
        rendered = render(argv, programme, doc if option.get("content_hash") else None)
    except Exception as exc:
        raise error(f"the facts changed since the offer, so this pick no longer applies: {exc}", fix=redo) from None
    if subject(rendered) != option.get("subject"):
        raise error("the facts this picker showed changed since the offer, so Shawn has not seen them", fix=redo)
    return rendered


def _picked_decline(error):
    return error("Shawn declined this offer; nothing runs", fix="do not run the command; ask Shawn what he wants")


def bind(offer, answer, argv, record, programme, error) -> dict:
    payload = offer["payload"]
    redo = _redo(payload)
    _check_driver(offer, record, error, redo)
    option = _chosen(payload, answer)
    shown = programme_journal.redact(answer)
    if option is None:
        raise error(f"answer {shown!r} is not one of the options this offer printed, so it approves nothing", fix=redo)
    if "argv_hash" not in option:
        raise _picked_decline(error)
    if option["argv_hash"] != argv_hash(argv):
        raise error(f"this pick approved a different command: {option.get('command')}", fix=redo)
    return {"answer": shown, "named": _rendered_now(option, argv, programme, error, redo)["named"]}


def _holding(payload, argv):
    want = argv_hash(argv)
    return next((option for option in payload.get("options") or [] if option.get("argv_hash") == want), None)


def _own_words(rows, row, offer, why, words, reading, argv, record, programme, error) -> dict:
    payload = offer["payload"]
    redo = _redo(payload)
    _check_driver(offer, record, error, redo)
    option = _holding(payload, argv)
    if option is None:
        raise error(f"{why}, but no open offer holds this command; the question just asked was "
                    f"{payload.get('question_key')!r}", fix=redo)
    label = option["label"]
    if option.get("authority"):
        raise error(f"{label!r} moves authority, so only a pick of that option approves it; {why}",
                    fix="relay his words, then ask again with the same picker; run the command only on a pick")
    if reading != label:
        raise error(f"{why}, so the PM states what it read them as: rerun with --reads-as {label!r}",
                    fix=f"read his words first. If they decline or ask something, run nothing. If they approve, add "
                        f"--reads-as {shlex.quote(label)}")
    rendered = _rendered_now(option, argv, programme, error, redo)
    newer = load_lib_module("programme_rulings").newer_words(rows, row["prompt_id"])
    if newer:
        raise error(f"prompt {row['prompt_id']!r} is older than {newer!r}, which nothing has cited yet; own words bind "
                    "only on Shawn's newest message", fix="read his newest message, then ask again if it is unclear")
    shown = programme_journal.redact(words)
    return {"quote": shown, "named": rendered["named"],
            "reading": {"read_as": label, "read_by": "pm", "offer_id": payload.get("offer_id"),
                        "read_back": f"Read your message as: {label}. Say so if that is wrong."}}


def bind_pick(rows, row, offer, pick, reading, argv, record, programme, error) -> dict:
    answer = pick["answer"]
    option = _chosen(offer["payload"], answer)
    if option is not None and "argv_hash" not in option:
        raise _picked_decline(error)
    if option is not None and not pick["noted"]:
        return bind(offer, answer, argv, record, programme, error)
    shown = programme_journal.redact(answer)
    why = (f"pick {row['prompt_id']!r} carries a note, which counts as Shawn's own words" if pick["noted"]
           else f"answer {shown!r} is not one of the options this offer printed, so it is Shawn's own words")
    said = [] if answer == programme_pick_source.NOTES_ONLY or option is not None else [answer]
    bound = _own_words(rows, row, offer, why, " ".join([*said, *pick["notes"]]) or answer, reading, argv, record,
                       programme, error)
    return dict(bound, answer=shown)


def _open_offer(rows, row):
    """The offer this message answers: the newest one, whose picker is the newest in the transcript at the message's
    enqueue position, and which no pick answered. Journal order alone would let words sent between the offer row and
    the asking row bind to a question Shawn had not seen."""
    offers = [r for r in rows[:rows.index(row)] if r.get("kind") == OFFERED]
    if not offers:
        return None
    asked = programme_pick_source.question_before(row)
    if asked is None or asked_hash(asked[1]) != offers[-1]["payload"].get("asked_hash"):
        return None
    answered = any(r.get("kind") == "prompt" and ((r.get("payload") or {}).get("source") or {}).get("tool_use_id") == asked[0]
                   for r in rows)
    return None if answered else offers[-1]


def _spent(rows, prompt_id) -> bool:
    return any(r.get("kind") not in ("prompt", "approval_refused")
               and prompt_id in {*(r.get("cites") or []), (r.get("payload") or {}).get("prompt_id")} for r in rows)


def bind_words(rows, row, origin, reading, argv, record, programme, error) -> dict:
    """What a typed, queued or suggested message adds to an approval; an empty dict leaves it on the older checks,
    which stay until the verbs move to offers."""
    prompt_id = row["prompt_id"]
    at = rows.index(row)
    if any(_holding(r.get("payload") or {}, argv) for r in rows[at + 1:] if r.get("kind") == OFFERED):
        raise error(f"prompt {prompt_id!r} came before the offer of this command, so it does not answer that question",
                    fix="ask again, or wait for his answer to the picker")
    offer = _open_offer(rows, row)
    if origin == "suggested":
        if offer is not None or reading is not None:
            raise error(f"prompt {prompt_id!r} is an accepted suggestion: the model wrote it, so it approves no offer",
                        fix="ask with the picker and wait for his pick or his own words")
        return {}
    if offer is None:
        if reading is not None:
            raise error(f"no open offer asks the question prompt {prompt_id!r} would answer, so it approves nothing",
                        fix="run `programme.sh offer`, ask with the input it prints, and wait for his answer")
        return {}
    if reading is None and _holding(offer["payload"], argv) is None:
        return {}
    if _spent(rows, prompt_id):
        raise error(f"prompt {prompt_id!r} already approved a change; one message approves one change",
                    fix="ask Shawn about this one")
    why = f"prompt {prompt_id!r} is Shawn's own words"
    payload = row.get("payload") or {}
    return _own_words(rows, row, offer, why, payload.get("text") or "", reading, argv, record, programme, error)


def after_pick(run, session_id, prompt_id, data):
    """A hint for the PM from the hook's payload. Evidence stays with the transcript check at approval."""
    tool_input = data.get("tool_input")
    answers = (data.get("tool_response") or {}).get("answers")
    if not isinstance(tool_input, dict) or not isinstance(answers, dict) or len(answers) != 1:
        return None
    want = asked_hash(tool_input.get("questions"))
    rows = programme_journal.read(run)
    offer = next((r for r in reversed(rows) if r.get("kind") == OFFERED and r.get("session_id") == session_id
                  and (r.get("payload") or {}).get("asked_hash") == want), None)
    if not offer:
        return None
    answer = next(iter(answers.values()))
    option = _chosen(offer["payload"], answer)
    annotations = (data.get("tool_response") or {}).get("annotations")
    noted = answer == programme_pick_source.NOTES_ONLY or (
        isinstance(annotations, dict) and any(isinstance(e, dict) and e.get("notes") for e in annotations.values()))
    if option is not None and "argv_hash" not in option:
        programme_journal.append(run, DECLINED, session_id, {"offer_id": offer["payload"].get("offer_id")},
                                 cites=[prompt_id])
        return {"declined": True, "note": "Shawn declined: nothing runs."}
    if option is None or noted:
        return {"own_words": True, "note": _OWN_WORDS_NOTE}
    return {"runs": option.get("command", "").replace("<pick id>", prompt_id)}


def takeover_label(driver) -> str:
    return f"Take over from the PM in session {driver}"


def takeover_input(driver) -> dict:
    return {"questions": [{
        "question": f"Replace the PM in session {driver} with this session?", "header": "Takeover",
        "multiSelect": False,
        "options": [_decline_option(),
                    {"label": takeover_label(driver), "description": "This session becomes the programme's PM."}]}]}


def takeover_matches(questions, answer, driver) -> bool:
    return answer == takeover_label(driver) and asked_hash(questions) == asked_hash(takeover_input(driver)["questions"])


_SPECS = (
    ("offer", _h_offer, "<question-key> --command '<verb> <args>' [--command ...] [--run <id>]",
     "a session that does not drive the programme; a verb a pick cannot approve; takeover, whose picker `become-pm` "
     "prints; a placeholder argument; more than 3 commands; two options with one text. Journals approval_offered and "
     "prints the exact AskUserQuestion input. The PM asks with that input unchanged. Set-remit takes the same JSON "
     "on stdin that the verb will read."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

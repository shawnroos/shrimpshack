#!/usr/bin/env python3
"""Auto writes a picker's text from the commands it approves and stores each option's link to its command."""

from __future__ import annotations

import collections
import functools
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
programme_fixes = load_lib_module("programme_fixes")
programme_home = load_lib_module("programme_home")
programme_offer_rendering = load_lib_module("programme_offer_rendering")
programme_offers_stores = load_lib_module("programme_offers_stores")

OfferError = programme_offer_rendering.OfferError
note_content = programme_offer_rendering.note_content
noted_content = programme_offer_rendering.noted_content
_rendered = programme_offer_rendering.rendered
_layered = programme_offer_rendering.layered
_whole_set = programme_offer_rendering.whole_set
asked_hash = content_hash = programme_journal.canonical_sha

OFFERED = "approval_offered"
DECLINED = "approval_declined"
DECLINE = "Not now"
_DECLINE_TEXT = "Approves nothing and runs nothing."
_PICK_ID = "<pick id>"
_PICK_PLACE = f"--prompt {_PICK_ID}"
# A question holds 2 to 4 options, and the decline takes one.
MAX_COMMANDS = 3
# The AskUserQuestion schema caps a header at 12 characters.
HEADER_CAP = 12
# Room for a whole draft at the verbs' cap plus the facts around it: Shawn approves what he can read.
DRAFT_TEXT_CAP = 900
_KEY = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
_NOT_BOUND = ("--prompt", "--run", "--op", "--reads-as")
STDIN_CAP = 256 * 1024
_OWN_WORDS_NOTE = ("This answer is Shawn's own words. If they decline or ask something, run nothing. If they approve, "
                   "run the command with --reads-as <the option's text>. On a draft his words become the text. An "
                   "authority move takes only a pick: relay his words and ask again.")


def bound_argv(argv) -> list:
    kept, args = [], list(argv)
    while args:
        arg = args.pop(0)
        if arg in _NOT_BOUND:
            args = args[1:]
        else:
            kept.append(arg)
    return kept


def argv_hash(argv) -> str:
    return load_lib_module("programme_approval").text_hash(shlex.join(bound_argv(argv)))


Binding = collections.namedtuple("Binding", "reading argv record programme error")


def _item(programme, ident) -> tuple:
    record = load_lib_module("programme_record")
    key = record._resolve(programme, ident)
    item = programme["items"][key]
    handed = item.get("handed")
    # The sweep marks an ask shown around the time it asks, and that mark is no fact Shawn answered on.
    facts = {k: v for k, v in handed.items() if k != "shown"} if isinstance(handed, dict) else handed
    return key, item, {"title": item.get("title"), "state": item.get("state"), "handed": facts}


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
    return _rendered(f"{choice.capitalize()} item {key}", _about(key, item), facts)


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
        label = _whole_set(f"Keep {noun}s {' and '.join(cmd.pos)} in {_layer_words(cmd)}", cmd.pos)
        entries = [_layered(module_name, programme, ident) for ident in cmd.pos]
        return _rendered(label, "", entries)
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
        return _accept_ruling(context, ident, block["decisions"][ident])
    revision = context.pending(block["requirements"].get(ident))
    if revision is None:
        raise OfferError(f"no pending revision of {ident!r} to accept")
    delta = revision.get("delta") if isinstance(revision.get("delta"), dict) else {}
    wider = bool(delta.get("wider"))
    return _rendered(f"{'Widen by accepting' if wider else 'Accept'} requirement {ident}",
                     revision.get("text") or "", revision, authority=wider)


def _draft(text) -> str:
    cleaned = programme_sanitize.clean(text, cap=0)
    if len(cleaned) > programme_sanitize.DEFAULT_CAP:
        raise OfferError(f"the draft is {len(cleaned)} characters and the record holds {programme_sanitize.DEFAULT_CAP}; "
                         "shorten it, since Shawn approves all of what is recorded")
    return programme_journal.redact(cleaned)


# Shawn sees each thing a widening adds, drops or extends.
def _ruling_words(content, delta) -> str:
    targets = " and ".join(content.get("applies_to") or []) or "no items yet"
    words = [f"{content.get('effect')} {content.get('kind')} on {targets}."]
    if content.get("limits"):
        words.append(f"Limits: {'; '.join(content['limits'])}.")
    if content.get("until"):
        words.append(f"Ends {content['until'][:10]}.")
    if delta:
        if delta.get("added"):
            words.append(f"Adds {' and '.join(delta['added'])}.")
        if delta.get("removed"):
            words.append(f"Removes {' and '.join(delta['removed'])}.")
        if delta.get("removed_limits"):
            words.append(f"Drops limits: {'; '.join(delta['removed_limits'])}.")
        if delta.get("until"):
            words.append(f"The end date is {delta['until']}.")
    return " ".join(words)


# A first grant has no delta, yet it widens the PM from nothing, so it takes a pick as a wider revision does.
def _widens(effect, current, delta) -> bool:
    return bool(delta and delta.get("wider")) or (current is None and effect == "grant")


def _accept_ruling(context, ident, revisions) -> dict:
    revision = context.pending(revisions)
    if revision is None:
        raise OfferError(f"no pending revision of {ident!r} to accept")
    delta = revision.get("delta") if isinstance(revision.get("delta"), dict) else None
    wider = _widens(revision.get("effect"), context.in_force(revisions), delta)
    verb = "Widen by accepting" if wider else "Accept"
    return _rendered(f"{verb} Ruling {ident}", f"{revision.get('scope')} ({_ruling_words(revision, delta)})",
                     revision, authority=wider, cap=DRAFT_TEXT_CAP)


def _record_ruling(cmd, programme) -> dict:
    context = load_lib_module("programme_context")
    rulings = load_lib_module("programme_rulings")
    ident = cmd.first("<id> --effect decided|grant|restrict --scope <text>")
    effect = cmd.one_of("effect", context.EFFECTS)
    revisions = context.block(programme)["decisions"].get(ident) or []
    if cmd.opt("replies-to"):
        anchor = rulings.anchor(programme, cmd.opt("replies-to"))
        kind, targets = anchor["kind"], [anchor["item"] or context.PROGRAMME_SCOPE]
    else:
        kind = cmd.opt("kind")
        if not kind:
            raise OfferError("record-ruling needs --kind <decision-kind> or --replies-to <ask-or-decision-id>")
        targets = context._scope(load_lib_module("programme_record"), programme, cmd.opts.get("applies-to"))
    rulings._check_protected(kind, effect)
    scope = _draft(cmd.opt("scope"))
    content = {"kind": kind, "effect": effect, "applies_to": targets, "until": cmd.opt("until") or None,
               "limits": sorted({programme_sanitize.clean(v) for v in cmd.opts.get("limit") or []})}
    current = context.in_force(revisions)
    delta = context.ruling_delta(current, content)
    wider = _widens(effect, current, delta)
    label = f"Widen with a {kind} grant in Ruling {ident}" if wider and effect == "grant" else (
        f"Widen by loosening restrict Ruling {ident}" if wider else f"Record {effect} Ruling {ident} on {kind}")
    why = f" Why: {cmd.opt('reason')}." if cmd.opt("reason") else ""
    return _rendered(label, f"{scope} ({_ruling_words(content, delta)}){why}", {"revisions": revisions, "draft": scope},
                     authority=wider, content=scope, cap=DRAFT_TEXT_CAP)


def _close_ruling(cmd, programme) -> dict:
    context = load_lib_module("programme_context")
    ident = cmd.first("<id> --as fulfilled|withdrawn")
    ending = cmd.one_of("as", load_lib_module("programme_rulings").ENDINGS)
    revisions = context.block(programme)["decisions"].get(ident) or []
    current = context.in_force(revisions) or context.pending(revisions)
    if current is None or not context.is_ruling(revisions):
        raise OfferError(f"no Ruling {ident!r} in force or pending to close")
    restrict = current.get("effect") == "restrict"
    label = f"{'Widen by closing' if restrict else 'Withdraw' if ending == 'withdrawn' else 'Close'} Ruling {ident}"
    why = _draft(cmd.opt("why"))
    back = f" This hands {current.get('kind')} back to the PM." if restrict else ""
    return _rendered(label, f"{current.get('scope')} ({current.get('effect')} {current.get('kind')}).{back} "
                            f"Closed as {ending}. Why: {why or 'none given'}.",
                     {"revisions": revisions, "draft": why}, authority=restrict, content=why, cap=DRAFT_TEXT_CAP)


def _define_requirement(cmd, programme) -> dict:
    ident = cmd.first("<id> --text <text> --check <item-id>=<deliverable>...")
    existing = load_lib_module("programme_context").block(programme)["requirements"].get(ident)
    text = _draft(cmd.opt("text"))
    return _rendered(f"Set requirement {ident}", f"{text} Checks: {cmd.opt('check')}.", {"revisions": existing, "draft": text},
                     cap=DRAFT_TEXT_CAP)


def _edit_term(cmd, programme) -> dict:
    if len(cmd.pos) != 2:
        raise OfferError("usage: edit-project-term <term-id> <text>")
    entry = load_lib_module("programme_terms")._find(programme, cmd.pos[0])
    text = _draft(cmd.pos[1])
    return _rendered(f"Change preferred tool {entry.get('area')}", f"New: {text} Now: {entry.get('value')}",
                     {"value": entry.get("value"), "draft": text}, content=text, cap=DRAFT_TEXT_CAP)


def _lift_pause(cmd, programme) -> dict:
    ident = cmd.first("<id>")
    entry = load_lib_module("programme_context").block(programme)["pauses"].get(ident)
    if not isinstance(entry, dict):
        raise OfferError(f"no pause {ident!r}")
    return _rendered(f"Lift pause {ident}", entry.get("reason") or "", entry)


_PERMISSION_WORDS = {"applied": "Check the rule added by hand for permission", "not-now": "Hold permission",
                     "no": "Refuse permission"}
# Shawn approves the reach and the exclusions along with the rule, so the usual cap must not cut them off.
_ALLOW_TEXT_CAP = 2000


def _allow_permission(ident, proposal, programme) -> dict:
    plan = load_lib_module("programme_permission_settle").allow_plan(programme, proposal)
    shown = {key: plan[key] for key in ("rules", "file", "reach", "exclusions")}
    text = (f"Auto writes {' and '.join(plan['rules'])} to {plan['file']}. This widens what the session may do. "
            f"Reach: {' '.join(plan['reach'])} Still not allowed: {'; '.join(plan['exclusions'])}.")
    return _rendered(f"Widen by allowing permission {ident}", text,
                     dict(shown, state=proposal.get("state"), changed_at=proposal.get("changed_at")), authority=True,
                     cap=_ALLOW_TEXT_CAP)


def _permission(cmd, programme) -> dict:
    if len(cmd.pos) != 2 or cmd.pos[1] not in ("allow", *_PERMISSION_WORDS):
        raise OfferError("usage: answer-permission <perm-id> allow|applied|not-now|no")
    ident, choice = cmd.pos
    proposal = load_lib_module("programme_permission_state").find(programme, ident)
    if proposal is None:
        raise OfferError(f"no permission proposal {ident!r}")
    if choice == "allow":
        return _allow_permission(ident, proposal, programme)
    rules = ", ".join(str(r) for r in proposal.get("rules") or [])
    return _rendered(f"{_PERMISSION_WORDS[choice]} {ident}", f"Rules: {rules}.",
                     {k: proposal.get(k) for k in ("rules", "state", "changed_at")})


def _dispose(cmd, _programme) -> dict:
    target = cmd.opt("attempt") or cmd.opt("resource")
    how = cmd.opt("as").replace("_", " ")
    if not target or not how:
        raise OfferError("usage: dispose-action (--attempt <id>|--resource <id>) --as <how>")
    return _rendered(f"Record {target} as {how}")


def _end(cmd, programme) -> dict:
    if cmd.pos:
        raise OfferError("usage: end [--why <text>] [--without-rituals]")
    unfinished = sorted(key for key, item in (programme.get("items") or {}).items()
                        if (item or {}).get("state") in load_lib_module("programme_archive").UNFINISHED)
    left = f"Not finished: {' '.join(unfinished)}." if unfinished else "No item is unfinished."
    skip = " without its rituals" if cmd.opts.get("without-rituals") else ""
    return _rendered(f"End this programme{skip}", f"No new work starts. {left} {cmd.extras('without-rituals')}",
                     {"unfinished": unfinished}, authority=True)


def _handover(cmd, _programme) -> dict:
    target = cmd.first("<session-id> [--without-rituals]")
    # The label cap is 80, and a session id is 36: a longer sentence would cut off the rituals it skips.
    skip = " without its rituals" if cmd.opts.get("without-rituals") else ""
    return _rendered(f"Hand the PM to session {target}{skip}",
                     "This session stops being the PM. Nothing from this chat carries over.", {"target": target},
                     authority=True)


def _accept(_cmd, programme) -> dict:
    digest = load_lib_module("programme_approval").terms_digest(programme)
    return _rendered(f"Accept the agreement with terms {digest}",
                     "These are the terms status shows now. Accepting gives the PM its authority.", authority=True)


def _remit(_cmd, programme, doc) -> dict:
    if doc is None:
        raise OfferError("set-remit reads the remit as a JSON object on stdin")
    lifecycle = load_lib_module("programme_lifecycle")
    changes = lifecycle.remit_changes(programme["remit"], lifecycle.parse_remit(doc, programme["remit"]))
    names = [lifecycle._names(part, entry)[0] for part, _how, entry in changes]
    wider = any(how == "added" for _part, how, _entry in changes)
    shown = "; ".join(f"{how} {part}: {name}" for (part, how, _entry), name in zip(changes, names))
    digest = content_hash(doc)[len("sha256:"):][:6]
    return _rendered(f"{'Widen' if wider else 'Change'} the remit, change {digest}",
                     shown or "No change.", authority=wider)


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
    "close-ruling": _close_ruling,
    "define-requirement": _define_requirement,
    "dispose-action": _dispose,
    "drop-item": _drop,
    "edit-project-term": _edit_term,
    "end": _end,
    "handover": _handover,
    "keep-behaviours": _keeper("behaviour", "programme_behaviours"),
    "keep-rituals": _keeper("ritual", "programme_rituals"),
    "lift-pause": _lift_pause,
    "move-behaviour": _mover("behaviour", "programme_behaviours"),
    "move-ritual": _mover("ritual", "programme_rituals"),
    "override-focus": _override,
    "record-ruling": _record_ruling,
    "reopen-item": _reopen,
    "retire-ritual": _ritual_step({"retired": "Retire", "undone": "Undo"}),
    "run-ritual": _ritual_step("Run"),
    "set-remit": _remit,
    "skip-ritual": _ritual_step("Skip"),
    "start-ritual": _ritual_step("Start"),
    "swap-item": _swap,
    **programme_offers_stores.RENDERERS,
}
_CONTENT_VERBS = ("set-remit",)
# These also run after `end`, so their offer must too.
_AFTER_END = frozenset(("carry-rulings", "dispose-action"))


def render(argv, programme, doc=None) -> dict:
    kept = bound_argv(argv)
    verb = kept[0] if kept else None
    if verb not in RENDERERS:
        raise OfferError(f"{verb} takes no approval, so nothing can offer it")
    cmd = programme_offer_rendering.Command(kept)
    return RENDERERS[verb](cmd, programme, doc) if verb in _CONTENT_VERBS else RENDERERS[verb](cmd, programme)


def subject(rendered) -> str:
    return programme_journal.canonical_sha({key: rendered[key] for key in ("label", "description", "facts")})


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
            rendered = render(argv, programme, doc)
        except Exception as exc:
            raise host.ProgrammeError(f"cannot offer {shlex.join(argv)}: {exc}",
                                      fix=programme_fixes.fix_for("offer")) from None
        tail = " < the same JSON" if argv[0] in _CONTENT_VERBS else ""
        option = {"label": rendered["label"], "description": rendered["description"], "argv_hash": argv_hash(argv),
                  "subject": subject(rendered), "authority": rendered["authority"],
                  "command": programme_journal.redact(f"programme.sh {shlex.join(argv)} {_PICK_PLACE}{tail}")}
        if rendered["content"] is not None:
            option["content"] = rendered["content"]
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
        if programme_home.sealed(programme):
            raise host.ProgrammeError("the programme is archived; nothing more can be asked or approved in it")
        options = _options(host, parsed, programme, doc)
        picker = _picker(key, options)
        return {"offer_id": "offer-" + uuid.uuid4().hex[:12], "question_key": key, "input": picker, "decline": DECLINE,
                "asked_hash": asked_hash(picker["questions"]),
                "options": [_decline_option(), *options]}

    return host._write(opts, change, OFFERED, verb="offer", target=key, beat=False,
                       after_end=all(argv[0] in _AFTER_END for argv in parsed))


def _newest_offer(rows, want):
    return next((r for r in reversed(rows)
                 if r.get("kind") == OFFERED and (r.get("payload") or {}).get("asked_hash") == want), None)


def offer_for(rows, row, pick):
    if pick is None:
        return None
    return _newest_offer(rows[:rows.index(row)], asked_hash(pick["questions"]))


def _chosen(payload, answer):
    return next((option for option in payload.get("options") or [] if option.get("label") == answer), None)


def _redo(payload) -> str:
    return f"rerun `programme.sh offer {payload.get('question_key')} --command '<the command>'` and ask Shawn again"


def _check_driver(offer, binding, redo) -> None:
    if offer.get("session_id") != binding.record.get("driving_session_id"):
        raise binding.error("this picker was offered by another PM; a new driver offers it again", fix=redo)


def _check_rendered_now(option, binding, redo) -> None:
    error = binding.error
    doc = noted_content()
    if option.get("content_hash") and (doc is None or content_hash(doc) != option["content_hash"]):
        raise error("the content on stdin differs from what this offer showed; Shawn approves what he saw", fix=redo)
    try:
        rendered = render(binding.argv, binding.programme, doc if option.get("content_hash") else None)
    except Exception as exc:
        raise error(f"the facts changed since the offer, so this pick no longer applies: {exc}", fix=redo) from None
    if subject(rendered) != option.get("subject"):
        raise error("the facts this picker showed changed since the offer, so Shawn has not seen them", fix=redo)


def _picked_decline(error):
    return error("Shawn declined this offer; nothing runs", fix="do not run the command; ask Shawn what he wants")


def bind(offer, answer, binding) -> dict:
    error = binding.error
    payload = offer["payload"]
    redo = _redo(payload)
    _check_driver(offer, binding, redo)
    option = _chosen(payload, answer)
    shown = programme_journal.redact(answer)
    if option is None:
        raise error(f"answer {shown!r} is not one of the options this offer printed, so it approves nothing", fix=redo)
    if "argv_hash" not in option:
        raise _picked_decline(error)
    if option["argv_hash"] != argv_hash(binding.argv):
        raise error(f"this pick approved a different command: {option.get('command')}", fix=redo)
    _check_rendered_now(option, binding, redo)
    return {"answer": shown, "quote": option.get("content") or option["label"],
            "reading": {"wording": programme_journal.PM_DRAFT, "offer_id": payload.get("offer_id")}}


def _holding(payload, argv):
    want = argv_hash(argv)
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
                        fix="relay this to Shawn and ask him for a shorter text, or split it into two Rulings")
    read_back = (f"Recorded your words as the text of: {label}. Say so if that is wrong." if is_draft
                 else f"Read your message as: {label}. Say so if that is wrong.")
    return {"quote": shown,
            "reading": {"read_as": label, "read_by": "pm", "offer_id": payload.get("offer_id"),
                        "wording": programme_journal.SHAWN, "read_back": read_back}}


def bind_pick(rows, row, offer, pick, binding) -> dict:
    answer = pick["answer"]
    option = _chosen(offer["payload"], answer)
    if option is not None and "argv_hash" not in option:
        raise _picked_decline(binding.error)
    if option is not None and not pick["noted"]:
        return bind(offer, answer, binding)
    shown = programme_journal.redact(answer)
    why = (f"pick {row['prompt_id']!r} carries a note, which counts as Shawn's own words" if pick["noted"]
           else f"answer {shown!r} is not one of the options this offer printed, so it is Shawn's own words")
    said = [] if answer == programme_pick_source.NOTES_ONLY or option is not None else [answer]
    bound = _own_words(rows, row, offer, why, " ".join([*said, *pick["notes"]]) or answer, binding)
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


def _no_offer(argv, prompt_id, error):
    return error(f"no open offer of this command asks the question prompt {prompt_id!r} would answer, so it approves "
                 "nothing", fix=programme_fixes.fix_for(argv[0] if argv else "offer"))


def bind_words(rows, row, origin, binding) -> dict:
    error, argv = binding.error, binding.argv
    prompt_id = row["prompt_id"]
    at = rows.index(row)
    if any(_holding(r.get("payload") or {}, argv) for r in rows[at + 1:] if r.get("kind") == OFFERED):
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


def after_pick(run, session_id, prompt_id, data):
    """A hint for the PM from the hook's payload. Evidence stays with the transcript check at approval."""
    tool_input = data.get("tool_input")
    answers = (data.get("tool_response") or {}).get("answers")
    if not isinstance(tool_input, dict) or not isinstance(answers, dict) or len(answers) != 1:
        return None
    want = asked_hash(tool_input.get("questions"))
    rows = programme_journal.read(run)
    offer = _newest_offer([r for r in rows if r.get("session_id") == session_id], want)
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
    return {"runs": option.get("command", "").replace(_PICK_ID, prompt_id)}


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
     "on stdin that the verb will read. On a draft, Other or his message becomes the text."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

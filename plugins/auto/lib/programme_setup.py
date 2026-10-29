#!/usr/bin/env python3
"""Setup verbs: picked terms before acceptance, and the walkthrough's step and probe notes.

``programme.py`` registers these through ``build_verbs(host)``.
"""

from __future__ import annotations

import functools
import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")
programme_naming = load_lib_module("programme_naming")
programme_proposals = load_lib_module("programme_proposals")
programme_terms = load_lib_module("programme_terms")
programme_view_setup = load_lib_module("programme_view_setup")
driver_session = load_lib_module("driver_session")

STEPS = (programme_view_setup.RULINGS, programme_view_setup.SHARED, programme_view_setup.ITEMS,
         programme_view_setup.ACCEPT)
TAKE_ALL = "take all recommendations"
_RECOMMENDED_SUFFIX = re.compile(r"\s*\(recommended\)$", re.IGNORECASE)


def _picked(host, run_id, rec, pick_id) -> dict:
    rows = programme_journal.read(run_id)
    row = programme_journal.find_prompt(run_id, pick_id, rows)
    if row is None:
        raise host.ProgrammeError(f"no prompt {pick_id!r} in this programme's journal")
    origin = programme_journal.prompt_origin(row)
    if row.get("provenance") in programme_authority.UNVERIFIED or origin != "picked":
        raise host.ProgrammeError(f"prompt {pick_id!r} is not a verified pick (origin {origin!r}); "
                                  "only a picker answer Shawn gave in this session approves a setup choice")
    if row.get("session_id") != rec.get("driving_session_id"):
        raise host.ProgrammeError(f"pick {pick_id!r} was not answered in the driving session")
    if row["payload"].get("driving") is False:
        raise host.ProgrammeError(f"pick {pick_id!r} was answered before this session drove the programme; "
                                  "it can serve only a takeover")
    source = row["payload"]["source"]
    used = programme_journal.pick_use(rows, source)
    if used is not None:
        raise host.ProgrammeError(f"pick {pick_id!r} was already used ({used.get('kind')}); "
                                  "one picker answer approves one choice")
    return {"prompt_id": pick_id, "answers": source["answers"], "path": source["path"],
            "tool_use_id": source["tool_use_id"]}


def _before_acceptance(host, programme) -> None:
    if programme["agreement"].get("accepted"):
        raise host.ProgrammeError("the agreement is accepted; after acceptance a change goes through its "
                                  "approval verb (`amend-term <key> <value> --prompt <id>` of a typed prompt or a pick)")


def _pickable(host, programme, key) -> dict:
    terms = programme["agreement"]["terms"]
    if key not in terms or not isinstance(terms[key], dict):
        raise host.ProgrammeError(
            f"{key!r} is not a per-programme agreement term, so it stays typed: a pick sets only "
            f"{sorted(terms)}; Rulings and shared "
            "settings need the reply Shawn types")
    return terms[key]


def _named(value, answer) -> list:
    if isinstance(value, list):
        return programme_naming.missing(answer, value or ["none"])
    return programme_naming.missing(answer, [value])


def _also_named(value, answer, options) -> list:
    if not isinstance(value, list):
        return []
    return [o for o in options if o not in value and not programme_naming.missing(answer, [o])]


def _answer_for(host, pick, key, value, options=()) -> tuple:
    others = [k for k in programme_home.TERM_GUIDE if k != key]
    asked = [(q, a) for q, a in pick["answers"].items()
             if not programme_naming.missing(q, [key]) and all(programme_naming.missing(q, [o]) for o in others)]
    if len(asked) != 1:
        raise host.ProgrammeError(f"pick {pick['prompt_id']!r} does not answer the {key!r} step: exactly one "
                                  f"of its questions must name {key!r} and no other term")
    question, answer = asked[0]
    missing = _named(value, answer)
    if missing:
        raise host.ProgrammeError(f"pick {pick['prompt_id']!r} does not name what it approves; its answer "
                                  f"{answer!r} must contain {' and '.join(missing)}")
    extra = _also_named(value, answer, options)
    if extra:
        raise host.ProgrammeError(f"pick {pick['prompt_id']!r} does not match what it approves; its answer "
                                  f"{answer!r} also names {' and '.join(extra)}, which the value leaves out")
    return question, answer


def _cite(pick, question, answer) -> dict:
    return {"prompt_id": pick["prompt_id"], "quote": f"picked: {question} -> {answer}", "origin": "picked",
            "question": question, "answer": answer, "path": pick["path"], "tool_use_id": pick["tool_use_id"]}


def _set(host, term, value, extra, cite, why, settle=True) -> dict:
    out = host._set_term(term, value, extra, set_by="shawn", why=why, prompt=cite)
    term["origin"] = "picked"
    if settle:
        programme_proposals.settle_amend(term, value)
    return out


def _pick_write(host, opts, change, kind, *, verb, target):
    pick_id = opts.get("pick")
    if not pick_id:
        raise ValueError(f"{verb} needs --pick <id> of a picked prompt")
    run_id, home, _ = host._locate(opts)
    seen = {}

    def mutate(rec):
        seen["sid"] = host._guard(home, rec)
        rec.setdefault("loop", {})["last_beat_at"] = host._now()
        rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        _before_acceptance(host, rec["programme"])
        pick = _picked(host, run_id, rec, pick_id)
        seen["payload"] = change(rec["programme"], pick)
        seen["record"] = rec

    def compose(_, rec):
        return programme_journal.entry(kind, seen["sid"], seen["payload"], cites=[pick_id])

    try:
        out = programme_authority.write(home, run_id, mutate, compose, operation_id=host._OPERATION["id"])
    except (host.ProgrammeError, ValueError, programme_terms.TermsError) as exc:
        if "sid" in seen:
            host._journal_refusal(run_id, home, seen["sid"], verb, target, pick_id, exc)
        raise
    payload = (out["row"] or {}).get("payload") if out["replayed"] else seen["payload"]
    if not out["replayed"]:
        host.refresh_view(run_id, home, seen["record"])
    host._emit({"ok": True, "run": run_id, "kind": kind, "replayed": out["replayed"], **(payload or {})})
    return 0


def _h_pick_term(host, argv):
    positional, opts = host._parse(
        argv, values=("run", "pick", "why", "until", "seconds") + programme_home.TERM_EXTRAS)
    if len(positional) != 2:
        raise ValueError("usage: pick-term <key> <value> --pick <id>")
    key, value = positional

    def change(programme, pick):
        term = _pickable(host, programme, key)
        checked = programme_proposals.check_amend(host, term, value, opts)
        options = programme_proposals.offered(term).get("options")
        question, answer = _answer_for(host, pick, key, checked, options or ())
        cite = _cite(pick, question, answer)
        return dict(_set(host, term, checked, opts, cite, opts.get("why")), **cite)

    return _pick_write(host, opts, change, programme_terms.PICKED, verb="pick-term", target=key)


def _recommendation(term) -> tuple:
    proposal = programme_proposals.pending(term)
    extras = dict((proposal or {}).get("extras") or {})
    # A proposed new remit space is accepted only by set-remit, so its proposal stays pending.
    if proposal is None or "add" in extras and term.get("key") == "remit":
        return term.get("value"), {k: term[k] for k in ("seconds", "until") if term.get(k) is not None}, False
    return proposal.get("value"), extras, True


def _is_take_all(answer) -> bool:
    return _RECOMMENDED_SUFFIX.sub("", str(answer).strip()).strip().casefold() == TAKE_ALL


def _h_take_recommendations(host, argv):
    positional, opts = host._parse(argv, values=("run", "pick"))
    if positional:
        raise ValueError("usage: take-recommendations --pick <id>")

    def change(programme, pick):
        taken = [(q, a) for q, a in pick["answers"].items() if _is_take_all(a)]
        if len(taken) != 1:
            raise host.ProgrammeError(f"pick {pick['prompt_id']!r} is not the {TAKE_ALL!r} option; its answers: "
                                      f"{sorted(pick['answers'].values())}")
        cite = _cite(pick, *taken[0])
        applied = {}
        for key, term in programme["agreement"]["terms"].items():
            if programme_home.is_opt_in(key) or not isinstance(term, dict):
                continue
            value, extras, settle = _recommendation(term)
            _set(host, term, value, extras, cite, TAKE_ALL, settle=settle)
            applied[key] = value
        return dict(cite, terms=applied)

    return _pick_write(host, opts, change, programme_terms.RECOMMENDED, verb="take-recommendations",
                       target="agreement")


def _step_name(host, programme, name, *, keep=False) -> str:
    known = list(programme["agreement"]["terms"]) + list(STEPS)
    if name not in known:
        raise host.ProgrammeError(f"unknown setup step {name!r}; steps: {known}")
    if keep and name == programme_view_setup.ACCEPT:
        raise host.ProgrammeError("the accept step is never kept: Shawn accepts by typing it or by "
                                  "picking the label `programme.sh approval-label accept-agreement` prints")
    return name


def _setup(programme) -> dict:
    setup = programme.get("setup")
    programme["setup"] = setup = dict(setup) if isinstance(setup, dict) else {}
    return setup


def _ui_write(host, opts, change, kind):
    return host._write(opts, change, kind, compact_exempt=True, beat=False)


def _h_setup_step(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 1:
        raise ValueError("usage: setup-step <name>")

    def change(programme, prompt, rec):
        _setup(programme)["step"] = _step_name(host, programme, positional[0])
        return {"step": positional[0]}

    return _ui_write(host, opts, change, "setup_step_set")


def _string_list(host, value, what) -> list:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise host.ProgrammeError(f"setup-seen {what} must be a list of strings")
    return value


def _seen_items(host, value) -> list:
    out = []
    for entry in value or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("item"), str) or not entry["item"]:
            raise host.ProgrammeError("setup-seen items must be objects with a string item id")
        out.append({k: entry.get(k) for k in ("item", "title", "pane", "session")})
    return out


def _read_seen(host, path) -> dict:
    try:
        if path == "-":
            text = sys.stdin.read()
        else:
            with open(path) as fh:
                text = fh.read()
        seen = json.loads(text)
    except (OSError, ValueError) as exc:
        raise host.ProgrammeError(f"setup-seen could not read JSON from {path!r}: {exc}") from None
    if not isinstance(seen, dict):
        raise host.ProgrammeError("setup-seen needs a JSON object")
    out = {part: _string_list(host, seen.get(part), part) for part in programme_view_setup.SEEN_PARTS}
    items = seen.get("items")
    if not isinstance(items, list):
        raise host.ProgrammeError("setup-seen needs an items list (empty when the sweep found nothing to adopt)")
    out["items"] = _seen_items(host, items)
    return out


def _h_setup_seen(host, argv):
    positional, opts = host._parse(argv, values=("run", "json"))
    if positional or not opts.get("json"):
        raise ValueError("usage: setup-seen --json <file>|-")
    seen = _read_seen(host, opts["json"])

    def change(programme, prompt, rec):
        _setup(programme)["seen"] = seen
        return {"seen": {part: len(values) for part, values in seen.items()}}

    return _ui_write(host, opts, change, "setup_seen_recorded")


def _h_setup_keep(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 1:
        raise ValueError("usage: setup-keep <step>")

    def change(programme, prompt, rec):
        setup = _setup(programme)
        name = _step_name(host, programme, positional[0], keep=True)
        kept = [k for k in setup.get("kept") or [] if isinstance(k, str)]
        setup["kept"] = kept + [name] if name not in kept else kept
        return {"kept": name}

    return _ui_write(host, opts, change, "setup_step_kept")


_SPECS = (
    ("pick-term", _h_pick_term,
     "<key> <value> --pick <id> [--seconds <n>] [--until <iso>] [--why <text>] [--run <id>]",
     "an accepted agreement; a key that is not a per-programme agreement term (Rulings and shared "
     "settings stay typed); a value outside the term's options; a prompt that is not a "
     "verified pick from the driving session; a pick already used; a pick whose question does not name "
     "the term alone, or whose answer does not name the value (for a list, exactly the value's options). "
     "A refusal journals approval_refused."),
    ("take-recommendations", _h_take_recommendations, "--pick <id> [--run <id>]",
     "an accepted agreement; a prompt that is not a verified pick from the driving session; a pick already "
     "used; a pick with no answer naming 'take all recommendations' without a negation. Sets every "
     "per-programme term to its pending proposal, else its current value; leaves rulings and "
     "shared settings alone."),
    ("setup-step", _h_setup_step, "<name> [--run <id>]",
     "an unknown step name (an agreement term key, rulings, shared, items or accept). Needs no prompt; "
     "allowed while the compact flag is set; never counts as a beat."),
    ("setup-seen", _h_setup_seen, "--json <file>|- [--run <id>]",
     "JSON that is not an object of tabs, repos and tracker string lists and a required items list (empty "
     "allowed) of objects with a string item id. Needs no prompt; allowed while the compact flag is set; "
     "never counts as a beat."),
    ("setup-keep", _h_setup_keep, "<step> [--run <id>]",
     "an unknown step name; accept. Keeping changes nothing, so it needs no prompt; allowed while the "
     "compact flag is set; never counts as a beat."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""Programme term proposals and notes.

``programme.py`` registers these through ``build_verbs(host)``. A proposal or a
note never changes a term's value: only an approval verb (`amend-term`,
`set-remit`) does, and that verb settles the proposal it meets.
"""

from __future__ import annotations

import functools
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_focus = load_lib_module("programme_focus")
programme_sanitize = load_lib_module("programme_sanitize")

ORIGINS = ("pm", "ui")
NOTE_CAP = 500
NOTES_MAX = 20
DESCRIPTION_CAP = 200
_TOOL_RE = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")


def origin_of(opts) -> str:
    origin = opts.get("origin") or "pm"
    if origin not in ORIGINS:
        raise ValueError(f"--origin must be one of {list(ORIGINS)}, got {origin!r}")
    return origin


def pending(term):
    proposal = term.get("proposal")
    return proposal if isinstance(proposal, dict) and proposal.get("state") == "pending" else None


def _with_tool(term, tool) -> dict:
    options = list(term.get("options") or [])
    return dict(term, options=options + [tool]) if tool and tool not in options else term


def _proposed_tool(term):
    proposal = pending(term)
    return ((proposal or {}).get("extras") or {}).get("add") if term.get("key") == "tools_of_record" else None


def offered(term) -> dict:
    return _with_tool(term, _proposed_tool(term))


def check_amend(host, term, value, opts):
    return host._check_value(offered(term), value, opts)


def _settle(term, matched) -> None:
    proposal = pending(term)
    if proposal:
        proposal.update(state="accepted" if matched else "superseded",
                        settled_at=programme_home._iso(programme_home._now()))


def settle_amend(term, value) -> None:
    proposal = pending(term)
    if not proposal:
        return
    extras = proposal.get("extras") or {}
    tool = _proposed_tool(term)
    if tool and isinstance(value, list) and tool in value and tool not in term["options"]:
        term["options"] = list(term["options"]) + [tool]
        term.setdefault("option_descriptions", {})[tool] = extras.get("description")
    # A proposed new space is accepted only by set-remit; an amend of the remit option supersedes it.
    matched = "add" not in extras or tool is not None
    matched = matched and proposal.get("value") == value and all(
        term.get(name) == extras[name] for name in ("seconds", "until") + programme_home.TERM_EXTRAS
        if name in extras)
    _settle(term, matched)


def settle_remit(term, changes) -> None:
    proposal = pending(term)
    if not proposal:
        return
    add = (proposal.get("extras") or {}).get("add")
    added = {programme_home.space_key(*programme_home.space_parts(e)) for part, how, e in changes if part == "spaces" and how == "added"}
    _settle(term, bool(add) and add in added)


def _tools_proposal(host, term, value, opts):
    tool, description = opts.get("add"), opts.get("description")
    extras = {}
    if tool is not None:
        if not _TOOL_RE.match(tool):
            raise host.ProgrammeError(f"--add needs a tool name of lower-case letters, digits, - or _, got {tool!r}")
        description = programme_sanitize.clean(description, DESCRIPTION_CAP)
        if not description:
            raise host.ProgrammeError("--add <tool> needs --description <text>")
        extras = {"add": tool, "description": description}
    elif description is not None:
        raise ValueError("--description goes with --add <tool>")
    widened = _with_tool(term, tool)
    if value is None:
        if tool is None:
            raise ValueError("usage: propose-term tools_of_record <list>|--add <tool> --description <text>")
        current = list(term.get("value") or [])
        value = ",".join(current + [tool] if tool not in current else current) or "none"
    return host._check_value(widened, value, opts), extras


def _remit_proposal(host, term, value, opts):
    if opts.get("add") is None and value is None:
        raise ValueError("usage: propose-term remit <option> | --add <server.workspace>")
    if opts.get("add") is None:
        return host._check_value(term, value, opts), {}
    if value is not None:
        raise ValueError("usage: propose-term remit <option> | --add <server.workspace>")
    try:
        space = programme_home.parse_space(opts["add"])
    except programme_home.ProgrammeHomeError as exc:
        raise host.ProgrammeError(f"--add needs a herdr space: {exc}") from None
    return term.get("value"), {"add": programme_home.space_key(*space)}


def _proposal(host, term, value, opts):
    key = term.get("key")
    if key == "tools_of_record":
        return _tools_proposal(host, term, value, opts)
    if key == "remit":
        return _remit_proposal(host, term, value, opts)
    if opts.get("add") is not None or opts.get("description") is not None:
        raise ValueError(f"--add and --description apply to remit and tools_of_record, not {key!r}")
    if value is None:
        raise ValueError(f"usage: propose-term {key} <value>")
    checked = host._check_value(term, value, opts)
    extras = {}
    if opts.get("seconds") is not None:
        extras["seconds"] = int(opts["seconds"])
    if checked == "until_time":
        extras["until"] = opts.get("until")
    extras.update(programme_focus.extras_of(host, key, opts))
    return checked, extras


def _ui_write(host, opts, change, kind):
    return host._write(opts, change, kind, compact_exempt=True, beat=False)


def _h_propose_term(host, argv):
    positional, opts = host._parse(
        argv, values=("run", "seconds", "until", "add", "description", "origin") + programme_home.TERM_EXTRAS)
    if len(positional) not in (1, 2):
        raise ValueError("usage: propose-term <key> [<value>] [--seconds N] [--until <iso>] "
                         "[--add <name> [--description <text>]]")
    key, value = positional[0], (positional[1] if len(positional) == 2 else None)
    origin = origin_of(opts)

    def change(programme, prompt, rec):
        term = host._term(programme, key)
        checked, extras = _proposal(host, term, value, opts)
        term["proposal"] = {"value": checked, "extras": extras, "at": host._now(),
                            "origin": origin, "state": "pending"}
        return {"term": key, "value": checked, "extras": extras, "origin": origin}

    return _ui_write(host, opts, change, "term_proposed")


def _h_clear_proposal(host, argv):
    positional, opts = host._parse(argv, values=("run", "origin"))
    if len(positional) != 1:
        raise ValueError("usage: clear-proposal <key>")
    key, origin = positional[0], origin_of(opts)

    def change(programme, prompt, rec):
        term = host._term(programme, key)
        if not isinstance(term.get("proposal"), dict):
            raise host.ProgrammeError(f"term {key!r} has no proposal")
        del term["proposal"]
        return {"term": key, "origin": origin}

    return _ui_write(host, opts, change, "proposal_cleared")


def _h_note_term(host, argv):
    positional, opts = host._parse(argv, values=("run", "origin"), flags=("clear",))
    clear = bool(opts.get("clear"))
    if len(positional) != (1 if clear else 2):
        raise ValueError("usage: note-term <key> <text> | note-term <key> --clear")
    key, origin = positional[0], origin_of(opts)
    text = None if clear else programme_sanitize.clean(positional[1], NOTE_CAP)
    if not clear and not text:
        raise ValueError("note-term needs some text, or --clear")

    def change(programme, prompt, rec):
        term = host._term(programme, key)
        if clear:
            term.pop("notes", None)
            return {"term": key, "cleared": True, "origin": origin}
        notes = list(term.get("notes") or [])
        if len(notes) >= NOTES_MAX:
            raise host.ProgrammeError(f"term {key!r} holds {NOTES_MAX} notes; clear them first")
        term["notes"] = notes + [{"text": text, "at": host._now(), "origin": origin}]
        return {"term": key, "note": text, "origin": origin}

    return _ui_write(host, opts, change, "term_noted")


def _h_request_reread(host, argv):
    _, opts = host._parse(argv, values=("run", "origin"))
    origin = origin_of(opts)
    return _ui_write(host, opts, lambda programme, prompt, rec: {"origin": origin}, "reread_requested")


_SPECS = (
    ("propose-term", _h_propose_term,
     "<key> [<value>] [--seconds <n>] [--until <iso>] [--add <tool|server.workspace>] "
     "[--description <text>] [--origin pm|ui] [--run <id>]",
     "a value outside the term's options; --add on a term other than remit or tools_of_record; "
     "--add <tool> without --description. Needs no prompt and never changes the value; a new "
     "proposal replaces the old one. Allowed while the compact flag is set; never counts as a beat."),
    ("clear-proposal", _h_clear_proposal, "<key> [--origin pm|ui] [--run <id>]",
     "a term with no proposal. Allowed while the compact flag is set; never counts as a beat."),
    ("request-reread", _h_request_reread, "[--origin pm|ui] [--run <id>]",
     "nothing; asks the PM to re-read the rules in force at its next sweep. Leaves the compact flag "
     "as it is. Allowed while the compact flag is set; never counts as a beat."),
    ("note-term", _h_note_term, "<key> <text> | <key> --clear [--origin pm|ui] [--run <id>]",
     f"empty text; more than {NOTES_MAX} notes on one term. Allowed while the compact flag is set; "
     "never counts as a beat."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""Project terms on the agreement and the contract stamp written at acceptance.

Project terms sit at ``agreement.project_terms``, outside the fixed ``terms`` map that
``normalize_programme`` back-fills, so a record without them keeps reading as the old contract.
``programme.py`` registers ``edit-project-term`` through ``build_verbs(host)``; its
``propose-agreement`` and ``accept-agreement`` call ``add``, ``check_accept_order`` and ``stamp``.
"""

from __future__ import annotations

import functools
import os
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_decisions = load_lib_module("programme_decisions")

CONTRACT_VERSION = 1
PROPOSED = "agreement_proposed"
EDITED = "project_term_edited"
AMENDED = "project_term_amended"
# Matched as substrings of the squashed area, so any spelling that contains a stem is refused.
PROTECTED_STEMS = {
    "prod_deploy": ("deploy", "production"),
    "full_release": ("release", "publish"),
    "spend_over_cap": ("spend", "budget", "overcap"),
    "merge_around_gate": ("aroundgate", "aroundthegate", "bypass", "skipgate", "skipthegate", "adminmerge"),
    "denied_operation": ("permission", "refused", "denied", "allowlist", "sandbox"),
    "risk_or_cost_limit": ("risk", "cost", "limit"),
    "settled_human_choice": ("settled", "reopen"),
}
# Whole words only: as a substring "prod" would also refuse "product".
PROTECTED_WORDS = {"prod": "prod_deploy"}


class TermsError(Exception):
    pass


def protected_kind(host, area):
    words = host._name_words(area)
    squashed = "".join(words)
    for kind, stems in PROTECTED_STEMS.items():
        if any(stem in squashed for stem in stems):
            return kind
    return next((PROTECTED_WORDS[w] for w in words if w in PROTECTED_WORDS), None)


def _check_area(host, area, reserved) -> None:
    kind = protected_kind(host, area)
    if kind and not reserved:
        raise TermsError(
            f"area {area!r} is a protected escalation ({kind}) and stays with Shawn: no project term "
            "may give it to the PM or a worker; mark it reserved or leave it out")


def _text(value, what) -> str:
    text = programme_sanitize.clean(value)
    if not text:
        raise ValueError(f"{what} needs a non-empty value")
    return text


def parse_specs(host, opts) -> tuple:
    specs = [(spec, False) for spec in opts.get("project-term") or []] + \
            [(spec, True) for spec in opts.get("reserved-term") or []]
    if not specs:
        return [], None
    if not programme_sanitize.clean(opts.get("source")):
        raise ValueError("a project term needs --source <evidence> naming where it came from")
    parsed = []
    for spec, reserved in specs:
        area, sep, text = spec.partition("=")
        if not sep:
            raise ValueError(f"a project term needs <area>=<text>, got {spec!r}")
        area = _text(area, "a project term area")
        if not host._squash(area):
            raise ValueError(f"a project term area needs a word to name it, got {area!r}")
        parsed.append((area, _text(text, "a project term text"), reserved))
    return parsed, programme_sanitize.clean(opts["source"])


def add(host, programme, parsed, source) -> dict:
    if not parsed:
        return {}
    agreement = programme["agreement"]
    entries = programme_home.project_terms(programme)
    taken = {host._squash(e.get("area")) for e in entries}
    added = []
    for area, text, reserved in parsed:
        _check_area(host, area, reserved)
        if host._squash(area) in taken:
            raise TermsError(f"area {area!r} already has a project term; change it with edit-project-term")
        taken.add(host._squash(area))
        entry = {"id": "t" + secrets.token_hex(3), "area": area, "value": text, "source": source,
                 "set_by": "proposal", "at": run_record_core.now_iso(), "reserved": reserved,
                 "history": []}
        entries.append(entry)
        added.append({k: entry[k] for k in ("id", "area", "value", "reserved")})
    agreement["project_terms"] = entries
    return {"project_terms": added, "source": source}


def check_accept_order(run_id, prompt_id) -> None:
    rows = programme_journal.read(run_id)
    cited = next((i for i, row in enumerate(rows)
                  if row.get("kind") == "prompt" and row.get("prompt_id") == prompt_id), None)
    last = max((i for i, row in enumerate(rows) if row.get("kind") in (PROPOSED, EDITED)), default=-1)
    if cited is None or cited < last:
        raise TermsError(
            f"prompt {prompt_id!r} is older than the last proposal or project-term edit; Shawn accepts "
            "the terms he last saw, so cite a prompt typed after it")


def stamp(programme) -> int:
    programme["agreement"][programme_decisions.STAMP_KEY] = CONTRACT_VERSION
    return CONTRACT_VERSION


def _find(programme, term_id) -> dict:
    for entry in programme_home.project_terms(programme):
        if entry.get("id") == term_id:
            return entry
    raise TermsError(f"no project term {term_id!r}")


def _amend(host, entry, text, source, prompt, reserve) -> dict:
    if prompt is None:
        raise TermsError("the agreement is accepted; edit-project-term needs --prompt <id> of a typed "
                         "prompt that names the area and the new text")
    if reserve is not None and reserve != bool(entry.get("reserved")):
        raise TermsError("the agreement is accepted; a project term's reservation is fixed")
    host.require_named(prompt, entry["area"], text)
    _check_area(host, entry["area"], entry.get("reserved"))
    previous = entry.get("value")
    entry.setdefault("history", []).append(
        {k: entry.get(k) for k in ("value", "set_by", "at", "source", "prompt_id")})
    entry.update(value=text, set_by="shawn", at=run_record_core.now_iso(),
                 prompt_id=prompt["prompt_id"], quote=prompt["quote"])
    if source:
        entry["source"] = source
    return {"previous": previous}


def _h_edit(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "source"), flags=("reserved", "unreserved"))
    if len(positional) != 2:
        raise ValueError("usage: edit-project-term <id> <text> [--prompt <id>]")
    if opts.get("reserved") and opts.get("unreserved"):
        raise ValueError("edit-project-term takes at most one of --reserved and --unreserved")
    term_id, text = positional[0], _text(positional[1], "edit-project-term <text>")
    source = programme_sanitize.clean(opts.get("source")) or None
    reserve = True if opts.get("reserved") else False if opts.get("unreserved") else None

    def change(programme, prompt, rec):
        entry = _find(programme, term_id)
        accepted = bool(programme["agreement"].get("accepted"))
        if accepted:
            extra = _amend(host, entry, text, source, prompt, reserve)
        else:
            reserved = bool(entry.get("reserved")) if reserve is None else reserve
            _check_area(host, entry["area"], reserved)
            entry.update(value=text, reserved=reserved, at=run_record_core.now_iso())
            if source:
                entry["source"] = source
            extra = {}
        return {"term_id": term_id, "area": entry["area"], "value": text, "reserved": entry["reserved"],
                "source": entry.get("source"), "accepted": accepted, **extra}

    return host._write(opts, change, lambda payload: AMENDED if payload["accepted"] else EDITED,
                       prompt_id=opts.get("prompt"))


_SPECS = (
    ("edit-project-term", _h_edit,
     "<term-id> <text> [--prompt <id>] [--source <evidence>] [--reserved|--unreserved] [--run <id>]",
     "an unknown term id; an empty text; both --reserved and --unreserved; a protected area left "
     "unreserved. After acceptance it also rejects no typed --prompt, a prompt that does not name the "
     "area and the new text, and any change of reservation."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""Project terms on the agreement and the contract stamp written at acceptance.

Project terms sit at ``agreement.project_terms``, outside the fixed ``terms`` map that
``normalize_programme`` back-fills, so a record without them keeps reading as the old contract.
Typed corrections live at ``agreement.corrections``; ``correct-term`` and ``undo-correction``
refuse while ``CORRECTIONS_ON`` is false.
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
ESCALATIONS = (
    "change the outcome or acceptance",
    "reopen a settled human decision",
    "touch a reserved area",
    "exceed a risk or cost limit",
    "need a permission that was refused",
)
CONTRACT_CAVEAT = "The PM decides unless the operating contract's escalation list applies."


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


def contract_view(programme):
    if not programme_decisions.stamped(programme):
        return None
    return {
        "version": programme["agreement"][programme_decisions.STAMP_KEY],
        "project_terms": [{k: e.get(k) for k in ("id", "area", "value", "reserved")}
                          for e in programme_home.project_terms(programme)],
        "escalations": list(ESCALATIONS),
        "protected": list(PROTECTED_STEMS),
    }


def apply_contract(rules, autonomy) -> tuple:
    rules = [dict(rule, caveat=CONTRACT_CAVEAT)
             if rule["id"] == "product-question" and rule["layer"] == "plugin" else rule
             for rule in rules]
    return rules, autonomy


def contract_lines(view) -> list:
    out = [f"operating contract v{view['version']}: when the terms are silent the PM decides and records why"]
    out += [f"{'reserved for Shawn' if t.get('reserved') else 'project term'} {t.get('id')} "
            f"{t.get('area')}: {t.get('value')}" for t in view["project_terms"]]
    out.append("bring Shawn only decisions that: " + "; ".join(view["escalations"]))
    out.append("protected escalations override every project term: " + ", ".join(view["protected"]))
    return [programme_sanitize.clean(text, cap=0) for text in out]


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


# No environment override: the PM can set environment variables from its own shell.
CORRECTIONS_ON = False
CORRECTIONS_OFF = "corrections are not on yet"
CORRECTED = "term_corrected"
UNDONE = "correction_undone"
CORRECTABLE_KINDS = ("technical_approach", "work_sequencing", "worker_coordination", "tool_choice",
                     "optimisation_depth")
OWNERS = ("pm", "worker", "shawn")
_ANCHOR_ROWS = {"item_handed": "ask", "pm_decided": "decision_id", "handed_answered": "decision_id"}


def corrections(programme) -> list:
    entries = programme.get("agreement", {}).get("corrections")
    return [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []


def active_corrections(programme) -> list:
    return [e for e in corrections(programme) if not e.get("undone")]


def owner_of(programme, kind):
    latest = [e for e in active_corrections(programme) if e.get("kind") == kind]
    return latest[-1] if latest else None


def _owner_text(owner) -> str:
    return owner or "the contract default"


def correction_lines(entries) -> list:
    return [programme_sanitize.clean(
        f"correction {e.get('id')}: {e.get('kind')} decided by {e.get('to')} (Shawn: \"{e.get('quote')}\"; "
        f"PM's reading: \"{e.get('pm_reading')}\")", cap=0) for e in entries]


def _check_switch() -> None:
    if not CORRECTIONS_ON:
        raise TermsError(CORRECTIONS_OFF)


def _row_index(rows, kind, key, value):
    return next((i for i, row in enumerate(rows) if row.get("kind") == kind
                 and (row.get(key) == value or (row.get("payload") or {}).get(key) == value)), None)


def _prompt_index(rows, prompt_id) -> int:
    index = _row_index(rows, "prompt", "prompt_id", prompt_id)
    if index is None:
        raise TermsError(f"no prompt {prompt_id!r} in this programme's journal")
    return index


def _anchor(programme, anchor_id) -> tuple:
    for entry in programme.get("decisions") or []:
        if isinstance(entry, dict) and entry.get("id") == anchor_id:
            return entry.get("kind"), None
    for key, item in programme["items"].items():
        if programme_decisions.ask_id(item) == anchor_id:
            return programme_decisions.ask_kind(item), key
    raise TermsError(f"no ask or recorded choice {anchor_id!r} in this programme")


def _check_correctable(kind) -> None:
    if kind not in CORRECTABLE_KINDS:
        raise TermsError(f"kind {kind!r} is not correctable; a correction may change only "
                         f"{', '.join(CORRECTABLE_KINDS)}")


def _check_anchor_order(rows, anchor_id, prompt_id) -> None:
    anchor = min((i for kind, key in _ANCHOR_ROWS.items()
                  for i in [_row_index(rows, kind, key, anchor_id)] if i is not None), default=None)
    if anchor is None or anchor > _prompt_index(rows, prompt_id):
        raise TermsError(f"{anchor_id!r} was not recorded before prompt {prompt_id!r}; a correction "
                         "replies only to an ask or choice Shawn had already seen")


def _check_prompt_unused(programme, prompt_id) -> None:
    for entry in corrections(programme):
        used = entry.get("prompt_id") == prompt_id or (entry.get("undone") or {}).get("prompt_id") == prompt_id
        if used:
            raise TermsError(f"prompt {prompt_id!r} already drove correction {entry.get('id')!r}; "
                             "one typed prompt makes one correction")


def _h_correct(host, argv):
    _check_switch()
    positional, opts = host._parse(argv, values=("run", "prompt", "replies-to", "to", "reading"))
    if positional or not opts.get("replies-to") or opts.get("to") not in OWNERS:
        raise ValueError("usage: correct-term --prompt <id> --replies-to <ask-or-choice-id> "
                         "--to pm|worker|shawn --reading <text>")
    reading = _text(opts.get("reading"), "--reading")
    anchor_id, to = opts["replies-to"], opts["to"]

    def change(programme, prompt, rec):
        kind, item_key = _anchor(programme, anchor_id)
        _check_correctable(kind)
        _check_anchor_order(programme_journal.read(rec["run_id"]), anchor_id, prompt["prompt_id"])
        _check_prompt_unused(programme, prompt["prompt_id"])
        current = owner_of(programme, kind)
        previous = current.get("to") if current else None
        if previous == to:
            raise TermsError(f"{kind} is already decided by {to} (correction {current.get('id')!r})")
        entry = {"id": "c" + secrets.token_hex(3), "at": run_record_core.now_iso(), "kind": kind,
                 "anchor": anchor_id, "to": to, "previous": previous, "prompt_id": prompt["prompt_id"],
                 "quote": prompt["quote"], "pm_reading": reading,
                 "choices_before": len(programme.get("decisions") or []), "undone": None}
        programme["agreement"]["corrections"] = corrections(programme) + [entry]
        reopened = None
        if item_key and to != "shawn" and programme["items"][item_key]["state"] == "handed":
            item = programme["items"][item_key]
            item.update(state="open", waiting_on=None)
            host.programme_record._history(item, "reopened", correction=entry["id"])
            reopened = item_key
        notice = (f"correction {entry['id']}: {kind} now decided by {to} (was {_owner_text(previous)}). "
                  f"Shawn said \"{prompt['quote']}\"; PM's reading: \"{reading}\"")
        return {"correction": entry["id"], "kind": kind, "anchor": anchor_id, "to": to, "previous": previous,
                "pm_reading": reading, "reopened": reopened, "notice": programme_sanitize.clean(notice, cap=0)}

    return host._write(opts, change, CORRECTED, prompt_id=opts.get("prompt"), needs_prompt=True)


def _h_undo(host, argv):
    _check_switch()
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: undo-correction <correction-id> --prompt <id>")
    correction_id = positional[0]

    def change(programme, prompt, rec):
        entries = corrections(programme)
        entry = next((e for e in entries if e.get("id") == correction_id), None)
        if entry is None:
            raise TermsError(f"no correction {correction_id!r}")
        if entry.get("undone"):
            raise TermsError(f"correction {correction_id!r} is already undone")
        newer = owner_of(programme, entry["kind"])
        if newer is not entry:
            raise TermsError(f"correction {newer.get('id')!r} changed {entry['kind']} later; undo it first")
        rows = programme_journal.read(rec["run_id"])
        if _prompt_index(rows, prompt["prompt_id"]) <= _prompt_index(rows, entry["prompt_id"]):
            raise TermsError(f"prompt {prompt['prompt_id']!r} is not later than the correction's prompt "
                             f"{entry['prompt_id']!r}")
        entry["undone"] = {"at": run_record_core.now_iso(), "prompt_id": prompt["prompt_id"],
                           "quote": prompt["quote"]}
        made = [d.get("id") for d in (programme.get("decisions") or [])[entry.get("choices_before", 0):]
                if isinstance(d, dict) and (d.get("kind") == entry["kind"] or d.get("term") == correction_id)]
        notice = (f"undid correction {correction_id}: {entry['kind']} back to {_owner_text(entry['previous'])}; "
                  f"choices made under it stand: {', '.join(made) or 'none'}")
        return {"correction": correction_id, "kind": entry["kind"], "restored": entry["previous"],
                "made_under": made, "notice": notice}

    return host._write(opts, change, UNDONE, prompt_id=opts.get("prompt"), needs_prompt=True)


_SPECS = (
    ("edit-project-term", _h_edit,
     "<term-id> <text> [--prompt <id>] [--source <evidence>] [--reserved|--unreserved] [--run <id>]",
     "an unknown term id; an empty text; both --reserved and --unreserved; a protected area left "
     "unreserved. After acceptance it also rejects no typed --prompt, a prompt that does not name the "
     "area and the new text, and any change of reservation."),
    ("correct-term", _h_correct,
     "--prompt <id> --replies-to <ask-or-choice-id> --to pm|worker|shawn --reading <text> [--run <id>]",
     "every call while corrections are not on yet; no typed prompt from the driving session; an "
     "unknown anchor; an anchor recorded after the prompt; a kind off the correctable list; a prompt "
     "that already drove a correction; a kind already decided by the new owner."),
    ("undo-correction", _h_undo,
     "<correction-id> --prompt <id> [--run <id>]",
     "every call while corrections are not on yet; no typed prompt from the driving session; an "
     "unknown or undone correction; a later correction of the same kind (named); a prompt not later "
     "than the correction's."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

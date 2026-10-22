#!/usr/bin/env python3
"""PM decisions, Shawn's answers and asks: one record shape with an id and a decision kind.

``programme.py`` registers ``log-decision`` through ``build_verbs(host)``;
``hand-item``, ``answer-handed`` and ``accept-agreement`` build their records here.
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
programme_sanitize = load_lib_module("programme_sanitize")

# Written by accept-agreement; an agreement without it keeps "every product question goes to Shawn".
STAMP_KEY = "contract_version"
PROGRAMME_TARGET = "programme"
PRODUCT_RULE = "product-question"
PRODUCT_KIND = "product_question"
PRODUCT_DECISION_KINDS = ("product_call", "product_scope")
DENIED_KIND = "denied_operation"
SHAWN_LEVELS = ("propose", "never")
DECIDED = "decided"
UNKNOWN_KIND = "unknown"
AGREEMENT_KIND = "agreement"
AUTONOMY_ACTIONS = (
    "merge_at_gate", "prod_off_flag", "file_issue", "eval_backed_prerelease",
    "worker_session_approval", "prod_deploy", "full_release", "eval_waiver",
    "spend_over_cap", "product_call", "fix_other_team_code", "merge_around_gate",
)
DECISION_KINDS = AUTONOMY_ACTIONS + (
    "technical_approach", "work_sequencing", "worker_coordination", "tool_choice",
    "optimisation_depth", "product_scope", "acceptance", "denied_operation",
)
PROTECTED_KINDS = ("prod_deploy", "full_release", "spend_over_cap", "merge_around_gate", DENIED_KIND)
# Narrowest first. Duplicates programme_protocol.AUTONOMY_WIDTH: this module stays a leaf.
LEVEL_ORDER = ("never", "propose", "act_and_tell", "act")


class DecisionError(Exception):
    pass


def check_kind(kind) -> str:
    if kind not in DECISION_KINDS:
        raise DecisionError(f"unknown decision kind {kind!r}; known: {sorted(DECISION_KINDS)}")
    return kind


def stamped(programme) -> bool:
    agreement = programme.get("agreement")
    return isinstance(agreement, dict) and bool(agreement.get(STAMP_KEY))


def handed(item) -> dict:
    handed = item.get("handed")
    return handed if isinstance(handed, dict) else {}


def ask_kind(item) -> str:
    return handed(item).get("kind") or UNKNOWN_KIND


def ask_id(item):
    return handed(item).get("id")


def new_ask(kind, question) -> dict:
    return {"id": "a" + secrets.token_hex(3), "kind": kind, "at": run_record_core.now_iso(),
            "question": question, "answered": None}


def add_decision(programme, *, kind, by, item, why, term=None, silent=False, **extra) -> dict:
    entry = {"id": "d" + secrets.token_hex(3), "at": run_record_core.now_iso(), "kind": kind,
             "by": by, "item": item, "term": term, "silent": silent,
             "why": programme_sanitize.clean(why) or None}
    entry.update(extra)
    programme.setdefault("decisions", []).append(entry)
    return entry


def shawn_decision(programme, *, kind, item, prompt, **extra) -> dict:
    return add_decision(programme, kind=kind, by="shawn", item=item, why=prompt["quote"],
                        prompt_id=prompt["prompt_id"], **extra)


def _protected(kind) -> bool:
    return kind in PROTECTED_KINDS


def _in_force(ruling, now) -> bool:
    until = ruling.get("until")
    if not until:
        return True
    end = run_record_core.parse_iso(until)
    if end is None:
        raise DecisionError(f"Ruling {ruling.get('id')!r} has an end date the gate cannot read: {until!r}")
    return now < end


def _restricting(rulings) -> list:
    return [r for r in rulings if r.get("effect") == "restrict"]


def _verdict(level, reason, conflict=False) -> dict:
    decider = "shawn" if level in SHAWN_LEVELS else "pm"
    return {"decider": decider, "level": level, "reason": reason, "conflict": conflict}


def who_decides(kind, item, *, level, rulings, now, accepted) -> dict:
    check_kind(kind)
    if _protected(kind):
        return _verdict("never", "protected")
    if kind in PRODUCT_DECISION_KINDS and not accepted:
        return _verdict("propose", "unaccepted")
    when = run_record_core.parse_iso(now)
    applying = [r for r in rulings if r.get("kind") == kind and item in (r.get("items") or ())
                and _in_force(r, when)]
    if _restricting(applying):
        return _verdict("propose", "restrict")
    grants = [r for r in applying if r.get("effect") == "grant"]
    if not grants:
        return _verdict(level, "authority")
    # A grant with no recorded baseline is compared as if it was made at act, so it never outranks Authority.
    if level is not None and any(LEVEL_ORDER.index(level) < LEVEL_ORDER.index(g.get("baseline") or "act")
                                 for g in grants):
        return _verdict(level, "conflict", conflict=True)
    return _verdict("act", "grant")


def refusal(kind, verdict) -> str:
    return (f"kind {kind!r} stays with Shawn ({verdict['reason']}); the PM does not record it as its own: "
            "use hand-item")


def _decide_product_question(record, protocol, programme, key) -> str:
    item = programme["items"][key]
    if not stamped(programme):
        raise DecisionError(
            f"item {key!r} matched the {PRODUCT_RULE} rule and this programme's agreement has no "
            "contract stamp, so product questions go to Shawn: use hand-item")
    if item["state"] not in record.WAITABLE_STATES:
        raise DecisionError(f"item {key!r} is {item['state']}; only an open or waiting product question "
                            "is decided")
    rest = [k for k in item.get("change_kinds") or [] if k != PRODUCT_KIND]
    if rest:
        record._apply_match(item, protocol, rest)
        return "open"
    item.update(state=DECIDED, waiting_on=None)
    return DECIDED


def _check_pm_may_decide(protocol, programme, kind) -> None:
    level = ((protocol.get("autonomy") or {}).get(kind) or {}).get("level")
    # A stamped contract hands product calls to the PM (KTD4); the protocol still says propose.
    if kind == "product_call" and stamped(programme):
        return
    if kind == DENIED_KIND or level in SHAWN_LEVELS:
        raise DecisionError(f"kind {kind!r} stays with Shawn ({level or 'refused permission'}); the PM "
                            "does not record it as its own: use hand-item")


def _h_log_decision(host, argv):
    positional, opts = host._parse(argv, values=("run", "kind", "term", "why", "repo"), flags=("silent",))
    if len(positional) != 1:
        raise ValueError("usage: log-decision <item|programme> --kind <kind> (--term <id> | --silent) "
                         "--why <text>")
    record = host.programme_record
    target = positional[0] if positional[0] == PROGRAMME_TARGET else record.check_item_id(positional[0])
    if bool(opts.get("term")) == bool(opts.get("silent")):
        raise ValueError("log-decision needs exactly one of --term <id> or --silent")
    why = record._text(opts.get("why"), "why")
    kind = check_kind(opts.get("kind"))
    term = None
    if opts.get("term"):
        term = programme_sanitize.token(opts["term"])
        if term is None:
            raise DecisionError(f"--term must be one term id with no spaces: {opts['term']!r}")
    protocol = record._load_protocol(host, opts.get("repo"))

    def change(programme, prompt, rec):
        key = None if target == PROGRAMME_TARGET else record._resolve(programme, target)
        state = None
        if key is not None and programme["items"][key]["state"] == "handed":
            raise DecisionError(f"item {key!r} is handed and waits on Shawn's answer; answer-handed or a "
                                "correction reopens it")
        if (key is not None and kind in PRODUCT_DECISION_KINDS
                and PRODUCT_RULE in (programme["items"][key].get("matched_rule") or [])):
            state = _decide_product_question(record, protocol, programme, key)
        _check_pm_may_decide(protocol, programme, kind)
        entry = add_decision(programme, kind=kind, by="pm", item=key or PROGRAMME_TARGET, why=why,
                             term=term, silent=term is None, outcome=DECIDED if state else None)
        if key is not None:
            record._history(programme["items"][key], "decision_recorded", decision_id=entry["id"],
                            outcome=entry["outcome"])
        return {"decision_id": entry["id"], "item": entry["item"], "decision_kind": kind, "term": term,
                "silent": entry["silent"], "outcome": entry["outcome"], "state": state, "why": why}

    return host._write(opts, change, "pm_decided")


_SPECS = (
    ("log-decision", _h_log_decision,
     "<item-id|programme> --kind <decision-kind> (--term <id> | --silent) --why <text> [--repo <path>] "
     "[--run <id>]",
     "an unknown decision kind; denied_operation, or a kind whose autonomy level is propose or never "
     "(hand the item instead; product_call is allowed on a stamped agreement); both or neither of "
     "--term and --silent; no --why; an unknown item; a handed item. A product_call or product_scope on an item that "
     "matched the product-question rule also rejects an unstamped agreement (hand the item instead) "
     "and a finished item; on a stamped agreement it closes the item as decided, or re-matches its "
     "other change kinds and leaves it open. Other kinds leave the item alone."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

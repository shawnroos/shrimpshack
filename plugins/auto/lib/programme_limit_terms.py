#!/usr/bin/env python3
"""Limits as terms of work: which are on for an item, the brief lines, and the asks for limits still off."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

checks = load_lib_module("programme_checks")


def item_limits(programme, key) -> list:
    item = checks.items(programme).get(key)
    return [name for name in checks.limit_names() if checks.effective(name, item, programme)]


def brief_lines(programme, key) -> list:
    names = item_limits(programme, key)
    if not names:
        return []
    verbs = ", ".join(load_lib_module("programme_limits").RUN_VERBS)
    return ["Limits on this work:", *(f"- `{name}`: {checks.CHECKS[name].text}" for name in names),
            "While a limit is on, Auto also refuses your writes to the programme's files, to the installed plugin "
            "and of `disableAllHooks` or `allowManagedHooksOnly` in a settings file, and any command that names "
            "`CLAUDE_CODE_SESSION_ID`. A command that names those places passes only as a plain read (`cat`, `grep`, `jq` and "
            f"the like) or as `programme.sh` with one of: {verbs}, with every argument written out (no `$` or "
            "backtick). These checks read command text to catch mistakes; do not look for a way round one. A refusal "
            "stops only that call and is journaled. Keep working on the rest; the PM sees the refusal "
            "and lifts the limit when the work needs it."]


def start_fields(programme, key, briefed) -> dict:
    names = item_limits(programme, key)
    return {} if not names else {"limits": names} if briefed else {"limits": names, "limits_not_briefed": names}


def _limit_ask(name, key) -> str:
    scope = f" --item {key}" if key else ""
    return f"programme.sh offer limit-{name} --command 'set-check {name} on{scope}'"


def limit_asks(programme, key, names) -> list:
    item = checks.items(programme).get(key) if key else None
    return [_limit_ask(name, key) for name in names if not checks.effective(name, item, programme)]


def _contract_limits(rows, key, item) -> list:
    set_rows = [r for r in rows if r.get("kind") == "contract_set" and (r.get("payload") or {}).get("item") == key
                and "limits" in r["payload"]]
    if set_rows:
        return set_rows[-1]["payload"]["limits"]
    run = item.get(checks.AUTO_RUN)
    seed = run.get("contract") if isinstance(run, dict) else None
    return seed.get("limits") or [] if isinstance(seed, dict) else []


def _still_off(programme, item, name) -> bool:
    return name in checks.CHECKS and checks.CHECKS[name].limit and not checks.effective(name, item, programme)


def named_limits(programme, rows, behaviours) -> list:
    out = [{"check": b["limit"], "via": f"behaviour {b.get('id')}", "ask": _limit_ask(b["limit"], None)}
           for b in behaviours or [] if b.get("limit") and b.get("in_force") and _still_off(programme, None, b["limit"])]
    for key, item in sorted(checks.items(programme).items()):
        if not checks.live_item(item):
            continue
        out += [{"check": name, "via": f"the contract of item {key}", "ask": _limit_ask(name, key)}
                for name in _contract_limits(rows or [], key, item) if _still_off(programme, item, name)]
    return out

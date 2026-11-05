#!/usr/bin/env python3
"""The PM's record of a hook patch, the registry of named checks, and how a hook reads a session's checks."""

from __future__ import annotations

import collections
import functools
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_record = load_lib_module("programme_record")
run_record_core = load_lib_module("run_record_core")
programme_sanitize = load_lib_module("programme_sanitize")
programme_store = load_lib_module("programme_store")

PATCHED = "hook_patched"
WHY_CAP = 300
FILE_CAP = 400
PR_CAP = 300

_PICKER = "Auto writing the picker's text from the command"
_PICK = "approvals that need a pick"
_PREFILL = "the pre-filled answer refusal"
_LINEAR = "the Linear done, cancelled and root-cause rule"

# Keyed by file name without extension, so a hook's .py and its .claude/hooks wrapper .sh count as one.
# A new file that implements one of these rules must be added here, or its patch notice stays silent.
PROTECTED = {
    "programme_approval": (_PICKER, _PICK),
    "programme_offers": (_PICKER, _PICK),
    "programme_pick_source": (_PICKER, _PICK),
    "programme_journal": (_PICK,),
    "programme_setup": (_PICK,),
    "programme_prompt_source": (_PICK,),
    "on-posttooluse-askuser": (_PICKER, _PICK),
    "on-pretooluse-askuser": (_PREFILL,),
    "on-pretooluse-action": (_LINEAR,),
    "programme_evidence": (_LINEAR,),
    "hooks": (_PICKER, _PICK, _PREFILL, _LINEAR),
}


def _protects(path) -> list:
    return list(PROTECTED.get(os.path.splitext(os.path.basename(path))[0], ()))


def _notice(path, why, pr, protects) -> str:
    held = f" It holds {', '.join(protects)}." if protects else ""
    return f"The PM patched {os.path.basename(path)}: {why}. PR: {pr}.{held}"


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "why", "pr"))
    path = programme_sanitize.clean(positional[0], FILE_CAP) if len(positional) == 1 else ""
    why = programme_sanitize.clean(opts.get("why") or "", WHY_CAP)
    pr = programme_sanitize.clean(opts.get("pr") or "", PR_CAP)
    if not (path and why and pr):
        raise ValueError("usage: record-hook-patch <file> --why <line> --pr <url or number> [--run <id>]")
    protects = _protects(path)

    def change(_programme, _prompt, _rec):
        return {"file": path, "why": why, "pr": pr, "protects": protects,
                "text": _notice(path, why, pr, protects)}

    def notify(payload):
        # A host's notify value is an exit code or a reason word, so 0 is the only delivered value.
        return {"notified": programme_record.notify_host("auto: hook code patched", payload["text"]) == 0}

    return host._write(opts, change, PATCHED, verb="record-hook-patch", target=path, after=notify)


_SPECS = (
    ("record-hook-patch", _h_record, "<file> --why <line> --pr <url or number> [--run <id>]",
     "a session that does not drive the programme; a missing file, --why or --pr. Journals hook_patched with the "
     "file, the why, the PR and the protected rules the file holds, sends Shawn the notice through the terminal "
     "host, and prints it as text for the PM to post. It needs no prompt, because it records what the PM did and "
     "approves nothing."),
)


SHAWN = "shawn"
PM = "pm"
SETTINGS_KEY = "check_settings"
UNREADABLE = "checks_unreadable"
STORE_WAIT_MS = 250
JOURNAL_LOCK_WAIT = 0.5
DETAIL_CAP = 300

Check = collections.namedtuple("Check", "text default can_turn_off on_needs own_run_on_needs limit")


def _check(text, default=True, can_turn_off=True, on_needs=PM, own_run_on_needs=None, limit=False):
    return Check(text, default, can_turn_off, on_needs, own_run_on_needs or on_needs, limit)


CHECKS = {
    "no-destructive-commands": _check("no destructive commands", default=False, on_needs=SHAWN, limit=True),
    "no-settings-writes": _check("no settings writes", default=False, on_needs=SHAWN, limit=True),
    "pm-settings-writes": _check("the PM's settings and behaviours writes"),
    "literal-send": _check("literal send into the PM's pane", on_needs=SHAWN),
    "tracker-outside-remit": _check("Linear writes outside the remit"),
    "advisor-redirect": _check("advisor redirect, programme task runs only", on_needs=SHAWN),
    "subagent-refusals": _check("sub-agent refusals"),
    "stop-block": _check("Stop block, programme runs only", on_needs=SHAWN, own_run_on_needs=PM),
    "tracker-proof": _check("Linear done, cancelled and root cause", can_turn_off=False, on_needs=None),
    "prefilled-answers": _check("pre-filled answer refusal", can_turn_off=False, on_needs=None),
}


def turning_on_needs(name, own_run=False):
    row = CHECKS[name]
    return row.own_run_on_needs if own_run else row.on_needs


def _setting(block, name):
    settings = block.get(SETTINGS_KEY) if isinstance(block, dict) else None
    entry = settings.get(name) if isinstance(settings, dict) else None
    state = entry.get("state") if isinstance(entry, dict) else None
    if state == "on":
        return True
    return False if state == "off" and CHECKS[name].can_turn_off else None


def _live_item(item) -> bool:
    return isinstance(item, dict) and item.get("state") not in programme_home.FINISHED_ITEM_STATES


def _attached(item, session_id) -> bool:
    try:
        return _live_item(item) and session_id in programme_home.session_ids(item)
    except (AttributeError, TypeError):
        return False


def _items(programme) -> dict:
    items = programme.get("items") if isinstance(programme, dict) else None
    return items if isinstance(items, dict) else {}


def _matches(run, record, lease_session, session_id) -> list:
    programme = record.get("programme")
    found = [{"run": run, "item": item_id, "role": "worker", "_blocks": (item, programme)}
             for item_id, item in sorted(_items(programme).items()) if _attached(item, session_id)]
    if (record.get("driving_session_id") or lease_session) == session_id:
        found.append({"run": run, "item": None, "role": "pm", "_blocks": (None, programme)})
    return found


def _decide(name, matches) -> tuple:
    row = CHECKS[name]
    votes = []
    for match in matches:
        if row.limit and match["item"] is None:
            continue
        item, programme = match["_blocks"]
        setting, scope = _setting(item, name), "item"
        if setting is None:
            setting, scope = _setting(programme, name), "programme"
        votes.append((row.default if setting is None else setting, setting, scope, match))
    # Across matches, on wins: a session on two items carries a limit either item has.
    state = any(vote[0] for vote in votes) if votes else row.default
    source = next(({"run": m["run"], "item": m["item"], "scope": scope}
                   for _, setting, scope, m in votes if setting is state), None)
    return state, source


def _marker(run) -> str:
    return os.path.join(programme_home.home_path(run), ".checks-unreadable.json")


def _create_new(path, text="") -> bool:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError:
        return False
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    return True


def _mark_episode(run, outcome, detail) -> None:
    payload = {"since": run_record_core.now_iso(), "outcome": outcome,
               "detail": programme_sanitize.clean(detail or "", DETAIL_CAP)}
    _create_new(_marker(run), json.dumps(payload))


def _journal_episode(run) -> None:
    # The store a hold blocks is the store the journal writes to, so a hold leaves only the marker
    # file and the first read after it writes the one row. The rename lets one of many hooks win.
    marker = _marker(run)
    claim = f"{marker}.{os.getpid()}"
    try:
        os.rename(marker, claim)
    except OSError:
        return
    try:
        try:
            with open(claim, encoding="utf-8") as fh:
                payload = json.load(fh)
        except ValueError:
            payload = {"since": None, "outcome": "unknown", "detail": ""}
        load_lib_module("programme_journal").append(run, UNREADABLE, None, payload, lock_timeout=JOURNAL_LOCK_WAIT)
    except Exception:
        os.replace(claim, marker)
    else:
        os.unlink(claim)


def _faults(programme) -> list:
    if not isinstance(programme, dict):
        return ["programme"]
    found = [] if isinstance(programme.get("items"), (dict, type(None))) else ["items"]
    blocks = [("programme", programme)] + sorted((k, v) for k, v in _items(programme).items() if _live_item(v))
    for where, block in blocks:
        settings = block.get(SETTINGS_KEY)
        if settings is None:
            continue
        if not isinstance(settings, dict):
            found.append(where)
            continue
        for name, entry in sorted(settings.items()):
            state = entry.get("state") if isinstance(entry, dict) else None
            frozen = name in CHECKS and not CHECKS[name].can_turn_off and state == "off"
            if frozen or state not in ("on", "off"):
                found.append(f"{where} {name}")
    return found


def _settle_faults(run, programme) -> None:
    seen = _marker(run) + ".bad-shape"
    faults = _faults(programme)
    if not faults:
        try:
            os.unlink(seen)
        except OSError:
            pass
    elif _create_new(seen):
        _mark_episode(run, "bad_shape", ", ".join(faults))
        _journal_episode(run)


def _held_runs(now):
    seen = set()
    for _key, lease in programme_home.iter_leases():
        run = lease.get("run") if isinstance(lease, dict) and not lease.get("corrupt") else None
        if not isinstance(run, str) or run in seen:
            continue
        try:
            status, read = programme_home.lease_state(lease, now)
        except Exception:
            # A record of the wrong shape must not hide the programmes after it in the walk.
            status, read = "unavailable", (None, None)
        if status in programme_home.HELD_LEASE_STATES and read is not None:
            seen.add(run)
            yield run, lease.get("session_id"), read[0], read[1]


def session_checks(session_id, now=None) -> dict:
    # Lowers the store wait for the rest of the process, so only a short-lived hook calls this.
    matches, unreadable = [], []
    try:
        programme_store.bound_waits(STORE_WAIT_MS)
        for run, lease_session, record, hold in _held_runs(now):
            try:
                if not isinstance(record, dict):
                    unreadable.append(run)
                    _mark_episode(run, (hold or {}).get("outcome") or "unreadable", (hold or {}).get("detail"))
                    continue
                _journal_episode(run)
                _settle_faults(run, record.get("programme"))
                if isinstance(session_id, str) and session_id:
                    matches += _matches(run, record, lease_session, session_id)
            except Exception:
                continue
    except Exception:
        pass
    states, decided_by = {}, {}
    for name in CHECKS:
        states[name], source = _decide(name, matches)
        if source is not None:
            decided_by[name] = source
    return {"states": states, "decided_by": decided_by, "unreadable": unreadable,
            "matches": [{k: m[k] for k in ("run", "item", "role")} for m in matches]}


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

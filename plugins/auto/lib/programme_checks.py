#!/usr/bin/env python3
"""The PM's record of a hook patch, the registry of named checks, how a hook reads them, and `set-check`."""

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
    "programme_checks": (_PREFILL, _LINEAR),
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


SHAWN = "shawn"
PM = "pm"
SETTINGS_KEY = "check_settings"
UNREADABLE = "checks_unreadable"
SET_KIND = "check_set"
OWN = "own"
STATES = ("on", "off")
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


def limit_names() -> list:
    return [name for name, row in CHECKS.items() if row.limit]


def item_limits(programme, key) -> list:
    match = {"run": None, "item": key, "_blocks": (_items(programme).get(key), programme)}
    return [name for name in limit_names() if _decide(name, [match])[0]]


def brief_lines(programme, key) -> list:
    names = item_limits(programme, key)
    if not names:
        return []
    return ["Limits on this work:", *(f"- `{name}`: {CHECKS[name].text}" for name in names),
            "While a limit is on, Auto also refuses your writes to the programme's files, to the installed plugin "
            "and of `disableAllHooks` or `allowManagedHooksOnly` in a settings file. Reads stay open. A refusal "
            "stops only that call and is journaled. To lift a limit, ask the PM."]


def start_fields(programme, key, briefed) -> dict:
    names = item_limits(programme, key)
    return {} if not names else {"limits": names} if briefed else {"limits": names, "limits_not_briefed": names}


def _has_own_run(name) -> bool:
    return CHECKS[name].own_run_on_needs != CHECKS[name].on_needs


def _entry(block, name):
    settings = block.get(SETTINGS_KEY) if isinstance(block, dict) else None
    entry = settings.get(name) if isinstance(settings, dict) else None
    return entry if isinstance(entry, dict) else {}


def _setting(block, name):
    state = _entry(block, name).get("state")
    if state == "on":
        return True
    return False if state == "off" and CHECKS[name].can_turn_off else None


def _own_setting(programme, name):
    own = _entry(programme, name).get(OWN) if _has_own_run(name) else None
    return {"on": True, "off": False}.get(own) if isinstance(own, str) else None


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
        if setting is None and match["item"] is None:
            setting, scope = _own_setting(programme, name), OWN
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
            only_own = state is None and name in CHECKS and _own_setting(block, name) is not None
            if frozen or (state not in STATES and not only_own):
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


def refusal(name, state, own=False, item=None):
    if name not in CHECKS:
        return f"unknown check {name!r}; the checks are {', '.join(CHECKS)}"
    if not CHECKS[name].can_turn_off:
        return (f"{name} has no off setting, so nothing can set it: it keeps Shawn's answer and Auto's proof from "
                "being forged")
    if own and not _has_own_run(name):
        names = [n for n in CHECKS if _has_own_run(n)]
        return f"--own is for the PM's own run, and only {' and '.join(names)} has a setting for it"
    if own and item:
        return "--own is the PM's own run and --item is one item's run, so give one of them"
    return None


def needs_pick(name, state, own=False) -> bool:
    return state == "on" and turning_on_needs(name, own_run=own) == SHAWN


def place(programme, ident, own=False) -> tuple:
    if own:
        return OWN, None, programme
    if not ident:
        return "programme", None, programme
    key = programme_record._resolve(programme, programme_record.check_item_id(ident))
    if not _live_item(programme["items"][key]):
        raise programme_record.RecordError(f"item {key!r} is finished, and a finished item's settings never apply")
    return "item", key, programme["items"][key]


def where_text(scope, key) -> str:
    return {OWN: "the PM's own run", "programme": "the programme"}.get(scope) or f"item {key}"


def stored_state(block, name, scope):
    return _entry(block, name).get(OWN if scope == OWN else "state")


def limit_asks(programme, key, names) -> list:
    item = (programme.get("items") or {}).get(key) if key else None
    asks = []
    for name in names:
        if _setting(item, name) or _setting(programme, name):
            continue
        scope = f" --item {key}" if key else ""
        asks.append(f"programme.sh offer limit-{name} --command 'set-check {name} on{scope}'")
    return asks


def _contract_limits(rows, key, item) -> list:
    set_rows = [r for r in rows if r.get("kind") == "contract_set" and (r.get("payload") or {}).get("item") == key
                and "limits" in r["payload"]]
    if set_rows:
        return set_rows[-1]["payload"]["limits"]
    run = item.get("auto_run")
    seed = run.get("contract") if isinstance(run, dict) else None
    return seed.get("limits") or [] if isinstance(seed, dict) else []


def _still_off(programme, item, name) -> bool:
    return name in CHECKS and CHECKS[name].limit and not (_setting(item, name) or _setting(programme, name))


def named_limits(programme, rows, behaviours) -> list:
    out = [{"check": b["limit"], "via": f"behaviour {b.get('id')}", "ask": limit_asks(programme, None, [b["limit"]])[0]}
           for b in behaviours or [] if b.get("limit") and b.get("in_force") and _still_off(programme, None, b["limit"])]
    for key, item in sorted(_items(programme).items()):
        if not _live_item(item):
            continue
        out += [{"check": name, "via": f"the contract of item {key}", "ask": limit_asks(programme, key, [name])[0]}
                for name in _contract_limits(rows or [], key, item) if _still_off(programme, item, name)]
    return out


def setting_rows(programme) -> list:
    out = []
    for name, row in CHECKS.items():
        entry = _entry(programme, name)
        base = {"check": name, "text": row.text}
        if not row.can_turn_off:
            out.append(dict(base, state="on", scope="fixed"))
        elif _setting(programme, name) is None:
            out.append(dict(base, state="on" if row.default else "off", scope="default"))
        else:
            out.append(dict(base, state=entry["state"], scope="programme", set_at=entry.get("set_at"),
                            set_by=entry.get("set_by")))
        if _own_setting(programme, name) is not None:
            out.append(dict(base, state=entry[OWN], scope=OWN, set_at=entry.get("own_set_at"),
                            set_by=entry.get("own_set_by")))
        for key, item in sorted(_items(programme).items()):
            if _live_item(item) and _setting(item, name) is not None:
                held = _entry(item, name)
                out.append(dict(base, state=held["state"], scope="item", item=key, set_at=held.get("set_at"),
                                set_by=held.get("set_by")))
    return out


def _differ(programme, name, state) -> list:
    return [key for key, item in sorted(_items(programme).items())
            if _live_item(item) and _entry(item, name).get("state") not in (None, state)]


_SET_USAGE = "usage: set-check <name> on|off [--item <id> | --own] [--prompt <id>] [--run <id>]"
_SEE_CHECKS = "`programme.sh status` lists the checks and their settings"


def _h_set_check(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "prompt"), flags=("own",))
    if len(positional) != 2 or positional[1] not in STATES:
        raise ValueError(_SET_USAGE)
    name, state = positional
    own, ident = bool(opts.get("own")), opts.get("item")
    why = refusal(name, state, own, ident)
    if why:
        raise host.ProgrammeError(why, fix=_SEE_CHECKS)
    needs = needs_pick(name, state, own)
    if opts.get("prompt") and not needs:
        raise host.ProgrammeError(f"set-check {name} {state} needs no pick, so it spends none",
                                  fix="rerun it without --prompt")

    def change(programme, prompt, _rec):
        scope, key, block = place(programme, ident, own)
        where = where_text(scope, key)
        if stored_state(block, name, scope) == state:
            raise host.ProgrammeError(f"{name} is already {state} for {where}; nothing changed", fix=_SEE_CHECKS)
        settings = block.get(SETTINGS_KEY)
        settings = block[SETTINGS_KEY] = dict(settings) if isinstance(settings, dict) else {}
        by = SHAWN if prompt else PM
        stamp = run_record_core.now_iso()
        settings[name] = dict(_entry(block, name), **({OWN: state, "own_set_at": stamp, "own_set_by": by} if own
                                                      else {"state": state, "set_at": stamp, "set_by": by}))
        payload = {"check": name, "state": state, "scope": scope, "set_by": by, "text": f"{name} {state} for {where}"}
        if key:
            payload["item"] = key
        differ = _differ(programme, name, state) if scope == "programme" else []
        return dict(payload, items_still_differ=differ) if differ else payload

    return host._write(opts, change, SET_KIND, prompt_id=opts.get("prompt"), needs_prompt=needs, verb="set-check",
                       target=name)


_SPECS = (
    ("record-hook-patch", _h_record, "<file> --why <line> --pr <url or number> [--run <id>]",
     "a session that does not drive the programme; a missing file, --why or --pr. Journals hook_patched with the "
     "file, the why, the PR and the protected rules the file holds, sends Shawn the notice through the terminal "
     "host, and prints it as text for the PM to post. It needs no prompt, because it records what the PM did and "
     "approves nothing."),
    ("set-check", _h_set_check, "<name> on|off [--item <id> | --own] [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; an unknown check; tracker-proof or prefilled-answers, which have "
     "no off setting; an unknown or finished item; a check already in that state there. Turning a check off needs no "
     "prompt, and neither does turning on one the PM may turn on alone; --prompt on such a change is refused. Turning "
     "on no-destructive-commands, no-settings-writes, literal-send, advisor-redirect or stop-block needs --prompt of "
     "Shawn's pick of `offer`: it moves authority, so the picker lists the decline first and his own words are "
     "refused. --own sets stop-block for the PM's own run alone, which the PM may turn on alone. An item setting "
     "beats the programme setting. Journals check_set; the setting is outside the agreed terms, so terms_digest "
     "stays the same."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""The PM's record of a hook patch, the registry of named checks, how a hook reads them, and `set-check`."""

from __future__ import annotations

import collections
import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
run_record_core = load_lib_module("run_record_core")
programme_sanitize = load_lib_module("programme_sanitize")
programme_store = load_lib_module("programme_store")
health = load_lib_module("programme_check_health")

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
    "programme_checks": (_PICK, _PREFILL, _LINEAR),
    "hooks": (_PICKER, _PICK, _PREFILL, _LINEAR),
}


def _record():
    return load_lib_module("programme_record")


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
        return {"notified": _record().notify_host("auto: hook code patched", payload["text"]) == 0}

    return host._write(opts, change, PATCHED, verb="record-hook-patch", target=path, after=notify)


SHAWN = "shawn"
PM = "pm"
SETTINGS_KEY = "check_settings"
SET_KIND = "check_set"
LIMIT_REFUSED = "limit_refused"
AUTO_RUN = "auto_run"
OWN = "own"
OWN_BLOCK = "pm_run"
STATES = ("on", "off")

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


def _layered(name, blocks) -> tuple:
    """(setting, scope): the first block holding a setting wins. None when none holds one."""
    for block, scope in blocks:
        if scope == OWN and not _has_own_run(name):
            continue
        setting = _setting(block, name)
        if setting is not None:
            return setting, scope
    return None, "programme"


def effective(name, item, programme) -> bool:
    setting = _layered(name, ((item, "item"), (programme, "programme")))[0]
    return CHECKS[name].default if setting is None else setting


def _own_block(programme):
    block = programme.get(OWN_BLOCK) if isinstance(programme, dict) else None
    return block if isinstance(block, dict) else None


def live_item(item) -> bool:
    return isinstance(item, dict) and item.get("state") not in programme_home.FINISHED_ITEM_STATES


def _attached(item, session_id) -> bool:
    try:
        return live_item(item) and session_id in programme_home.session_ids(item)
    except (AttributeError, TypeError):
        return False


def items(programme) -> dict:
    found = programme.get("items") if isinstance(programme, dict) else None
    return found if isinstance(found, dict) else {}


def _matches(run, record, lease_session, session_id) -> list:
    programme = record.get("programme")
    found = [{"run": run, "item": item_id, "role": "worker", "_blocks": ((item, "item"), (programme, "programme"))}
             for item_id, item in sorted(items(programme).items()) if _attached(item, session_id)]
    if (record.get("driving_session_id") or lease_session) == session_id:
        found.append({"run": run, "item": None, "role": "pm",
                      "_blocks": ((_own_block(programme), OWN), (programme, "programme"))})
    return found


def _decide(name, matches) -> tuple:
    row = CHECKS[name]
    votes = []
    for match in matches:
        if row.limit and match["item"] is None:
            continue
        setting, scope = _layered(name, match["_blocks"])
        votes.append((row.default if setting is None else setting, setting, scope, match))
    # Across matches, on wins: a session on two items carries a limit either item has.
    state = any(vote[0] for vote in votes) if votes else row.default
    source = next(({"run": m["run"], "item": m["item"], "scope": scope}
                   for _, setting, scope, m in votes if setting is state), None)
    return state, source


def _faults(programme) -> list:
    if not isinstance(programme, dict):
        return ["programme"]
    found = [where for where in ("items", OWN_BLOCK) if not isinstance(programme.get(where), (dict, type(None)))]
    blocks = [("programme", programme), (OWN_BLOCK, _own_block(programme) or {})]
    blocks += sorted((k, v) for k, v in items(programme).items() if live_item(v))
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
            if frozen or state not in STATES:
                found.append(f"{where} {name}")
    return found


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
        programme_store.bound_waits(programme_store.HOOK_WAIT_MS)
        for run, lease_session, record, hold in _held_runs(now):
            try:
                if not isinstance(record, dict):
                    unreadable.append(run)
                    health.mark_episode(run, (hold or {}).get("outcome") or "unreadable", (hold or {}).get("detail"))
                    continue
                health.journal_episode(run)
                health.settle_faults(run, _faults(record.get("programme")))
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
    by_run = {m["run"]: {name: _decide(name, [o for o in matches if o["run"] == m["run"]])[0] for name in CHECKS}
              for m in matches}
    return {"states": states, "decided_by": decided_by, "unreadable": unreadable, "by_run": by_run,
            "matches": [{k: m[k] for k in ("run", "item", "role")} for m in matches]}


# One read per session per hook process: up to five guards ask, and each would walk every lease.
hook_checks = functools.lru_cache(maxsize=8)(session_checks)


def run_state(name, run, session_id) -> bool:
    """A check for this session in this programme. A session with no place in it gets the programme's setting."""
    states = hook_checks(session_id)["by_run"].get(run)
    if states:
        return states[name]
    record, _hold = programme_home.read_programme(run)
    return effective(name, None, record.get("programme") if isinstance(record, dict) else None)


def _bound_to(item, run_id, repo_root) -> bool:
    bound = item.get(AUTO_RUN)
    if not isinstance(bound, dict) or bound.get("run_id") != run_id:
        return False
    path = bound.get("path")
    # Run ids repeat across repositories, and a standalone run must keep its default.
    return not (isinstance(path, str) and repo_root) or os.path.realpath(path) == os.path.realpath(repo_root)


def task_run_state(name, run_id, repo_root) -> bool:
    """A check for a task run. Only a run bound to a live item has a setting; a standalone run gets the default."""
    try:
        programme_store.bound_waits(programme_store.HOOK_WAIT_MS)
        for _run, _session, record, _hold in _held_runs(None):
            programme = record.get("programme") if isinstance(record, dict) else None
            for item in items(programme).values():
                if live_item(item) and _bound_to(item, run_id, repo_root):
                    return effective(name, item, programme)
    except Exception:
        pass
    return CHECKS[name].default


def limit_refusal(name, session_id, tool, what, **detail) -> tuple:
    """(deny, journal_row) for one call under a limit. Nothing pauses: the worker keeps its turn."""
    source = hook_checks(session_id)["decided_by"].get(name) or {}
    item = source.get("item")
    where, lift = (f"item {item}", f" --item {item}") if item else ("this programme", "")
    reason = (f"auto: the agreed limit `{name}` ({CHECKS[name].text}) on {where} refuses this call: it {what}. "
              f"Nothing is paused. Keep working on what does not need this; the PM sees this refusal in the "
              f"journal and lifts the limit when the work needs it (`programme.sh set-check {name} off{lift}`). "
              f"This attempt is journaled.")
    payload = {"check": name, "item": item, "scope": source.get("scope"), "tool": tool, **detail}
    deny = load_lib_module("programme_guard_text").deny(reason)
    return deny, (source.get("run"), LIMIT_REFUSED, session_id, payload)


def refusal(name, own=False, item=None):
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
        return OWN, None, _own_block(programme) or {}
    if not ident:
        return "programme", None, programme
    record = _record()
    key = record._resolve(programme, record.check_item_id(ident))
    if not live_item(programme["items"][key]):
        raise record.RecordError(f"item {key!r} is finished, and a finished item's settings never apply")
    return "item", key, programme["items"][key]


def where_text(scope, key) -> str:
    return {OWN: "the PM's own run", "programme": "the programme"}.get(scope) or f"item {key}"


def stored_state(block, name):
    return _entry(block, name).get("state")


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
        own = _own_block(programme)
        if _has_own_run(name) and _setting(own, name) is not None:
            held = _entry(own, name)
            out.append(dict(base, state=held["state"], scope=OWN, set_at=held.get("set_at"), set_by=held.get("set_by")))
        for key, item in sorted(items(programme).items()):
            if live_item(item) and _setting(item, name) is not None:
                held = _entry(item, name)
                out.append(dict(base, state=held["state"], scope="item", item=key, set_at=held.get("set_at"),
                                set_by=held.get("set_by")))
    return out


def _differ(programme, name, state) -> list:
    return [key for key, item in sorted(items(programme).items())
            if live_item(item) and _entry(item, name).get("state") not in (None, state)]


_SET_USAGE = "usage: set-check <name> on|off [--item <id> | --own] [--prompt <id>] [--run <id>]"
_SEE_CHECKS = "`programme.sh status` lists the checks and their settings"


def _h_set_check(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "prompt"), flags=("own",))
    if len(positional) != 2 or positional[1] not in STATES:
        raise ValueError(_SET_USAGE)
    name, state = positional
    own, ident = bool(opts.get("own")), opts.get("item")
    why = refusal(name, own, ident)
    if why:
        raise host.ProgrammeError(why, fix=_SEE_CHECKS)
    needs = needs_pick(name, state, own)
    if opts.get("prompt") and not needs:
        raise host.ProgrammeError(f"set-check {name} {state} needs no pick, so it spends none",
                                  fix="rerun it without --prompt")

    def change(programme, prompt, _rec):
        scope, key, block = place(programme, ident, own)
        where = where_text(scope, key)
        if stored_state(block, name) == state:
            raise host.ProgrammeError(f"{name} is already {state} for {where}; nothing changed", fix=_SEE_CHECKS)
        if scope == OWN:
            programme[OWN_BLOCK] = block
        settings = block.get(SETTINGS_KEY)
        settings = block[SETTINGS_KEY] = dict(settings) if isinstance(settings, dict) else {}
        by = SHAWN if prompt else PM
        stamp = run_record_core.now_iso()
        settings[name] = {"state": state, "set_at": stamp, "set_by": by}
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

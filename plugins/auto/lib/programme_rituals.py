#!/usr/bin/env python3
"""Rituals: named workflows the PM runs when a calendar rule or a programme moment fires.

A ritual lives in the same three layers as a behaviour. Programme-layer entries sit in the
programme block under ``rituals``; personal and repo entries sit in ``rituals.json`` beside the
personal protocol, each with an adoption block. The entry holds the rule only: each programme keeps
its own clock in ``ritual_clock``, because a stored entry is shared by every programme on the
machine. A ritual carries no authority, and one whose steps name a protected escalation is refused.
"""

from __future__ import annotations

import calendar
import datetime
import functools
import os
import re
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_protocol = load_lib_module("programme_protocol")
programme_sanitize = load_lib_module("programme_sanitize")
programme_naming = load_lib_module("programme_naming")
programme_carryover = load_lib_module("programme_carryover")
programme_behaviours = load_lib_module("programme_behaviours")
programme_layered_store = load_lib_module("programme_layered_store")

STORE_PATH_ENV = "CLAUDE_AUTO_RITUALS_STORE"
STORE_NAME = "rituals.json"
STORE_LOCK = ".rituals.lock"
STORE_FORMAT = 1
APPROVAL_KIND = "rule_adopted"

LAYERS = ("programme", "repo", "personal")
STORED_LAYERS = ("repo", "personal")
STATES = ("active", "proposed", "retired")
ACTIVE = "active"
TRIGGERS = ("calendar", "start", "takeover", "handover", "end", "resume", "quiet")
RESUME_EVENT = "ritual_event"
EVENT_ROWS = {"start": "programme_started", "takeover": "taken_over", "handover": "handed_over",
              "end": "programme_ended", "quiet": "stop_quiet", "resume": RESUME_EVENT}
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
EVERY = ("day", "week", "month")
WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

REQUIRED = ("id", "layer", "when", "steps")
OPTIONAL = ("why", "offers", "source", "state", "repo_key", "moved_to", "moved_repo_key", "history", "at")

_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
_Reject = programme_protocol._Reject


class RitualError(Exception):
    pass


def _check_schedule(schedule) -> None:
    programme_protocol._keys(schedule, ("every", "at"), ("weekday", "day"))
    if schedule["every"] not in EVERY or not isinstance(schedule["at"], str) or not _TIME_RE.match(schedule["at"]):
        raise _Reject("bad_value", "when.schedule")
    weekday, day = schedule.get("weekday"), schedule.get("day")
    if (schedule["every"] == "week") != (weekday is not None) or (schedule["every"] == "month") != (day is not None):
        raise _Reject("bad_value", "when.schedule")
    if weekday is not None and (type(weekday) is not int or not 0 <= weekday <= 6):
        raise _Reject("bad_value", "when.schedule.weekday")
    if day is not None and (type(day) is not int or not 1 <= day <= 31):
        raise _Reject("bad_value", "when.schedule.day")


def _check_when(when) -> None:
    programme_protocol._keys(when, ("text", "trigger"), ("schedule",))
    programme_protocol._text(when["text"], "when.text")
    if when["trigger"] not in TRIGGERS:
        raise _Reject("bad_value", "when.trigger")
    if (when["trigger"] == "calendar") != ("schedule" in when):
        raise _Reject("bad_value", "when.schedule")
    if "schedule" in when:
        _check_schedule(when["schedule"])


def _check_layer(entry) -> None:
    layer = entry["layer"]
    if layer not in LAYERS:
        raise _Reject("bad_value", "layer")
    if layer == "repo":
        if "repo_key" not in entry:
            raise _Reject("missing_field", "repo_key")
        programme_protocol._text(entry["repo_key"], "repo_key")
    elif "repo_key" in entry:
        raise _Reject("bad_value", "repo_key")
    if "moved_to" in entry and (layer != "programme" or entry["moved_to"] not in STORED_LAYERS):
        raise _Reject("bad_value", "moved_to")
    if entry.get("moved_to") == "repo":
        programme_protocol._text(entry.get("moved_repo_key"), "moved_repo_key")
    elif "moved_repo_key" in entry:
        raise _Reject("bad_value", "moved_repo_key")


programme_terms = load_lib_module("programme_terms")


def _hit_word(line, kind):
    words = programme_naming.name_words(line)
    tails = ["".join(words[i:]) for i in range(len(words))]
    for stem in programme_terms.PROTECTED_STEMS.get(kind, ()):
        if any(t.startswith(stem) for t in tails):
            return stem
    return next((w for w in words if programme_terms.PROTECTED_WORDS.get(w) == kind), None)


def _scan(entry):
    """``(step number from 1, kind, matched word)`` of the first step that names a protected escalation."""
    for number, line in enumerate(entry.get("steps") or (), 1):
        kind = programme_behaviours._line_kind(line)
        if kind:
            return number, kind, _hit_word(line, kind)
    return None


def protected_kind(entry):
    hit = _scan(entry)
    return hit[1] if hit else None


def _validate(entry, *, allow_adoption=True) -> None:
    programme_protocol._keys(entry, REQUIRED, OPTIONAL + (("adoption",) if allow_adoption else ()))
    if not isinstance(entry["id"], str) or not _ID_RE.match(entry["id"]):
        raise _Reject("bad_value", "id")
    _check_layer(entry)
    _check_when(entry["when"])
    steps = entry["steps"]
    if not isinstance(steps, list) or not steps or not all(isinstance(s, str) and s.strip() for s in steps):
        raise _Reject("bad_value", "steps")
    if entry.get("state", ACTIVE) not in STATES:
        raise _Reject("bad_value", "state")
    if "why" in entry:
        programme_protocol._text(entry["why"], "why")
    if "offers" in entry:
        offers = entry["offers"]
        if not isinstance(offers, list) or not offers or not all(isinstance(o, str) and o.strip() for o in offers):
            raise _Reject("bad_value", "offers")
    if "source" in entry:
        programme_protocol._keys(entry["source"], (), ("prompt_id", "quote"))
    if not isinstance(entry.get("history", []), list):
        raise _Reject("bad_value", "history")
    if "at" in entry and run_record_core.parse_iso(entry["at"]) is None:
        raise _Reject("bad_value", "at")
    hit = _scan(entry)
    if hit:
        number, kind, word = hit
        raise _Reject("protected_escalation", f'{kind}: step {number} names "{word}"; reword that step, '
                                              "or put the question in an offer so Shawn decides")


def verdict(entry, *, allow_adoption=True) -> dict:
    return programme_protocol._verdict(lambda: _validate(entry, allow_adoption=allow_adoption))


_is = programme_layered_store._is


def put_programme_entry(programme, entry) -> dict:
    _refuse(entry, verdict(entry, allow_adoption=False))
    if entry["layer"] != "programme":
        raise RitualError(f"ritual {entry['id']!r} is a {entry['layer']} entry, not a programme one")
    programme["rituals"] = [e for e in programme.get("rituals") or [] if not _is(e, entry["id"])] + [entry]
    return entry


def parse_schedule(text) -> dict:
    """``daily 09:00``, ``weekly mon 09:00`` or ``monthly 1 09:00``."""
    words = (text or "").lower().split()
    schedule = None
    try:
        if words[0] == "daily" and len(words) == 2:
            schedule = {"every": "day", "at": words[1]}
        elif words[0] == "weekly" and len(words) == 3:
            schedule = {"every": "week", "weekday": WEEKDAYS.index(words[1][:3]), "at": words[2]}
        elif words[0] == "monthly" and len(words) == 3:
            schedule = {"every": "month", "day": int(words[1]), "at": words[2]}
    except (ValueError, IndexError):
        schedule = None
    if schedule is None or not programme_protocol._verdict(lambda: _check_schedule(schedule))["ok"]:
        raise ValueError("--schedule must read 'daily HH:MM', 'weekly mon HH:MM' or 'monthly 1-31 HH:MM'")
    return schedule


def _local(when_utc) -> datetime.datetime:
    return when_utc.astimezone().replace(tzinfo=None)


def _utc(naive_local) -> datetime.datetime:
    return naive_local.astimezone(datetime.timezone.utc)


def _at(day, hhmm) -> datetime.datetime:
    hour, minute = int(hhmm[:2]), int(hhmm[3:])
    return datetime.datetime(day.year, day.month, day.day, hour, minute)


def _month_day(year, month, day):
    return datetime.date(year, month, min(day, calendar.monthrange(year, month)[1]))


def next_after(schedule, after) -> datetime.datetime:
    """UTC-aware; the schedule itself reads in the machine's local clock."""
    local = _local(after)
    today = local.date()
    if schedule["every"] == "day":
        candidates = [_at(today + datetime.timedelta(days=n), schedule["at"]) for n in (0, 1)]
    elif schedule["every"] == "week":
        shift = (schedule["weekday"] - today.weekday()) % 7
        first = today + datetime.timedelta(days=shift)
        candidates = [_at(first + datetime.timedelta(days=7 * n), schedule["at"]) for n in (0, 1)]
    else:
        candidates = []
        for n in (0, 1):
            month = today.month - 1 + n
            candidates.append(_at(_month_day(today.year + month // 12, month % 12 + 1, schedule["day"]), schedule["at"]))
    return _utc(next(c for c in candidates if c > local))


_S = programme_layered_store.LayeredStore(
    "ritual", file_name=STORE_NAME, lock_name=STORE_LOCK, path_env=STORE_PATH_ENV, error=RitualError,
    verdict=lambda entry: verdict(entry), target=lambda entry: target(entry))
REWORD_FIX = ("reword the named step so it no longer names the protected action; typing an approval does not "
              "change this. To ask Shawn about the action, put the question in --offer")


def _refuse(entry, check) -> None:
    try:
        _S.refuse(entry, check)
    except RitualError as exc:
        if check.get("reason") == "protected_escalation":
            exc.fix = REWORD_FIX
        raise


store_path = _S.path
read_store = _S.read
write_store = _S.write
load_store = _S.load
_default_lookup = programme_layered_store._default_lookup
_without, _place = programme_layered_store._without, programme_layered_store._place
adopt = programme_carryover.adopt


def target(entry) -> str:
    if entry.get("layer") == "repo":
        return f"ritual:repo:{entry.get('repo_key')}:{entry.get('id')}"
    return f"ritual:personal:{entry.get('id')}"


def _require_readable_store() -> None:
    # load_store swallows an unreadable file into notices, so a verb that must refuse on one reads it directly.
    read_store()


def store(adopted, prompt, run_id, session_id, how="ritual") -> None:
    _S.store(adopted, prompt, run_id, session_id, how)


def _programme_entries(programme, rejected) -> list:
    out = []
    for entry in programme.get("rituals") or []:
        check = verdict(entry, allow_adoption=False)
        if check["ok"] and entry["layer"] != "programme":
            check = {"ok": False, "reason": "wrong_layer", "detail": entry["layer"]}
        if check["ok"]:
            out.append(entry)
            continue
        name = entry.get("id") if isinstance(entry, dict) else None
        rejected.append({"layer": "programme", "key": None, "id": name,
                         "reason": check["reason"], "detail": check["detail"]})
    return out


def _held(loaded, entry, keys) -> bool:
    """A moved copy hides the programme one only while the store holds a verified copy for this programme."""
    if entry.get("moved_to") is None:
        return False
    if entry["moved_to"] == "personal":
        rows = loaded["personal"]
    elif entry.get("moved_repo_key") in keys:
        rows = loaded["repos"].get(entry["moved_repo_key"])
    else:
        return False
    return any(e["id"] == entry["id"] for e in rows or ())


def resolve(record, *, lookup=None, store=None) -> dict:
    """Active rituals in force for this programme; the narrower layer wins when ids collide."""
    programme = (record or {}).get("programme") or {}
    loaded = store if store is not None else load_store(lookup)
    rejected = list(loaded["rejected"])
    keys = programme_carryover.repo_keys(programme)
    narrow = [e for e in _programme_entries(programme, rejected) if not _held(loaded, e, keys)]
    repo = [e for key in keys for e in loaded["repos"].get(key) or []]
    chosen = {}
    for entry in loaded["personal"] + repo + narrow:
        chosen[entry["id"]] = entry
    in_force = [e for e in chosen.values() if e.get("state", ACTIVE) == ACTIVE]
    return {"in_force": in_force, "rejected": rejected, "notices": list(loaded["notices"])}


def in_force(record, *, lookup=None, store=None) -> list:
    return resolve(record, lookup=lookup, store=store)["in_force"]


since = programme_behaviours.since


RECORDED = "ritual_recorded"
PROPOSED = "ritual_proposed"
MOVED = "ritual_moved"
RETIRED = "ritual_retired"
KEPT = "rituals_kept"
STARTED = "ritual_started"
RAN = "ritual_ran"
FAILED = "ritual_failed"
SKIPPED = "ritual_skipped"
OFFERED = "ritual_offered"
ENDINGS = ("retired", "undone")
LAYER_WORDS = {"programme": ("programme",), "repo": ("repo",), "personal": ("personal", "global", "all projects")}
_FIELDS_DOC = ("--when <text> (--trigger start|takeover|handover|end|resume|quiet | --schedule 'daily HH:MM'|"
               "'weekly mon HH:MM'|'monthly 1-31 HH:MM') --step <line>... [--offer <line>...] [--why <text>]")


_clean = programme_behaviours._clean


def _draft(opts, rid) -> dict:
    if not opts.get("when"):
        raise ValueError("a ritual needs --when <text> describing when it runs")
    steps = [_clean(s, "--step") for s in opts.get("step") or []]
    if not steps:
        raise ValueError("a ritual needs at least one --step <line>")
    if bool(opts.get("schedule")) == bool(opts.get("trigger")):
        raise ValueError("a ritual needs exactly one of --trigger or --schedule")
    when = {"text": _clean(opts["when"], "--when")}
    if opts.get("schedule"):
        when.update(trigger="calendar", schedule=parse_schedule(opts["schedule"]))
    elif opts["trigger"] in TRIGGERS[1:]:
        when["trigger"] = opts["trigger"]
    else:
        raise ValueError("--trigger must be one of " + "|".join(TRIGGERS[1:]))
    entry = {"id": rid, "layer": "programme", "state": ACTIVE, "at": run_record_core.now_iso(), "when": when,
             "steps": steps}
    if opts.get("why"):
        entry["why"] = _clean(opts["why"], "--why")
    offers = [_clean(o, "--offer") for o in opts.get("offer") or []]
    if offers:
        entry["offers"] = offers
    return entry


_mark = programme_behaviours._mark


def _programme_entry(programme, rid):
    return next((e for e in programme.get("rituals") or [] if _is(e, rid)), None)


_stored_rows = programme_behaviours._stored_rows
_stored_entry = programme_behaviours._stored_entry


def describe_clock() -> str:
    zone = datetime.datetime.now().astimezone().tzname()
    return f"machine local time ({zone}); a schedule such as 'daily 09:00' reads in this clock"


def local_text(when_utc) -> str:
    return _local(when_utc).strftime("%Y-%m-%d %H:%M ") + datetime.datetime.now().astimezone().tzname()


def advance_clock(programme, entry, now=None, first_slot_done=False) -> None:
    """Past now, not one slot after the old time: otherwise a three-week-old miss is offered again.

    ``first_slot_done`` also steps past the next slot, for a ritual whose first run was done by hand before that slot.
    """
    schedule = entry["when"].get("schedule")
    if schedule:
        stamp = now or datetime.datetime.now(datetime.timezone.utc)
        if first_slot_done:
            stamp = next_after(schedule, stamp)
        programme.setdefault("ritual_clock", {})[entry["id"]] = {
            "next_due_at": next_after(schedule, stamp).strftime(TIME_FORMAT)}


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "from-proposal", "when", "trigger", "schedule", "why", "outcome"),
                                   flags=("ran-now",), multi=("step", "offer"))
    proposal = opts.get("from-proposal")
    given = any(opts.get(k) for k in ("when", "trigger", "schedule", "step", "offer", "why", "ran-now", "outcome"))
    if positional or (proposal and given):
        raise ValueError("usage: record-ritual --prompt <id> " + _FIELDS_DOC + ", or record-ritual "
                         "--from-proposal <id> --prompt <id>")
    rid = proposal or "r" + secrets.token_hex(3)
    if not proposal:
        _draft(opts, rid)

    def change(programme, prompt, rec):
        if proposal:
            entry = _programme_entry(programme, proposal)
            if entry is None or entry.get("state") != "proposed":
                raise RitualError(f"no proposed ritual {proposal!r}")
            host.require_named(prompt, proposal)
            entry = dict(entry, state=ACTIVE)
        else:
            entry = _draft(opts, rid)
        entry["source"] = {"prompt_id": prompt["prompt_id"], "quote": programme_journal.redact(prompt["quote"])}
        schedule = entry["when"].get("schedule")
        if opts.get("ran-now") and not schedule:
            raise RitualError("--ran-now only applies to a scheduled ritual; an event ritual has no first slot to mark done")
        entry = put_programme_entry(programme, _mark(entry, "recorded", prompt))
        advance_clock(programme, entry, first_slot_done=bool(opts.get("ran-now")))
        out = {"ritual": rid, "layer": "programme", "when": entry["when"]["text"], "trigger": entry["when"]["trigger"],
               "undo": f"retire-ritual {rid} --as undone --prompt <id>"}
        if schedule:
            due_at = programme["ritual_clock"][rid]["next_due_at"]
            out.update(first_due_at=due_at, first_due_local=local_text(run_record_core.parse_iso(due_at)),
                       clock=describe_clock(), ran_now=bool(opts.get("ran-now")))
            if opts.get("ran-now") and opts.get("outcome"):
                out["outcome"] = _clean(opts["outcome"], "--outcome")
        return out

    return host._write(opts, change, RECORDED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="record-ritual", target=rid)


def _h_propose(host, argv):
    positional, opts = host._parse(argv, values=("run", "when", "trigger", "schedule", "why"), multi=("step", "offer"))
    if positional:
        raise ValueError("usage: propose-ritual " + _FIELDS_DOC)
    rid = "r" + secrets.token_hex(3)

    def change(programme, prompt, rec):
        entry = put_programme_entry(programme, _mark(dict(_draft(opts, rid), state="proposed"), "proposed"))
        return {"ritual": rid, "state": "proposed", "when": entry["when"]["text"], "trigger": entry["when"]["trigger"]}

    return host._write(opts, change, PROPOSED)


def _check_layer_named(host, prompt, rid, to) -> None:
    options = LAYER_WORDS[to]
    host.require_named(prompt, options, *([rid] if rid else []))
    # require_named looks only at the word just before the name, so "not the repo" would pass it.
    words = host._name_words(programme_journal.named_text(prompt))
    start = min(s for option in options for s, _ in host._runs(words, host._squash(option)))
    if set(words[:start]) & set(host._NEGATIONS):
        raise RitualError(f"prompt {prompt['prompt_id']!r} negates the {to} layer; a move needs a plain yes")


def _repo_key(programme, wanted) -> str:
    keys = programme_carryover.repo_keys(programme)
    if wanted:
        if wanted not in keys:
            raise RitualError(f"--repo {wanted!r} is not a remit repo; the remit holds {', '.join(keys) or 'none'}")
        return wanted
    if len(keys) != 1:
        raise RitualError(f"the remit holds {len(keys)} repos ({', '.join(keys) or 'none'}); pass --repo <key> naming one")
    return keys[0]


def _placed(entry, to, key) -> dict:
    out = {k: v for k, v in entry.items() if k not in ("adoption", "moved_to", "moved_repo_key", "repo_key")}
    out["layer"] = to
    if to == "repo":
        out["repo_key"] = key
    return out


_pointer = programme_behaviours._pointer


def _current(programme, loaded, rid) -> tuple:
    stored = _stored_entry(loaded, rid)
    local = _programme_entry(programme, rid)
    keys = programme_carryover.repo_keys(programme)
    entry = stored if stored is not None and (local is None or _held(loaded, local, keys)) else local
    if entry is None or entry.get("state", ACTIVE) != ACTIVE:
        raise RitualError(f"no active ritual {rid!r} to move")
    return entry, local


def _move(host, programme, prompt, rec, rid, to, wanted) -> dict:
    _require_readable_store()
    loaded = load_store(host.prompt_lookup)
    entry, local = _current(programme, loaded, rid)
    key = _repo_key(programme, wanted) if to == "repo" else None
    if entry["layer"] == to and entry.get("repo_key") == key:
        raise RitualError(f"ritual {rid!r} is already on the {to} layer")
    moved = _mark(_placed(entry, to, key), "moved", prompt, **{"from": entry["layer"], "to": to})
    if to == "programme":
        return {"from": entry["layer"], "adopted": None, "unstore": entry["layer"] != "programme",
                "programme": put_programme_entry(programme, moved)}
    adopted = adopt(moved, prompt, rec)
    _refuse(adopted, verdict(adopted))
    if local is not None:
        put_programme_entry(programme, _pointer(local, to, key))
    return {"from": entry["layer"], "adopted": adopted, "unstore": False, "key": key}


def _unstore(rid) -> None:
    write_store(lambda doc: _without(doc, rid))


# The store write and its rule_adopted rows run after the programme write commits; until the
# store holds a verified copy, resolve keeps the programme copy in force.
def _after_store(seen, how) -> None:
    if seen.get("adopted"):
        store([seen["adopted"]], seen["prompt"], seen["run"], seen["sid"], how)
    if seen.get("unstore"):
        _unstore(seen["rid"])


def _h_move(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "to", "repo"))
    if len(positional) != 1 or opts.get("to") not in LAYERS or (opts.get("repo") and opts["to"] != "repo"):
        raise ValueError("usage: move-ritual <id> --to programme|repo|personal --prompt <id> "
                         "[--repo <key>] (--repo only with --to repo)")
    rid, to = positional[0], opts["to"]
    seen = {"rid": rid}

    def change(programme, prompt, rec):
        _check_layer_named(host, prompt, rid, to)
        out = _move(host, programme, prompt, rec, rid, to, opts.get("repo"))
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        adopted = out["adopted"]
        return {"ritual": rid, "from": out["from"], "to": to, "repo_key": out.get("key"),
                "target": adopted and target(adopted), "store_path": store_path()}

    return host._write(opts, change, MOVED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="move-ritual", target=rid, after=lambda _: _after_store(seen, "move"))


def _retire(host, programme, prompt, rec, rid, how) -> dict:
    local = _programme_entry(programme, rid)
    if local is None or local.get("moved_to"):
        _require_readable_store()
    stored = _stored_entry(load_store(host.prompt_lookup), rid)
    live = [e for e in (local, stored) if e is not None and e.get("state", ACTIVE) != "retired"]
    if not live:
        raise RitualError(f"no ritual {rid!r} that is not already retired")
    adopted = None
    if local is not None and local.get("state", ACTIVE) != "retired":
        put_programme_entry(programme, _mark(dict(local, state="retired"), how, prompt))
    if stored is not None and stored.get("state", ACTIVE) != "retired":
        bare = {k: v for k, v in stored.items() if k != "adoption"}
        adopted = adopt(_mark(dict(bare, state="retired"), how, prompt), prompt, rec)
    programme.get("ritual_clock", {}).pop(rid, None)
    return {"layers": [e["layer"] for e in live], "adopted": adopted}


def _h_retire(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "as"))
    if len(positional) != 1 or opts.get("as") not in ENDINGS:
        raise ValueError("usage: retire-ritual <id> --as retired|undone --prompt <id>")
    rid, how = positional[0], opts["as"]
    seen = {"rid": rid}

    def change(programme, prompt, rec):
        out = _retire(host, programme, prompt, rec, rid, how)
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        return {"ritual": rid, "as": how, "layers": out["layers"], "target": out["adopted"] and target(out["adopted"])}

    return host._write(opts, change, RETIRED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="retire-ritual", target=rid, after=lambda _: _after_store(seen, "retire"))


def _h_keep(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "to", "repo"))
    if not positional or opts.get("to") not in STORED_LAYERS or (opts.get("repo") and opts["to"] != "repo"):
        raise ValueError("usage: keep-rituals <id>... --to repo|personal --prompt <id> [--repo <key>]")
    wanted, to = list(dict.fromkeys(positional)), opts["to"]
    seen = {}

    def change(programme, prompt, rec):
        _check_layer_named(host, prompt, None, to)
        _require_readable_store()
        named = [r for r in wanted if not programme_naming.missing(programme_journal.named_text(prompt), [r])]
        if not named:
            raise RitualError(f"prompt {prompt['prompt_id']!r} names none of {', '.join(wanted)}")
        key = _repo_key(programme, opts.get("repo")) if to == "repo" else None
        adopted = []
        for rid in named:
            local = _programme_entry(programme, rid)
            if local is None or local.get("state", ACTIVE) != ACTIVE:
                raise RitualError(f"no active programme-layer ritual {rid!r} to keep")
            adopted.append(adopt(_mark(_placed(local, to, key), "kept", prompt, to=to), prompt, rec))
            _refuse(adopted[-1], verdict(adopted[-1]))
            put_programme_entry(programme, _pointer(local, to, key))
        seen.update(adopted=adopted, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        return {"kept": named, "not_named": [r for r in wanted if r not in named], "to": to, "repo_key": key,
                "targets": [target(a) for a in adopted], "store_path": store_path()}

    return host._write(opts, change, KEPT, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="keep-rituals", target=",".join(wanted),
                       after=lambda _: store(seen["adopted"], seen["prompt"], seen["run"], seen["sid"], "keep"))


def note_gap(run_id, session_id, previous_beat, record) -> bool:
    """Runs after the write that refreshed ``last_beat_at``, so a second write never sees the same gap."""
    before = run_record_core.parse_iso(previous_beat or "")
    if before is None:
        return False
    now = datetime.datetime.now(datetime.timezone.utc)
    limit = programme_home.ORPHAN_CADENCE_PERIODS * programme_home.cadence_seconds(record)
    if (now - before).total_seconds() <= limit:
        return False
    try:
        programme_journal.append(run_id, RESUME_EVENT, session_id, {"trigger": "resume", "silent_since": previous_beat})
    except programme_journal.JournalError:
        # A programme that ended between the write and this row has no PM left to run a resume ritual.
        return False
    return True


_SPECS = (
    ("record-ritual", _h_record,
     "--prompt <id> " + _FIELDS_DOC + " [--run <id>], or --from-proposal <id> --prompt <id> [--run <id>]",
     "no typed prompt from the driving session; no --when or --step; neither or both of --trigger and --schedule; "
     "a step that names a protected escalation; with --from-proposal, any field option, an id that is not a "
     "proposal, or a prompt that does not name the proposal id. Applies at once at the programme layer."),
    ("propose-ritual", _h_propose, _FIELDS_DOC + " [--run <id>]",
     "no --when or --step; neither or both of --trigger and --schedule; a protected escalation in a step. "
     "Needs no prompt: a proposal applies nothing."),
    ("move-ritual", _h_move,
     "<id> --to programme|repo|personal --prompt <id> [--repo <key>] [--run <id>]",
     "no typed prompt from the driving session; a prompt that does not name the ritual id and the layer, or "
     "holds a negation before the layer word; an unreadable rituals store; a ritual that is not active; a move "
     "to the layer it is on; --to repo with a remit of several repos and no --repo, or a --repo outside the remit."),
    ("retire-ritual", _h_retire, "<id> --as retired|undone --prompt <id> [--run <id>]",
     "no typed prompt from the driving session; an unknown or already retired ritual; an unreadable rituals "
     "store when the ritual lives there. The entry stays visible as retired and its clock is dropped."),
    ("keep-rituals", _h_keep, "<id>... --to repo|personal --prompt <id> [--repo <key>] [--run <id>]",
     "no typed prompt from the driving session; a prompt that does not name the layer or negates it, or names "
     "none of the ids; a named id that is not an active programme-layer ritual; an unreadable rituals store; "
     "--to repo with several remit repos and no --repo."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

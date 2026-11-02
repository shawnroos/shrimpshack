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
import json
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
OPTIONAL = ("why", "source", "state", "repo_key", "moved_to", "moved_repo_key", "history", "at")

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


def protected_kind(entry):
    for line in entry.get("steps") or ():
        kind = programme_behaviours._line_kind(line)
        if kind:
            return kind
    return None


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
    if "source" in entry:
        programme_protocol._keys(entry["source"], (), ("prompt_id", "quote"))
    if not isinstance(entry.get("history", []), list):
        raise _Reject("bad_value", "history")
    if "at" in entry and run_record_core.parse_iso(entry["at"]) is None:
        raise _Reject("bad_value", "at")
    kind = protected_kind(entry)
    if kind:
        raise _Reject("protected_escalation", kind)


def verdict(entry, *, allow_adoption=True) -> dict:
    return programme_protocol._verdict(lambda: _validate(entry, allow_adoption=allow_adoption))


def _refuse(entry, check) -> None:
    if not check["ok"]:
        name = entry.get("id") if isinstance(entry, dict) else None
        detail = f" ({check['detail']})" if check["detail"] else ""
        raise RitualError(f"ritual {name!r} refused: {check['reason']}{detail}")


_is = programme_behaviours._is


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


def store_path() -> str:
    override = os.environ.get(STORE_PATH_ENV)
    if override:
        return override
    return os.path.join(os.path.dirname(programme_protocol.personal_path()), STORE_NAME)


def _read(path) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {"format": STORE_FORMAT, "personal": [], "repos": {}}
    except (OSError, ValueError) as exc:
        raise RitualError(f"rituals store {path} is unreadable; not overwriting it: {exc}")
    repos = doc.get("repos", {}) if isinstance(doc, dict) else None
    if not isinstance(doc, dict) or not isinstance(doc.get("personal", []), list) \
            or not isinstance(repos, dict) or not all(isinstance(v, list) for v in repos.values()):
        raise RitualError(f"rituals store {path} is not a rituals store; not overwriting it")
    doc.setdefault("format", STORE_FORMAT)
    doc.setdefault("personal", [])
    doc.setdefault("repos", {})
    return doc


def read_store() -> dict:
    return _read(store_path())


def _require_readable_store() -> None:
    # load_store swallows an unreadable file into notices, so a verb that must refuse on one reads it directly.
    read_store()


# The doc is read inside the lock, so an update that replaces an id acts on the file as it is at
# the moment of the write.
def write_store(update) -> None:
    path = store_path()

    def body():
        doc = _read(path)
        if not isinstance(doc["format"], int) or doc["format"] > STORE_FORMAT:
            raise RitualError(f"rituals store {path} has a newer format; not overwriting it")
        update(doc)
        folder = os.path.dirname(os.path.abspath(path))
        os.makedirs(folder, exist_ok=True)

        def write(fh):
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")

        programme_home.atomic_write(path, write, ".rituals.", folder)

    os.makedirs(programme_home.programmes_dir(), exist_ok=True)
    run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), STORE_LOCK), body)


def target(entry) -> str:
    if entry.get("layer") == "repo":
        return f"ritual:repo:{entry.get('repo_key')}:{entry.get('id')}"
    return f"ritual:personal:{entry.get('id')}"


adopt = programme_carryover.adopt


_without = programme_behaviours._without
_place = programme_behaviours._place


# The loader verifies a same-machine entry only through its approval row, so every stored entry
# gets one. The rows are separate journal writes: call this after the programme write commits.
def store(adopted, prompt, run_id, session_id, how="ritual") -> None:
    for entry in adopted:
        _refuse(entry, verdict(entry))
        if entry["layer"] not in STORED_LAYERS or "adoption" not in entry:
            raise RitualError(f"ritual {entry['id']!r} is not an adopted personal or repo entry")

    def update(doc):
        for entry in adopted:
            _place(doc, entry)

    write_store(update)
    for entry in adopted:
        programme_journal.append(
            run_id, APPROVAL_KIND, session_id,
            {"entry": how, "target": target(entry), "hash": entry["adoption"]["hash"],
             "prompt_id": prompt["prompt_id"], "quote": prompt["quote"]},
            cites=[prompt["prompt_id"]])


_default_lookup = programme_behaviours._default_lookup


def _stored_reason(entry, layer, key, lookup):
    check = verdict(entry)
    if not check["ok"]:
        return check["reason"], check["detail"]
    if entry["layer"] != layer:
        return "wrong_layer", entry["layer"]
    if layer == "repo" and entry["repo_key"] != key:
        return "wrong_key", entry["repo_key"]
    try:
        programme_protocol._verify_adoption(entry, lookup, target(entry), local_only=False)
    except _Reject as exc:
        return exc.reason, exc.detail
    return None


def _admit(out, layer, key, entry, lookup) -> None:
    reason = _stored_reason(entry, layer, key, lookup)
    if reason is None:
        (out["personal"] if layer == "personal" else out["repos"].setdefault(key, [])).append(entry)
        return
    name = entry.get("id") if isinstance(entry, dict) else None
    out["rejected"].append({"layer": layer, "key": key, "id": name, "reason": reason[0], "detail": reason[1]})


def load_store(lookup=None) -> dict:
    out = {"personal": [], "repos": {}, "rejected": [], "notices": []}
    try:
        doc = read_store()
    except RitualError as exc:
        out["notices"].append(programme_sanitize.clean(str(exc), cap=0))
        return out
    lookup = lookup or _default_lookup()
    for entry in doc["personal"]:
        _admit(out, "personal", None, entry, lookup)
    for key, rows in doc["repos"].items():
        for entry in rows:
            _admit(out, "repo", key, entry, lookup)
    return out


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
               "'weekly mon HH:MM'|'monthly 1-31 HH:MM') --step <line>... [--why <text>]")


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
    return entry


_mark = programme_behaviours._mark


def _programme_entry(programme, rid):
    return next((e for e in programme.get("rituals") or [] if _is(e, rid)), None)


_stored_rows = programme_behaviours._stored_rows
_stored_entry = programme_behaviours._stored_entry


def advance_clock(programme, entry, now=None) -> None:
    """Past now, not one slot after the old time: otherwise a three-week-old miss is offered again."""
    schedule = entry["when"].get("schedule")
    if schedule:
        stamp = now or datetime.datetime.now(datetime.timezone.utc)
        programme.setdefault("ritual_clock", {})[entry["id"]] = {
            "next_due_at": next_after(schedule, stamp).strftime(TIME_FORMAT)}


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "from-proposal", "when", "trigger", "schedule", "why"),
                                   multi=("step",))
    proposal = opts.get("from-proposal")
    given = any(opts.get(k) for k in ("when", "trigger", "schedule", "step", "why"))
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
        entry = put_programme_entry(programme, _mark(entry, "recorded", prompt))
        advance_clock(programme, entry)
        return {"ritual": rid, "layer": "programme", "when": entry["when"]["text"], "trigger": entry["when"]["trigger"],
                "undo": f"retire-ritual {rid} --as undone --prompt <id>"}

    return host._write(opts, change, RECORDED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="record-ritual", target=rid)


def _h_propose(host, argv):
    positional, opts = host._parse(argv, values=("run", "when", "trigger", "schedule", "why"), multi=("step",))
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


def _find(host, programme, rec, rid):
    entry = next((e for e in in_force(dict(rec, programme=programme), lookup=host.prompt_lookup) if e["id"] == rid), None)
    if entry is None:
        raise RitualError(f"ritual {rid!r} is not in force (unknown, retired or proposed)")
    return entry


def _due(host, programme, rec) -> dict:
    # Loaded here, not at import: the due module imports this one.
    return load_lib_module("programme_rituals_due").due(dict(rec, programme=programme), rec["run_id"],
                                                         lookup=host.prompt_lookup)


def _state_of(host, programme, rec, rid) -> str | None:
    due = _due(host, programme, rec)
    for bucket in ("in_flight", "missed", "due"):
        if any(r["ritual"] == rid for r in due[bucket]):
            return bucket
    return None


def _needs_answer(host, opts, rid) -> bool:
    """A missed ritual runs, starts or is skipped only on Shawn's typed answer, so the prompt is demanded for exactly that state."""
    run_id, home, record = host._locate(opts)
    probe = programme_home.normalize_programme(record.get("programme") or {})
    return _state_of(host, probe, dict(record, run_id=run_id), rid) == "missed"


def _check_answer(host, programme, rec, rid, prompt) -> None:
    """The unlocked probe only decides whether a prompt is demanded; this decides again under the lock."""
    if prompt:
        host.require_named(prompt, rid)
    elif _state_of(host, programme, rec, rid) == "missed":
        raise RitualError(f"ritual {rid!r} is missed: it needs Shawn's typed answer naming it (--prompt <id>)")


def _h_start(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: start-ritual <id> [--prompt <id>] [--run <id>]")
    rid = positional[0]
    needs = _needs_answer(host, opts, rid)

    def change(programme, prompt, rec):
        # Resolution re-validates every entry, so a ritual stored before a protected word was added is
        # rejected there and never reaches this point: that is the run-time refusal.
        entry = _find(host, programme, rec, rid)
        _check_answer(host, programme, rec, rid, prompt)
        return {"ritual": rid, "trigger": entry["when"]["trigger"], "steps": entry["steps"]}

    return host._write(opts, change, STARTED, prompt_id=opts.get("prompt"), needs_prompt=needs,
                       verb="start-ritual", target=rid)


def _answer(host, argv, kind, verb, fields=(), typed=False):
    positional, opts = host._parse(argv, values=("run", "prompt") + fields)
    if len(positional) != 1:
        raise ValueError(f"usage: {verb} <id> {' '.join('[--' + f + ' <text>]' for f in fields)} [--prompt <id>] [--run <id>]")
    rid = positional[0]
    needs = typed or _needs_answer(host, opts, rid)

    def change(programme, prompt, rec):
        entry = _find(host, programme, rec, rid)
        _check_answer(host, programme, rec, rid, prompt)
        advance_clock(programme, entry)
        extra = {f: _clean(opts[f], "--" + f) for f in fields if opts.get(f)}
        return dict({"ritual": rid, "trigger": entry["when"]["trigger"]}, **extra)

    return host._write(opts, change, kind, prompt_id=opts.get("prompt"), needs_prompt=needs, verb=verb, target=rid)


def _h_run(host, argv):
    return _answer(host, argv, RAN, "run-ritual", ("outcome",))


def _h_skip(host, argv):
    # Skipping is Shawn's call in every state; an unprompted skip would also satisfy the handover and end gates.
    return _answer(host, argv, SKIPPED, "skip-ritual", ("why",), typed=True)


def _h_fail(host, argv):
    positional, opts = host._parse(argv, values=("run", "why"))
    why = programme_sanitize.clean(opts.get("why") or "", 300)
    if len(positional) != 1 or not why:
        raise ValueError("usage: fail-ritual <id> --why <line> [--run <id>]")
    rid = positional[0]

    def change(programme, _prompt, rec):
        entry = _find(host, programme, rec, rid)
        return {"ritual": rid, "trigger": entry["when"]["trigger"], "why": why}

    return host._write(opts, change, FAILED, verb="fail-ritual", target=rid)


def _h_offer(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if not positional:
        raise ValueError("usage: offer-rituals <id>... [--run <id>]")
    wanted = list(dict.fromkeys(positional))

    def change(programme, _prompt, rec):
        due = _due(host, programme, rec)
        waiting = {r["ritual"]: r for r in due["missed"] + due["in_flight"]}
        absent = [r for r in wanted if r not in waiting]
        if absent:
            raise RitualError(f"no missed or in-flight ritual {', '.join(absent)} to offer")
        return {"offered": [{"ritual": r, "pending_at": waiting[r]["pending_at"]} for r in wanted]}

    return host._write(opts, change, OFFERED, verb="offer-rituals", target=",".join(wanted))


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
    ("start-ritual", _h_start, "<id> [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force (a ritual whose step names a "
     "protected escalation is rejected on load, so it is never in force); a missed ritual without a typed "
     "prompt that names its id."),
    ("run-ritual", _h_run, "<id> [--outcome <text>] [--prompt <id>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; a missed ritual without a typed "
     "prompt that names its id. Moves this programme's next-due time past now."),
    ("fail-ritual", _h_fail, "<id> --why <line> [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no --why. Ends the in-flight state "
     "without answering the ritual."),
    ("skip-ritual", _h_skip, "<id> --prompt <id> [--why <text>] [--run <id>]",
     "a session that does not drive the programme; a ritual not in force; no typed prompt that names the "
     "ritual id, in any state. Moves this programme's next-due time past now."),
    ("offer-rituals", _h_offer, "<id>... [--run <id>]",
     "a session that does not drive the programme; an id that is not a missed or in-flight ritual. Records the "
     "offer once so an unanswered picker is not posted again."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

#!/usr/bin/env python3
"""Behaviours: Shawn's standing guidance on how the PM and its workers do the work.

A behaviour lives in one of three layers. Programme-layer entries sit in the programme
block under ``behaviours``. Personal and repo entries sit in ``behaviours.json`` beside
the personal protocol, a personal list plus a list per repo key; each carries an
adoption block like the personal protocol's. A behaviour carries no authority and no
done bar, and one that names a protected escalation in what it tells an agent to do is
refused.
"""

from __future__ import annotations

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
programme_terms = load_lib_module("programme_terms")

STORE_PATH_ENV = "CLAUDE_AUTO_BEHAVIOURS_STORE"
STORE_NAME = "behaviours.json"
STORE_LOCK = ".behaviours.lock"
STORE_FORMAT = 1
APPROVAL_KIND = "rule_adopted"

LAYERS = ("programme", "repo", "personal")
STORED_LAYERS = ("repo", "personal")
AUDIENCES = ("pm", "workers", "both")
STATES = ("active", "proposed", "retired")
ACTIVE = "active"
CHECK_BY = ("pm", "agent")
LIST_FIELDS = ("do", "dont", "skills", "tools", "agents", "formats", "comms")
TEXT_FIELDS = ("evidence", "stop", "why")
REQUIRED = ("id", "layer", "when", "applies_to")
OPTIONAL = LIST_FIELDS + TEXT_FIELDS + (
    "repo_key", "examples", "source", "state", "overrides", "moved_to", "moved_repo_key", "history", "at",
)
# The other fields stay unscanned: stop conditions and "don't" lines need words such as
# "cost", "limit" and "publish", which are protected stems.
PROTECTED_FIELDS = ("do", "skills", "tools", "agents")
# A behaviour carries no authority and limits are enforced in code, so "keep cost under $1"
# is ordinary guidance here, unlike in a project term.
UNPROTECTED_KINDS = ("risk_or_cost_limit", "settled_human_choice")

_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_Reject = programme_protocol._Reject


class BehaviourError(Exception):
    pass


def _lines(entry, field) -> None:
    rows = entry.get(field)
    if not isinstance(rows, list) or not all(isinstance(r, str) and r.strip() for r in rows):
        raise _Reject("bad_value", field)


def _sub(obj, required, optional, prefix) -> None:
    try:
        programme_protocol._keys(obj, required, optional)
    except _Reject as exc:
        raise _Reject(exc.reason, prefix + ("." + exc.detail if exc.detail != "not an object" else ""))


def _check_when(when) -> None:
    _sub(when, ("text",), ("checks",), "when")
    programme_protocol._text(when["text"], "when.text")
    checks = when.get("checks", [])
    if not isinstance(checks, list):
        raise _Reject("bad_value", "when.checks")
    for check in checks:
        _sub(check, ("text", "by"), (), "when.checks")
        if not isinstance(check["text"], str) or not check["text"].strip() or check["by"] not in CHECK_BY:
            raise _Reject("bad_value", "when.checks")


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


def _check_extras(entry) -> None:
    for field in TEXT_FIELDS:
        if field in entry:
            programme_protocol._text(entry[field], field)
    if "examples" in entry:
        _sub(entry["examples"], (), ("good", "bad"), "examples")
        for field, text in entry["examples"].items():
            programme_protocol._text(text, "examples." + field)
    if "source" in entry:
        _sub(entry["source"], (), ("prompt_id", "quote"), "source")
    overrides = entry.get("overrides", [])
    if not isinstance(overrides, list) or not all(isinstance(o, str) and _ID_RE.match(o) for o in overrides):
        raise _Reject("bad_value", "overrides")
    if not isinstance(entry.get("history", []), list):
        raise _Reject("bad_value", "history")
    if "at" in entry and run_record_core.parse_iso(entry["at"]) is None:
        raise _Reject("bad_value", "at")


# Unlike programme_terms.protected_kind, a stem counts only where a word starts, so
# "reproduction" does not match "production" while "deployed" still matches "deploy".
def _line_kind(line):
    words = programme_naming.name_words(line)
    tails = ["".join(words[i:]) for i in range(len(words))]
    for kind, stems in programme_terms.PROTECTED_STEMS.items():
        if kind not in UNPROTECTED_KINDS and any(t.startswith(stem) for t in tails for stem in stems):
            return kind
    return next((programme_terms.PROTECTED_WORDS[w] for w in words if w in programme_terms.PROTECTED_WORDS), None)


def protected_kind(entry):
    for field in PROTECTED_FIELDS:
        for line in entry.get(field) or ():
            kind = _line_kind(line)
            if kind:
                return kind
    return None


def _validate(entry, *, allow_adoption=True) -> None:
    programme_protocol._keys(entry, REQUIRED, OPTIONAL + (("adoption",) if allow_adoption else ()))
    if not isinstance(entry["id"], str) or not _ID_RE.match(entry["id"]):
        raise _Reject("bad_value", "id")
    _check_layer(entry)
    _check_when(entry["when"])
    if entry["applies_to"] not in AUDIENCES:
        raise _Reject("bad_value", "applies_to")
    if entry.get("state", ACTIVE) not in STATES:
        raise _Reject("bad_value", "state")
    for field in LIST_FIELDS:
        if field in entry:
            _lines(entry, field)
    if not entry.get("do") and not entry.get("dont"):
        raise _Reject("missing_field", "do or dont")
    _check_extras(entry)
    kind = protected_kind(entry)
    if kind:
        raise _Reject("protected_escalation", kind)


def verdict(entry, *, allow_adoption=True) -> dict:
    return programme_protocol._verdict(lambda: _validate(entry, allow_adoption=allow_adoption))


def _refuse(entry, check) -> None:
    if not check["ok"]:
        name = entry.get("id") if isinstance(entry, dict) else None
        detail = f" ({check['detail']})" if check["detail"] else ""
        raise BehaviourError(f"behaviour {name!r} refused: {check['reason']}{detail}")


def put_programme_entry(programme, entry) -> dict:
    check = verdict(entry, allow_adoption=False)
    _refuse(entry, check)
    if entry["layer"] != "programme":
        raise BehaviourError(f"behaviour {entry['id']!r} is a {entry['layer']} entry, not a programme one")
    rows = [e for e in programme.get("behaviours") or [] if not (isinstance(e, dict) and e.get("id") == entry["id"])]
    programme["behaviours"] = rows + [entry]
    return entry


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
        raise BehaviourError(f"behaviours store {path} is unreadable; not overwriting it: {exc}")
    repos = doc.get("repos", {}) if isinstance(doc, dict) else None
    if not isinstance(doc, dict) or not isinstance(doc.get("personal", []), list) \
            or not isinstance(repos, dict) or not all(isinstance(v, list) for v in repos.values()):
        raise BehaviourError(f"behaviours store {path} is not a behaviours store; not overwriting it")
    doc.setdefault("format", STORE_FORMAT)
    doc.setdefault("personal", [])
    doc.setdefault("repos", {})
    return doc


def read_store() -> dict:
    return _read(store_path())


# The doc is read inside the lock, so what an update decides (the id it replaces, the
# layer it clears) always acts on the file as it is at the moment of the write.
def write_store(update) -> None:
    path = store_path()

    def body():
        doc = _read(path)
        if not isinstance(doc["format"], int) or doc["format"] > STORE_FORMAT:
            raise BehaviourError(f"behaviours store {path} has a newer format; not overwriting it")
        update(doc)
        folder = os.path.dirname(os.path.abspath(path))
        os.makedirs(folder, exist_ok=True)

        def write(fh):
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")

        programme_home.atomic_write(path, write, ".behaviours.", folder)

    os.makedirs(programme_home.programmes_dir(), exist_ok=True)
    run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), STORE_LOCK), body)


def target(entry) -> str:
    if entry.get("layer") == "repo":
        return f"behaviour:repo:{entry.get('repo_key')}:{entry.get('id')}"
    return f"behaviour:personal:{entry.get('id')}"


def adopt(entry, prompt, rec) -> dict:
    adoption = {"machine": programme_protocol.machine_name(), "run_id": rec["run_id"],
                "prompt_id": prompt["prompt_id"], "quote": programme_journal.redact(prompt["quote"]),
                "prompt_hash": prompt["text_hash"], "hash": programme_protocol.content_hash(entry)}
    return dict(entry, adoption=adoption)


def _place(doc, entry) -> None:
    def other(e):
        return not (isinstance(e, dict) and e.get("id") == entry["id"])

    doc["personal"] = [e for e in doc["personal"] if other(e)]
    doc["repos"] = {k: [e for e in rows if other(e)] for k, rows in doc["repos"].items()}
    doc["repos"] = {k: rows for k, rows in doc["repos"].items() if rows}
    if entry["layer"] == "personal":
        doc["personal"].append(entry)
    else:
        doc["repos"].setdefault(entry["repo_key"], []).append(entry)


# The loader verifies a same-machine entry only through its approval row, so every stored
# entry gets one. The rows are separate journal writes: call this after the programme
# write commits, never inside it.
def store(adopted, prompt, run_id, session_id, how="behaviour") -> None:
    for entry in adopted:
        _refuse(entry, verdict(entry))
        if entry["layer"] not in STORED_LAYERS or "adoption" not in entry:
            raise BehaviourError(f"behaviour {entry['id']!r} is not an adopted personal or repo entry")

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


def _default_lookup():
    # Loaded here, not at import: programme.py imports this module. A caller inside
    # programme.py passes host.prompt_lookup, since its module is __main__ there.
    programme = load_lib_module("programme")
    journals = {}
    return lambda run_id, prompt_id: programme.prompt_lookup(run_id, prompt_id, journals)


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
    except BehaviourError as exc:
        out["notices"].append(programme_sanitize.clean(str(exc), cap=0))
        return out
    lookup = lookup or _default_lookup()
    for entry in doc["personal"]:
        _admit(out, "personal", None, entry, lookup)
    for key, rows in doc["repos"].items():
        for entry in rows:
            _admit(out, "repo", key, entry, lookup)
    return out


def repo_key_for(programme, repo):
    if isinstance(repo, dict):
        return programme_carryover.key_of(repo)
    if not isinstance(repo, str) or not repo:
        return None
    real = os.path.realpath(repo)
    for entry in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(entry, dict) and isinstance(entry.get("path"), str) \
                and os.path.realpath(entry["path"]) == real:
            return programme_carryover.key_of(entry)
    return os.path.normpath(repo)


def _programme_entries(programme, rejected) -> list:
    out = []
    for entry in programme.get("behaviours") or []:
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


def _reaches(entry, audience) -> bool:
    return audience is None or entry["applies_to"] in (audience, "both")


def _held(loaded, entry) -> bool:
    if entry.get("moved_to") is None:
        return False
    rows = loaded["personal"] if entry["moved_to"] == "personal" else loaded["repos"].get(entry["moved_repo_key"])
    return any(e["id"] == entry["id"] for e in rows or ())


def resolve(record, item, repo=None, *, audience=None, lookup=None, store=None) -> dict:
    programme = (record or {}).get("programme") or {}
    loaded = store if store is not None else load_store(lookup)
    rejected = list(loaded["rejected"])
    key = repo_key_for(programme, repo if repo is not None else (item or {}).get("repo"))
    candidates = [e for e in _programme_entries(programme, rejected) if not _held(loaded, e)]
    candidates += (loaded["repos"].get(key) or []) if key else []
    candidates += loaded["personal"]
    candidates = [e for e in candidates if e.get("state", ACTIVE) == ACTIVE]
    overridden = {name for e in candidates for name in e.get("overrides") or ()}
    in_force = [e for e in candidates if e["id"] not in overridden and _reaches(e, audience)]
    return {"in_force": in_force, "rejected": rejected, "notices": list(loaded["notices"])}


def in_force(record, item, repo=None, *, audience=None, lookup=None, store=None) -> list:
    return resolve(record, item, repo, audience=audience, lookup=lookup, store=store)["in_force"]


RECORDED = "behaviour_recorded"
PROPOSED = "behaviour_proposed"
MOVED = "behaviour_moved"
RETIRED = "behaviour_retired"
ENDINGS = ("retired", "undone")
LAYER_WORDS = {"programme": ("programme",), "repo": ("repo",), "personal": ("personal", "global", "all projects")}
_LIST_OPTS = (("do", "do"), ("dont", "dont"), ("skill", "skills"), ("tool", "tools"), ("agent", "agents"),
              ("format", "formats"), ("comm", "comms"))
_FIELD_VALUES = ("when", "applies-to", "evidence", "stop", "why", "good", "bad")
_FIELD_MULTI = ("pm-check", "agent-check") + tuple(opt for opt, _ in _LIST_OPTS)
_COMMON = ("stop", "the", "and", "for", "when", "with", "that", "this", "its", "from", "into", "are", "was",
           "not", "all", "any", "each", "work", "item")
_FIELDS_DOC = ("--when <text> [--pm-check <text>]... [--agent-check <text>]... [--applies-to pm|workers|both] "
               "[--do <line>]... [--dont <line>]... [--skill <name>]... [--tool <name>]... [--agent <name>]... "
               "[--format <line>]... [--comm <line>]... [--evidence <text>] [--stop <text>] [--good <text>] "
               "[--bad <text>] [--why <text>]")


def _clean(value, what) -> str:
    text = programme_sanitize.clean(value)
    if not text:
        raise ValueError(f"{what} needs a non-empty value")
    return text


def _has_fields(opts) -> bool:
    return any(opts.get(name) for name in _FIELD_VALUES + _FIELD_MULTI)


def _draft(opts, bid, *, when=None, tools=(), do=()) -> dict:
    when_text = opts.get("when") or when
    if not when_text:
        raise ValueError("a behaviour needs --when <text> describing the situation")
    checks = [{"text": _clean(t, "--" + by + "-check"), "by": by}
              for by in CHECK_BY for t in opts.get(by + "-check") or []]
    entry = {"id": bid, "layer": "programme", "applies_to": opts.get("applies-to") or "both", "state": ACTIVE,
             "at": run_record_core.now_iso(), "when": {"text": _clean(when_text, "--when"), "checks": checks}}
    for opt, field in _LIST_OPTS:
        rows = [_clean(v, "--" + opt) for v in opts.get(opt) or []]
        if rows:
            entry[field] = rows
    if tools and "tools" not in entry:
        entry["tools"] = list(tools)
    if do and not entry.get("do") and not entry.get("dont"):
        entry["do"] = list(do)
    for field in TEXT_FIELDS:
        if opts.get(field):
            entry[field] = _clean(opts[field], "--" + field)
    examples = {k: _clean(opts[k], "--" + k) for k in ("good", "bad") if opts.get(k)}
    if examples:
        entry["examples"] = examples
    return entry


def _mark(entry, event, prompt=None, **extra) -> dict:
    row = {"event": event, "at": run_record_core.now_iso(), **extra}
    if prompt:
        row["prompt_id"] = prompt["prompt_id"]
    return dict(entry, history=list(entry.get("history") or []) + [row])


def _programme_entry(programme, bid):
    return next((e for e in programme.get("behaviours") or [] if isinstance(e, dict) and e.get("id") == bid), None)


def _stored_entry(loaded, bid):
    rows = loaded["personal"] + [e for es in loaded["repos"].values() for e in es]
    return next((e for e in rows if e["id"] == bid), None)


def _active(programme, loaded) -> list:
    rows = [e for e in _programme_entries(programme, []) if not _held(loaded, e)]
    rows += loaded["personal"] + [e for es in loaded["repos"].values() for e in es]
    return [e for e in rows if e.get("state", ACTIVE) == ACTIVE]


def _topic(entry) -> set:
    text = " ".join([entry["when"]["text"]] + list(entry.get("tools") or []) + list(entry.get("skills") or []))
    return {w for w in programme_naming.name_words(text) if len(w) >= 3 and w not in _COMMON}


# Code cannot tell that two behaviours disagree; this only points the PM at the ones worth
# reading, so it can name a conflict to Shawn and re-record with --conflicts-with.
def _related(entry, others) -> list:
    out = []
    for other in others:
        shared = sorted(_topic(entry) & _topic(other))
        if other["id"] != entry["id"] and shared:
            out.append({"id": other["id"], "layer": other["layer"], "shared": shared})
    return out


def _overrides(entry, conflicts, known) -> list:
    for other in conflicts:
        if other == entry["id"] or other not in known:
            raise BehaviourError(f"no behaviour {other!r} in force to override")
    return sorted(set(entry.get("overrides") or []) | set(conflicts))


def _from_proposal(host, programme, prompt, proposal) -> dict:
    entry = _programme_entry(programme, proposal)
    if entry is None or entry.get("state") != "proposed":
        raise BehaviourError(f"no proposed behaviour {proposal!r}")
    host.require_named(prompt, proposal)
    return dict(entry, state=ACTIVE)


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "from-proposal") + _FIELD_VALUES,
                                   multi=_FIELD_MULTI + ("conflicts-with",))
    proposal = opts.get("from-proposal")
    if positional or (proposal and _has_fields(opts)):
        raise ValueError("usage: record-behaviour --prompt <id> " + _FIELDS_DOC + " [--conflicts-with <id>]..., "
                         "or record-behaviour --from-proposal <id> --prompt <id> [--conflicts-with <id>]...")
    bid = proposal or "b" + secrets.token_hex(3)
    if not proposal:
        _draft(opts, bid)

    def change(programme, prompt, rec):
        entry = _from_proposal(host, programme, prompt, proposal) if proposal else _draft(opts, bid)
        loaded = load_store(host.prompt_lookup)
        others = _active(programme, loaded)
        entry["overrides"] = _overrides(entry, opts["conflicts-with"], {e["id"] for e in others})
        entry["source"] = {"prompt_id": prompt["prompt_id"], "quote": programme_journal.redact(prompt["quote"])}
        entry = put_programme_entry(programme, _mark(entry, "recorded", prompt))
        return {"behaviour": bid, "layer": "programme", "when": entry["when"]["text"],
                "checks": entry["when"]["checks"], "overrides": entry["overrides"], "from_proposal": proposal,
                "related": _related(entry, others), "undo": f"retire-behaviour {bid} --as undone --prompt <id>"}

    return host._write(opts, change, RECORDED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="record-behaviour", target=bid)


def _term(programme, term_id) -> dict:
    for entry in programme_home.project_terms(programme):
        if entry.get("id") == term_id:
            return entry
    raise BehaviourError(f"no project term {term_id!r}")


def _h_propose(host, argv):
    positional, opts = host._parse(argv, values=("run", "from-term") + _FIELD_VALUES, multi=_FIELD_MULTI)
    if positional:
        raise ValueError("usage: propose-behaviour " + _FIELDS_DOC + ", or propose-behaviour --from-term <term-id>")
    bid = "b" + secrets.token_hex(3)

    def change(programme, prompt, rec):
        term = _term(programme, opts["from-term"]) if opts.get("from-term") else None
        if term:
            area, value = term.get("area"), term.get("value")
            entry = _draft(opts, bid, when=f"choosing a tool for {area}", tools=[value],
                           do=[f"use {value} for {area}"])
        else:
            entry = _draft(opts, bid)
        entry = dict(entry, state="proposed")
        entry = put_programme_entry(programme, _mark(entry, "proposed", **({"from_term": term["id"]} if term else {})))
        return {"behaviour": bid, "state": "proposed", "when": entry["when"]["text"],
                "checks": entry["when"]["checks"], "from_term": term and term["id"]}

    return host._write(opts, change, PROPOSED)


def _check_layer_named(host, prompt, bid, to) -> None:
    options = LAYER_WORDS[to]
    host.require_named(prompt, options, bid)
    # require_named looks only at the word just before the name, so "not the repo" would
    # pass it; any negation earlier in the prompt refuses, as for promote-correction.
    words = host._name_words(programme_journal.redact(prompt["quote"]))
    start = min(s for option in options for s, _ in host._runs(words, host._squash(option)))
    if set(words[:start]) & set(host._NEGATIONS):
        raise BehaviourError(f"prompt {prompt['prompt_id']!r} negates the {to} layer; a move needs a plain yes")


def _repo_key(programme, wanted) -> str:
    keys = programme_carryover.repo_keys(programme)
    if wanted:
        if wanted not in keys:
            raise BehaviourError(f"--repo {wanted!r} is not a remit repo; the remit holds {', '.join(keys) or 'none'}")
        return wanted
    if len(keys) != 1:
        raise BehaviourError(f"the remit holds {len(keys)} repos ({', '.join(keys) or 'none'}); "
                             "pass --repo <key> naming one")
    return keys[0]


def _current(programme, loaded, bid) -> tuple:
    stored = _stored_entry(loaded, bid)
    local = _programme_entry(programme, bid)
    entry = stored if stored is not None and (local is None or _held(loaded, local)) else local
    if entry is None or entry.get("state", ACTIVE) != ACTIVE:
        raise BehaviourError(f"no active behaviour {bid!r} to move")
    return entry, local


def _placed(entry, to, key) -> dict:
    out = {k: v for k, v in entry.items() if k not in ("adoption", "moved_to", "moved_repo_key", "repo_key")}
    out["layer"] = to
    if to == "repo":
        out["repo_key"] = key
    return out


def _pointer(local, to, key) -> dict:
    out = {k: v for k, v in local.items() if k not in ("moved_to", "moved_repo_key")}
    if to != "programme":
        out["moved_to"] = to
    if to == "repo":
        out["moved_repo_key"] = key
    return out


def _move(host, programme, prompt, rec, bid, to, wanted) -> dict:
    read_store()
    loaded = load_store(host.prompt_lookup)
    entry, local = _current(programme, loaded, bid)
    key = _repo_key(programme, wanted) if to == "repo" else None
    if entry["layer"] == to and entry.get("repo_key") == key:
        raise BehaviourError(f"behaviour {bid!r} is already on the {to} layer")
    moved = _mark(_placed(entry, to, key), "moved", prompt, **{"from": entry["layer"], "to": to})
    if to == "programme":
        return {"from": entry["layer"], "programme": put_programme_entry(programme, moved), "adopted": None,
                "unstore": entry["layer"] != "programme"}
    adopted = adopt(moved, prompt, rec)
    _refuse(adopted, verdict(adopted))
    if local is not None:
        put_programme_entry(programme, _pointer(local, to, key))
    return {"from": entry["layer"], "adopted": adopted, "unstore": False, "key": key}


def _unstore(bid) -> None:
    def update(doc):
        doc["personal"] = [e for e in doc["personal"] if not (isinstance(e, dict) and e.get("id") == bid)]
        doc["repos"] = {k: [e for e in rows if not (isinstance(e, dict) and e.get("id") == bid)]
                        for k, rows in doc["repos"].items()}
        doc["repos"] = {k: rows for k, rows in doc["repos"].items() if rows}

    write_store(update)


# The store write and its rule_adopted rows run after the programme write commits; until
# the store holds a verified copy, resolve keeps the programme copy in force (KTD12).
def _after_store(seen, how) -> None:
    if seen.get("adopted"):
        store([seen["adopted"]], seen["prompt"], seen["run"], seen["sid"], how)
    if seen.get("unstore"):
        _unstore(seen["bid"])


def _h_move(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "to", "repo"))
    if len(positional) != 1 or opts.get("to") not in LAYERS or (opts.get("repo") and opts["to"] != "repo"):
        raise ValueError("usage: move-behaviour <id> --to programme|repo|personal --prompt <id> "
                         "[--repo <key>] (--repo only with --to repo)")
    bid, to = positional[0], opts["to"]
    seen = {"bid": bid}

    def change(programme, prompt, rec):
        _check_layer_named(host, prompt, bid, to)
        out = _move(host, programme, prompt, rec, bid, to, opts.get("repo"))
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        adopted = out["adopted"]
        return {"behaviour": bid, "from": out["from"], "to": to, "repo_key": out.get("key"),
                "target": adopted and target(adopted), "hash": adopted and adopted["adoption"]["hash"],
                "store_path": store_path()}

    return host._write(opts, change, MOVED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="move-behaviour", target=bid, after=lambda _: _after_store(seen, "move"))


def _retire(host, programme, prompt, rec, bid, how) -> dict:
    local = _programme_entry(programme, bid)
    if local is None or local.get("moved_to"):
        read_store()
    stored = _stored_entry(load_store(host.prompt_lookup), bid)
    live = [e for e in (local, stored) if e is not None and e.get("state", ACTIVE) != "retired"]
    if not live:
        raise BehaviourError(f"no behaviour {bid!r} that is not already retired")
    adopted = None
    if local is not None and local.get("state", ACTIVE) != "retired":
        put_programme_entry(programme, _mark(dict(local, state="retired"), how, prompt))
    if stored is not None and stored.get("state", ACTIVE) != "retired":
        bare = {k: v for k, v in stored.items() if k != "adoption"}
        adopted = adopt(_mark(dict(bare, state="retired"), how, prompt), prompt, rec)
    return {"layers": [e["layer"] for e in live], "adopted": adopted}


def _h_retire(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "as"))
    if len(positional) != 1 or opts.get("as") not in ENDINGS:
        raise ValueError("usage: retire-behaviour <id> --as retired|undone --prompt <id>")
    bid, how = positional[0], opts["as"]
    seen = {"bid": bid}

    def change(programme, prompt, rec):
        out = _retire(host, programme, prompt, rec, bid, how)
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        return {"behaviour": bid, "as": how, "layers": out["layers"],
                "target": out["adopted"] and target(out["adopted"])}

    return host._write(opts, change, RETIRED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="retire-behaviour", target=bid, after=lambda _: _after_store(seen, "retire"))


_SPECS = (
    ("record-behaviour", _h_record,
     "--prompt <id> " + _FIELDS_DOC + " [--conflicts-with <id>]... [--run <id>], or --from-proposal <id> "
     "--prompt <id> [--conflicts-with <id>]... [--run <id>]",
     "no typed prompt from the driving session; no --when, or neither --do nor --dont; a bad --applies-to; a "
     "do line, skill, tool or agent that names a protected escalation; a --conflicts-with id that is not a "
     "behaviour in force; with --from-proposal, any field option, an id that is not a proposal, or a prompt "
     "that does not name the proposal id. Applies at once at the programme layer."),
    ("propose-behaviour", _h_propose,
     _FIELDS_DOC + " [--run <id>], or --from-term <term-id> [--run <id>]",
     "no --when (unless --from-term), or neither --do nor --dont; an unknown project term; a protected "
     "escalation in a do line, skill, tool or agent. Needs no prompt: a proposal applies nothing."),
    ("move-behaviour", _h_move,
     "<id> --to programme|repo|personal --prompt <id> [--repo <key>] [--run <id>]",
     "no typed prompt from the driving session; a prompt that does not name the behaviour id and the layer "
     "(programme, repo, or personal, global or all projects), or holds a negation anywhere before the layer "
     "word; an unreadable behaviours store; a behaviour that is not active; a move to the layer it is on; "
     "--to repo with a remit of several repos and no --repo, or a --repo outside the remit."),
    ("retire-behaviour", _h_retire,
     "<id> --as retired|undone --prompt <id> [--run <id>]",
     "no typed prompt from the driving session; an unknown or already retired behaviour; an unreadable "
     "behaviours store when the behaviour lives there. The entry stays visible as retired."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

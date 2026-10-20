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

import json
import os
import re
import sys
import types

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
    "repo_key", "examples", "source", "state", "overrides", "moved_to", "history", "at",
)
# The other fields stay unscanned: stop conditions and "don't" lines need words such as
# "cost", "limit" and "publish", which are protected stems.
PROTECTED_FIELDS = ("do", "skills", "tools", "agents")

_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_Reject = programme_protocol._Reject
_NAMING = types.SimpleNamespace(_name_words=programme_naming.name_words)


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


def protected_kind(entry):
    for field in PROTECTED_FIELDS:
        for line in entry.get(field) or ():
            kind = programme_terms.protected_kind(_NAMING, line)
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


def resolve(record, item, repo=None, *, audience=None, lookup=None, store=None) -> dict:
    programme = (record or {}).get("programme") or {}
    loaded = store if store is not None else load_store(lookup)
    rejected = list(loaded["rejected"])
    key = repo_key_for(programme, repo if repo is not None else (item or {}).get("repo"))
    moved = {"personal": {e["id"] for e in loaded["personal"]},
             "repo": {e["id"] for rows in loaded["repos"].values() for e in rows}}
    candidates = [e for e in _programme_entries(programme, rejected)
                  if e.get("moved_to") is None or e["id"] not in moved[e["moved_to"]]]
    candidates += (loaded["repos"].get(key) or []) if key else []
    candidates += loaded["personal"]
    candidates = [e for e in candidates if e.get("state", ACTIVE) == ACTIVE]
    overridden = {name for e in candidates for name in e.get("overrides") or ()}
    in_force = [e for e in candidates if e["id"] not in overridden and _reaches(e, audience)]
    return {"in_force": in_force, "rejected": rejected, "notices": list(loaded["notices"])}


def in_force(record, item, repo=None, *, audience=None, lookup=None, store=None) -> list:
    return resolve(record, item, repo, audience=audience, lookup=lookup, store=store)["in_force"]

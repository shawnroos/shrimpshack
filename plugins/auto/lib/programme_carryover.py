#!/usr/bin/env python3
"""The per-machine carry-over store for corrections kept past the end of a programme.

One JSON file beside the personal protocol. Entries sit under each remit repo's GitHub
owner/name (or its normalised path when it has none), or under "all" once Shawn promotes
a correction to every project. Each entry carries an adoption block like the personal
protocol's; ``set-remit`` on an unaccepted agreement pre-fills project terms from the
entries that verify. Running programmes never read the store.
"""

from __future__ import annotations

import json
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
programme_protocol = load_lib_module("programme_protocol")
programme_sanitize = load_lib_module("programme_sanitize")

STORE_PATH_ENV = "CLAUDE_AUTO_CARRYOVER_STORE"
STORE_NAME = "carryover.json"
STORE_LOCK = ".carryover.lock"
STORE_FORMAT = 1
ALL = "all"
SET_BY = "carried_over"
APPROVAL_KIND = "rule_adopted"
OWNER_TEXT = {"pm": "the PM", "worker": "workers", "shawn": "Shawn"}


def store_path() -> str:
    override = os.environ.get(STORE_PATH_ENV)
    if override:
        return override
    return os.path.join(os.path.dirname(programme_protocol.personal_path()), STORE_NAME)


def key_of(repo) -> str:
    return repo.get("github") or os.path.normpath(repo["path"])


def repo_keys(programme) -> list:
    keys = []
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(repo, dict) and repo.get("path") and key_of(repo) not in keys:
            keys.append(key_of(repo))
    return keys


def target(key, entry_id) -> str:
    return f"carryover:{key}:{entry_id}"


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {"format": STORE_FORMAT, "keys": {}}
    if not isinstance(doc, dict) or not isinstance(doc.get("keys"), dict):
        raise ValueError("the carry-over store is not an object with keys")
    return doc


def entries_under(doc, key) -> list:
    rows = doc["keys"].get(key)
    return [e for e in rows if isinstance(e, dict)] if isinstance(rows, list) else []


def read_store() -> dict:
    return _read(store_path())


def _write(update) -> None:
    path = store_path()

    def body():
        doc = _read(path)
        update(doc)
        folder = os.path.dirname(os.path.abspath(path))
        os.makedirs(folder, exist_ok=True)

        def write(fh):
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")

        programme_home.atomic_write(path, write, ".carryover.", folder)

    os.makedirs(programme_home.programmes_dir(), exist_ok=True)
    run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), STORE_LOCK), body)


def entry_for(correction, key, rec) -> dict:
    return {"id": "k" + secrets.token_hex(3), "key": key, "correction": correction["id"],
            "kind": correction["kind"], "to": correction["to"],
            "area": correction["kind"].replace("_", " "),
            "value": f"decided by {OWNER_TEXT.get(correction['to'], correction['to'])}",
            "reserved": correction["to"] == "shawn", "quote": correction.get("quote"),
            "pm_reading": correction.get("pm_reading"), "run_id": rec["run_id"],
            "at": run_record_core.now_iso()}


def adopt(entry, prompt, rec) -> dict:
    adoption = {"machine": programme_protocol.machine_name(), "run_id": rec["run_id"],
                "prompt_id": prompt["prompt_id"], "quote": programme_journal.redact(prompt["quote"]),
                "prompt_hash": prompt["text_hash"], "hash": programme_protocol.content_hash(entry)}
    return dict(entry, adoption=adoption)


# Pre-fill verifies an entry only through its approval row, so every stored entry gets one.
def store(entries, prompt, rec, how) -> list:
    adopted = [adopt(e, prompt, rec) for e in entries]

    def update(doc):
        for entry in adopted:
            kept = [e for e in entries_under(doc, entry["key"]) if e.get("kind") != entry["kind"]]
            doc["keys"][entry["key"]] = kept + [entry]

    _write(update)
    for entry in adopted:
        programme_journal.append(
            rec["run_id"], APPROVAL_KIND, rec.get("driving_session_id"),
            {"entry": how, "target": target(entry["key"], entry["id"]), "hash": entry["adoption"]["hash"],
             "prompt_id": prompt["prompt_id"], "quote": prompt["quote"]},
            cites=[prompt["prompt_id"]])
    return [{"id": e["id"], "key": e["key"], "correction": e["correction"], "hash": e["adoption"]["hash"]}
            for e in adopted]


def _verified(entry, key, lookup):
    if entry.get("key") != key:
        return "stored under the wrong key"
    try:
        programme_protocol._verify_adoption(entry, lookup, target(key, entry.get("id")), local_only=True,
                                            elsewhere="adopted_on_another_machine")
    except programme_protocol._Reject as exc:
        return exc.reason + (f" ({exc.detail})" if exc.detail else "")
    return None


# Never raises on store content: a bad store must not block set-remit.
def prefill(host, programme) -> tuple:
    try:
        doc = read_store()
    except (OSError, ValueError) as exc:
        return [], [programme_sanitize.clean(f"carry-over store unreadable, nothing pre-filled: {exc}", cap=0)]
    terms = programme_home.project_terms(programme)
    taken = {host._squash(t.get("area")) for t in terms}
    added, notices, journals = [], [], {}
    for key in repo_keys(programme) + [ALL]:
        for entry in entries_under(doc, key):
            reason = _verified(entry, key, lambda run, prompt: host.prompt_lookup(run, prompt, journals))
            if reason:
                notices.append(programme_sanitize.clean(
                    f"dropped carried-over entry {entry.get('id')} under {key}: {reason}", cap=0))
                continue
            area = programme_sanitize.clean(entry.get("area"))
            if not area or host._squash(area) in taken:
                continue
            taken.add(host._squash(area))
            term = {"id": "t" + secrets.token_hex(3), "area": area,
                    "value": programme_sanitize.clean(entry.get("value")), "source": f"carried over from {key}",
                    "set_by": SET_BY, "origin": key, "carried": entry.get("id"),
                    "at": run_record_core.now_iso(), "reserved": bool(entry.get("reserved")), "history": []}
            terms.append(term)
            added.append({k: term[k] for k in ("id", "area", "value", "origin", "carried")})
    programme["agreement"]["project_terms"] = terms
    return added, notices

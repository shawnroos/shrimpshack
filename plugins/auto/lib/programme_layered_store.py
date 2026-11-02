#!/usr/bin/env python3
"""The repo and personal store that Behaviours and Rituals share.

One file beside the personal protocol holds the personal entries and the entries of each repo. Every
stored entry is verified through its approval row in the journal. Behaviours and Rituals each build
one ``LayeredStore`` and keep their own entry rules, ids and error class.
"""

from __future__ import annotations

import json
import os
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

STORE_FORMAT = 1
APPROVAL_KIND = "rule_adopted"
STORED_LAYERS = ("repo", "personal")
_Reject = programme_protocol._Reject


class LayeredStore:
    """``verdict`` and ``target`` are passed as callables so the owning module can define them after the store."""

    def __init__(self, noun, *, file_name, lock_name, path_env, error, verdict, target):
        self.noun, self.plural = noun, noun + "s"
        self.file_name, self.lock_name, self.path_env = file_name, lock_name, path_env
        self.error, self.verdict, self.target = error, verdict, target

    def refuse(self, entry, check) -> None:
        if not check["ok"]:
            name = entry.get("id") if isinstance(entry, dict) else None
            detail = f" ({check['detail']})" if check["detail"] else ""
            raise self.error(f"{self.noun} {name!r} refused: {check['reason']}{detail}")

    def path(self) -> str:
        override = os.environ.get(self.path_env)
        if override:
            return override
        return os.path.join(os.path.dirname(programme_protocol.personal_path()), self.file_name)

    def _read(self, path) -> dict:
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except FileNotFoundError:
            return {"format": STORE_FORMAT, "personal": [], "repos": {}}
        except (OSError, ValueError) as exc:
            raise self.error(f"{self.plural} store {path} is unreadable; not overwriting it: {exc}")
        repos = doc.get("repos", {}) if isinstance(doc, dict) else None
        if not isinstance(doc, dict) or not isinstance(doc.get("personal", []), list) \
                or not isinstance(repos, dict) or not all(isinstance(v, list) for v in repos.values()):
            raise self.error(f"{self.plural} store {path} is not a {self.plural} store; not overwriting it")
        doc.setdefault("format", STORE_FORMAT)
        doc.setdefault("personal", [])
        doc.setdefault("repos", {})
        return doc

    def read(self) -> dict:
        return self._read(self.path())

    # The doc is read inside the lock, so what an update decides (the id it replaces, the layer it
    # clears) always acts on the file as it is at the moment of the write.
    def write(self, update) -> None:
        path = self.path()

        def body():
            doc = self._read(path)
            if not isinstance(doc["format"], int) or doc["format"] > STORE_FORMAT:
                raise self.error(f"{self.plural} store {path} has a newer format; not overwriting it")
            update(doc)
            folder = os.path.dirname(os.path.abspath(path))
            os.makedirs(folder, exist_ok=True)

            def dump(fh):
                json.dump(doc, fh, indent=2, sort_keys=True)
                fh.write("\n")

            programme_home.atomic_write(path, dump, f".{self.plural}.", folder)

        os.makedirs(programme_home.programmes_dir(), exist_ok=True)
        run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), self.lock_name), body)

    # The loader verifies a same-machine entry only through its approval row, so every stored entry
    # gets one. The rows are separate journal writes: call this after the programme write commits.
    def store(self, adopted, prompt, run_id, session_id, how) -> None:
        for entry in adopted:
            self.refuse(entry, self.verdict(entry))
            if entry["layer"] not in STORED_LAYERS or "adoption" not in entry:
                raise self.error(f"{self.noun} {entry['id']!r} is not an adopted personal or repo entry")

        def update(doc):
            for entry in adopted:
                _place(doc, entry)

        self.write(update)
        for entry in adopted:
            programme_journal.append(
                run_id, APPROVAL_KIND, session_id,
                {"entry": how, "target": self.target(entry), "hash": entry["adoption"]["hash"],
                 "prompt_id": prompt["prompt_id"], "quote": prompt["quote"]},
                cites=[prompt["prompt_id"]])

    def _stored_reason(self, entry, layer, key, lookup):
        check = self.verdict(entry)
        if not check["ok"]:
            return check["reason"], check["detail"]
        if entry["layer"] != layer:
            return "wrong_layer", entry["layer"]
        if layer == "repo" and entry["repo_key"] != key:
            return "wrong_key", entry["repo_key"]
        try:
            programme_protocol._verify_adoption(entry, lookup, self.target(entry), local_only=False)
        except _Reject as exc:
            return exc.reason, exc.detail
        return None

    def _admit(self, out, layer, key, entry, lookup) -> None:
        reason = self._stored_reason(entry, layer, key, lookup)
        if reason is None:
            (out["personal"] if layer == "personal" else out["repos"].setdefault(key, [])).append(entry)
            return
        name = entry.get("id") if isinstance(entry, dict) else None
        out["rejected"].append({"layer": layer, "key": key, "id": name, "reason": reason[0], "detail": reason[1]})

    def load(self, lookup=None) -> dict:
        out = {"personal": [], "repos": {}, "rejected": [], "notices": []}
        try:
            doc = self.read()
        except self.error as exc:
            out["notices"].append(programme_sanitize.clean(str(exc), cap=0))
            return out
        lookup = lookup or _default_lookup()
        for entry in doc["personal"]:
            self._admit(out, "personal", None, entry, lookup)
        for key, rows in doc["repos"].items():
            for entry in rows:
                self._admit(out, "repo", key, entry, lookup)
        return out


def _default_lookup():
    # Loaded here, not at import: programme.py imports the modules that import this one. A caller
    # inside programme.py passes host.prompt_lookup, since its module is __main__ there.
    programme = load_lib_module("programme")
    journals = {}
    return lambda run_id, prompt_id: programme.prompt_lookup(run_id, prompt_id, journals)


def _is(e, entry_id) -> bool:
    return isinstance(e, dict) and e.get("id") == entry_id


def _without(doc, entry_id) -> None:
    doc["personal"] = [e for e in doc["personal"] if not _is(e, entry_id)]
    doc["repos"] = {k: [e for e in rows if not _is(e, entry_id)] for k, rows in doc["repos"].items()}
    doc["repos"] = {k: rows for k, rows in doc["repos"].items() if rows}


def _place(doc, entry) -> None:
    _without(doc, entry["id"])
    if entry["layer"] == "personal":
        doc["personal"].append(entry)
    else:
        doc["repos"].setdefault(entry["repo_key"], []).append(entry)

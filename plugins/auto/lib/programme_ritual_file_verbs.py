#!/usr/bin/env python3
"""The verbs that put a repo's ritual file in force for one programme, or take it out.

``adopt-ritual-file`` and ``decline-ritual-file`` need Shawn's answer to an offer of that command. The offer
stores the file's content hash, so a file that changed since is refused and he only approves what he was shown.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_ritual_files = load_lib_module("programme_ritual_files")
programme_rituals = load_lib_module("programme_rituals")
run_record_core = load_lib_module("run_record_core")

RitualError = programme_rituals.RitualError
ADOPTED = "ritual_file_adopted"
DECLINED = "ritual_file_declined"


def file_rows(programme, ref, lookup) -> list:
    key, _, rid = ref.rpartition("/")
    if not key or not rid:
        raise ValueError("name the ritual as <repo key>/<id>, for example acme/alpha/plugin-versions")
    programme_ritual_files.invalidate()
    got = programme_rituals.resolve({"programme": programme}, lookup=lookup)["file_rituals"]
    return [r for r in got["proposals"] + got["adopted"] + got["declined"] if r["repo_key"] == key and r["id"] == rid]


def proposed_row(rows):
    return next((r for r in rows if r["state"] in ("proposed", "changed")), None)


def declinable_row(rows):
    return next((r for r in rows if r["state"] in ("proposed", "changed", "declined")), rows[0] if rows else None)


def _h_adopt(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: adopt-ritual-file <repo key>/<id> --prompt <id> [--run <id>]")
    ref = positional[0]

    def change(programme, prompt, rec):
        row = proposed_row(file_rows(programme, ref, host.prompt_lookup))
        if row is None:
            raise RitualError(f"no proposed ritual file {ref!r}; it may be rejected, declined, already adopted "
                              "at this content, or not on the default branch")
        record = {"state": "adopted", "hash": row["hash"], "adopted_at": run_record_core.now_iso(),
                  "prompt_id": prompt["prompt_id"], "snapshot": row["entry"]}
        programme.setdefault("ritual_adoptions", {})[ref] = record
        if row["entry"]["when"].get("schedule") and row["id"] not in programme.setdefault("ritual_clock", {}):
            programme_rituals.advance_clock(programme, row["entry"])
        return {"ritual": row["id"], "repo_key": row["repo_key"], "hash": row["hash"], "file": row["file"]["path"],
                "commit": row["file"]["commit"], "trigger": row["entry"]["when"]["trigger"]}

    return host._write(opts, change, ADOPTED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="adopt-ritual-file", target=ref)


def _h_decline(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: decline-ritual-file <repo key>/<id> --prompt <id> [--run <id>]")
    ref = positional[0]

    def change(programme, prompt, rec):
        row = declinable_row(file_rows(programme, ref, host.prompt_lookup))
        if row is None:
            raise RitualError(f"no ritual file {ref!r} to decline")
        programme.setdefault("ritual_adoptions", {})[ref] = {
            "state": "declined", "hash": row["hash"], "declined_at": run_record_core.now_iso(),
            "prompt_id": prompt["prompt_id"]}
        if not any(e.get("id") == row["id"] for e in programme.get("rituals") or []):
            programme.setdefault("ritual_clock", {}).pop(row["id"], None)
        return {"ritual": row["id"], "repo_key": row["repo_key"], "hash": row["hash"]}

    return host._write(opts, change, DECLINED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="decline-ritual-file", target=ref)


_SPECS = (
    ("adopt-ritual-file", _h_adopt, "<repo key>/<id> --prompt <id> [--run <id>]",
     "no answer from the driving session to an offer of this command; a file that changed since that offer; a file "
     "that is not proposed (rejected, declined, already adopted at this content, or not on the default branch)."),
    ("decline-ritual-file", _h_decline, "<repo key>/<id> --prompt <id> [--run <id>]",
     "no answer from the driving session to an offer of this command; a file that changed since that offer. "
     "Takes an adopted ritual out of force too; a changed file proposes again."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

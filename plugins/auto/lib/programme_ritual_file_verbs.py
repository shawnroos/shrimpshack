#!/usr/bin/env python3
"""The verbs that put a repo's ritual file in force for one programme, or take it out.

``adopt-ritual-file`` and ``decline-ritual-file`` need a typed prompt that names the ritual id and the
content hash of the file as it stands now (and the check, when it carries one). A prompt that names a
hash from an earlier reading is refused, so Shawn only ever approves the content he was shown.
"""

from __future__ import annotations

import functools
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_journal = load_lib_module("programme_journal")
programme_ritual_files = load_lib_module("programme_ritual_files")
programme_rituals = load_lib_module("programme_rituals")
run_record_core = load_lib_module("run_record_core")

RitualError = programme_rituals.RitualError
ADOPTED = "ritual_file_adopted"
DECLINED = "ritual_file_declined"
_HASH_WORD = re.compile(r"(?<![0-9a-f])[0-9a-f]{12}(?![0-9a-f])")


def _rows(host, programme, rec, ref) -> list:
    key, _, rid = ref.rpartition("/")
    if not key or not rid:
        raise ValueError("name the ritual as <repo key>/<id>, for example acme/alpha/plugin-versions")
    programme_ritual_files.invalidate()
    got = programme_rituals.resolve(dict(rec, programme=programme), lookup=host.prompt_lookup)["file_rituals"]
    return [r for r in got["proposals"] + got["adopted"] + got["declined"] if r["repo_key"] == key and r["id"] == rid]


def _named(host, prompt, row, *, grants=True) -> None:
    text = programme_journal.named_text(prompt).lower()
    if any(word != row["hash_short"] for word in _HASH_WORD.findall(text)) and row["hash_short"] not in text:
        raise RitualError(f"prompt {prompt['prompt_id']!r} names a hash, but the file has changed since it was shown; "
                          f"show Shawn the file as it is now (hash {row['hash_short']}) and ask again")
    needs = [row["id"], row["hash_short"]]
    if grants and row["entry"].get("check"):
        needs.append(row["entry"]["check"]["name"].replace("-", " "))
    host.require_named(prompt, *needs)


def _h_adopt(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: adopt-ritual-file <repo key>/<id> --prompt <id> [--run <id>]")
    ref = positional[0]

    def change(programme, prompt, rec):
        rows = [r for r in _rows(host, programme, rec, ref) if r["state"] in ("proposed", "changed")]
        if not rows:
            raise RitualError(f"no proposed ritual file {ref!r}; it may be rejected, declined, already adopted "
                              "at this content, or not on the default branch")
        row = rows[0]
        _named(host, prompt, row)
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
        rows = _rows(host, programme, rec, ref)
        current = [r for r in rows if r["state"] in ("proposed", "changed", "declined")] or rows
        if not current:
            raise RitualError(f"no ritual file {ref!r} to decline")
        row = current[0]
        _named(host, prompt, row, grants=False)
        programme.setdefault("ritual_adoptions", {})[ref] = {
            "state": "declined", "hash": row["hash"], "declined_at": run_record_core.now_iso(),
            "prompt_id": prompt["prompt_id"]}
        programme.setdefault("ritual_clock", {}).pop(row["id"], None)
        return {"ritual": row["id"], "repo_key": row["repo_key"], "hash": row["hash"]}

    return host._write(opts, change, DECLINED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="decline-ritual-file", target=ref)


_SPECS = (
    ("adopt-ritual-file", _h_adopt, "<repo key>/<id> --prompt <id> [--run <id>]",
     "no typed prompt from the driving session; a prompt that does not name the ritual id and the content hash "
     "of the file as it stands now (and the check, when it has one); a prompt that names an earlier hash; a file "
     "that is not proposed (rejected, declined, already adopted at this content, or not on the default branch)."),
    ("decline-ritual-file", _h_decline, "<repo key>/<id> --prompt <id> [--run <id>]",
     "no typed prompt from the driving session; a prompt that does not name the ritual id and the content hash. "
     "Takes an adopted ritual out of force too; a changed file proposes again."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

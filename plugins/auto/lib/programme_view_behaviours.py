#!/usr/bin/env python3
"""Labels for behaviour rows that come from the shipped and personal behaviour folders."""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviour_files = load_lib_module("programme_behaviour_files")
programme_behaviours = load_lib_module("programme_behaviours")

SHIPPED = "shipped"
REPLACES = "yours (replaces shipped)"
PERSONAL_FILE = "personal file"
UPDATE = "update available"


def file_entries(loaded) -> list:
    return list(loaded.get("shipped") or []) + list(loaded.get("files") or [])


def _seen() -> dict:
    # Read-only: the view must never create or repair the record, and a bad record means no tag.
    try:
        with open(programme_behaviour_files.seen_path(), encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def file_facts(loaded) -> dict:
    shipped = loaded.get("shipped") or []
    files = loaded.get("files") or []
    shipped_by_id = {e["id"]: e for e in shipped}
    file_ids = {f["id"] for f in files}
    seen = _seen()
    facts = {}
    for e in shipped:
        facts[(SHIPPED, e["id"])] = {"label": SHIPPED,
                                     "replaced_by": [e["id"]] if e["id"] in file_ids else []}
    for e in files:
        copy = e["id"] in shipped_by_id
        record = seen.get(e["id"]) if isinstance(seen.get(e["id"]), dict) else {}
        current = programme_behaviour_files.entry_hash(shipped_by_id[e["id"]]) if copy else None
        stale = bool(copy and record.get("seen") and current and record["seen"] != current)
        facts[("personal", e["id"])] = {"label": REPLACES if copy else PERSONAL_FILE, "update_available": stale,
                                        "needs_show": stale and record.get("shown") != current,
                                        "replaced_by": []}
    return facts


def apply(row, entry, facts) -> None:
    fact = facts.get((entry["layer"], entry["id"])) if programme_behaviours.from_file(entry) else None
    if not fact:
        return
    row["label"] = fact["label"]
    if fact.get("update_available"):
        row["update_available"] = True
        row["needs_show"] = bool(fact.get("needs_show"))
    if fact["replaced_by"] and "overridden_by" in row:
        row["overridden_by"] = sorted(set(row.get("overridden_by") or ()) | set(fact["replaced_by"]))


def layer_text(b, repo_layer) -> str:
    label = b.get("label") or repo_layer
    return f"{label}, {UPDATE}" if b.get("update_available") else label


def show_text(b) -> list:
    return ["not yet shown"] if b.get("needs_show") else []


def source_text(b) -> str:
    if b.get("quote"):
        return f"source: Shawn: \"{b['quote']}\""
    return f"source: {b['label']}" if b.get("label") else "source: none recorded"

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

programme_behaviour_file_verbs = load_lib_module("programme_behaviour_file_verbs")

SHIPPED = "shipped"
REPLACES = "yours (replaces shipped)"
PERSONAL_FILE = "personal file"
UPDATE = "update available"


def file_entries(loaded) -> list:
    return list(loaded.get("shipped") or []) + list(loaded.get("files") or [])


def _seen() -> dict:
    # Read-only: the view must never create or repair the record, and a bad record means no tag.
    try:
        with open(programme_behaviour_file_verbs.seen_path(), encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def _shipped_now(bid):
    try:
        return programme_behaviour_file_verbs.shipped_hash(bid)
    except Exception:
        return None


def file_facts(loaded) -> dict:
    """Per-id label facts, keyed by (layer, id), for the entries loaded from files."""
    shipped_ids = {e["id"] for e in loaded.get("shipped") or []}
    seen = _seen()
    facts = {}
    for e in loaded.get("shipped") or []:
        facts[(SHIPPED, e["id"])] = {"label": SHIPPED,
                                     "replaced_by": [e["id"]] if any(f["id"] == e["id"] for f in loaded.get("files") or []) else []}
    for e in loaded.get("files") or []:
        copy = e["id"] in shipped_ids
        record = seen.get(e["id"]) if isinstance(seen.get(e["id"]), dict) else {}
        current = _shipped_now(e["id"]) if copy else None
        stale = bool(copy and record.get("seen") and current and record["seen"] != current)
        facts[("personal", e["id"])] = {"label": REPLACES if copy else PERSONAL_FILE, "update_available": stale,
                                        "replaced_by": []}
    return facts


def apply(row, entry, facts) -> None:
    """Add the file labels to a row; a row with no file facts is left untouched."""
    fact = facts.get((entry["layer"], entry["id"])) if entry.get("layer") == SHIPPED or entry.get("source") == "file" else None
    if not fact:
        return
    row["label"] = fact["label"]
    if fact.get("update_available"):
        row["update_available"] = True
    if fact["replaced_by"] and "overridden_by" in row:
        row["overridden_by"] = sorted(set(row.get("overridden_by") or ()) | set(fact["replaced_by"]))


def layer_text(b, repo_layer) -> str:
    label = b.get("label") or repo_layer
    return f"{label}, {UPDATE}" if b.get("update_available") else label

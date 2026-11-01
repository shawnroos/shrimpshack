#!/usr/bin/env python3
"""The PM sweep's view of its whole domain: remit session order, gone folders and outside sessions.

Pure functions over the pane rows ``programme_sources`` already reads. Nothing here calls a host.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_sanitize = load_lib_module("programme_sanitize")

RANKS = ("needs_shawn", "unknown_state", "claims_merge", "idle", "working")
SHAWN_WAITERS = ("shawn",)
UNKNOWN_STATUS = ("", "unknown")
FOLDER_GONE = "folder_gone"
OUTSIDE_CAP = 40


def folder_gone(pane) -> bool:
    cwd = pane.get("cwd")
    return bool(cwd) and not os.path.isdir(cwd)


def item_of(programme, pane_id):
    for key, item in (programme.get("items") or {}).items():
        if ((item.get("owner") or {}).get("pane") == pane_id
                and item.get("state") not in programme_home.FINISHED_ITEM_STATES):
            return key, item
    return None, None


def _claims_merge(item) -> bool:
    merged = ((item or {}).get("deliverables") or {}).get("merged") or {}
    return bool(merged.get("ref") or (merged.get("fields") or {}).get("pr")) and merged.get("result") != "confirmed"


def rank(pane, item) -> int:
    status = pane.get("agent_status") or ""
    waiter = ((item or {}).get("waiting_on") or {}).get("who")
    if status == "blocked" or ((item or {}).get("state") == "waiting" and waiter in SHAWN_WAITERS):
        return 0
    if status in UNKNOWN_STATUS:
        return 1
    if _claims_merge(item):
        return 2
    if status == "idle" and (item is None or item.get("state") == "open"):
        return 3
    return 4


def order(programme, panes) -> list:
    rows = []
    for pane in panes:
        key, item = item_of(programme, pane["pane_id"])
        n = rank(pane, item)
        rows.append({"pane": pane["pane_id"], "item": key, "rank": n, "why": RANKS[n],
                     "agent_status": pane.get("agent_status")})
    return sorted(rows, key=lambda r: (r["rank"], r["pane"]))


def gone_entry(programme, pane) -> dict:
    key, _ = item_of(programme, pane["pane_id"])
    return {"pane": pane["pane_id"], "workspace_id": pane.get("workspace_id"), "title": pane.get("title"),
            "cwd": pane.get("cwd"), "agent": pane.get("agent"), "agent_status": pane.get("agent_status"),
            "item": key, "why": FOLDER_GONE}


def outside_views(snap, scope, owner_of, role_of) -> list:
    """Agent panes the remit does not cover: other spaces, and other tabs of a remit space when the remit names tabs."""
    agents = {a.get("pane_id"): a for a in snap.get("agents") or [] if isinstance(a, dict)}
    out = []
    for row in snap.get("panes") or []:
        if not isinstance(row, dict):
            continue
        in_space = row.get("workspace_id") in scope["workspaces"]
        if in_space and (scope["tabs"] is None or row.get("tab_id") in scope["tabs"]):
            continue
        pane_id = programme_sanitize.token(row.get("pane_id"))
        agent = agents.get(row.get("pane_id"))
        if not pane_id or not (agent or row.get("agent")):
            continue
        cwd = row.get("foreground_cwd") or row.get("cwd")
        pane = {
            "pane_id": pane_id,
            "workspace_id": programme_sanitize.token(row.get("workspace_id")),
            "tab_id": programme_sanitize.token(row.get("tab_id")),
            "terminal_id": programme_sanitize.token(row.get("terminal_id")),
            "label": programme_sanitize.clean(row.get("label"), 200) or None,
            "title": programme_sanitize.clean(
                row.get("terminal_title_stripped") or row.get("terminal_title"), 200) or None,
            "cwd": programme_sanitize.clean(cwd, 400) or None,
            "agent": programme_sanitize.token((agent or row).get("agent")),
            "agent_status": programme_sanitize.token((agent or row).get("agent_status")),
            "owner": owner_of(row, agent),
        }
        if role_of(pane) in ("pm", "tracker"):
            continue
        out.append(pane)
    return out[:OUTSIDE_CAP]


def recommendation(pane) -> dict:
    reason = pane.get("title") or pane.get("label") or "an agent session outside the remit"
    if folder_gone(pane):
        reason += " (its folder is gone)"
    return {"pane": pane["pane_id"], "workspace_id": pane["workspace_id"], "agent": pane["agent"],
            "agent_status": pane["agent_status"], "title": pane["title"], "cwd": pane["cwd"], "reason": reason}

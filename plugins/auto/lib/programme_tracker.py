#!/usr/bin/env python3
"""The issue tracker source: an ordered chain of providers, first answer wins.

A provider is a function ``(workspaces, idents) -> dict`` with ``state`` (available,
unavailable, unsupported, or None when it had nothing to ask), ``reason``, ``issues``
and ``bindings``. Add a provider by adding it to PROVIDERS; callers only see ``read``.
"""

from __future__ import annotations

import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_exec = load_lib_module("programme_exec")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")

BOARD_TIMEOUT = 15.0
LINEAR_TIMEOUT = 15.0
LINEAR_BATCH = 50
LINEAR_URL = "https://api.linear.app/graphql"
LINEAR_KEY = "LINEAR_API_KEY"
ISSUE_ID = re.compile(r"\b([A-Za-z][A-Za-z0-9]{1,7})-(\d{1,6})\b")
_PANE_LABEL = re.compile(r"Linear(?:: .+)?")
_UNSUPPORTED_OP = re.compile(r"\bop unsupported\b", re.IGNORECASE)


def issue_ids(text) -> list:
    out = []
    for match in ISSUE_ID.finditer(text or ""):
        if int(match.group(2)) == 0:
            continue
        ident = f"{match.group(1).upper()}-{match.group(2)}"
        if ident not in out:
            out.append(ident)
    return out


def is_tracker_pane(label) -> bool:
    return bool(label) and bool(_PANE_LABEL.fullmatch(label))


def _issue_view(raw, provider) -> dict:
    state = raw.get("state") if isinstance(raw.get("state"), dict) else {}
    return {"title": programme_sanitize.clean(raw.get("title"), 200),
            "state": programme_sanitize.clean(state.get("name"), 60) or None,
            "state_type": programme_sanitize.token(state.get("type")),
            "url": programme_sanitize.token(raw.get("url")), "source": provider,
            "project": named_ref(raw.get("project"))}


def named_ref(raw):
    if not isinstance(raw, dict):
        return None
    out = {"id": programme_sanitize.token(raw.get("id"), 64), "name": programme_sanitize.clean(raw.get("name"), 100) or None}
    return out if out["id"] or out["name"] else None


def _down(state, reason) -> dict:
    return {"state": state, "reason": reason, "issues": None, "bindings": {}}


def _board_argv(workspace) -> list:
    return ["board", "linear", "snapshot", "--json", workspace]


def _board(workspaces, idents) -> dict:
    issues, bindings = {}, {}
    for ws in workspaces:
        result = programme_exec.bounded(_board_argv(ws), programme_exec.source_timeout(BOARD_TIMEOUT))
        doc = (programme_exec.parse_json(result["stdout"]) or programme_exec.parse_json(result["stderr"])
               if result["ran"] else None)
        if not result["ran"] or result["code"] != 0 or not isinstance(doc, dict) or doc.get("error"):
            error = (doc or {}).get("error") if isinstance(doc, dict) else None
            message = error.get("message") if isinstance(error, dict) else None
            reason = (programme_sanitize.clean(message, 200) if message
                      else programme_exec.failure(result, "board linear snapshot"))
            unsupported = result["missing"] or bool(_UNSUPPORTED_OP.search(reason))
            return _down("unsupported" if unsupported else "unavailable", f"{ws}: {reason}")
        if not isinstance(doc.get("issues"), dict):
            return _down("unavailable", f"{ws}: board snapshot has no issues")
        for key, raw in doc["issues"].items():
            ident = programme_sanitize.token(key)
            if not ident or not isinstance(raw, dict):
                continue
            issues[ident] = _issue_view(raw, "board")
            for binding in raw.get("bindings") or []:
                for pane in (binding or {}).get("panes") or []:
                    bindings.setdefault(pane, []).append(ident)
    return {"state": "available", "reason": None, "issues": issues, "bindings": bindings}


def linear_key():
    value = os.environ.get(LINEAR_KEY)
    if not value:
        try:
            for key, raw in programme_journal.secret_assignments(encoding="utf-8"):
                if key == LINEAR_KEY:
                    value = raw.strip("'\"")
        except OSError:
            value = None
    if not value or any(ch in value for ch in "\"\\\n\r ") or len(value) > 200:
        return None
    return value


def read_linear(idents) -> dict:
    key = linear_key()
    if not key:
        return _down("unavailable", f"no {LINEAR_KEY} in the environment or secrets file")
    idents = sorted(idents)[:LINEAR_BATCH]
    fields = " ".join(f"i{n}: issue(id: {json.dumps(ident)}) {{ identifier title url state {{ name type }} project {{ id name }} }}"
                      for n, ident in enumerate(idents))
    body = json.dumps({"query": "query { " + fields + " }"})
    # The key travels in curl's config on stdin so it never appears in a process list.
    config = (f'url = "{LINEAR_URL}"\nheader = "Authorization: {key}"\n'
              f'header = "Content-Type: application/json"\ndata = {json.dumps(body)}\n')
    timeout = programme_exec.source_timeout(LINEAR_TIMEOUT)
    result = programme_exec.bounded(["curl", "-sS", "--max-time", str(int(timeout) or 1), "-K", "-"],
                                    timeout + 2, config)
    doc = programme_exec.parse_json(result["stdout"]) if result["ran"] and result["code"] == 0 else None
    data = doc.get("data") if isinstance(doc, dict) else None
    if not isinstance(data, dict):
        return _down("unsupported" if result["missing"] else "unavailable",
                     programme_exec.failure(result, "Linear read") if not doc else "Linear answered with no data")
    issues = {}
    for raw in data.values():
        ident = programme_sanitize.token((raw or {}).get("identifier")) if isinstance(raw, dict) else None
        if ident:
            issues[ident] = _issue_view(raw, "linear-api")
    return {"state": "available", "reason": None, "issues": issues, "bindings": {}}


def _linear_api(workspaces, idents) -> dict:
    if not idents:
        if linear_key():
            return {"state": "available", "reason": None, "issues": {}, "bindings": {}}
        return _down(None, f"no {LINEAR_KEY} in the environment or secrets file")
    return read_linear(idents)


PROVIDERS = (("board", _board), ("linear-api", _linear_api))
WATCH_PROVIDERS = (("board", _board_argv),)


def read(workspaces, idents) -> dict:
    tried = []
    for name, provider in PROVIDERS:
        found = provider(workspaces, idents)
        tried.append({"provider": name, "state": found["state"], "reason": found["reason"]})
        if found["state"] == "available":
            return {"state": "available", "unavailable": False, "provider": name, "reason": None,
                    "issues": found["issues"], "bindings": found["bindings"], "tried": tried}
    states = [t["state"] for t in tried if t["state"] is not None]
    state = "unavailable" if "unavailable" in states else "unsupported"
    reason = "; ".join(f"{t['provider']}: {t['reason']}" for t in tried if t["reason"])
    return {"state": state, "unavailable": True, "provider": None, "reason": reason or None,
            "issues": None, "bindings": {}, "tried": tried}


def needs_you_argv(key) -> list:
    return ["board", "mark", key, "needs_you"]

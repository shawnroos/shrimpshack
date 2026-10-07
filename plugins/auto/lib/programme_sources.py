#!/usr/bin/env python3
"""herdr, board and Linear reads for the programme sweep, plus the worker start and prompt verbs.

``programme.py`` registers the verbs through ``build_verbs(host)``. Every outside
call is bounded, and every piece of outside text passes through programme_sanitize.
"""

from __future__ import annotations

import contextlib
import functools
import glob
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_record = load_lib_module("programme_record")
session_registry = load_lib_module("session_registry")

TIMEOUT_ENV = "CLAUDE_AUTO_SOURCE_TIMEOUT"
WORKER_WAIT_ENV = "CLAUDE_AUTO_WORKER_WAIT"
SPINOFF_TIMEOUT_ENV = "CLAUDE_AUTO_SPINOFF_TIMEOUT"
HERDR_TIMEOUT = 5.0
BOARD_TIMEOUT = 15.0
LINEAR_TIMEOUT = 15.0
GIT_TIMEOUT = 2.0
SPINOFF_TIMEOUT = 600.0
WORKER_WAIT = 30.0
POLL_SECONDS = 1.0
LINEAR_BATCH = 50
PROMPT_CAP = 4000
QUOTE_CAP = 500
LINEAR_URL = "https://api.linear.app/graphql"
LINEAR_KEY = "LINEAR_API_KEY"
SPINOFF_REL = os.path.join("skills", "spinoff", "scripts", "spinoff.sh")
SIGNALS = ("board", "branch", "title", "label", "registry")
_IDENT = re.compile(r"\b([A-Za-z][A-Za-z0-9]{1,7})-(\d{1,6})\b")
_BOARD_LABEL = re.compile(r"Linear(?:: .+)?")
_PANE_LINE = re.compile(r"herdr agent pane: (\S+)")
_UNSUPPORTED_OP = re.compile(r"\bop unsupported\b", re.IGNORECASE)


def _seconds(env_name, default) -> float:
    try:
        value = float(os.environ.get(env_name) or "")
    except ValueError:
        return default
    return value if value > 0 else default


def _source_timeout(default) -> float:
    return _seconds(TIMEOUT_ENV, default)


def _kill(proc) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        proc.communicate(timeout=1)
    except (subprocess.SubprocessError, OSError, ValueError):
        pass


def bounded(argv, timeout, stdin_text=None) -> dict:
    out = {"ran": False, "code": None, "stdout": "", "stderr": "", "timed_out": False, "error": None,
           "missing": False}
    path = argv[0] if os.path.isabs(argv[0]) else shutil.which(argv[0])
    if not path:
        out.update(error=f"{argv[0]} not found on PATH", missing=True)
        return out
    try:
        proc = subprocess.Popen(
            [path] + list(argv[1:]), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            text=True, errors="replace", start_new_session=True)
    except OSError as exc:
        out["error"] = f"could not run {argv[0]}: {exc}"
        return out
    try:
        stdout, stderr = proc.communicate(stdin_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        # A killed child's grandchildren keep the pipes open; kill the whole group.
        _kill(proc)
        out.update(timed_out=True, error=f"{' '.join(argv[:3])} timed out after {timeout:g}s")
        return out
    out.update(ran=True, code=proc.returncode, stdout=stdout or "", stderr=stderr or "")
    return out


def _json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def _failure(result, what) -> str:
    if not result["ran"]:
        return result["error"]
    detail = programme_sanitize.clean(result["stderr"] or result["stdout"], 200)
    return f"{what} exited {result['code']}" + (f": {detail}" if detail else "")


def _herdr(args):
    return bounded(["herdr"] + list(args), _source_timeout(HERDR_TIMEOUT))


def probe():
    result = _herdr(["status", "server"])
    if not result["ran"] or result["code"] != 0:
        return _failure(result, "herdr status server")
    if not any(line.strip() == "status: running" for line in result["stdout"].splitlines()):
        return "herdr server is not running"
    return None


def read_herdr():
    reason = probe()
    if reason:
        return None, reason
    result = _herdr(["api", "snapshot"])
    if not result["ran"] or result["code"] != 0:
        return None, _failure(result, "herdr api snapshot")
    snap = ((_json(result["stdout"]) or {}).get("result") or {}).get("snapshot")
    if not isinstance(snap, dict) or not isinstance(snap.get("panes"), list):
        return None, "herdr api snapshot returned no pane list"
    return snap, None


def agent_rows():
    result = _herdr(["agent", "list"])
    if not result["ran"] or result["code"] != 0:
        return None
    rows = ((_json(result["stdout"]) or {}).get("result") or {}).get("agents")
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else None


def current_server() -> str:
    return (session_registry.server_from_socket(os.environ.get("HERDR_SOCKET_PATH"))
            or programme_home.DEFAULT_SERVER)


def remit(programme) -> dict:
    server = current_server()
    reached, unreached = [], []
    for space in (programme.get("remit") or {}).get("spaces") or []:
        if space.get("server") == server:
            reached.append(space.get("workspace"))
        else:
            unreached.append(f"{space.get('server')}.{space.get('workspace')}")
    term = ((programme.get("agreement") or {}).get("terms") or {}).get("remit") or {}
    tabs = (programme.get("remit") or {}).get("tabs") or []
    return {"server": server, "workspaces": reached, "unreached": unreached,
            "tabs": list(tabs) if term.get("value") == "tabs" and tabs else None}


def session_of(entry):
    info = (entry or {}).get("agent_session")
    if isinstance(info, dict):
        return None if info.get("kind") == "path" else programme_sanitize.token(info.get("value"))
    return programme_sanitize.token(info) if isinstance(info, str) else None


def registry_hint(rows, pane_id, terminal_id):
    hits = [r for r in rows if r.get("pane_id") == pane_id and r.get("interactive")
            and (not r.get("terminal_id") or not terminal_id or r.get("terminal_id") == terminal_id)]
    return max(hits, key=lambda r: r.get("at") or "") if hits else None


def _branch(path, cache) -> str:
    if not path or not os.path.isdir(path):
        return ""
    if path not in cache:
        result = bounded(["git", "-C", path, "branch", "--show-current"], GIT_TIMEOUT)
        ok = result["ran"] and result["code"] == 0
        cache[path] = (programme_sanitize.token(result["stdout"]) or "") if ok else ""
    return cache[path]


def _owner(row, agent, hint) -> dict:
    sid = session_of(row) or session_of(agent)
    if sid:
        return {"session_id": sid, "source": "snapshot", "name": None}
    if hint and programme_sanitize.token(hint.get("session_id")):
        name = os.path.basename(str(hint.get("cwd") or "").rstrip("/"))
        return {"session_id": programme_sanitize.token(hint.get("session_id")), "source": "registry",
                "name": programme_sanitize.clean(name, 120) or None}
    return {"session_id": None, "source": None, "name": None}


def pane_views(snap, scope) -> list:
    agents = {a.get("pane_id"): a for a in snap.get("agents") or [] if isinstance(a, dict)}
    registry = {ws: session_registry.read_space(scope["server"], ws) for ws in scope["workspaces"]}
    branches = {}
    out = []
    for row in snap.get("panes") or []:
        if not isinstance(row, dict) or row.get("workspace_id") not in scope["workspaces"]:
            continue
        if scope["tabs"] is not None and row.get("tab_id") not in scope["tabs"]:
            continue
        pane_id = programme_sanitize.token(row.get("pane_id"))
        if not pane_id:
            continue
        agent = agents.get(row.get("pane_id"))
        terminal = programme_sanitize.token(row.get("terminal_id"))
        has_agent = bool(agent or row.get("agent"))
        cwd = row.get("foreground_cwd") or row.get("cwd")
        hint = registry_hint(registry.get(row.get("workspace_id")) or [], row.get("pane_id"), terminal)
        out.append({
            "pane_id": pane_id,
            "tab_id": programme_sanitize.token(row.get("tab_id")),
            "workspace_id": programme_sanitize.token(row.get("workspace_id")),
            "terminal_id": terminal,
            "label": programme_sanitize.clean(row.get("label"), 200) or None,
            "title": programme_sanitize.clean(
                row.get("terminal_title_stripped") or row.get("terminal_title"), 200) or None,
            "cwd": programme_sanitize.clean(cwd, 400) or None,
            "branch": _branch(cwd, branches) if has_agent else "",
            "agent": programme_sanitize.token((agent or row).get("agent")) if has_agent else None,
            "agent_status": programme_sanitize.token((agent or row).get("agent_status")),
            "owner": _owner(row, agent, hint),
        })
    return out


def _drivers(record) -> dict:
    panes = set()
    for entry in session_registry.driver_panes():
        panes.update(v for v in (entry.get("pane_id"), entry.get("terminal_id")) if v)
    return {"panes": panes, "session": record.get("driving_session_id")}


def role(pane, drivers) -> str:
    if (pane["pane_id"] in drivers["panes"] or pane["terminal_id"] in drivers["panes"]
            or (pane["owner"]["session_id"] and pane["owner"]["session_id"] == drivers["session"])):
        return "pm"
    if pane["label"] and _BOARD_LABEL.fullmatch(pane["label"]):
        return "board"
    return "worker" if pane["agent"] else "shell"


def named_issues(pane, board_bindings) -> dict:
    found = {}
    for ident in board_bindings.get(pane["pane_id"], []):
        found.setdefault(ident, []).append("board")
    texts = (("branch", pane["branch"]), ("title", pane["title"]), ("label", pane["label"]),
             ("registry", pane["owner"]["name"] if pane["owner"]["source"] == "registry" else None))
    for signal_name, text in texts:
        for match in _IDENT.finditer(text or ""):
            if int(match.group(2)) == 0:
                continue
            ident = f"{match.group(1).upper()}-{match.group(2)}"
            if signal_name not in found.setdefault(ident, []):
                found[ident].append(signal_name)
    return found


def _issue_view(raw, source) -> dict:
    state = raw.get("state") if isinstance(raw.get("state"), dict) else {}
    return {"title": programme_sanitize.clean(raw.get("title"), 200),
            "state": programme_sanitize.clean(state.get("name"), 60) or None,
            "state_type": programme_sanitize.token(state.get("type")),
            "url": programme_sanitize.token(raw.get("url")), "source": source}


def read_board(workspaces) -> dict:
    issues, bindings = {}, {}
    for ws in workspaces:
        result = bounded(["board", "linear", "snapshot", "--json", ws], _source_timeout(BOARD_TIMEOUT))
        doc = (_json(result["stdout"]) or _json(result["stderr"])) if result["ran"] else None
        if not result["ran"] or result["code"] != 0 or not isinstance(doc, dict) or doc.get("error"):
            error = (doc or {}).get("error") if isinstance(doc, dict) else None
            message = error.get("message") if isinstance(error, dict) else None
            reason = (programme_sanitize.clean(message, 200) if message
                      else _failure(result, "board linear snapshot"))
            unsupported = result["missing"] or bool(_UNSUPPORTED_OP.search(reason))
            return {"unavailable": True, "state": "unsupported" if unsupported else "unavailable",
                    "reason": f"{ws}: {reason}", "issues": None, "bindings": {}}
        if not isinstance(doc.get("issues"), dict):
            return {"unavailable": True, "state": "unavailable", "reason": f"{ws}: board snapshot has no issues",
                    "issues": None, "bindings": {}}
        for key, raw in doc["issues"].items():
            ident = programme_sanitize.token(key)
            if not ident or not isinstance(raw, dict):
                continue
            issues[ident] = _issue_view(raw, "board")
            for binding in raw.get("bindings") or []:
                for pane in (binding or {}).get("panes") or []:
                    bindings.setdefault(pane, []).append(ident)
    return {"unavailable": False, "state": "available", "reason": None, "issues": issues, "bindings": bindings}


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
        return {"unavailable": True, "reason": f"no {LINEAR_KEY} in the environment or secrets file",
                "issues": None}
    idents = sorted(idents)[:LINEAR_BATCH]
    fields = " ".join(f"i{n}: issue(id: {json.dumps(ident)}) {{ identifier title url state {{ name type }} }}"
                      for n, ident in enumerate(idents))
    body = json.dumps({"query": "query { " + fields + " }"})
    # The key travels in curl's config on stdin so it never appears in a process list.
    config = (f'url = "{LINEAR_URL}"\nheader = "Authorization: {key}"\n'
              f'header = "Content-Type: application/json"\ndata = {json.dumps(body)}\n')
    timeout = _source_timeout(LINEAR_TIMEOUT)
    result = bounded(["curl", "-sS", "--max-time", str(int(timeout) or 1), "-K", "-"], timeout + 2, config)
    doc = _json(result["stdout"]) if result["ran"] and result["code"] == 0 else None
    data = doc.get("data") if isinstance(doc, dict) else None
    if not isinstance(data, dict):
        return {"unavailable": True, "state": "unsupported" if result["missing"] else "unavailable",
                "reason": _failure(result, "Linear read") if not doc else "Linear answered with no data",
                "issues": None}
    issues = {}
    for raw in data.values():
        ident = programme_sanitize.token((raw or {}).get("identifier")) if isinstance(raw, dict) else None
        if ident:
            issues[ident] = _issue_view(raw, "linear-direct")
    return {"unavailable": False, "reason": None, "issues": issues}


def _choose(found, verified):
    ranked = []
    for ident, signals in found.items():
        if verified is not None and ident not in verified:
            continue
        ranked.append((min(SIGNALS.index(s) for s in signals), ident, signals))
    if not ranked:
        return None, []
    _, ident, signals = min(ranked)
    return ident, sorted(signals, key=SIGNALS.index)


def _existing(programme, item_id, pane_id):
    try:
        return "known", programme_record._resolve(programme, item_id)
    except programme_record.RecordError:
        pass
    for key, item in (programme.get("items") or {}).items():
        if ((item.get("owner") or {}).get("pane") == pane_id
                and item.get("state") not in programme_home.FINISHED_ITEM_STATES):
            return "alias", key
    return "adopt", None


def propose(programme, panes, drivers, issues_found, verified) -> dict:
    proposals, skipped = [], []
    for pane in panes:
        why = role(pane, drivers)
        if why != "worker":
            skipped.append({"pane": pane["pane_id"], "why": why})
            continue
        ident, signals = _choose(issues_found.get(pane["pane_id"]) or {}, verified)
        item_id = f"linear:{ident}" if ident else "herdr:" + pane["pane_id"].replace(":", "/")
        action, existing = _existing(programme, item_id, pane["pane_id"])
        entry = {"item": item_id, "action": action, "pane": pane["pane_id"], "issue": ident,
                 "signals": signals, "terminal_id": pane["terminal_id"],
                 "session_id": pane["owner"]["session_id"], "session_source": pane["owner"]["source"],
                 "title": pane["title"] or pane["label"]}
        if action == "known" and existing != item_id:
            entry["known_as"] = existing
        if action == "alias":
            entry["from"] = existing
        proposals.append(entry)
    return {"proposals": proposals, "skipped": skipped}


def _issue_lookup(candidates, board) -> dict:
    out = {"linear": {"unavailable": None, "reason": None}, "issues": {}, "verified": None,
           "issues_source": None}
    if not board["unavailable"]:
        out.update(issues=board["issues"], verified=set(board["issues"]), issues_source="board")
        return out
    if not candidates:
        return out
    linear = read_linear(candidates)
    out["linear"] = {"unavailable": linear["unavailable"], "state": linear.get("state"),
                     "reason": linear["reason"]}
    if not linear["unavailable"]:
        out.update(issues=linear["issues"], verified=set(linear["issues"]), issues_source="linear-direct")
    return out


def sweep(record) -> dict:
    programme = programme_home.normalize_programme(record.get("programme") or {})
    scope = remit(programme)
    snap, herdr_reason = read_herdr()
    board = read_board(scope["workspaces"])
    panes = pane_views(snap, scope) if snap is not None else None
    drivers = _drivers(record)
    found = {}
    if panes is not None:
        for pane in panes:
            if role(pane, drivers) == "worker":
                found[pane["pane_id"]] = named_issues(pane, board["bindings"])
    candidates = {ident for named in found.values() for ident in named}
    lookup = _issue_lookup(candidates, board)
    result = {
        "run": record.get("run_id"), "at": run_record_core.now_iso(),
        "server": scope["server"], "workspaces": scope["workspaces"], "unreached": scope["unreached"],
        "sources": {"herdr": {"unavailable": snap is None, "state": _herdr_state(snap),
                              "reason": herdr_reason},
                    "board": {"unavailable": board["unavailable"], "state": board["state"],
                              "reason": board["reason"]},
                    "linear": lookup["linear"]},
        "issues_source": lookup["issues_source"],
        "issues": {k: v for k, v in lookup["issues"].items() if k in candidates},
        "panes": panes, "proposals": None, "skipped": None,
    }
    if panes is not None:
        result.update(propose(programme, panes, drivers, found, lookup["verified"]))
    result["source_changes"] = source_changes(programme, result["sources"])
    return result


def _herdr_state(snap) -> str:
    if snap is not None:
        return "available"
    return "unavailable" if shutil.which("herdr") else "unsupported"


def _seen_state(seen) -> str | None:
    if seen.get("unavailable") is None:
        return None
    return seen.get("state") or ("unavailable" if seen["unavailable"] else "available")


def _recorded_state(entry) -> str:
    if entry.get("unsupported_since"):
        return "unsupported"
    return "unavailable" if entry.get("unavailable_since") else "available"


def source_changes(programme, sources) -> list:
    recorded = programme.get("sources") or {}
    changes = []
    for name in programme_record.SOURCES:
        state = _seen_state(sources.get(name) or {})
        if state is not None and state != _recorded_state(recorded.get(name) or {}):
            changes.append({"source": name, "state": state, "unavailable": state != "available"})
    return changes


def _h_sweep(host, argv):
    _, opts = host._parse(argv, values=("run",), flags=("record-sources",))
    run_id, home, record = host._locate(opts)
    if opts.get("record-sources"):
        host._guard(home, record)
    result = sweep(record)
    result["recorded_sources"] = []
    if opts.get("record-sources"):
        for change in result["source_changes"]:
            flag = "--" + change["state"]
            with contextlib.redirect_stdout(io.StringIO()):
                programme_record._h_set_source(host, ["set-source", change["source"], flag, "--run", run_id])
            result["recorded_sources"].append(change)
    host._emit(result)
    return 0


def spinoff_path():
    found = shutil.which("spinoff")
    if found:
        return found
    plugins = os.path.dirname(os.path.dirname(_LIB_DIR))
    beside = os.path.join(plugins, "spinoff", SPINOFF_REL)
    if os.access(beside, os.X_OK):
        return beside
    cached = glob.glob(os.path.join(os.path.dirname(plugins), "spinoff", "*", SPINOFF_REL))
    cached.sort(key=lambda p: [int(n) for n in re.findall(r"\d+", p.split(os.sep)[-5])], reverse=True)
    return cached[0] if cached else None


def await_agent(session_id, pane, before, wait) -> dict:
    deadline = time.monotonic() + wait
    while True:
        rows = agent_rows() or []
        for row in rows:
            if session_of(row) == session_id:
                return {"row": row}
        if pane:
            for row in rows:
                if row.get("pane_id") == pane:
                    other = session_of(row)
                    if other and other != session_id:
                        return {"row": None, "reason": f"pane {pane} reports session {other}, not {session_id}"}
                    return {"row": row}
        else:
            fresh = [r for r in rows if r.get("pane_id") not in before and not session_of(r)]
            if len(fresh) == 1:
                return {"row": fresh[0]}
        if time.monotonic() >= deadline:
            where = f"pane {pane}" if pane else "any new pane"
            return {"row": None, "reason": f"no agent appeared in {where} within {wait:g}s"}
        time.sleep(POLL_SECONDS)


def launch_worker(spinoff, extra) -> dict:
    session_id = str(uuid.uuid4())
    before = {r.get("pane_id") for r in agent_rows() or []}
    run = bounded([spinoff] + list(extra) + ["--session-id", session_id],
                  _seconds(SPINOFF_TIMEOUT_ENV, SPINOFF_TIMEOUT))
    output = programme_sanitize.clean(run["stdout"] + "\n" + run["stderr"], 0, keep_newlines=True)
    match = _PANE_LINE.search(output)
    pane = programme_sanitize.token(match.group(1)) if match else None
    out = {"session_id": session_id, "pane": pane, "terminal_id": None, "spinoff_exit": run["code"],
           "ok": False, "reason": None, "output_tail": programme_sanitize.clean(output[-400:], 400)}
    if not run["ran"] or run["code"] != 0:
        out["reason"] = _failure(run, "spinoff")
        return out
    found = await_agent(session_id, pane, before, _seconds(WORKER_WAIT_ENV, WORKER_WAIT))
    if found["row"] is None:
        out["reason"] = found["reason"]
        return out
    out.update(ok=True, pane=programme_sanitize.token(found["row"].get("pane_id")) or pane,
               terminal_id=programme_sanitize.token(found["row"].get("terminal_id")))
    return out


def _h_start_worker(host, argv):
    argv = list(argv)
    cut = argv.index("--", 1) if "--" in argv[1:] else len(argv)
    own, extra = argv[:cut], argv[cut + 1:]
    positional, opts = host._parse(own, values=("run", "session-name"))
    if len(positional) != 1 or not extra:
        raise ValueError("usage: start-worker <item> [--session-name <name>] -- <spinoff arguments>")
    if any(a == "--session-id" or a.startswith("--session-id=") for a in extra):
        raise host.ProgrammeError("start-worker mints the session id; do not pass --session-id")
    item_id = programme_record.check_item_id(positional[0])
    run_id, home, record = host._locate(opts)
    host._guard(home, record)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = programme_record._resolve(programme, item_id)
    if programme["items"][key]["state"] in programme_home.FINISHED_ITEM_STATES:
        raise host.ProgrammeError(f"item {key!r} is {programme['items'][key]['state']}")
    spinoff = spinoff_path()
    if not spinoff:
        raise host.ProgrammeError("spinoff.sh not found beside this plugin or on PATH")
    started = launch_worker(spinoff, extra)

    def change(prog, prompt, rec):
        item = prog["items"][programme_record._resolve(prog, item_id)]
        entry = {k: started[k] for k in ("session_id", "pane", "terminal_id", "ok", "reason", "spinoff_exit")}
        entry["at"] = run_record_core.now_iso()
        item.setdefault("starts", []).append(entry)
        if started["ok"]:
            programme_record._set_owner(item, {"session": started["session_id"], "pane": started["pane"],
                                               "terminal-id": started["terminal_id"],
                                               "session-name": opts.get("session-name")})
        item["history"].append({"at": entry["at"], "kind": "started" if started["ok"] else "start_failed",
                                "session_id": started["session_id"]})
        return dict(item=item["id"], started=started["ok"], **{k: v for k, v in started.items() if k != "ok"})

    host._write(opts, change, lambda p: "worker_started" if p["started"] else "worker_start_failed")
    return 0 if started["ok"] else 1


def check_target(owner, record) -> dict:
    pane = owner.get("pane")
    out = {"ok": False, "pane": pane, "reason": None, "reported": None, "session_unknown": False,
           "owner_source": None}
    if not pane:
        out["reason"] = "the item has no recorded pane"
        return out
    drivers = _drivers(record)
    if pane in drivers["panes"]:
        out["reason"] = f"pane {pane} is a programme driver's pane"
        return out
    snap, reason = read_herdr()
    if snap is None:
        out["reason"] = f"herdr is unavailable: {reason}"
        return out
    row = next((p for p in snap.get("panes") or [] if p.get("pane_id") == pane), None)
    if row is None:
        out["reason"] = f"pane {pane} is not in the live snapshot"
        return out
    agent = next((a for a in snap.get("agents") or [] if a.get("pane_id") == pane), None)
    live = session_of(row) or session_of(agent)
    out["reported"] = live
    terminal = programme_sanitize.token(row.get("terminal_id"))
    if live and live == drivers["session"]:
        out["reason"] = f"pane {pane} is a programme driver's pane: it runs the driving session"
    elif _BOARD_LABEL.fullmatch(programme_sanitize.clean(row.get("label"), 200) or ""):
        out["reason"] = f"pane {pane} is the board's pane"
    elif owner.get("terminal_id") and terminal and owner["terminal_id"] != terminal:
        out["reason"] = f"pane {pane} now holds terminal {terminal}, not the item's {owner['terminal_id']}"
    elif not (agent or row.get("agent")):
        out["reason"] = f"no live agent in pane {pane}"
    if out["reason"]:
        return out
    hint = None if live else registry_hint(
        session_registry.read_space(current_server(), row.get("workspace_id")) or [], pane, terminal)
    seen = live or programme_sanitize.token((hint or {}).get("session_id"))
    out["owner_source"] = "snapshot" if live else ("registry" if seen else None)
    if seen and owner.get("session_id") and seen != owner["session_id"]:
        out["reported"] = seen
        out["reason"] = f"pane {pane} reports session {seen}, but the item's owner is {owner['session_id']}"
        return out
    out.update(ok=True, session_unknown=not seen)
    return out


def _h_prompt_item(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 2:
        raise ValueError("usage: prompt-item <item> <text>")
    item_id = programme_record.check_item_id(positional[0])
    text = programme_sanitize.clean(positional[1], PROMPT_CAP, keep_newlines=True)
    if not text or text.startswith("-"):
        raise ValueError("prompt-item needs text that is not empty and does not start with '-'")
    run_id, home, record = host._locate(opts)
    sid = host._guard(home, record)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = programme_record._resolve(programme, item_id)
    target = check_target(programme["items"][key]["owner"], record)
    payload = {"item": key, "pane": target["pane"], "reported_session": target["reported"],
               "owner_session": programme["items"][key]["owner"].get("session_id")}
    if not target["ok"]:
        payload["reason"] = target["reason"]
        programme_journal.append(run_id, "prompt_refused", sid, payload)
        raise host.ProgrammeError(f"prompt refused: {target['reason']}")
    sent = _herdr(["agent", "prompt", target["pane"], text])
    ok = sent["ran"] and sent["code"] == 0
    payload.update(sent=ok, session_unknown=target["session_unknown"], owner_source=target["owner_source"],
                   text=programme_journal.redact(programme_sanitize.clean(text, QUOTE_CAP)),
                   error=None if ok else _failure(sent, "herdr agent prompt"))
    programme_journal.append(run_id, "prompt_sent", sid, payload)
    host._emit(dict({"ok": ok, "run": run_id, "kind": "prompt_sent"}, **payload))
    return 0 if ok else 1


_SPECS = (
    ("sweep", _h_sweep, "[--record-sources] [--run <id>]",
     "--record-sources from any session but the driving one. Without it, sweep writes nothing."),
    ("start-worker", _h_start_worker, "<item> [--session-name <name>] [--run <id>] -- <spinoff arguments>",
     "an unknown or finished item; spinoff arguments that carry --session-id; no spinoff arguments."),
    ("prompt-item", _h_prompt_item, "<item> <text> [--run <id>]",
     "an item with no pane; a driver's or the board's pane; a pane whose terminal changed; a pane "
     "with no live agent; a pane whose reported session is not the item's owner. Refusals are "
     "journaled."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

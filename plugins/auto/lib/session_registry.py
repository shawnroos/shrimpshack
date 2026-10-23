#!/usr/bin/env python3
"""Which Claude session runs in which herdr pane.

SessionStart appends one line per session to
``<data dir>/sessions/<server>.<workspace>.jsonl``, resolving the pane through
herdr because a moved pane keeps a stale ``HERDR_PANE_ID``. Interactive sessions
are also reported to herdr, so its snapshot carries the owner.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
driver_session = load_lib_module("driver_session")

LINES_PER_PANE = 50
# SessionStart's hook timeout is 5s; both herdr calls together must stay well under it.
PANE_GET_TIMEOUT = 1.0
REPORT_TIMEOUT = 1.0
FIELD_CAP = 512
# "unavailable": a programme whose store is held still has a driver pane to protect.
DRIVER_LEASE_STATES = ("live", "orphaned", "expired", "unavailable")

_CONTROL = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|[\x00-\x1f\x7f]")


def _clean(value):
    if not isinstance(value, str):
        return None
    return _CONTROL.sub("", value)[:FIELD_CAP] or None


def _path(value):
    if not isinstance(value, str) or not os.path.isabs(value) or len(value) > FIELD_CAP \
            or _CONTROL.search(value):
        return None
    return value


def sessions_dir() -> str:
    return os.path.join(programme_home.data_dir(), "sessions")


def registry_path(server: str, workspace: str) -> str:
    return os.path.join(sessions_dir(), programme_home.space_key(server, workspace) + ".jsonl")


def server_from_socket(sock) -> str | None:
    if not isinstance(sock, str) or not sock.endswith("/herdr.sock"):
        return None
    folder = os.path.dirname(sock)
    if os.path.basename(os.path.dirname(folder)) == "sessions":
        name = os.path.basename(folder)
        try:
            return programme_home.check_segment(name)
        except programme_home.ProgrammeHomeError:
            return None
    return programme_home.DEFAULT_SERVER


def is_headless(env) -> bool:
    return (env.get("CLAUDE_CODE_ENTRYPOINT") or "").startswith("sdk")


def _herdr():
    return shutil.which("herdr")


def _pane_get(pane_id: str):
    binary = _herdr()
    if not binary:
        return None
    try:
        done = subprocess.run([binary, "pane", "get", pane_id], capture_output=True,
                              text=True, timeout=PANE_GET_TIMEOUT, stdin=subprocess.DEVNULL)
        pane = json.loads(done.stdout)["result"]["pane"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return None
    return pane if isinstance(pane, dict) else None


def _report(session_id: str, pane_id: str, source) -> None:
    binary = _herdr()
    if not binary:
        return
    argv = [binary, "pane", "report-agent-session", "--source", "auto", "--agent", "claude",
            "--agent-session-id", session_id]
    if source:
        argv += ["--session-start-source", source]
    argv.append(pane_id)
    try:
        subprocess.run(argv, capture_output=True, timeout=REPORT_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        pass


def _trimmed(rows: list) -> list:
    seen = {}
    keep = []
    for row in reversed(rows):
        pane = row.get("pane_id")
        seen[pane] = seen.get(pane, 0) + 1
        if seen[pane] <= LINES_PER_PANE:
            keep.append(row)
    keep.reverse()
    return keep


def _read_rows(path: str) -> list:
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _append(path: str, entry: dict) -> None:
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)

    def body():
        rows = _trimmed(_read_rows(path) + [entry])

        def write(fh):
            for row in rows:
                fh.write(json.dumps(row, sort_keys=True) + "\n")

        programme_home.atomic_write(path, write, ".registry.", folder)

    run_record_core._flock_run(os.path.join(folder, ".registry.lock"), body)


def record_session(hook_input: dict, env) -> dict | None:
    env_pane = env.get("HERDR_PANE_ID")
    session_id = hook_input.get("session_id")
    if not env_pane or not isinstance(session_id, str) or not session_id:
        return None
    server = server_from_socket(env.get("HERDR_SOCKET_PATH")) or programme_home.DEFAULT_SERVER
    pane = _pane_get(env_pane)
    if pane:
        pane_id = pane.get("pane_id") or env_pane
        workspace = pane.get("workspace_id") or env.get("HERDR_WORKSPACE_ID")
        resolved = "herdr"
    else:
        pane, pane_id, workspace, resolved = {}, env_pane, env.get("HERDR_WORKSPACE_ID"), "env"
    if not workspace and ":" in pane_id:
        workspace = pane_id.split(":", 1)[0]
    headless = is_headless(env)
    source = _clean(hook_input.get("source"))
    entry = {
        "at": run_record_core.now_iso(),
        "session_id": _clean(session_id),
        "pane_id": _clean(pane_id),
        "env_pane": _clean(env_pane),
        "terminal_id": _clean(pane.get("terminal_id")),
        "tab_id": _clean(pane.get("tab_id")),
        "server": server,
        "workspace": _clean(workspace),
        "source": source,
        "cwd": _clean(hook_input.get("cwd")),
        "transcript_path": _path(hook_input.get("transcript_path")),
        "interactive": not headless,
        "resolved": resolved,
    }
    path = registry_path(server, workspace)
    if not headless:
        _report(session_id, pane_id, source)
    _append(path, entry)
    return entry


def read_space(server: str, workspace: str) -> list:
    try:
        return _read_rows(registry_path(server, workspace))
    except programme_home.ProgrammeHomeError:
        return []


def _all_rows() -> list:
    try:
        folder = sessions_dir()
        names = sorted(n for n in os.listdir(folder) if n.endswith(".jsonl") and not n.startswith("."))
    except (OSError, programme_home.ProgrammeHomeError):
        return []
    rows = []
    for name in names:
        rows.extend(_read_rows(os.path.join(folder, name)))
    return rows


def session_rows(session_id) -> list:
    if not session_id:
        return []
    return [r for r in _all_rows() if r.get("session_id") == session_id]


def lookup(session_id, server=None, workspace=None, *, include_headless=False):
    if not session_id:
        return None
    def hits(rows):
        return [r for r in rows if r.get("session_id") == session_id
                and (include_headless or r.get("interactive"))]

    found = hits(read_space(server, workspace)) if server and workspace else []
    found = found or hits(_all_rows())
    if not found:
        return None
    return max(found, key=lambda r: r.get("at") or "")


def latest_rows(*, include_headless=False) -> dict:
    latest = {}
    for row in _all_rows():
        if not (include_headless or row.get("interactive")):
            continue
        sid = row.get("session_id")
        try:
            if sid in latest and latest[sid] is None:
                continue
            best = latest.get(sid)
        except TypeError:
            continue
        try:
            if best is None or (row.get("at") or "") > (best.get("at") or ""):
                latest[sid] = row
        except TypeError:
            latest[sid] = None
    return latest


def space_of_session(session_id, env):
    row = lookup(session_id, include_headless=True)
    if row and row.get("server") and row.get("workspace"):
        return row["server"], row["workspace"]
    workspace = env.get("HERDR_WORKSPACE_ID")
    if not workspace and ":" in (env.get("HERDR_PANE_ID") or ""):
        workspace = env["HERDR_PANE_ID"].split(":", 1)[0]
    if not workspace:
        return None
    server = server_from_socket(env.get("HERDR_SOCKET_PATH")) or programme_home.DEFAULT_SERVER
    return server, workspace


def driver_panes(now=None) -> list:
    out = []
    seen = set()
    for key, lease in programme_home.iter_leases():
        if not lease or lease.get("corrupt"):
            continue
        if programme_home.lease_status(lease, now) not in DRIVER_LEASE_STATES:
            continue
        marker = (lease.get("run"), lease.get("session_id"))
        if marker in seen:
            continue
        seen.add(marker)
        row = lookup(lease.get("session_id"), lease.get("server"), lease.get("workspace"))
        if row and row.get("pane_id"):
            out.append({"run": lease.get("run"), "session_id": lease.get("session_id"),
                        "pane_id": row["pane_id"], "terminal_id": row.get("terminal_id"),
                        "lease": key})
    return out


def _label(row, key) -> str | None:
    text = _clean((row or {}).get(key))
    return " ".join(text.split()) or None if text else None


def driver_presence(session_id, snap, reported, *, current_server) -> dict:
    out = {"state": "unknown", "session_id": session_id, "herdr_reachable": snap is not None,
           "registry_pane": None, "pane_in_snapshot": None, "session_reported": None,
           "pane_id": None, "pane_label": None, "tab_label": None, "why": None}
    row = lookup(session_id, include_headless=True)
    if row:
        out["registry_pane"] = row.get("pane_id")
    if snap is None:
        out["why"] = "herdr could not be read"
        return out
    panes = [p for p in snap.get("panes") or [] if isinstance(p, dict)]
    agents = [a for a in snap.get("agents") or [] if isinstance(a, dict)]
    tabs = {t.get("tab_id"): t for t in snap.get("tabs") or [] if isinstance(t, dict)}

    def named(pane):
        out.update(pane_id=_clean(pane.get("pane_id")), pane_label=_label(pane, "label"),
                   tab_label=_label(tabs.get(pane.get("tab_id")), "label"))

    hosting = next((p for p in panes + agents if session_id and reported(p) == session_id), None)
    if hosting is not None:
        named(next((p for p in panes if p.get("pane_id") == hosting.get("pane_id")), hosting))
        out.update(state="present", session_reported=session_id, pane_in_snapshot=True,
                   why=f"herdr reports the session in pane {out['pane_id']}")
        return out
    if not row or not row.get("pane_id"):
        out["why"] = "no herdr pane was ever recorded for the driving session"
        return out
    if not row.get("interactive"):
        out["why"] = "the driving session runs headless, outside a herdr pane"
        return out
    if row.get("server") != current_server:
        out["why"] = f"the driving session's pane is on herdr server {row.get('server')}, not this one"
        return out
    # A pane moved to another tab or workspace gets a new id but keeps its terminal.
    pane = next((p for p in panes if row.get("terminal_id")
                 and p.get("terminal_id") == row["terminal_id"]), None)
    pane = pane or next((p for p in panes if p.get("pane_id") == row["pane_id"]), None)
    out["pane_in_snapshot"] = pane is not None
    if pane is None:
        out.update(state="gone", pane_id=row["pane_id"],
                   why=f"pane {row['pane_id']} that ran the driving session is closed")
        return out
    named(pane)
    agent = next((a for a in agents if a.get("pane_id") == pane.get("pane_id")), None)
    now_runs = reported(pane) or reported(agent or {})
    out["session_reported"] = now_runs
    terminal = _clean(pane.get("terminal_id"))
    if now_runs and now_runs != session_id:
        out.update(state="gone", why=f"pane {out['pane_id']} now runs another session")
    elif row.get("terminal_id") and terminal and terminal != row["terminal_id"]:
        out.update(state="gone", why=f"pane {out['pane_id']} now holds a different terminal")
    else:
        # A live pane that reports no session is ambiguous: herdr loses reported sessions on restart.
        out["why"] = f"pane {out['pane_id']} is still open and herdr does not say which session it runs"
    return out


def caller_drives(record, session_id=None) -> bool:
    sid = session_id or driver_session.driving_session_id()
    if not sid or not isinstance(record, dict):
        return False
    return record.get("driving_session_id") == sid


def _cli(argv) -> int:
    if argv[:1] != ["record"]:
        return 0
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw else {}
        if isinstance(data, dict):
            record_session(data, os.environ)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

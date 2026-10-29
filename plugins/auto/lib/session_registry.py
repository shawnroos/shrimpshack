#!/usr/bin/env python3
"""Which Claude session runs in which terminal pane.

SessionStart appends one line per session to
``<data dir>/sessions/<server>.<workspace>.jsonl``, resolving the pane through
the session's terminal host (herdr, because a moved pane keeps a stale ``HERDR_PANE_ID``). Interactive sessions
are also reported to herdr, so its snapshot carries the owner.
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

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
driver_session = load_lib_module("driver_session")
terminal_host = load_lib_module("terminal_host")

LINES_PER_PANE = 50
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


def registry_path(server: str, workspace: str, host=None) -> str:
    return os.path.join(sessions_dir(), programme_home.space_key(server, workspace, host) + ".jsonl")


def process_tty(pid=None):
    return load_lib_module("host_ghostty").process_tty(pid)


def is_headless(env) -> bool:
    return (env.get("CLAUDE_CODE_ENTRYPOINT") or "").startswith("sdk")


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


def _entry(found, host):
    """The place a host proved for this session; a host that cannot (refuse) records nothing."""
    if not found.ok or not isinstance(found.value, dict):
        return None
    pane = found.value
    ids = (pane.get("pane_id"), pane.get("server"), pane.get("workspace"))
    if not all(isinstance(i, str) and i for i in ids):
        return None
    return {"pane_id": pane["pane_id"], "terminal_id": pane.get("terminal_id"), "tab_id": pane.get("tab_id"),
            "server": pane["server"], "workspace": pane["workspace"], "resolved": pane.get("resolved") or host,
            "env_pane": pane.get("env_pane") or pane["pane_id"], "tab_space_name": pane.get("tab_space_name"),
            "tty": pane.get("tty")}


def record_session(hook_input: dict, env, tty=None) -> dict | None:
    session_id = hook_input.get("session_id")
    found = terminal_host.detect(env)
    if found.name is None or not isinstance(session_id, str) or not session_id:
        return None
    place = _entry(terminal_host.host_named(found.name).own_pane(env, tty=tty), found.name)
    return _store(hook_input, env, found.name, place, tty) if place else None


def record_proven_pane(session_id, host, found, env) -> dict | None:
    """Write the row a live own_pane answer proved, for a session whose SessionStart probe failed or timed out.

    Without a row driver_panes() drops the programme's lease and the send-guard never covers the PM.
    """
    place = _entry(found, host)
    if place is None or not isinstance(session_id, str) or not session_id:
        return None
    return _store({"session_id": session_id}, env, host, place, place["tty"])


def _store(hook_input, env, host, place, tty) -> dict:
    session_id = hook_input["session_id"]
    headless = is_headless(env)
    source = _clean(hook_input.get("source"))
    entry = {
        "at": run_record_core.now_iso(),
        "session_id": _clean(session_id),
        "pane_id": _clean(place["pane_id"]),
        "env_pane": _clean(place["env_pane"]),
        "terminal_id": _clean(place["terminal_id"]),
        "tab_id": _clean(place["tab_id"]),
        "server": place["server"],
        "workspace": _clean(place["workspace"]),
        "source": source,
        "cwd": _clean(hook_input.get("cwd")),
        "transcript_path": _path(hook_input.get("transcript_path")),
        "interactive": not headless,
        "resolved": place["resolved"],
    }
    entry["host"] = host
    for key, value in (("tty", tty), ("tab_space_name", place["tab_space_name"])):
        if _clean(value):
            entry[key] = _clean(value)
    path = registry_path(entry["server"], entry["workspace"], host)
    if not headless:
        terminal_host.host_named(host).report_session(session_id, place["pane_id"], source)
    _append(path, entry)
    return entry


def read_space(server: str, workspace: str, host=None) -> list:
    try:
        return _read_rows(registry_path(server, workspace, host))
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


def lookup(session_id, server=None, workspace=None, *, include_headless=False, host=None):
    if not session_id:
        return None
    def hits(rows):
        return [r for r in rows if r.get("session_id") == session_id
                and (include_headless or r.get("interactive"))]

    found = hits(read_space(server, workspace, host)) if server and workspace else []
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


def host_of_row(row) -> str:
    return (row or {}).get("host") or programme_home.DEFAULT_HOST


def space_of_session(session_id, env, *, registry_only=False):
    """(server, workspace) for a herdr session, (server, workspace, host) for any other host.

    Without a registry row the herdr variables name the space, but a variable is not evidence of
    membership (KTD3): a gate passes registry_only=True and gets None instead.
    """
    row = lookup(session_id, include_headless=True)
    if row and row.get("server") and row.get("workspace"):
        host = host_of_row(row)
        return (row["server"], row["workspace"]) + ((host,) if host != programme_home.DEFAULT_HOST else ())
    if registry_only:
        return None
    workspace = env.get("HERDR_WORKSPACE_ID")
    if not workspace and ":" in (env.get("HERDR_PANE_ID") or ""):
        workspace = env["HERDR_PANE_ID"].split(":", 1)[0]
    if not workspace:
        return None
    server = load_lib_module("host_herdr").server_from_socket(env.get("HERDR_SOCKET_PATH")) or programme_home.DEFAULT_SERVER
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
        row = lookup(lease.get("session_id"), lease.get("server"), lease.get("workspace"),
                     host=lease.get("host"))
        if row and row.get("pane_id"):
            out.append({"run": lease.get("run"), "session_id": lease.get("session_id"),
                        "pane_id": row["pane_id"], "terminal_id": row.get("terminal_id"),
                        "host": host_of_row(row), "lease": key})
    return out


def driver_presence(session_id, snap, reported, *, current_server) -> dict:
    row = lookup(session_id, include_headless=True)
    found = terminal_host.current().presence(session_id, row, snap, reported, current_server=current_server,
                                             clean=_clean)
    if found.ok and isinstance(found.value, dict):
        return found.value
    # A host that cannot answer says unknown, never gone: only host evidence moves a lease.
    return terminal_host.presence_facts(session_id, (row or {}).get("pane_id"), reachable=snap is not None,
                                        why=found.why)


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
            host = terminal_host.current()
            tty = load_lib_module("host_" + host.name).process_tty() if host.needs_tty else None
            record_session(data, os.environ, tty)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

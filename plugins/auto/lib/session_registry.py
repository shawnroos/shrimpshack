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
import subprocess
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
# SessionStart's hook timeout is 5s; the whole walk (a few ps calls) must stay far under it.
PS_TIMEOUT = 0.5
CHAIN_DEPTH = 8
_NO_TTY = {"", "?", "??"}
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


def _ps(pid, fields):
    try:
        done = subprocess.run(["ps", "-o", fields, "-p", str(pid)], capture_output=True, text=True,
                              timeout=PS_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.split() if done.returncode == 0 else None


def process_tty(pid=None):
    """The tty of the claude process above this one, or None.

    A hook has no controlling tty, so its own tty reads "??"; only the claude ancestor's tty means
    anything. The claude process is found by argv, not comm (comm hides launcher-run processes). "??" from claude itself (headless) is None too, never a path.
    """
    pid = pid or os.getppid()
    for _ in range(CHAIN_DEPTH):
        row = _ps(pid, "ppid=,tty=,args=")
        if not row or len(row) < 3:
            return None
        parent, tty, argv0 = row[0], row[1], row[2]
        if os.path.basename(argv0) == "claude":
            return None if tty in _NO_TTY else (tty if tty.startswith("/dev/") else "/dev/" + tty)
        if not parent.isdigit() or int(parent) <= 1:
            return None
        pid = int(parent)
    return None


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


def _herdr_entry(env, env_pane):
    server = server_from_socket(env.get("HERDR_SOCKET_PATH")) or programme_home.DEFAULT_SERVER
    pane = terminal_host.host_named("herdr").own_pane(env).value["pane"]
    if pane:
        pane_id = pane.get("pane_id") or env_pane
        workspace = pane.get("workspace_id") or env.get("HERDR_WORKSPACE_ID")
        resolved = "herdr"
    else:
        pane, pane_id, workspace, resolved = {}, env_pane, env.get("HERDR_WORKSPACE_ID"), "env"
    if not workspace and ":" in pane_id:
        workspace = pane_id.split(":", 1)[0]
    return {"pane_id": pane_id, "terminal_id": pane.get("terminal_id"), "tab_id": pane.get("tab_id"),
            "server": server, "workspace": workspace, "resolved": resolved, "tab_space_name": None}


def _other_entry(found, host):
    """A non-herdr host proves the pane itself; a host that cannot (refuse) records nothing."""
    if not found.ok or not isinstance(found.value, dict):
        return None
    pane = found.value
    ids = (pane.get("pane_id"), pane.get("server"), pane.get("workspace"))
    if not all(isinstance(i, str) and i for i in ids):
        return None
    return {"pane_id": pane["pane_id"], "terminal_id": pane.get("terminal_id"), "tab_id": None,
            "server": pane["server"], "workspace": pane["workspace"], "resolved": host,
            "tab_space_name": pane.get("tab_space_name")}


def record_session(hook_input: dict, env, tty=None) -> dict | None:
    session_id = hook_input.get("session_id")
    found = terminal_host.detect(env)
    if found.name is None or not isinstance(session_id, str) or not session_id:
        return None
    host = found.name
    env_pane = env.get("HERDR_PANE_ID")
    if host == programme_home.DEFAULT_HOST:
        if not env_pane:
            return None
        place = _herdr_entry(env, env_pane)
    else:
        place = _other_entry(terminal_host.host_named(host).own_pane(env), host)
        if place is None:
            return None
        env_pane = place["pane_id"]
    headless = is_headless(env)
    source = _clean(hook_input.get("source"))
    entry = {
        "at": run_record_core.now_iso(),
        "session_id": _clean(session_id),
        "pane_id": _clean(place["pane_id"]),
        "env_pane": _clean(env_pane),
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


def host_of_session(session_id, env) -> str:
    """The host the registry recorded for the session; the environment only picks one for a session with no row (KTD3)."""
    row = lookup(session_id, include_headless=True) if session_id else None
    if row:
        return host_of_row(row)
    return terminal_host.detect(env).name or programme_home.DEFAULT_HOST


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
        row = lookup(lease.get("session_id"), lease.get("server"), lease.get("workspace"),
                     host=lease.get("host"))
        if row and row.get("pane_id"):
            out.append({"run": lease.get("run"), "session_id": lease.get("session_id"),
                        "pane_id": row["pane_id"], "terminal_id": row.get("terminal_id"),
                        "lease": key})
    return out


def driver_presence(session_id, snap, reported, *, current_server) -> dict:
    row = lookup(session_id, include_headless=True)
    found = terminal_host.current().presence(session_id, row, snap, reported, current_server=current_server,
                                             clean=_clean)
    if found.ok and isinstance(found.value, dict):
        return found.value
    # A host that cannot answer says unknown, never gone: only host evidence moves a lease.
    return {"state": "unknown", "session_id": session_id, "herdr_reachable": snap is not None,
            "registry_pane": (row or {}).get("pane_id"), "pane_in_snapshot": None, "session_reported": None,
            "pane_id": None, "pane_label": None, "tab_label": None, "why": found.why}


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
            record_session(data, os.environ, process_tty())
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

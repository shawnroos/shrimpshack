"""The herdr terminal host: every herdr command auto runs lives in this file."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

terminal_host = load_lib_module("terminal_host")
programme_exec = load_lib_module("programme_exec")
programme_sanitize = load_lib_module("programme_sanitize")

HERDR_TIMEOUT = 5.0
# SessionStart's hook timeout is 5s; both herdr calls together must stay well under it.
PANE_GET_TIMEOUT = 1.0
REPORT_TIMEOUT = 1.0
SERVER_PROBE_TIMEOUT = 1.0
NOTIFY_TIMEOUT = 5
POLL_SECONDS = 1.0
BIN_TOKENS = frozenset({"$HERDR_BIN_PATH", "${HERDR_BIN_PATH}"})
SEND_VERBS = frozenset({
    ("agent", "prompt"), ("agent", "send"), ("agent", "send-keys"),
    ("pane", "send-text"), ("pane", "send-keys"), ("pane", "run"),
})
GLOBAL_VALUE_OPTS = frozenset({"--session", "--machine", "--remote"})
VALUE_OPTS = frozenset({"--until", "--timeout", "--seq"})
_PANE_LINE = re.compile(r"herdr agent pane: (\S+)")

native, refuse = terminal_host.native, terminal_host.refuse


class HerdrHost(terminal_host.TerminalHost):
    name = "herdr"

    def installed(self) -> bool:
        return shutil.which("herdr") is not None

    def own_pane(self, env, **_):
        env_pane = env.get("HERDR_PANE_ID")
        if not env_pane:
            return refuse("this session is not in a herdr pane", fix="run Claude from a herdr pane")
        binary = shutil.which("herdr")
        pane = None
        if binary:
            try:
                done = subprocess.run([binary, "pane", "get", env_pane], capture_output=True,
                                      text=True, timeout=PANE_GET_TIMEOUT, stdin=subprocess.DEVNULL)
                pane = json.loads(done.stdout)["result"]["pane"]
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
                pane = None
        return native({"env_pane": env_pane, "pane": pane if isinstance(pane, dict) else None})

    def report_session(self, session_id, pane_id, source) -> None:
        binary = shutil.which("herdr")
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

    def list_panes(self, agents=False, **_):
        if agents:
            result = _herdr(["agent", "list"])
            if not result["ran"] or result["code"] != 0:
                return refuse("herdr agent list is unavailable")
            rows = ((programme_exec.parse_json(result["stdout"]) or {}).get("result") or {}).get("agents")
            return native([r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else None)
        result = _herdr(["status", "server"])
        if not result["ran"] or result["code"] != 0:
            return refuse(programme_exec.failure(result, "herdr status server"))
        if not any(line.strip() == "status: running" for line in result["stdout"].splitlines()):
            return refuse("herdr server is not running")
        result = _herdr(["api", "snapshot"])
        if not result["ran"] or result["code"] != 0:
            return refuse(programme_exec.failure(result, "herdr api snapshot"))
        snap = ((programme_exec.parse_json(result["stdout"]) or {}).get("result") or {}).get("snapshot")
        if not isinstance(snap, dict) or not isinstance(snap.get("panes"), list):
            return refuse("herdr api snapshot returned no pane list")
        return native(snap)

    def start_pane(self, argv, timeout, **_):
        run = programme_exec.bounded(argv, timeout)
        output = programme_sanitize.clean(run["stdout"] + "\n" + run["stderr"], 0, keep_newlines=True)
        match = _PANE_LINE.search(output)
        pane = programme_sanitize.token(match.group(1)) if match else None
        return native({"run": run, "output": output, "pane": pane})

    def confirm_started(self, session_id, pane, before, wait, session_of, **_):
        deadline = time.monotonic() + wait
        while True:
            rows = self.list_panes(agents=True).value or []
            for row in rows:
                if session_of(row) == session_id:
                    return native({"row": row})
            if pane:
                for row in rows:
                    if row.get("pane_id") == pane:
                        other = session_of(row)
                        if other and other != session_id:
                            return refuse(f"pane {pane} reports session {other}, not {session_id}",
                                          value={"row": None})
                        return native({"row": row})
            else:
                fresh = [r for r in rows if r.get("pane_id") not in before and not session_of(r)]
                if len(fresh) == 1:
                    return native({"row": fresh[0]})
            if time.monotonic() >= deadline:
                where = f"pane {pane}" if pane else "any new pane"
                return refuse(f"no agent appeared in {where} within {wait:g}s", value={"row": None})
            time.sleep(POLL_SECONDS)

    def send_prompt(self, pane, text, **_):
        sent = _herdr(["agent", "prompt", pane, text])
        if sent["ran"] and sent["code"] == 0:
            return native(sent)
        return refuse(programme_exec.failure(sent, "herdr agent prompt"), value=sent)

    def presence(self, session_id, row, snap, reported, *, current_server, clean, **_):
        out = {"state": "unknown", "session_id": session_id, "herdr_reachable": snap is not None,
               "registry_pane": None, "pane_in_snapshot": None, "session_reported": None,
               "pane_id": None, "pane_label": None, "tab_label": None, "why": None}
        if row:
            out["registry_pane"] = row.get("pane_id")
        if snap is None:
            out["why"] = "herdr could not be read"
            return native(out)
        panes = [p for p in snap.get("panes") or [] if isinstance(p, dict)]
        agents = [a for a in snap.get("agents") or [] if isinstance(a, dict)]
        tabs = {t.get("tab_id"): t for t in snap.get("tabs") or [] if isinstance(t, dict)}

        def label(entry, key):
            text = clean((entry or {}).get(key))
            return " ".join(text.split()) or None if text else None

        def named(pane):
            out.update(pane_id=clean(pane.get("pane_id")), pane_label=label(pane, "label"),
                       tab_label=label(tabs.get(pane.get("tab_id")), "label"))

        hosting = next((p for p in panes + agents if session_id and reported(p) == session_id), None)
        if hosting is not None:
            named(next((p for p in panes if p.get("pane_id") == hosting.get("pane_id")), hosting))
            out.update(state="present", session_reported=session_id, pane_in_snapshot=True,
                       why=f"herdr reports the session in pane {out['pane_id']}")
            return native(out)
        if not row or not row.get("pane_id"):
            out["why"] = "no herdr pane was ever recorded for the driving session"
            return native(out)
        if not row.get("interactive"):
            out["why"] = "the driving session runs headless, outside a herdr pane"
            return native(out)
        if row.get("server") != current_server:
            out["why"] = f"the driving session's pane is on herdr server {row.get('server')}, not this one"
            return native(out)
        # A pane moved to another tab or workspace gets a new id but keeps its terminal.
        pane = next((p for p in panes if row.get("terminal_id")
                     and p.get("terminal_id") == row["terminal_id"]), None)
        pane = pane or next((p for p in panes if p.get("pane_id") == row["pane_id"]), None)
        out["pane_in_snapshot"] = pane is not None
        if pane is None:
            out.update(state="gone", pane_id=row["pane_id"],
                       why=f"pane {row['pane_id']} that ran the driving session is closed")
            return native(out)
        named(pane)
        agent = next((a for a in agents if a.get("pane_id") == pane.get("pane_id")), None)
        now_runs = reported(pane) or reported(agent or {})
        out["session_reported"] = now_runs
        terminal = clean(pane.get("terminal_id"))
        if now_runs and now_runs != session_id:
            out.update(state="gone", why=f"pane {out['pane_id']} now runs another session")
        elif row.get("terminal_id") and terminal and terminal != row["terminal_id"]:
            out.update(state="gone", why=f"pane {out['pane_id']} now holds a different terminal")
        else:
            # A live pane that reports no session is ambiguous: herdr loses reported sessions on restart.
            out["why"] = f"pane {out['pane_id']} is still open and herdr does not say which session it runs"
        return native(out)

    def change_token(self, read_json, **_):
        data, err = read_json(["herdr", "api", "snapshot"])
        if err:
            return refuse(err)
        snapshot = (data.get("result") or {}).get("snapshot") if isinstance(data.get("result"), dict) else None
        if not isinstance(snapshot, dict):
            return refuse("bad-json")
        return native(snapshot)

    def notify(self, title, body, **_):
        path = shutil.which("herdr")
        if path is None:
            return refuse("herdr not found on PATH", value=None)
        argv = [path, "notification", "show", title, "--body", body, "--sound", "request"]
        try:
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=NOTIFY_TIMEOUT, check=False)
        except subprocess.TimeoutExpired:
            return refuse("herdr notification timed out", value="timeout")
        except OSError:
            return refuse("herdr notification could not run", value=None)
        return native(done.returncode)

    def is_host_command(self, argv, pane_ids=()):
        if not argv or not (argv[0] in BIN_TOKENS or os.path.basename(argv[0]) == "herdr"):
            return None
        rest, i = list(argv[1:]), 0
        while i < len(rest) and rest[i].startswith("-"):
            i += 2 if rest[i] in GLOBAL_VALUE_OPTS else 1
        if i + 1 >= len(rest) or (rest[i], rest[i + 1]) not in SEND_VERBS:
            return None
        j = i + 2
        while j < len(rest):
            if rest[j] in VALUE_OPTS:
                j += 2
            elif rest[j].startswith("-"):
                j += 1
            else:
                return f"{rest[i]} {rest[i + 1]}", rest[j]
        return None


def _herdr(args):
    return programme_exec.bounded(["herdr"] + list(args), programme_exec.source_timeout(HERDR_TIMEOUT))


def server_running() -> bool:
    binary = shutil.which("herdr")
    if not binary:
        return False
    try:
        done = subprocess.run([binary, "status", "server"], capture_output=True, text=True,
                              timeout=SERVER_PROBE_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(line.strip() == "status: running" for line in done.stdout.splitlines())

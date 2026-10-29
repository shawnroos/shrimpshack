"""The one door from auto to a terminal host (herdr today; Rex and Ghostty next).

Every method on a host returns a HostResult, never a bare value, so a caller
cannot mistake "this host cannot do that" for an empty answer.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

HOSTS = ("herdr", "rex", "ghostty")
STATUSES = ("native", "degraded", "refuse")
# is_host_command has no row: its per-host coverage is a required test, not a table cell.
CAPABILITY_OF = {"own_pane": "find_own_pane", "list_panes": "list_panes", "start_pane": "start_pane",
                 "confirm_started": "confirm_started", "send_prompt": "send_prompt",
                 "presence": "presence", "change_token": "change_signal", "notify": "notify"}
_NEW_PANE_LINE = re.compile(r"^[ \t]*(?:\u25b8[ \t]+)?agent pane: ([a-z]+) (\S+)", re.MULTILINE)
_OLD_PANE_LINE = re.compile(r"herdr agent pane: (\S+)")


def agent_pane(output: str, host: str):
    """The pane id spinoff reported for `host`, from the new `agent pane: <host> <id>` line or herdr's older line."""
    for found_host, pane in _NEW_PANE_LINE.findall(output):
        if found_host == host:
            return pane
    if host == "herdr":
        old = _OLD_PANE_LINE.search(output)
        return old.group(1) if old else None
    return None


TABLE_PATH = os.path.join(_LIB_DIR, "terminal_host_capabilities.json")


class HostResult:
    __slots__ = ("status", "why", "fix", "value")

    def __init__(self, status, why=None, fix=None, value=None):
        if status not in STATUSES:
            raise ValueError(f"unknown host status {status!r}")
        self.status, self.why, self.fix, self.value = status, why, fix, value

    @property
    def ok(self) -> bool:
        return self.status != "refuse"


def native(value=None, why=None) -> HostResult:
    return HostResult("native", why=why, value=value)


def degraded(why, value=None) -> HostResult:
    return HostResult("degraded", why=why, value=value)


def refuse(why, fix=None, value=None) -> HostResult:
    return HostResult("refuse", why=why, fix=fix, value=value)


def capability_table() -> dict:
    with open(TABLE_PATH) as fh:
        return json.load(fh)["capabilities"]


def presence_facts(session_id, registry_pane=None, reachable=False, **over) -> dict:
    """The one shape every host's presence() answers in; a host fills in only what it proved."""
    return dict({"state": "unknown", "session_id": session_id, "herdr_reachable": reachable,
                 "registry_pane": registry_pane, "pane_in_snapshot": None, "session_reported": None,
                 "pane_id": None, "pane_label": None, "tab_label": None, "why": None}, **over)


def pane_result(run: dict, host: str) -> dict:
    """A finished spinoff run as {run, output, pane}; the pane is the id on its `agent pane: <host> <id>` line, or None."""
    programme_sanitize = load_lib_module("programme_sanitize")
    output = programme_sanitize.clean(run["stdout"] + "\n" + run["stderr"], 0, keep_newlines=True)
    found = agent_pane(output, host)
    return {"run": run, "output": output, "pane": programme_sanitize.token(found) if found else None}


def spinoff_pane(host: str, argv, timeout) -> dict:
    """Run spinoff with `host`'s launcher named."""
    cmd = list(argv)
    if "--launcher" not in cmd:
        cmd += ["--launcher", host]
    return pane_result(load_lib_module("programme_exec").bounded(cmd, timeout), host)


def confirm_via_registry(host: str, place: str, why_degraded: str, session_id, pane, wait, poll=1.0) -> "HostResult":
    """Degraded confirm for a host that lists no agent sessions: the worker's own SessionStart row is the proof."""
    registry = load_lib_module("session_registry")
    deadline = time.monotonic() + wait
    while True:
        row = registry.lookup(session_id, include_headless=True)
        if row:
            if registry.host_of_row(row) != host or (pane and row.get("pane_id") != pane):
                return refuse(f"session {session_id} registered in {row.get('pane_id')}, not {place} {pane}",
                              value={"row": None})
            return degraded(why_degraded, value={"row": row})
        if time.monotonic() >= deadline:
            return refuse(f"no SessionStart row for session {session_id} appeared within {wait:g}s", value={"row": None})
        time.sleep(poll)


class TerminalHost:
    name = ""
    binaries = ()

    def _unimplemented(self, method) -> HostResult:
        cell = capability_table()[CAPABILITY_OF[method]][self.name]
        return refuse(f"the {self.name} terminal host does not support this yet",
                      fix=cell.get("fix") or cell.get("how"))

    def own_pane(self, env, **_) -> HostResult:
        return self._unimplemented("own_pane")

    def list_panes(self, **_) -> HostResult:
        return self._unimplemented("list_panes")

    def start_pane(self, *_, **__) -> HostResult:
        return self._unimplemented("start_pane")

    def confirm_started(self, *_, **__) -> HostResult:
        return self._unimplemented("confirm_started")

    def send_prompt(self, *_, **__) -> HostResult:
        return self._unimplemented("send_prompt")

    def presence(self, *_, **__) -> HostResult:
        return self._unimplemented("presence")

    def change_token(self, *_, **__) -> HostResult:
        return self._unimplemented("change_token")

    def notify(self, *_, **__) -> HostResult:
        return self._unimplemented("notify")

    def is_host_command(self, argv, pane_ids=()):
        """(verb, target) when ``argv`` (one simple command) types into a pane, else None.

        The default denies: any call to one of this host's binaries that names a pane id is a send.
        A host with a real verb list overrides this and still falls back to it.
        """
        if not argv or os.path.basename(argv[0]) not in self.binaries:
            return None
        for token in argv[1:]:
            folded = token.casefold()
            for ident in pane_ids:
                if ident and ident.casefold() in folded:
                    return "send", ident
        return None

    def is_piped_script(self, argv, text, pane_ids=(), strict=False):
        """Like is_host_command for a command whose script arrives on stdin: ``text`` is everything the shell sees.

        strict is for a session that is not the programme's PM: the host then allows only what it can prove harmless.
        """
        return None

    def installed(self) -> bool:
        return any(shutil.which(b) for b in self.binaries)

    def report_session(self, session_id, pane_id, source) -> None:
        return None


TEST_HOST_ENV = "AUTO_TEST_HOST"
FALLBACK_HOST = "herdr"
_FIX_BOTH = "start Claude inside one multiplexer only: unset HERDR_PANE_ID and HERDR_ENV, or unset REX_SESSION"
_FIX_CMUX = "run Claude from a herdr pane, a Rex session or a Ghostty window; cmux is not supported"

_hosts = {}
_server_probe = []


class Detection:
    """What the session environment announces. A name of None means auto must refuse; `why` and `fix` then say how."""
    __slots__ = ("name", "announced", "why", "fix")

    def __init__(self, name=None, announced=False, why=None, fix=None):
        self.name, self.announced, self.why, self.fix = name, announced, why, fix


def key_hosts() -> tuple:
    """Hosts a space key may carry. stub exists only while AUTO_TEST_HOST selects it, so no production state names it."""
    return HOSTS + (("stub",) if os.environ.get(TEST_HOST_ENV) == "stub" else ())


def _herdr_server_up() -> bool:
    if not _server_probe:
        _server_probe.append(load_lib_module("host_herdr").server_running())
    return _server_probe[0]


def detect(env=None) -> Detection:
    """Environment variables only SELECT a host module (KTD3); the host module then proves the pane from its own host."""
    env = os.environ if env is None else env
    if env.get(TEST_HOST_ENV) == "stub":
        return Detection("stub", True)
    announced = [name for name, hit in (("herdr", env.get("HERDR_PANE_ID") or env.get("HERDR_ENV")),
                                        ("rex", env.get("REX_SESSION"))) if hit]
    if len(announced) == 2:
        return Detection(None, True, "this session announces both herdr and Rex, so auto cannot tell which host to type into",
                         _FIX_BOTH)
    if announced:
        return Detection(announced[0], True)
    if env.get("CMUX_WORKSPACE_ID"):
        return Detection(None, True, "this session runs in cmux, which auto does not support", _FIX_CMUX)
    if env.get("TERM_PROGRAM") == "ghostty":
        return Detection("herdr" if _herdr_server_up() else "ghostty", True)
    return Detection(FALLBACK_HOST, False)


class RefusedHost(TerminalHost):
    """Stands in when detection refuses: every capability answers refuse with the detection's fix line."""
    name = ""

    def __init__(self, detection):
        self._detection = detection

    def _unimplemented(self, method) -> HostResult:
        return refuse(self._detection.why, fix=self._detection.fix)

    def installed(self) -> bool:
        return False


def _build(name) -> TerminalHost:
    return getattr(load_lib_module(f"host_{name}"), name.capitalize() + "Host")()


def host_named(name) -> TerminalHost:
    if name not in _hosts:
        _hosts[name] = _build(name)
    return _hosts[name]


def current(env=None) -> TerminalHost:
    found = detect(env)
    return RefusedHost(found) if found.name is None else host_named(found.name)

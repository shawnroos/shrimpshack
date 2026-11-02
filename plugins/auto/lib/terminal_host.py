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
                 "presence": "presence", "change_token": "change_signal", "notify": "notify",
                 "close_pane": "close_pane"}
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
    # Only a host that matches a session to its terminal by tty makes the SessionStart hook walk ps.
    needs_tty = False

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

    def wake_source(self):
        """An object with start, due, begin_read and close that lets the watcher skip quiet reads, or None to poll."""
        return None

    def notify(self, *_, **__) -> HostResult:
        return self._unimplemented("notify")

    def close_pane(self, pane, **_) -> HostResult:
        return self._unimplemented("close_pane")

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

    def is_piped_script(self, argv, text, pane_ids=()):
        """Like is_host_command for a command whose script arrives on stdin: ``text`` is everything the shell sees."""
        return None

    def send_class(self, argv, text=""):
        """None when ``argv`` is not a call to this host's command, else (kind, targets).

        kind is "read" (cannot type into a pane), "send" (can) or "unknown" (not told apart, so treated as a send).
        targets are the literal pane ids the call names, or None when any target is runtime-built, missing or hidden
        in a script on stdin or in a file. The send-guard's one policy decides what to do with the answer.
        """
        if not argv or os.path.basename(argv[0]) not in self.binaries:
            return None
        return "unknown", None

    def installed(self) -> bool:
        return any(shutil.which(b) for b in self.binaries)

    def report_session(self, session_id, pane_id, source) -> None:
        return None


TEST_HOST_ENV = "AUTO_TEST_HOST"
FALLBACK_HOST = "herdr"
_FIX_AMBIGUOUS = ("prefix the command with `env -u REX_SESSION` to use herdr or `env -u HERDR_PANE_ID -u HERDR_ENV` to use Rex, "
                  "or start Claude inside one multiplexer only")
_PROOF_ENV = ("HERDR_PANE_ID", "HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_WORKSPACE_ID", "REX_SESSION", "REX_BLOCK")
_FIX_CMUX = "run Claude from a herdr pane, a Rex session or a Ghostty window; cmux is not supported"

_hosts = {}
_server_probe = []
# Only a Detection that resolved to a host is kept: a refused one returns RefusedHost, which never reaches a host module.
_proved = {}


class Detection:
    """What the session environment announces. A name of None means auto must refuse; `why` and `fix` then say how.

    `proof` is the own_pane answer that selected the host when two hosts were announced, so a caller does not probe twice.
    """
    __slots__ = ("name", "announced", "why", "fix", "proof", "rung")

    def __init__(self, name=None, announced=False, why=None, fix=None, proof=None, rung=None):
        self.name, self.announced, self.why, self.fix, self.proof, self.rung = name, announced, why, fix, proof, rung


def key_hosts() -> tuple:
    """Hosts a space key may carry. stub exists only while AUTO_TEST_HOST selects it, so no production state names it."""
    return HOSTS + (("stub",) if os.environ.get(TEST_HOST_ENV) == "stub" else ())


RUNG_LIVE = "live proof"
RUNG_INSTALLED = "only announced host installed"
RUNG_ROW = "this session's registry row"
# A host picked by these was not proven to hold this session's pane, so nothing may record a pane for it.
FALLBACK_RUNGS = (RUNG_INSTALLED, RUNG_ROW)


# The environment variable that names a host's pane, and the registry field that kept its value at record time.
_ROW_PANE_FIELD = {"herdr": ("HERDR_PANE_ID", "env_pane"), "rex": ("REX_BLOCK", "pane_id")}


def _herdr_server_up() -> bool:
    if not _server_probe:
        _server_probe.append(load_lib_module("host_herdr").server_running())
    return _server_probe[0]


def _proves(name, found) -> bool:
    """herdr answers `resolved: env` when its own lookup failed, and that echo of the environment is not proof."""
    if not found.ok or not isinstance(found.value, dict):
        return False
    return found.value.get("resolved") == "herdr" if name == "herdr" else True


def _tell_apart(env) -> Detection:
    key = tuple(env.get(k) for k in _PROOF_ENV) + (env.get("PATH"), env.get("CLAUDE_CODE_SESSION_ID"))
    if key in _proved:
        return _proved[key]
    answers = {name: host_named(name).own_pane(env) for name in ("herdr", "rex")}
    proven = [name for name, found in answers.items() if _proves(name, found)]
    if len(proven) == 1:
        _proved[key] = Detection(proven[0], True, proof=answers[proven[0]], rung=RUNG_LIVE)
        return _proved[key]
    if proven:
        return Detection(None, True, "both herdr and Rex prove this session's pane, so auto cannot tell which one to type into",
                         _FIX_AMBIGUOUS)
    installed = [name for name in ("herdr", "rex") if host_named(name).installed()]
    # Fallback picks are never memoised: the registry row and the installed set can change under a long-lived watcher.
    if len(installed) == 1:
        return Detection(installed[0], True, rung=RUNG_INSTALLED)
    recorded = _recorded_host(env, installed)
    if recorded:
        return Detection(recorded, True, rung=RUNG_ROW)
    facts = ("neither the herdr nor the Rex command is on PATH" if not installed else
             "both commands are installed and the session registry has no interactive row for this session")
    return Detection(None, True, f"this session announces both herdr and Rex, and neither herdr nor Rex could prove its pane; {facts}",
                     _FIX_AMBIGUOUS)


def _recorded_host(env, installed) -> str | None:
    """The host this session's own registry row names, when its command is installed and the row was written under
    the same pane variable this environment still carries.

    `claude --resume` reuses the session id, so the id alone would let an old herdr row decide for a session that
    now runs in Rex. A broken registry file must not turn a refusal into a crash, so any failure means no answer.
    """
    sid = env.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return None
    try:
        registry = load_lib_module("session_registry")
        row = registry.lookup(sid)
        host = registry.host_of_row(row) if row else None
    except Exception:  # noqa: BLE001
        return None
    if host not in installed:
        return None
    variable, field = _ROW_PANE_FIELD[host]
    return host if not env.get(variable) or env[variable] == row.get(field) else None


def detect(env=None) -> Detection:
    """Environment variables only SELECT a host module (KTD3); the host module then proves the pane from its own host.

    When the environment announces both herdr and Rex, each host's own proof decides; only one proving selects it.
    """
    env = os.environ if env is None else env
    if env.get(TEST_HOST_ENV) == "stub":
        return Detection("stub", True)
    announced = [name for name, hit in (("herdr", env.get("HERDR_PANE_ID") or env.get("HERDR_ENV")),
                                        ("rex", env.get("REX_SESSION"))) if hit]
    if len(announced) == 2:
        return _tell_apart(env)
    if announced:
        return Detection(announced[0], True)
    if env.get("CMUX_WORKSPACE_ID"):
        return Detection(None, True, "this session runs in cmux, which auto does not support", _FIX_CMUX)
    if env.get("TERM_PROGRAM") == "ghostty":
        return Detection("herdr" if _herdr_server_up() else "ghostty", True)
    return Detection(FALLBACK_HOST, False)


def explain(env=None) -> dict:
    """The facts behind detect() for this session, for a person whose session was refused. Reads only; writes nothing."""
    env = os.environ if env is None else env
    found = detect(env)
    return {"host": found.name, "decided_by": found.rung or ("environment" if found.name else None),
            "why": found.why, "fix": found.fix,
            "announced": [n for n, hit in (("herdr", env.get("HERDR_PANE_ID") or env.get("HERDR_ENV")),
                                           ("rex", env.get("REX_SESSION"))) if hit],
            "installed": [n for n in ("herdr", "rex") if host_named(n).installed()],
            "session_id_set": bool(env.get("CLAUDE_CODE_SESSION_ID"))}


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

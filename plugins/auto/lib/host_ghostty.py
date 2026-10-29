"""The Ghostty terminal host: every osascript command auto runs lives in this file.

Ghostty has no screen-read verb and no change feed, so most answers are degraded. How ids line up:
  * spinoff reports a launched worker as `agent pane: ghostty <terminal id>`, the AppleScript `id of terminal`.
  * the registry's pane_id is that same terminal id and its terminal_id is the terminal's tty path, so the
    send-guard matches either; the space is local + the window id (a terminal has no back-pointer, so the
    window is found by scanning).
  * a session finds its own terminal by tty only (R11): the SessionStart hook walks to the claude process
    and passes that tty in. GHOSTTY_* variables are never read (KTD3: GHOSTTY_SURFACE_ID matches no terminal id).
  * presence is the recorded tty plus the terminal's foreground pid mapped to a session by claude's own
    ~/.claude/sessions/<pid>.json (KTD6).
"""
from __future__ import annotations

import hashlib
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

terminal_host = load_lib_module("terminal_host")
programme_exec = load_lib_module("programme_exec")
programme_sanitize = load_lib_module("programme_sanitize")

LIST_TIMEOUT = 1.0
SEND_TIMEOUT = 3.0
# SessionStart allows 5s and own_pane is its only osascript call; the first call after Ghostty idles measured 1.26s.
OWN_PANE_TIMEOUT = 3.0
# SessionStart's hook timeout is 5s; the whole ps walk (a few calls) must stay far under it.
PS_TIMEOUT = 0.5
CHAIN_DEPTH = 8
SPACE_SERVER = "local"
RS, US = "\x1e", "\x1f"
MAX_TERMINALS = 256
SESSION_FILE_CAP = 65536
# Matched on casefolded text with whitespace collapsed; the run-together spellings are the JXA method names, and
# System Events types into whatever app is frontmost, Ghostty included.
SEND_VERBS = ("input text", "send key", "perform action", "send mouse", "inputtext", "sendkey", "performaction", "sendmouse",
              "keystroke", "key code")
# A send that picks its terminal without naming an id still reaches the PM's terminal.
BROADCAST = re.compile(r"\b(every terminal|terminals|focused terminal|front window|selected tab|(first|last|some) terminal"
                       r"|terminal \d+)\b")
OSASCRIPT_TOKENS = frozenset({"$OSASCRIPT", "${OSASCRIPT}"})
_REDIRECTS = frozenset({"<", "<<", "<<-", "<<<"})
_FILE_LIKE = re.compile(r"^-[ls]|^[./~]|\.(?:scpt|scptd|applescript|js|jxa)$")
_VALUE_OPTS = frozenset({"-e", "-l", "-s"})
# Anything a worker's osascript may not contain: it could name Ghostty or a terminal, build a name from pieces, or run
# code that was not written on the command line.
_FORBIDDEN = ("ghostty", "terminal", "&", "+", "run script", "do shell script", "system events", "evaluate", "objc")
# The one send a non-PM session may make: a single line, one literal id (the shell may have stripped its quotes).
_OTHER_SEND = re.compile(r"""^-e tell application [\\"']*ghostty[\\"']* to (?:input text|send key) """
                         r"""(?:"[^"&()\\]*"|[^"&()'\\]*?) to terminal id [\\"']*(?P<id>[a-z0-9._-]+)[\\"']*(?: --.*)?$""")
_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
_NO_TTY = ("", "??", "?", "-")
_OWN_PANE = {}

# Scripts are constants and every value arrives in argv after "--" (a leading dash is not an option), so no text
# is ever interpolated into AppleScript. The first line is a marker the test fakes match on. pgrep guards the
# tell block because AppleScript launches an app it addresses, and `application "Ghostty" is running` answered
# false for a running Ghostty here.
LIST_SCRIPT = """-- auto-ghostty-list
on run argv
	try
		do shell script "pgrep -xq ghostty"
	on error
		return ""
	end try
	set us to character id 31
	set rs to character id 30
	set out to ""
	tell application "Ghostty"
		repeat with w in windows
			set wid to id of w as text
			repeat with tb in tabs of w
				repeat with t in terminals of tb
					try
						set out to out & wid & us & (id of t as text) & us & (tty of t as text) & us & (pid of t as text) & us & (name of t as text) & rs
					end try
				end repeat
			end repeat
		end repeat
	end tell
	return out
end run"""
SEND_SCRIPT = """-- auto-ghostty-send
on run argv
	try
		do shell script "pgrep -xq ghostty"
	on error
		return "error=ghostty-not-running"
	end try
	tell application "Ghostty"
		repeat with tt in terminals
			try
				if (id of tt as text) is (item 1 of argv) then
					input text (item 2 of argv) to tt
					try
						send key "enter" to tt
					on error
						return "partial=text-typed"
					end try
					return "sent"
				end if
			end try
		end repeat
	end tell
	return "error=terminal-not-found"
end run"""

_READ_ONLY = re.compile(re.escape(re.sub(r"\s+", " ", LIST_SCRIPT.casefold())))



native, degraded, refuse = terminal_host.native, terminal_host.degraded, terminal_host.refuse
_UNSET = object()


class GhosttyHost(terminal_host.TerminalHost):
    name = "ghostty"
    binaries = ("osascript",)
    needs_tty = True

    def installed(self) -> bool:
        return shutil.which("osascript") is not None

    def _fix(self, method) -> str:
        return terminal_host.capability_table()[terminal_host.CAPABILITY_OF[method]]["ghostty"].get("fix")

    def _refusal(self, method, failure, value=None):
        return refuse(failure["why"], fix=self._fix(method) if failure["kind"] == "denied" else failure["fix"], value=value)

    def own_pane(self, env, tty=_UNSET, **_):
        if not self.installed():
            return refuse("osascript is not on PATH, so auto cannot read Ghostty", fix=self._fix("own_pane"))
        if tty is _UNSET:
            tty = process_tty()
        if not tty or tty in _NO_TTY:
            return refuse("this session's claude process has no tty to match against a Ghostty terminal",
                          fix="run Claude interactively inside a Ghostty window or tab, not headless or through a remote shell")
        found, failure = _terminals(OWN_PANE_TIMEOUT)
        if found is None:
            return self._refusal("own_pane", failure)
        mine = next((t for t in found if t["tty"] == tty), None)
        if mine is None:
            return refuse(f"Ghostty reports no terminal on {tty}, so this session is not in a Ghostty terminal auto can find",
                          fix="run Claude directly in a Ghostty window or tab: tmux, screen, ssh and other terminal apps hide the tty")
        workspace = _segment(mine["window"])
        if workspace is None:
            return refuse(f"Ghostty window id {mine['window']!r} cannot name a space", fix=self._fix("own_pane"))
        return degraded("matched by tty, never by GHOSTTY_* variables",
                        value={"pane_id": mine["id"], "terminal_id": mine["tty"], "tty": mine["tty"], "server": SPACE_SERVER,
                               "workspace": workspace, "tab_space_name": mine["name"] or None})

    def list_panes(self, agents=False, **_):
        if agents:
            return degraded("Ghostty does not report which agent session a terminal runs", value=[])
        found, failure = _terminals(LIST_TIMEOUT)
        if found is None:
            return self._refusal("list_panes", failure)
        return native(_snapshot(found, with_seq=False, own=None))

    def start_pane(self, argv, timeout, **_):
        launched = terminal_host.spinoff_pane("ghostty", argv, timeout)
        denied = launched["run"]["ran"] and launched["run"]["code"] != 0 and _denied(launched["output"])
        if denied:
            return refuse("macOS denied Automation control of Ghostty", fix=self._fix("start_pane"), value=launched)
        return native(launched)

    def confirm_started(self, session_id, pane, before, wait, session_of, **_):
        return terminal_host.confirm_via_registry(
            "ghostty", "Ghostty terminal", "Ghostty does not list agent sessions, so the worker's own SessionStart row confirms it",
            session_id, pane, wait)

    def send_prompt(self, pane, text, **_):
        if not self.installed() or not pane:
            return refuse("osascript is not on PATH, or no terminal was named", fix=self._fix("send_prompt"),
                          value=programme_exec.not_run("no osascript or no terminal id"))
        sent = programme_exec.bounded(["osascript", "-e", SEND_SCRIPT, "--", pane, text], SEND_TIMEOUT)
        if sent["ran"] and sent["code"] == 0 and sent["stdout"].strip() == "sent":
            return native(sent)
        failure = _failure_of(sent, "osascript send")
        if sent["ran"] and sent["code"] == 0 and sent["stdout"].strip() == "partial=text-typed":
            failure = {"kind": "error", "why": "Ghostty typed the prompt but could not press enter",
                       "fix": "check the terminal's input line before sending again: the text is already there"}
            sent = dict(sent, text_typed=True)
        elif sent["ran"] and sent["code"] == 0:
            failure = {"kind": "gone", "why": f"Ghostty has no terminal {pane} ({sent['stdout'].strip() or 'no answer'})",
                       "fix": "list the live terminals with the host's list verb and prompt one of them"}
        return self._refusal("send_prompt", failure, value=sent)

    def presence(self, session_id, row, snap, reported, **_):
        out = terminal_host.presence_facts(session_id, (row or {}).get("pane_id"))
        if not self.installed():
            out["why"] = "osascript is not on PATH, so auto cannot read Ghostty"
            return native(out)
        out.update(_probe(session_id, row))
        return native(out)

    def change_token(self, read_json, **_):
        found, failure = _terminals(LIST_TIMEOUT)
        if found is None:
            return self._refusal("change_token", failure)
        own = _own_pane_id(os.environ.get("CLAUDE_CODE_SESSION_ID"))
        return degraded("Ghostty has no change feed, so the terminal list is polled", value=_snapshot(found, with_seq=True, own=own))

    def notify(self, title, body, **_):
        return degraded("Ghostty has no notification command, so the ask stays in the journal and the tracker",
                        value="journal")

    def is_host_command(self, argv, pane_ids=()):
        if not _is_osascript(argv):
            return None
        return _classify(" ".join(argv[1:]), pane_ids)

    def is_piped_script(self, argv, text, pane_ids=(), strict=False):
        if not _is_osascript(argv):
            return None
        if strict:
            return _unlisted(argv[1:], pane_ids)
        if not _reads_stdin(argv[1:]):
            return None
        return _classify(text, pane_ids)


def _is_osascript(argv) -> bool:
    return bool(argv) and (argv[0] in OSASCRIPT_TOKENS or os.path.basename(argv[0]) == "osascript")


def _reads_stdin(args) -> bool:
    """True when osascript has neither -e text nor a script file, so its script arrives on stdin (pipe, heredoc, redirect)."""
    i, has_script = 0, False
    while i < len(args):
        tok = args[i]
        if tok in _REDIRECTS or tok in _VALUE_OPTS:
            has_script = has_script or tok == "-e"
            i += 2
            continue
        has_script = has_script or not tok.startswith("-")
        i += 1
    return not has_script


def _fold(text, keep_lines=False) -> str:
    """Casefolded text with AppleScript line continuations joined; whitespace collapsed unless lines are kept."""
    out = re.sub(r"\u00ac[ \t]*\r?\n[ \t]*", " ", text.casefold())
    return out if keep_lines else re.sub(r"\s+", " ", out)


def _classify(text, pane_ids):
    """(verb, target) when ``text`` is an osascript script that may type into a driver's terminal."""
    folded = _READ_ONLY.sub("", _fold(text))
    verb = next((v for v in SEND_VERBS if v in folded), None)
    for ident in pane_ids:
        if ident and _names(folded, ident):
            return verb or "script", ident
    first = next((i for i in pane_ids if i), None)
    if not first:
        return None
    if verb in ("keystroke", "key code") or (verb and BROADCAST.search(folded)):
        return verb, first
    return None


def _unlisted(args, pane_ids):
    """Allow-list for a session that is not the PM while a driver pane is live: only a literal -e script that is auto's
    list script, one send to a different literal terminal id, or text that cannot reach a terminal. Everything else is a hit."""
    first = next((i for i in pane_ids if i), None)
    if not first:
        return None
    deny = ("unlisted osascript", first)
    if not args or args[0] != "-e" or any(t in _REDIRECTS or _FILE_LIKE.search(t) for t in args):
        return deny
    raw = _fold(" ".join(args), keep_lines=True)
    folded = _fold(" ".join(args))
    if folded in ("-e " + _fold(LIST_SCRIPT), "-e " + _fold(LIST_SCRIPT) + " --"):
        return None
    if "\n" not in raw and "\r" not in raw:
        match = _OTHER_SEND.match(folded)
        if match:
            return deny if _hits_driver(match.group("id"), folded, pane_ids) else None
    text = folded[3:]
    if any(w in text for w in _FORBIDDEN + SEND_VERBS) or any(i and _names(folded, i) for i in pane_ids):
        return deny
    return None


def _hits_driver(ident, folded, pane_ids) -> bool:
    """True when the literal id is, contains or is part of a driver's id or tty, or the text names one."""
    for driver in pane_ids:
        low = (driver or "").casefold()
        if low and (ident in low or low in ident or _names(folded, driver)):
            return True
    return False



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
            return None if tty in ("", "?", "??") else (tty if tty.startswith("/dev/") else "/dev/" + tty)
        if not parent.isdigit() or int(parent) <= 1:
            return None
        pid = int(parent)
    return None


def _own_pane_id(session_id):
    """The PM's own title changes every turn; counting it would wake the PM on its own output. A watcher's row never
    changes while it runs, so the registry is read once per session instead of once per poll."""
    if session_id not in _OWN_PANE:
        row = load_lib_module("session_registry").lookup(session_id, include_headless=True)
        _OWN_PANE[session_id] = (row or {}).get("pane_id") if (row or {}).get("host") == "ghostty" else None
    return _OWN_PANE[session_id]


def _denied(text) -> bool:
    return "-1743" in text or "not authorized to send apple events" in text.casefold()


def _failure_of(result, what) -> dict:
    """Why an osascript call did not answer. Only `denied` and `timeout` and `error` mean the call itself failed."""
    text = (result["stderr"] or "") + (result["stdout"] or "")
    if result["ran"] and _denied(text):
        return {"kind": "denied", "why": "macOS denied Automation control of Ghostty", "fix": None}
    if result["timed_out"]:
        return {"kind": "timeout", "why": result["error"],
                "fix": "check that Ghostty responds, then run the command again"}
    return {"kind": "error", "why": programme_exec.failure(result, what),
            "fix": "check that Ghostty is installed and running, then run the command again"}


def _segment(value):
    return value if isinstance(value, str) and _SEGMENT.match(value) and "--" not in value else None


def _terminals(timeout):
    """(terminals, None), or (None, failure). No Ghostty running is an honest empty list, not a failure."""
    result = programme_exec.bounded(["osascript", "-e", LIST_SCRIPT, "--"], timeout)
    if not result["ran"] or result["code"] != 0:
        return None, _failure_of(result, "osascript list")
    terminals = []
    for record in result["stdout"].split(RS)[:MAX_TERMINALS]:
        fields = record.strip("\n").split(US, 4)
        if len(fields) != 5 or not fields[1] or not fields[0]:
            continue
        window, ident, tty, pid, name = fields
        terminals.append({"window": window, "id": ident, "tty": tty,
                          "pid": int(pid) if pid.isdigit() else None, "name": programme_sanitize.clean(name, 80)})
    return terminals, None


def _snapshot(terminals, with_seq, own) -> dict:
    """The herdr-shaped snapshot the sweep and the remit watcher read; seq is a hash of the terminal's name and foreground pid."""
    panes, agents = [], []
    for t in terminals:
        panes.append({"pane_id": t["id"], "workspace_id": t["window"], "tab_id": None, "label": t["name"],
                      "terminal_id": t["tty"]})
        if with_seq and t["id"] != own:
            digest = hashlib.sha256(f"{t['id']}\0{t['name']}\0{t['pid']}".encode()).hexdigest()
            agents.append({"pane_id": t["id"], "state_change_seq": int(digest[:12], 16)})
    return {"panes": panes, "agents": agents, "tabs": []}


def _sessions_dir() -> str:
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "sessions")


def _session_of_pid(pid):
    """The Claude session id running as `pid`, from Claude's own pid file, or None when that file says nothing about it."""
    try:
        with open(os.path.join(_sessions_dir(), f"{pid}.json")) as fh:
            data = json.loads(fh.read(SESSION_FILE_CAP))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("pid") != pid or not isinstance(data.get("sessionId"), str):
        return None
    return data["sessionId"]


def _probe(session_id, row) -> dict:
    """Presence facts for the driving session. Gone needs one of two Ghostty facts; everything else is unknown (R16)."""
    tty = (row or {}).get("tty")
    if not row or (row.get("host") or "") != "ghostty" or not tty:
        return {"why": "no Ghostty tty was ever recorded for the driving session"}
    if not row.get("interactive"):
        return {"why": "the driving session runs headless, outside a Ghostty terminal"}
    found, failure = _terminals(LIST_TIMEOUT)
    if found is None:
        return {"why": f"Ghostty could not be read ({failure['why']})"}
    base = {"herdr_reachable": True}
    mine = next((t for t in found if t["tty"] == tty), None)
    if mine is None:
        return dict(base, state="gone", pane_in_snapshot=False, pane_id=row.get("pane_id"),
                    why=f"{tty}, where the driving session ran, is no longer a Ghostty terminal")
    named = dict(base, pane_in_snapshot=True, pane_id=mine["id"], pane_label=mine["name"])
    if mine["pid"] is None:
        return dict(named, why=f"the foreground process of the terminal on {tty} could not be read")
    owner = _session_of_pid(mine["pid"])
    if owner is None:
        return dict(named, why=f"process {mine['pid']} in the terminal on {tty} is not a Claude session auto can name")
    if owner != session_id:
        return dict(named, state="gone", why=f"the terminal on {tty} now runs another Claude session")
    return dict(named, state="present", why=f"the terminal on {tty} runs the driving session")


def _names(folded, ident) -> bool:
    """True when the lower-cased command text holds the terminal id, the tty path, or the tty's short name."""
    low = ident.casefold()
    if low in folded:
        return True
    short = low[len("/dev/"):] if low.startswith("/dev/") else None
    return bool(short) and re.search(r"(?<![a-z0-9])%s(?![a-z0-9])" % re.escape(short), folded) is not None

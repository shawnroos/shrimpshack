"""The Rex terminal host: every rex command auto runs lives in this file.

It needs the rex command on PATH and nothing else (R18). REX_SESSION and REX_BLOCK only select a block;
`rex session inspect` proves it (KTD3).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

terminal_host = load_lib_module("terminal_host")
programme_exec = load_lib_module("programme_exec")
programme_sanitize = load_lib_module("programme_sanitize")

REX_TIMEOUT = 5.0
# SessionStart's hook timeout is 5s, and own_pane runs inside it.
INSPECT_TIMEOUT = 2.0
POLL_SECONDS = 1.0
MAX_SESSIONS = 32
# A poll must never start a Rex server.
NO_AUTOSTART = "--autostart=false"
PROCESS_METHOD = "com.superlogical.terminal.process"
STATUS_METHOD = "com.superlogical.terminal.program_status"
# Rex's state names, worst first. "done" is a finished turn, which the sweep treats as idle.
STATE_RANK = ("blocked", "error", "working", "done", "idle")
STATE_WORD = {"done": "idle"}
# One status call and at most one process call per block, each up to REX_TIMEOUT.
MAX_STATUS_BLOCKS = 64
_OFFERED: dict = {}
# Bounds how long a missed event can hide: the watcher reads at least this often while the stream is healthy.
SAFETY_NET_SECONDS = 300.0
# Only these leave or join the remit. Every CLI call, the watcher's own included, also raises client events.
JOIN_LEAVE_EVENTS = frozenset({"block_created", "block_closed", "session_created", "session_destroyed"})
SESSION_PREFIX = "session:"
BIN_TOKENS = frozenset({"$REX", "${REX}", "$REX_BIN", "${REX_BIN}"})
GLOBAL_VALUE_OPTS = frozenset({"-S", "--server", "-C", "--client", "--timeout", "--color"})
# Everything else that names the PM's block is a send: an unknown or future verb must not slip through.
READ_VERBS = frozenset({"capture", "ls", "list", "whoami", "version", "wait", "events", "actions", "keymap",
                        "help", "completion", "terminfo"})
READ_NOUNS = frozenset({"session", "window", "block", "client", "server", "hosts", "config", "skill", "home", "api"})
# rename only changes a label and cannot type into a block, so it sits with the reads on purpose.
READ_SUBVERBS = frozenset({"ls", "list", "inspect", "status", "logs", "describe", "show", "rename"})
TYPING_VERBS = frozenset({"send", "send-key", "run", "split", "do"})
# Rex accepts the end of an id as a target; 4 characters is the shortest tail worth treating as naming a block.
MIN_ID_TAIL = 4
_FRAGMENT_SPLIT = re.compile(r"[\s=,;:\"'{}\[\]]+")
_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
CLAUDE_MARKERS = ("claude",)

native, degraded, refuse = terminal_host.native, terminal_host.degraded, terminal_host.refuse


class RexHost(terminal_host.TerminalHost):
    name = "rex"
    binaries = ("rex",)

    def installed(self) -> bool:
        return shutil.which("rex") is not None

    def _needs_rex(self, method):
        if self.installed():
            return None
        cell = terminal_host.capability_table()[terminal_host.CAPABILITY_OF[method]]["rex"]
        return refuse("the rex command is not on PATH", fix=cell.get("fix"))

    def own_pane(self, env, **_):
        missing = self._needs_rex("own_pane")
        if missing:
            return missing
        session, block = env.get("REX_SESSION"), env.get("REX_BLOCK")
        fix = "run Claude from a terminal block inside a live Rex session"
        if not session or not block or session.startswith("-") or block.startswith("-"):
            return refuse("this session did not name a Rex session and block", fix=fix)
        view, why = _json(_rex(["session", "inspect", session, "--json"], INSPECT_TIMEOUT), "rex session inspect")
        if view is None:
            return refuse(why, fix=fix)
        found = _block_in(view, block)
        if found is None:
            return refuse(f"Rex session {session} has no block {block}", fix=fix)
        window, entry = found
        workspace = _segment(view.get("session_id"))
        if workspace is None:
            return refuse(f"Rex session id {view.get('session_id')!r} cannot name a space", fix=fix)
        return native({"pane_id": entry["block_id"], "terminal_id": None,
                       "server": _segment(entry.get("host_id")) or "local", "workspace": workspace,
                       "tab_space_name": programme_sanitize.clean(view.get("label"), 80) or None,
                       "window_id": window.get("window_id"), "block_label": entry.get("label")})

    def list_panes(self, agents=False, **_):
        missing = self._needs_rex("list_panes")
        if missing:
            return missing
        if agents:
            return degraded("Rex does not report which agent session a block runs", value=[])
        views, why = _all_views(_rex_json)
        if views is None:
            return refuse(why)
        return native(_snapshot(views, with_seq=False, statuses=_statuses(views)))

    def start_pane(self, argv, timeout, **_):
        missing = self._needs_rex("start_pane")
        if missing:
            why = f"{missing.why}; fix: {missing.fix}"
            return refuse(missing.why, fix=missing.fix, value={"run": programme_exec.not_run(why), "output": why, "pane": None})
        return native(terminal_host.spinoff_pane("rex", argv, timeout))

    def confirm_started(self, session_id, pane, before, wait, session_of, **_):
        return terminal_host.confirm_via_registry(
            "rex", "Rex block", "Rex does not list agent sessions, so the worker's own SessionStart row confirms it",
            session_id, pane, wait, POLL_SECONDS)

    def send_prompt(self, pane, text, **_):
        missing = self._needs_rex("send_prompt")
        if missing:
            return refuse(missing.why, fix=missing.fix, value=programme_exec.not_run(f"{missing.why}; fix: {missing.fix}"))
        # The text goes after "--" so a prompt that starts with a dash is not read as a flag.
        sent = programme_exec.bounded(["rex", "send", "-b", pane, NO_AUTOSTART, "--", text], REX_TIMEOUT)
        what = "rex send"
        if sent["ran"] and sent["code"] == 0:
            sent, what = _rex(["send-key", "-b", pane, "enter"], REX_TIMEOUT), "rex send-key enter (the text is already typed)"
            sent = dict(sent, text_typed=True)
        if sent["ran"] and sent["code"] == 0:
            return native(sent)
        return refuse(programme_exec.failure(sent, what), value=sent)

    def presence(self, session_id, row, snap, reported, **_):
        out = terminal_host.presence_facts(session_id, (row or {}).get("pane_id"))
        out.update(_probe(row, self.installed()))
        return native(out)

    def change_token(self, read_json, **_):
        missing = self._needs_rex("change_token")
        if missing:
            return missing
        views, why = _all_views(lambda args: read_json(["rex"] + args + [NO_AUTOSTART]))
        if views is None:
            return refuse(why)
        return native(_snapshot(views, with_seq=True))

    def wake_source(self):
        return _EventWake() if self.installed() else None

    def notify(self, title, body, **_):
        return degraded("Rex has no notification command, so the ask stays in the journal and the tracker",
                        value="journal")

    def send_class(self, argv, text=""):
        if not argv or not (argv[0] in BIN_TOKENS or os.path.basename(argv[0]) == "rex"):
            return None
        rest = list(argv[1:])
        verb = _verb_words(rest)
        if not verb or _reads_only(verb):
            return "read", []
        return ("send" if _types(verb) else "unknown"), _blocks_of(rest) or None

    def is_host_command(self, argv, pane_ids=()):
        if not argv or not (argv[0] in BIN_TOKENS or os.path.basename(argv[0]) == "rex"):
            return None
        rest = list(argv[1:])
        verb = _verb_words(rest)
        if verb and _reads_only(verb):
            return None
        for token in rest:
            for ident in pane_ids:
                if ident and _names_block(token, ident):
                    return " ".join(verb[:2] if verb[:1] == ["api"] else verb[:1]) or "rex", ident
        return None


def _rex(args, timeout) -> dict:
    return programme_exec.bounded(["rex"] + list(args) + [NO_AUTOSTART], timeout)


def _json(result, what):
    if not result["ran"] or result["code"] != 0:
        return None, programme_exec.failure(result, what)
    data = programme_exec.parse_json(result["stdout"])
    return (data, None) if isinstance(data, dict) else (None, f"{what} returned no JSON object")


def _rex_json(args):
    return _json(_rex(args, REX_TIMEOUT), "rex " + " ".join(args[:3]))


def _block_process(session, block):
    return _rex_json(["api", "call", "-s", session, PROCESS_METHOD, json.dumps({"block_id": block})])


def _process_nodes(proc) -> list:
    return [proc.get("foreground"), proc.get("child")] + (proc.get("ancestors") or [])


def _segment(value):
    """A Rex id as a path-safe space segment: the id without its kind prefix, or None when it is not safe."""
    text = value.split(":", 1)[-1] if isinstance(value, str) else ""
    return text if _SEGMENT.match(text) and "--" not in text else None


def _blocks(view):
    for window in view.get("windows") or []:
        for layer in window.get("layers") or []:
            for entry in layer.get("blocks") or []:
                if isinstance(entry, dict) and entry.get("block_id"):
                    yield window, entry


def _block_in(view, block_id):
    return next(((w, b) for w, b in _blocks(view) if b["block_id"] == block_id), None)


def _all_views(call):
    """(views, None), or (None, why). `call(args)` returns (json, error); a server with no sessions has no views."""
    listing, why = call(["session", "ls", "--json"])
    if listing is None:
        return None, why
    ids = [s.get("session_id") for s in listing.get("sessions") or [] if isinstance(s, dict)]
    views = []
    for sid in [i for i in ids if i][:MAX_SESSIONS]:
        view, why = call(["api", "call", "-s", sid, "session.view"])
        if view is None:
            return None, why
        if not isinstance(view.get("revision"), int):
            return None, "bad-json"
        views.append(view)
    return views, None


class _EventWake:
    """Wakes the remit watcher from `rex events`: a block or session joining or leaving makes it due.
    Healthy only while the stream runs; once it ends the watcher reads on every poll, as it did before."""

    def __init__(self):
        self._proc, self._flag, self._last_read = None, threading.Event(), None
        self._flag.set()

    def start(self) -> bool:
        try:
            self._proc = subprocess.Popen(["rex", "events", "--json", NO_AUTOSTART], stdin=subprocess.DEVNULL,
                                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return False
        threading.Thread(target=self._read, args=(self._proc,), daemon=True).start()
        return True

    def _read(self, proc):
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            inner = ((event.get("payload") or {}).get("event") or {}).get("type")
            if event.get("type") in JOIN_LEAVE_EVENTS or inner in JOIN_LEAVE_EVENTS:
                self._flag.set()
        self._flag.set()

    def healthy(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def due(self) -> bool:
        """True when the watcher must read now: an event came, the stream is down, or the safety net is due."""
        return (not self.healthy() or self._flag.is_set()
                or time.monotonic() - self._last_read >= SAFETY_NET_SECONDS)

    def begin_read(self) -> None:
        # Cleared before the read, so an event that lands during it still makes the next poll due.
        self._flag.clear()
        self._last_read = time.monotonic()

    def close(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()


def _offers(method) -> bool:
    """True when the connected server offers `method`. The server's answer is kept for the process; a describe
    that could not run (a timeout) reads as no this time and is asked again."""
    if method not in _OFFERED:
        asked = _rex(["api", "describe", method], REX_TIMEOUT)
        if not asked["ran"]:
            return False
        _OFFERED[method] = asked["code"] == 0
    return _OFFERED[method]


def _owner_alive(owner, alive) -> bool:
    # A program writes its own report, so the owner's shape is not trusted: a list would not even hash.
    return (isinstance(owner, dict) and isinstance(owner.get("pid"), int) and isinstance(owner.get("name"), str)
            and (owner["pid"], owner["name"]) in alive)


def _block_status(session, block):
    """The one status word for a block, or None. A report counts only while its reporter still runs in the block."""
    reported, _ = _rex_json(["api", "call", "-s", session, STATUS_METHOD, json.dumps({"block_id": block})])
    records = [r for r in (reported or {}).get("records") or [] if isinstance(r, dict)]
    if not records:
        return None
    proc, _ = _block_process(session, block)
    if proc is None:
        return None
    # Compare the name as well as the pid: the system reuses pids.
    alive = {(n.get("pid"), n.get("name")) for n in _process_nodes(proc) if isinstance(n, dict)}
    states = {r["state"] if r.get("state") in STATE_RANK else "idle" for r in records if _owner_alive(r.get("owner"), alive)}
    worst = next((s for s in STATE_RANK if s in states), None)
    return STATE_WORD.get(worst, worst)


def _statuses(views) -> dict:
    """block id -> status word for the blocks whose program reported one; empty on a server without the method."""
    if not _offers(STATUS_METHOD):
        return {}
    found, budget = {}, MAX_STATUS_BLOCKS
    for view in views:
        for _, entry in _blocks(view):
            if budget <= 0:
                return found
            budget -= 1
            word = _block_status(view.get("session_id"), entry["block_id"])
            if word:
                found[entry["block_id"]] = word
    return found


def _snapshot(views, with_seq, statuses=None) -> dict:
    """The herdr-shaped snapshot the sweep and the remit watcher read; every block carries its session's revision."""
    panes, agents, tabs = [], [], []
    statuses = statuses or {}
    for view in views:
        space = _segment(view.get("session_id")) or "?"
        for window in view.get("windows") or []:
            tabs.append({"tab_id": window.get("window_id"), "label": window.get("label")})
        for window, entry in _blocks(view):
            pane = {"pane_id": entry["block_id"], "workspace_id": space,
                    "tab_id": window.get("window_id"), "label": entry.get("label"), "terminal_id": None}
            if statuses.get(entry["block_id"]):
                pane["agent_status"] = statuses[entry["block_id"]]
            panes.append(pane)
            if with_seq:
                agents.append({"pane_id": entry["block_id"], "state_change_seq": view["revision"]})
    return {"panes": panes, "agents": agents, "tabs": tabs}


def _names_process(proc) -> bool:
    if not isinstance(proc, dict):
        return False
    text = " ".join(str(proc.get(k) or "") for k in ("name", "argv0", "script", "invoked_path", "path")).casefold()
    return any(marker in text for marker in CLAUDE_MARKERS)


def _probe(row, installed) -> dict:
    """Presence facts for the driving session's block. Only an authoritative absence says gone."""
    if not installed:
        return {"why": "the rex command is not on PATH, so auto cannot read Rex"}
    if not row or not row.get("pane_id") or (row.get("host") or "herdr") != "rex":
        return {"why": "no Rex block was ever recorded for the driving session"}
    if not row.get("interactive"):
        return {"why": "the driving session runs headless, outside a Rex block"}
    block, session = row["pane_id"], SESSION_PREFIX + str(row.get("workspace"))
    listing, why = _rex_json(["session", "ls", "--json"])
    if listing is None:
        return {"why": f"Rex could not be read ({why})"}
    known = [s.get("session_id") for s in listing.get("sessions") or [] if isinstance(s, dict)]
    base = {"herdr_reachable": True}
    if not known:
        return dict(base, why="Rex lists no sessions, so auto cannot tell where the driving session ran")
    if session not in known:
        return dict(base, state="gone", pane_in_snapshot=False, pane_id=block,
                    why=f"Rex session {session} that ran the driving session no longer exists")
    view, why = _rex_json(["api", "call", "-s", session, "session.view"])
    if view is None:
        return dict(base, why=f"Rex session {session} could not be read ({why})")
    found = _block_in(view, block)
    if found is None:
        return dict(base, state="gone", pane_in_snapshot=False, pane_id=block,
                    why=f"block {block} that ran the driving session is closed")
    named = dict(base, pane_in_snapshot=True, pane_id=block, pane_label=found[1].get("label"),
                 tab_label=found[0].get("label"))
    proc, why = _block_process(session, block)
    if proc is None:
        return dict(named, why=f"the processes in block {block} could not be read ({why})")
    if proc.get("last_exit") is not None:
        return dict(named, state="gone", why=f"the program in block {block} has exited")
    if any(_names_process(p) for p in _process_nodes(proc)):
        return dict(named, state="present", why=f"a claude process runs in block {block}; Rex does not say which session")
    return dict(named, why=f"block {block} is open and runs no claude process Rex can see, which may be a quit session")


def _verb_words(rest) -> list:
    words, i = [], 0
    while i < len(rest):
        tok = rest[i]
        if tok.startswith("-"):
            i += 2 if tok in GLOBAL_VALUE_OPTS else 1
            continue
        words.append(tok)
        if len(words) == 2:
            break
        i += 1
    return words


def _types(verb) -> bool:
    return verb[0] in TYPING_VERBS or list(verb[:2]) == ["api", "call"]


def _blocks_of(rest) -> list:
    blocks = [rest[i + 1] for i, tok in enumerate(rest[:-1]) if tok in ("-b", "--block")]
    return blocks + [tok.split("=", 1)[1] for tok in rest if tok.startswith("--block=")]


def _reads_only(verb) -> bool:
    return verb[0] in READ_VERBS or (verb[0] in READ_NOUNS and len(verb) > 1 and verb[1] in READ_SUBVERBS)


def _names_block(token, ident) -> bool:
    """True when `token` holds the block id or a tail of it, in any quoting, `--block=` or JSON form."""
    text, low = token.casefold(), ident.casefold()
    if low in text:
        return True
    tail = low.split(":", 1)[-1]
    return any(len(frag) >= MIN_ID_TAIL and tail.endswith(frag) for frag in _FRAGMENT_SPLIT.split(text))

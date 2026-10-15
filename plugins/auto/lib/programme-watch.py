#!/usr/bin/env python3
"""Programme wake watcher: polls cheap signals and prints one line when the remit changes.

Remit mode beats the `remit` watcher each interval and exits after printing the change.
Item mode runs a watch command, beats that item's watcher until it exits, then prints
its exit status. Record writes go only through the programme CLI.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_predicate = load_lib_module("programme_predicate")
programme_record = load_lib_module("programme_record")
programme_sanitize = load_lib_module("programme_sanitize")
programme_tracker = load_lib_module("programme_tracker")
programme_tasks = load_lib_module("programme_tasks")
programme_plans = load_lib_module("programme_plans")
driver_session = load_lib_module("driver_session")

PROG = "programme-watch"
REMIT_WATCHER = "remit"
DEFAULT_INTERVAL_SECONDS = 30.0
READ_TIMEOUT_SECONDS = 20
BEAT_TIMEOUT_SECONDS = 20
REFUSED_BEATS_LIMIT = 3
MAX_LISTED_CHANGES = 6
USAGE = ("usage: programme-watch [--run <id>] [--tracker] [--max-polls <n>]\n"
         "       programme-watch [--run <id>] --item <id> -- <command> [args...]")

_UNSAFE_ID_CHARS = re.compile(r"[^A-Za-z0-9_-]")


class WatchError(Exception):
    pass


def _say(line) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _warn(message) -> None:
    sys.stderr.write(f"{PROG}: {message}\n")
    sys.stderr.flush()


def _interval() -> float:
    raw = os.environ.get("CLAUDE_AUTO_WATCH_INTERVAL_SECONDS")
    try:
        value = float(raw) if raw else DEFAULT_INTERVAL_SECONDS
    except ValueError:
        value = DEFAULT_INTERVAL_SECONDS
    return value if value > 0 else DEFAULT_INTERVAL_SECONDS


def _parse(argv):
    command = None
    if "--" in argv:
        cut = argv.index("--")
        argv, command = argv[:cut], argv[cut + 1:]
    opts = {"run": None, "item": None, "tracker": False, "max_polls": None, "command": command}
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--tracker":
            opts["tracker"] = True
        elif arg in ("--run", "--item", "--max-polls"):
            if not args:
                raise ValueError(f"{arg} needs a value")
            opts[arg[2:].replace("-", "_")] = args.pop(0)
        else:
            raise ValueError(f"unknown argument {arg!r}")
    if opts["max_polls"] is not None:
        if not opts["max_polls"].isdigit() or int(opts["max_polls"]) < 1:
            raise ValueError("--max-polls must be a positive number")
        opts["max_polls"] = int(opts["max_polls"])
    if opts["item"] is not None:
        if not command:
            raise ValueError("--item needs a command after --")
        if opts["tracker"] or opts["max_polls"]:
            raise ValueError("--tracker and --max-polls apply to remit mode only")
        programme_record.check_item_id(opts["item"])
    elif command is not None:
        raise ValueError("a command after -- needs --item <id>")
    return opts


def _run_from_leases() -> str:
    sid = driver_session.driving_session_id()
    if not sid:
        raise WatchError("CLAUDE_CODE_SESSION_ID is unset; pass --run <id>")
    runs = {lease.get("run") for lease in programme_home.leases_for_session(sid)
            if programme_home.lease_status(lease) in programme_home.HELD_LEASE_STATES}
    if len(runs) != 1:
        raise WatchError("this session holds no single programme lease; pass --run <id>")
    return runs.pop()


def _read(run_id) -> dict:
    home = programme_home.home_path(run_id)
    try:
        record = run_record_core.read_run_record(home, run_id)
    except run_record_core.RunRecordError as exc:
        raise WatchError(f"cannot read programme {run_id!r}: {exc}") from exc
    if run_record_core.run_kind(record) != "programme":
        raise WatchError(f"run {run_id!r} is not a programme")
    return record


def _programme(record) -> dict:
    block = record.get("programme")
    return block if isinstance(block, dict) else {}


def _cli_argv() -> list:
    override = os.environ.get("CLAUDE_AUTO_PROGRAMME_CLI")
    return [override] if override else [sys.executable, os.path.join(_LIB_DIR, "programme.py")]


def _beat(run_id, watcher_id, item=None) -> bool:
    argv = _cli_argv() + ["watcher-beat", watcher_id, "--process-id", str(os.getpid()), "--run", run_id]
    if item is not None:
        argv += ["--item", item]
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, universal_newlines=True,
                              timeout=BEAT_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired) as exc:
        _warn(f"watcher-beat {watcher_id} failed: {exc}")
        return False
    if proc.returncode != 0:
        _warn(f"watcher-beat {watcher_id} refused: {programme_sanitize.clean(proc.stderr, 300)}")
        return False
    return True


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (ValueError, TypeError, OverflowError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _other_remit_watcher(record):
    watcher = (_programme(record).get("watchers") or {}).get(REMIT_WATCHER)
    if not isinstance(watcher, dict):
        return None
    pid = watcher.get("process_id")
    if not pid or str(pid) == str(os.getpid()):
        return None
    now = run_record_core.parse_iso(run_record_core.now_iso())
    live = programme_predicate.watcher_live(watcher, now, programme_home.cadence_seconds(record))
    return str(pid) if live and _pid_alive(pid) else None


def _read_json_command(argv):
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, universal_newlines=True,
                              timeout=READ_TIMEOUT_SECONDS)
    except FileNotFoundError:
        return None, "missing"
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "unreachable"
    if proc.returncode != 0:
        return None, f"exit={proc.returncode}"
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return None, "bad-json"
    if not isinstance(data, dict) or "error" in data:
        return None, "error"
    return data, None


def _remit_workspaces(record) -> set:
    spaces = (_programme(record).get("remit") or {}).get("spaces") or []
    return {s.get("workspace") for s in spaces if isinstance(s, dict) and s.get("workspace")}


def _pane_label(value) -> str:
    return programme_sanitize.token(value, 64) or "?"


def _session_value(entry):
    info = entry.get("agent_session")
    if isinstance(info, dict):
        return None if info.get("kind") == "path" else programme_sanitize.token(info.get("value"))
    return programme_sanitize.token(info) if isinstance(info, str) else None


def _read_herdr(ctx):
    data, err = _read_json_command(["herdr", "api", "snapshot"])
    if err:
        return None, err
    snapshot = (data.get("result") or {}).get("snapshot") if isinstance(data.get("result"), dict) else None
    if not isinstance(snapshot, dict):
        return None, "bad-json"
    workspaces, own = ctx["workspaces"], os.environ.get("HERDR_PANE_ID")
    seqs, panes, sessions, cwds = {}, set(), set(), set()
    for agent in snapshot.get("agents") or []:
        if isinstance(agent, dict) and agent.get("pane_id") != own:
            seqs[_pane_label(agent.get("pane_id"))] = agent.get("state_change_seq")
    for pane in snapshot.get("panes") or []:
        if isinstance(pane, dict) and pane.get("workspace_id") in workspaces:
            panes.add(_pane_label(pane.get("pane_id")))
            sessions.add(_session_value(pane))
            cwd = programme_sanitize.clean(pane.get("foreground_cwd") or pane.get("cwd"), 400)
            if cwd:
                cwds.add(cwd)
    sessions.discard(None)
    ctx.update(sessions=sessions, cwds=cwds)
    return {"seqs": seqs, "panes": panes}, None


def _herdr_changes(old, new) -> list:
    parts = [f"+{p}" for p in sorted(new["panes"] - old["panes"])]
    parts += [f"-{p}" for p in sorted(old["panes"] - new["panes"])]
    for pane in sorted(set(old["seqs"]) | set(new["seqs"])):
        before, after = old["seqs"].get(pane), new["seqs"].get(pane)
        if before != after and pane in new["panes"] and pane in old["panes"]:
            parts.append(f"{pane} {_seq_label(before)}->{_seq_label(after)}")
    return _listed("remit-changed", parts)


def _seq_label(value) -> str:
    return str(value) if isinstance(value, int) else "-"


def _latest_update(node, best):
    if isinstance(node, dict):
        stamp = run_record_core.parse_iso(node.get("updatedAt")) if isinstance(node.get("updatedAt"), str) else None
        if stamp is not None and (best is None or stamp > best[0]):
            best = (stamp, programme_sanitize.token(node.get("identifier"), 64) or "?")
        for value in node.values():
            best = _latest_update(value, best)
    elif isinstance(node, list):
        for value in node:
            best = _latest_update(value, best)
    return best


def _read_tracker(ctx):
    err = "no-provider"
    for name, argv_of in programme_tracker.WATCH_PROVIDERS:
        best = None
        for workspace in sorted(ctx["workspaces"]):
            data, err = _read_json_command(argv_of(workspace))
            if err:
                break
            best = _latest_update(data, best)
        if not err:
            return {"latest": best, "provider": name}, None
    return None, err


def _tracker_changes(old, new) -> list:
    before, after = old["latest"], new["latest"]
    if after is not None and (before is None or after[0] > before[0]):
        return [f"tracker-changed {after[1]} {after[0].strftime('%Y-%m-%dT%H:%M:%SZ')}"]
    return []


def _remit_sessions(ctx) -> set:
    return set(ctx.get("sessions") or ()) | set(ctx.get("owners") or ())


def _read_tasks(ctx):
    found = programme_tasks.read(_remit_sessions(ctx))
    if found["unavailable"]:
        return None, "unreadable"
    return {sid: tuple(v["counts"][s] for s in programme_tasks.STATUSES)
            for sid, v in found["sessions"].items() if v["total"]}, None


def _tasks_changes(old, new) -> list:
    empty = tuple(0 for _ in programme_tasks.STATUSES)
    parts = [f"{programme_sanitize.token(sid, 64) or '?'} {'/'.join(map(str, old.get(sid, empty)))}->"
             f"{'/'.join(map(str, new.get(sid, empty)))}"
             for sid in sorted(set(old) | set(new)) if old.get(sid, empty) != new.get(sid, empty)]
    return _listed("tasks-changed", parts)


def _read_plans(ctx):
    roots = ctx.setdefault("roots", {})
    files = {}
    for cwd in sorted(ctx.get("cwds") or ()):
        root = programme_plans.repo_root(cwd, roots)
        if root:
            for path, mtime in programme_plans.plan_files(root):
                files[os.path.join(os.path.basename(root), os.path.relpath(path, root))] = mtime
    return files, None


def _plans_changes(old, new) -> list:
    parts = [("+" if path not in old else "~") + programme_sanitize.clean(path, 200)
             for path in sorted(new) if old.get(path) != new[path]]
    return _listed("plans-changed", parts)


def _listed(kind, parts) -> list:
    if not parts:
        return []
    extra = len(parts) - MAX_LISTED_CHANGES
    return [kind + " " + " ".join(parts[:MAX_LISTED_CHANGES] + ([f"+{extra} more"] if extra > 0 else []))]


class Source:
    def __init__(self, name, read, diff):
        self.name, self.read, self.diff = name, read, diff
        self.baseline, self.down, self.reported = None, False, False

    def poll(self, ctx, record) -> list:
        if not programme_home.source_enabled(_programme(record), self.name):
            self.baseline, self.down, self.reported = None, False, False
            return []
        known = (_programme(record).get("sources") or {}).get(self.name) or {}
        recorded_down = isinstance(known, dict) and bool(known.get("unavailable_since"))
        value, err = self.read(ctx)
        if err:
            if not (self.down or self.reported or recorded_down):
                _say(f"source-unavailable {self.name} {err}")
                self.reported = True
            self.down = True
            return []
        if self.down or recorded_down:
            return [f"source-available {self.name}"]
        if self.baseline is None:
            self.baseline = value
            return []
        changes = self.diff(self.baseline, value)
        self.baseline = value
        return changes


def _due_waits(record) -> set:
    now = run_record_core.parse_iso(run_record_core.now_iso())
    due = set()
    for item_id, item in (_programme(record).get("items") or {}).items():
        waiting_on = item.get("waiting_on") if isinstance(item, dict) else None
        if not (isinstance(waiting_on, dict) and item.get("state") == "waiting"):
            continue
        when = run_record_core.parse_iso(waiting_on.get("due_at")) if isinstance(waiting_on.get("due_at"), str) else None
        if when is not None and when <= now:
            due.add(item_id)
    return due


def _owner_sessions(record) -> set:
    out = set()
    for item in (_programme(record).get("items") or {}).values():
        if isinstance(item, dict) and item.get("state") not in programme_home.FINISHED_ITEM_STATES:
            out.add(programme_sanitize.token((item.get("owner") or {}).get("session_id")))
    out.discard(None)
    return out


class RemitSignals:
    def __init__(self, ctx, tracker):
        self.ctx = ctx
        # herdr runs first: tasks and plans read the sessions and folders it just saw.
        self.sources = [Source("herdr", _read_herdr, _herdr_changes)]
        if tracker:
            self.sources.append(Source("tracker", _read_tracker, _tracker_changes))
        self.sources += [Source("tasks", _read_tasks, _tasks_changes),
                         Source("plans", _read_plans, _plans_changes)]
        self.claims = None
        self.due = None

    def poll(self, record) -> list:
        self.ctx["workspaces"] = _remit_workspaces(record)
        self.ctx["owners"] = _owner_sessions(record)
        changes = []
        for source in self.sources:
            changes += source.poll(self.ctx, record)
        claims = programme_record.claims_count(self.ctx["home"])
        if self.claims is not None and claims > self.claims:
            changes.append(f"claim {claims - self.claims} new")
        self.claims = claims
        due = _due_waits(record)
        if self.due is not None:
            changes += [f"wait-due {item_id}" for item_id in sorted(due - self.due)]
        self.due = due
        return changes


def _ended(record) -> bool:
    if _programme(record).get("ended"):
        _warn("programme ended; not watching")
        return True
    return False


def _superseded(record) -> bool:
    other = _other_remit_watcher(record)
    if other:
        _warn(f"remit watcher {other} is current; exiting")
    return bool(other)


def _remit_mode(run_id, opts) -> int:
    record = _read(run_id)
    if _ended(record) or _superseded(record):
        return 0
    if opts["tracker"] and not programme_home.source_enabled(_programme(record), "tracker"):
        _warn("the agreement turns the tracker off; not watching it")
    signals = RemitSignals({"home": programme_home.home_path(run_id)}, opts["tracker"])
    changes = signals.poll(record)
    if changes:
        _say("; ".join(changes))
        return 0
    if not _beat(run_id, REMIT_WATCHER):
        return 1
    interval, deadline, polls, refused = _interval(), time.monotonic(), 0, 0
    while True:
        deadline += interval
        time.sleep(max(0.0, deadline - time.monotonic()))
        polls += 1
        record = _read(run_id)
        if _ended(record) or _superseded(record):
            return 0
        changes = signals.poll(record)
        if changes:
            _say("; ".join(changes))
            return 0
        refused = 0 if _beat(run_id, REMIT_WATCHER) else refused + 1
        if refused >= REFUSED_BEATS_LIMIT:
            _warn(f"{refused} beats refused in a row; exiting")
            return 1
        if opts["max_polls"] and polls >= opts["max_polls"]:
            return 0


def item_watcher_id(item_id) -> str:
    return "item-" + _UNSAFE_ID_CHARS.sub("-", item_id)


def _exit_label(code) -> str:
    return f"exit={code}" if code >= 0 else f"signal={-code}"


def _stop_child(child):
    def handler(signum, frame):
        if child.poll() is None:
            child.terminate()
        sys.exit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, handler)


def _item_mode(run_id, opts) -> int:
    item_id, watcher_id = opts["item"], item_watcher_id(opts["item"])
    _read(run_id)
    try:
        child = subprocess.Popen(opts["command"], stdin=subprocess.DEVNULL, stdout=sys.stderr)
    except OSError as exc:
        _warn(f"cannot start the watch command: {exc}")
        _say(f"item-exited {item_id} exit=127")
        return 0
    interval, deadline, refused = _interval(), time.monotonic(), 0
    _stop_child(child)
    if not _beat(run_id, watcher_id, item=item_id):
        child.terminate()
        child.wait()
        return 1
    while True:
        deadline += interval
        try:
            code = child.wait(timeout=max(0.0, deadline - time.monotonic()))
            break
        except subprocess.TimeoutExpired:
            pass
        refused = 0 if _beat(run_id, watcher_id, item=item_id) else refused + 1
        if refused >= REFUSED_BEATS_LIMIT:
            _warn(f"{refused} beats refused in a row; stopping the watch command")
            child.terminate()
            child.wait()
            return 1
    _say(f"item-exited {item_id} {_exit_label(code)}")
    return 0


def main(argv) -> int:
    try:
        opts = _parse(argv)
    except (ValueError, programme_record.RecordError) as exc:
        _warn(str(exc))
        _warn(USAGE)
        return 2
    try:
        run_id = programme_home.check_run_id(opts["run"] or _run_from_leases())
        return _item_mode(run_id, opts) if opts["item"] else _remit_mode(run_id, opts)
    except (WatchError, programme_home.ProgrammeHomeError, run_record_core.RunRecordError) as exc:
        _warn(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

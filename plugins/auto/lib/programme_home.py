#!/usr/bin/env python3
"""Programme homes, remit leases and the programme record shape.

A programme lives in ``<data dir>/programmes/<run-id>/``, outside every repo. The
home holds a ``.claude/auto/`` folder, so the run-record primitives work with the
home as their ``repo_root``. One lease file per herdr space,
``programmes/leases/<server>.<workspace>.json``, names the run that holds it.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import secrets
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")

DATA_DIR_ENV = "CLAUDE_AUTO_DATA_DIR"
DEFAULT_DATA_DIR = "~/.claude/plugins/data/auto-shrimpshack"
DEFAULT_SERVER = "default"
DEFAULT_CADENCE_SECONDS = 3600
ORPHAN_CADENCE_PERIODS = 2

ITEM_STATES = ("open", "waiting", "done", "handed", "dropped")
FINISHED_ITEM_STATES = ("done", "handed", "dropped")
DELIVERABLES = ("merged", "flagged", "verified", "released", "recorded")
STOP_RULES = ("nothing_it_can_act_on", "only_when_done", "until_time", "never_stop")
AUTONOMY_LEVELS = ("act", "act_and_tell", "propose", "never")
LEASE_STATES = ("free", "live", "orphaned", "ended", "expired", "newer")
HELD_LEASE_STATES = ("live", "orphaned", "expired")
COMPACT_FLAG = ".compact-flag"
WATCHER_KINDS = ("cron", "monitor")

ITEM_FIELDS = (
    "id", "title", "state", "aliases", "owner", "sessions", "matched_rule",
    "deliverables", "waiting_on", "task_runs", "dropped_reason", "joined_at",
    "history",
)
PROGRAMME_FIELDS = (
    "remit", "created_at", "agreement", "instructions", "items",
    "working_model", "watchers", "inbox_offset", "ended",
)

_SEGMENT_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")
_ITEM_ID_RE = re.compile(r"^[a-z][a-z0-9_-]*:\S+$")


class ProgrammeHomeError(Exception):
    pass


class UnsafeDataDir(ProgrammeHomeError):
    pass


class UnsafeSegment(ProgrammeHomeError):
    pass


class LeaseHeld(ProgrammeHomeError):
    def __init__(self, key, lease, status):
        self.key = key
        self.lease = lease
        self.status = status
        if lease is None or lease.get("corrupt"):
            holder = "an unreadable lease"
        else:
            holder = f"run {lease.get('run')} (session {lease.get('session_id')})"
        suffix = {
            "orphaned": "; orphaned, takeover needed",
            "newer": "; programme written by a newer auto",
        }.get(status, "")
        super().__init__(f"remit {key} is held by {holder}{suffix}")


def _within(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def data_dir() -> str:
    raw = os.environ.get(DATA_DIR_ENV) or DEFAULT_DATA_DIR
    path = os.path.expanduser(raw)
    if not os.path.isabs(path):
        raise UnsafeDataDir(f"data dir must be absolute: {raw!r}")
    real = os.path.realpath(path)
    claude = os.path.join(os.path.expanduser("~"), ".claude")
    for sub in ("shared", "skills", "auto"):
        if _within(real, os.path.realpath(os.path.join(claude, sub))):
            raise UnsafeDataDir(f"data dir may not sit under ~/.claude/{sub}: {real}")
    projects = os.path.realpath(os.path.join(claude, "projects"))
    if _within(real, projects) and "memory" in os.path.relpath(real, projects).split(os.sep):
        raise UnsafeDataDir(f"data dir may not sit in a memory dir: {real}")
    return real


def check_segment(value) -> str:
    if not isinstance(value, str) or not _SEGMENT_RE.match(value) or value in (".", ".."):
        raise UnsafeSegment(f"unsafe path segment: {value!r}")
    return value


def check_run_id(run_id) -> str:
    check_segment(run_id)
    try:
        slug = run_record_core._slugify_branch(run_id)
    except ValueError:
        slug = None
    if slug != run_id:
        raise UnsafeSegment(f"run id must be its own record slug: {run_id!r}")
    return run_id


def _contained(path: str) -> str:
    root = data_dir()
    if not _within(os.path.realpath(path), root):
        raise UnsafeSegment(f"path escapes the data dir: {path}")
    return path


def _ensure_dir(path: str) -> str:
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def programmes_dir() -> str:
    return os.path.join(data_dir(), "programmes")


def leases_dir() -> str:
    return os.path.join(programmes_dir(), "leases")


def _leases_lock_path() -> str:
    # Beside the leases folder, never in it: the bash hook gate treats an empty
    # leases folder as "no programme here" and skips Python entirely.
    return os.path.join(programmes_dir(), "leases.lock")


def home_path(run_id: str) -> str:
    return _contained(os.path.join(programmes_dir(), check_run_id(run_id)))


def parse_space(spec):
    if isinstance(spec, dict):
        server, workspace = spec.get("server") or DEFAULT_SERVER, spec.get("workspace")
    elif isinstance(spec, (list, tuple)) and len(spec) == 2:
        server, workspace = spec
    elif isinstance(spec, str) and "." in spec:
        server, workspace = spec.split(".", 1)
    else:
        server, workspace = DEFAULT_SERVER, spec
    return check_segment(server), check_segment(workspace)


def space_key(server: str, workspace: str) -> str:
    return f"{check_segment(server)}.{check_segment(workspace)}"


def lease_path(server: str, workspace: str) -> str:
    return _contained(os.path.join(leases_dir(), space_key(server, workspace) + ".json"))


def _now(now=None) -> datetime.datetime:
    return now or datetime.datetime.now(datetime.timezone.utc)


def _iso(dt: datetime.datetime) -> str:
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_terms(now_iso: str) -> dict:
    def term(key, options, default, **extra):
        out = {"key": key, "options": list(options), "default": default, "value": default,
               "set_by": "default", "set_at": now_iso, "why": None}
        out.update(extra)
        return out

    return {
        "remit": term("remit", ("space", "tabs", "spaces"), "space"),
        "stop_rule": term("stop_rule", STOP_RULES, "nothing_it_can_act_on", until=None),
        "autonomy": term("autonomy", ("protocol",), "protocol", overrides={}),
        "cadence": term("cadence", ("on_change", "fixed"), "on_change",
                        seconds=DEFAULT_CADENCE_SECONDS, eval_budget_usd_per_day=25,
                        quiet_hours=None),
    }


def new_programme_block(spaces, now_iso: str) -> dict:
    return {
        "remit": {
            "spaces": [{"server": s, "workspace": w} for s, w in spaces],
            "tabs": [],
        },
        "created_at": now_iso,
        "agreement": {"accepted": None, "terms": default_terms(now_iso)},
        "instructions": [],
        "items": {},
        "working_model": {"doing": None, "queue": []},
        "watchers": {},
        "inbox_offset": 0,
        "ended": None,
    }


def new_item(item_id: str, title: str = "", *, state: str = "open", now_iso=None) -> dict:
    return normalize_item({"id": item_id, "title": title, "state": state,
                           "joined_at": now_iso or run_record_core.now_iso()})


def normalize_item(item: dict, item_id=None) -> dict:
    if not isinstance(item, dict):
        raise ProgrammeHomeError(f"item must be a dict: {item!r}")
    out = dict(item)
    out["id"] = item_id or item.get("id")
    if not isinstance(out["id"], str) or not _ITEM_ID_RE.match(out["id"]):
        raise ProgrammeHomeError(f"item id must be source:key: {out['id']!r}")
    out.setdefault("title", "")
    out.setdefault("state", "open")
    if out["state"] not in ITEM_STATES:
        raise ProgrammeHomeError(f"invalid item state: {out['state']!r}")
    owner = dict(item.get("owner") or {})
    for key in ("pane", "terminal_id", "session_id"):
        owner.setdefault(key, None)
    out["owner"] = owner
    for key in ("aliases", "sessions", "task_runs", "history"):
        out[key] = list(item.get(key) or [])
    out["deliverables"] = dict(item.get("deliverables") or {})
    for key in ("matched_rule", "waiting_on", "dropped_reason", "joined_at"):
        out.setdefault(key, None)
    return out


def normalize_programme(block: dict) -> dict:
    if not isinstance(block, dict):
        raise ProgrammeHomeError(f"programme block must be a dict: {block!r}")
    base = new_programme_block([], block.get("created_at") or run_record_core.now_iso())
    out = dict(block)
    for key in PROGRAMME_FIELDS:
        out.setdefault(key, base[key])
    agreement = dict(out["agreement"] or {})
    agreement.setdefault("accepted", None)
    terms = dict(agreement.get("terms") or {})
    for key, term in base["agreement"]["terms"].items():
        terms.setdefault(key, term)
    agreement["terms"] = terms
    out["agreement"] = agreement
    out["items"] = {k: normalize_item(v, k) for k, v in (out["items"] or {}).items()}
    return out


def cadence_seconds(record: dict) -> int:
    try:
        seconds = int(record["programme"]["agreement"]["terms"]["cadence"]["seconds"])
    except (KeyError, TypeError, ValueError):
        return DEFAULT_CADENCE_SECONDS
    return seconds if seconds > 0 else DEFAULT_CADENCE_SECONDS


def watcher_kind(watcher) -> str | None:
    watcher = watcher if isinstance(watcher, dict) else {}
    if watcher.get("kind") in WATCHER_KINDS:
        return watcher["kind"]
    # Records written before kinds existed: only the cadence cron was registered with its prompt.
    if watcher.get("task_id"):
        return "cron" if watcher.get("prompt") else "monitor"
    return "process" if watcher.get("process_id") else None


def read_lease(path: str):
    try:
        with open(path) as fh:
            lease = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {"corrupt": True}
    if not isinstance(lease, dict):
        return {"corrupt": True}
    return lease


def _read_record(run_id: str):
    try:
        return run_record_core.read_run_record(home_path(run_id), run_id)
    except (run_record_core.RunRecordError, ProgrammeHomeError, OSError, ValueError):
        return None


def _newer(stamp) -> bool:
    return isinstance(stamp, int) and stamp > run_record_core.PROGRAMME_FORMAT


def _age_seconds(stamp, now) -> float | None:
    when = run_record_core.parse_iso(stamp)
    return None if when is None else (now - when).total_seconds()


def lease_status(lease, now=None) -> str:
    if lease is None:
        return "free"
    if lease.get("corrupt"):
        return "orphaned"
    if _newer(lease.get("programme_format")):
        return "newer"
    run = lease.get("run")
    try:
        if lease.get("home") != home_path(run):
            return "orphaned"
    except ProgrammeHomeError:
        return "orphaned"
    record = _read_record(run)
    if record is None:
        return "orphaned"
    if _newer(record.get("programme_format")):
        return "newer"
    if load_lib_module("phase-grammar").current_phase(record) == "done":
        return "ended"
    now = _now(now)
    cadence = cadence_seconds(record)
    programme = record.get("programme") or {}
    if not (programme.get("agreement") or {}).get("accepted"):
        age = _age_seconds(programme.get("created_at"), now)
        if age is not None and age > cadence:
            return "expired"
    beat_age = _age_seconds((record.get("loop") or {}).get("last_beat_at"), now)
    if beat_age is None or beat_age > ORPHAN_CADENCE_PERIODS * cadence:
        return "orphaned"
    return "live"


def iter_leases():
    try:
        folder = leases_dir()
        names = sorted(os.listdir(folder))
    except (OSError, ProgrammeHomeError):
        return
    for name in names:
        if name.startswith(".") or not name.endswith(".json"):
            continue
        yield name[: -len(".json")], read_lease(os.path.join(folder, name))


def leases_for_session(session_id) -> list:
    if not session_id:
        return []
    try:
        return [dict(lease, key=key) for key, lease in iter_leases()
                if lease and not lease.get("corrupt") and lease.get("session_id") == session_id]
    except Exception:
        return []


def driven_runs(session_id, now=None) -> list:
    found = []
    for lease in leases_for_session(session_id):
        try:
            run = lease.get("run")
            if any(hold["run"] == run for hold in found):
                continue
            if lease_status(lease, now) not in HELD_LEASE_STATES:
                continue
            record = _read_record(run)
            if not isinstance(record, dict) or record.get("driving_session_id") != session_id:
                continue
            found.append({"run": run, "home": home_path(run), "record": record})
        except Exception:
            continue
    return found


def _write_lease(server, workspace, run_id, home, session_id, now_iso):
    lease = {
        "programme_format": run_record_core.PROGRAMME_FORMAT,
        "run": run_id,
        "home": home,
        "session_id": session_id,
        "server": server,
        "workspace": workspace,
        "created_at": now_iso,
    }

    def write(fh):
        json.dump(lease, fh, indent=2, sort_keys=True)
        fh.write("\n")

    atomic_write(lease_path(server, workspace), write, ".lease.")


def atomic_write(path, write, prefix, folder=None) -> None:
    fd, tmp = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=folder or os.path.dirname(path))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            write(fh)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _release_leases(run_id: str) -> None:
    for key, lease in list(iter_leases()):
        if lease and lease.get("run") == run_id:
            try:
                os.unlink(os.path.join(leases_dir(), key + ".json"))
            except FileNotFoundError:
                pass


def _end_locked(run_id: str, reason: str, now_iso: str) -> None:
    record = _read_record(run_id)
    if record is not None:
        home = home_path(run_id)

        def mutate(rec):
            programme = rec.setdefault("programme", {})
            programme["ended"] = {"at": now_iso, "reason": reason}

        # Phase first: a crash between the two writes must leave a record that
        # reads as ended, or its lease stays held as live or orphaned.
        load_lib_module("run_record").set_loop(home, run_id, loop_phase="done")
        run_record_core._with_locked_run_record(home, run_id, mutate)
    _release_leases(run_id)


def _with_leases_lock(body):
    _ensure_dir(programmes_dir())
    _ensure_dir(leases_dir())
    return run_record_core._flock_run(_leases_lock_path(), body)


def end_programme(run_id: str, reason: str, now=None) -> None:
    check_run_id(run_id)
    stamp = _iso(_now(now))
    _with_leases_lock(lambda: _end_locked(run_id, reason, stamp))


def _mint_run_id(now) -> str:
    return f"prog-{now.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}"


def create_programme(spaces, session_id, *, run_id=None, now=None) -> dict:
    if not isinstance(session_id, str) or not session_id:
        raise ProgrammeHomeError("a programme needs its driving session id")
    parsed = []
    for spec in spaces or []:
        space = parse_space(spec)
        if space not in parsed:
            parsed.append(space)
    if not parsed:
        raise ProgrammeHomeError("a programme needs at least one herdr space")
    now = _now(now)
    stamp = _iso(now)
    run_id = check_run_id(run_id or _mint_run_id(now))

    # Lock order is leases lock, then the run-record lock (taken inside
    # _end_locked and init_run_record). Every caller holding both must take them
    # in this order or two writers can deadlock.
    def body():
        for server, workspace in parsed:
            lease = read_lease(lease_path(server, workspace))
            if lease_status(lease, now) == "expired":
                _end_locked(lease["run"], "agreement_unaccepted", stamp)
        for server, workspace in parsed:
            lease = read_lease(lease_path(server, workspace))
            status = lease_status(lease, now)
            if status not in ("free", "ended"):
                raise LeaseHeld(space_key(server, workspace), lease, status)
        home = home_path(run_id)
        if os.path.exists(home):
            raise ProgrammeHomeError(f"programme home already exists: {home}")
        _ensure_dir(home)
        run_record_core.init_run_record(
            home, run_id, backend="native", steps=[], loop_phase="work",
            run_kind="programme", programme=new_programme_block(parsed, stamp),
            driving_session_id=session_id,
        )
        for server, workspace in parsed:
            _write_lease(server, workspace, run_id, home, session_id, stamp)
        return {"run": run_id, "home": home,
                "leases": [space_key(s, w) for s, w in parsed]}

    return _with_leases_lock(body)

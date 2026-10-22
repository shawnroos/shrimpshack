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
import time

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

ITEM_STATES = ("open", "waiting", "done", "handed", "dropped", "decided")
FINISHED_ITEM_STATES = ("done", "handed", "dropped", "decided")
CLOSED_ITEM_STATES = ("handed", "dropped", "decided")
DELIVERABLES = ("merged", "flagged", "verified", "released", "recorded")
STOP_RULES = ("nothing_it_can_act_on", "only_when_done", "until_time", "never_stop")
AUTONOMY_LEVELS = ("act", "act_and_tell", "propose", "never")
LEASE_STATES = ("free", "live", "orphaned", "ended", "expired", "newer", "unavailable")
HELD_LEASE_STATES = ("live", "orphaned", "expired", "unavailable")
AUTHORITY_HOLDS = ("unsupported", "corrupt", "unavailable")
COMPACT_FLAG = ".compact-flag"
ARCHIVE = "archive"
CLOSURE = "closure"
WATCHER_KINDS = ("cron", "monitor")
SWEEP_SOURCES = ("tracker", "tasks", "plans")
TRACKER_SCOPE_PARTS = ("teams", "projects", "initiatives")

ITEM_FIELDS = (
    "id", "title", "state", "aliases", "owner", "sessions", "matched_rule",
    "deliverables", "waiting_on", "task_runs", "dropped_reason", "joined_at",
    "history", "trajectory", "repo",
)
PROGRAMME_FIELDS = (
    "remit", "created_at", "agreement", "decisions", "items",
    "working_model", "watchers", "inbox_offset", "ended", "permission_proposals",
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
        "cadence": term("cadence", ("on_change", "fixed"), "on_change",
                        seconds=DEFAULT_CADENCE_SECONDS, eval_budget_usd_per_day=25,
                        quiet_hours=None),
        "tools_of_record": term("tools_of_record", SWEEP_SOURCES, list(SWEEP_SOURCES)),
    }


TERM_GUIDE = {
    "remit": {
        "editor": "space",
        "binding": "code",
        "description": "Which herdr spaces, repos and tracker scope the PM looks after.",
        "options": {
            "space": "One herdr space.",
            "tabs": "Only some tabs inside a herdr space.",
            "spaces": "Several herdr spaces.",
        },
    },
    "stop_rule": {
        "editor": "until",
        "binding": "code",
        "description": "When the PM may stop sweeping and end its turn.",
        "options": {
            "nothing_it_can_act_on": "Stop when nothing is left that the PM can act on.",
            "only_when_done": "Stop only when every item is done.",
            "until_time": "Keep going until a set time, then stop.",
            "never_stop": "Never stop on its own.",
        },
    },
    "cadence": {
        "editor": "interval",
        "binding": "code",
        "description": "How often the PM sweeps the programme.",
        "options": {
            "on_change": "Sweep when something changes.",
            "fixed": "Sweep on a fixed interval.",
        },
    },
    "tools_of_record": {
        "editor": "checklist",
        "binding": "code",
        "description": "Which tools the PM reads to learn the state of the work.",
        "options": {
            "tracker": "The issue tracker.",
            "tasks": "Each session's task list.",
            "plans": "Plan files in the remit's repos.",
        },
    },
}

_OLD_TOOLS_KEY = "sources"
_OLD_INSTRUCTIONS_KEY = "instructions"
_OLD_AUTONOMY_TERM = "autonomy"
_RENAMED_FIELDS = ("value", "set_by", "set_at", "why", "prompt_id", "quote")


def _tools_term(terms):
    for key in ("tools_of_record", _OLD_TOOLS_KEY):
        if isinstance(terms.get(key), dict):
            return terms[key]
    return {}


def enabled_sources(programme) -> set:
    terms = ((programme or {}).get("agreement") or {}).get("terms") or {}
    value = _tools_term(terms).get("value")
    if not isinstance(value, list):
        return set(SWEEP_SOURCES)
    return {name for name in value if name in SWEEP_SOURCES}


def project_terms(programme) -> list:
    entries = ((programme or {}).get("agreement") or {}).get("project_terms")
    return [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []


def source_enabled(programme, name) -> bool:
    return name not in SWEEP_SOURCES or name in enabled_sources(programme)


def empty_tracker_scope() -> dict:
    return {part: [] for part in TRACKER_SCOPE_PARTS}


def new_programme_block(spaces, now_iso: str) -> dict:
    return {
        "remit": {
            "spaces": [{"server": s, "workspace": w} for s, w in spaces],
            "tabs": [],
            "repos": [],
            "tracker": empty_tracker_scope(),
        },
        "created_at": now_iso,
        "agreement": {"accepted": None, "terms": default_terms(now_iso)},
        "decisions": [],
        "items": {},
        "working_model": {"doing": None, "queue": []},
        "watchers": {},
        "inbox_offset": 0,
        "ended": None,
        "permission_proposals": [],
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
    for key in ("matched_rule", "waiting_on", "dropped_reason", "joined_at", "trajectory", "repo"):
        out.setdefault(key, None)
    return out


def session_ids(item) -> list:
    sids = [(item.get("owner") or {}).get("session_id")]
    sids += [s.get("session_id") for s in item.get("sessions") or [] if isinstance(s, dict)]
    return [s for s in dict.fromkeys(sids) if isinstance(s, str) and s]


def _legacy_revision(entry, legacy, effect, scope, applies_to, until) -> dict:
    at = entry.get("at")
    prompt_id = entry.get("prompt_id")
    closed = entry.get("state") not in (None, "active")
    out = {"rev": 1, "state": "closed" if closed else "accepted", "at": at, "kind": None, "effect": effect,
           "legacy": legacy, "scope": scope, "reason": entry.get("why"), "limits": [], "requirements": [],
           "applies_to": applies_to, "until": until, "quote": entry.get("quote"), "replies_to": None,
           "baseline": None, "delta": None, "supersedes": None, "superseded_by": None,
           "source": {"class": "human_input" if prompt_id else "derived", "prompt_id": prompt_id,
                      "origin_label": "typed" if prompt_id else None, "origin_verified": False},
           "accepted": {"at": at, "prompt_id": prompt_id, "origin_verified": False}}
    if closed:
        ended = entry.get("closed") if isinstance(entry.get("closed"), dict) else {}
        out["closed"] = {"at": ended.get("at"), "as": entry.get("state"), "why": ended.get("why"),
                         "prompt_id": ended.get("prompt_id")}
    return out


def _legacy_rulings(block) -> dict:
    out = {}
    for entry in block.get(_OLD_INSTRUCTIONS_KEY) or []:
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            out[entry["id"]] = _legacy_revision(entry, "instruction", "decided", entry.get("quote"),
                                                [entry.get("applies_to") or "programme"], entry.get("until"))
    for entry in project_terms(block):
        if entry.get("reserved") and isinstance(entry.get("id"), str):
            revision = _legacy_revision(dict(entry, why=None), "project_term", "restrict", entry.get("value"),
                                        ["programme"], None)
            revision["area"] = entry.get("area")
            out[entry["id"]] = revision
    return out


def _with_legacy_rulings(block) -> bool:
    legacy = _legacy_rulings(block)
    context = block.get("context")
    if not legacy:
        return True
    if not isinstance(context or {}, dict) or not isinstance((context or {}).get("decisions", {}), dict):
        return False
    context = dict(context or {})
    decisions = dict(context.get("decisions") or {})
    for rid, revision in legacy.items():
        decisions.setdefault(rid, [revision])
    context["decisions"] = decisions
    block["context"] = context
    return True


def _drop_retired(block) -> None:
    block.pop(_OLD_INSTRUCTIONS_KEY, None)
    agreement = block["agreement"]
    if isinstance(agreement.get("project_terms"), list):
        agreement["project_terms"] = [e for e in agreement["project_terms"]
                                      if not (isinstance(e, dict) and e.get("reserved"))]


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
    old = terms.pop(_OLD_TOOLS_KEY, None)
    if isinstance(old, dict) and "tools_of_record" not in terms:
        renamed = dict(base["agreement"]["terms"]["tools_of_record"])
        renamed.update({k: old[k] for k in _RENAMED_FIELDS if k in old})
        terms["tools_of_record"] = renamed
    terms.pop(_OLD_AUTONOMY_TERM, None)
    for key, term in base["agreement"]["terms"].items():
        terms.setdefault(key, term)
    agreement["terms"] = terms
    out["agreement"] = agreement
    out["items"] = {k: normalize_item(v, k) for k, v in (out["items"] or {}).items()}
    out["trajectory_sweeps"] = list(out.get("trajectory_sweeps") or [])
    remit = dict(out["remit"] or {})
    remit.setdefault("spaces", [])
    remit.setdefault("tabs", [])
    remit.setdefault("repos", [])
    tracker = dict(remit.get("tracker") or {})
    for part in TRACKER_SCOPE_PARTS:
        tracker.setdefault(part, [])
    remit["tracker"] = tracker
    out["remit"] = remit
    # A malformed context cannot take the legacy copy, so the old keys stay until it is repaired.
    if _with_legacy_rulings(out):
        _drop_retired(out)
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


def read_programme(run_id: str) -> tuple:
    try:
        return run_record_core.read_run_record(home_path(run_id), run_id), None
    except run_record_core.RunRecordError as exc:
        outcome = getattr(exc, "outcome", None)
        if outcome in AUTHORITY_HOLDS:
            return None, {"outcome": outcome, "detail": str(exc)}
        return None, None
    except (ProgrammeHomeError, OSError, ValueError):
        return None, None


def _read_record(run_id: str):
    return read_programme(run_id)[0]


def _newer(stamp) -> bool:
    return isinstance(stamp, int) and stamp > run_record_core.PROGRAMME_FORMAT


def _age_seconds(stamp, now) -> float | None:
    when = run_record_core.parse_iso(stamp)
    return None if when is None else (now - when).total_seconds()


def sealed(programme) -> bool:
    return bool(((programme or {}).get(ARCHIVE) or {}).get("sealed_at"))


def lease_status(lease, now=None) -> str:
    return lease_state(lease, now)[0]


def lease_state(lease, now=None) -> tuple:
    # (status, (record, hold)) when the status came from reading the run, else (status, None).
    if lease is None:
        return "free", None
    if lease.get("corrupt"):
        return "orphaned", None
    if _newer(lease.get("programme_format")):
        return "newer", None
    run = lease.get("run")
    try:
        if lease.get("home") != home_path(run):
            return "orphaned", None
    except ProgrammeHomeError:
        return "orphaned", None
    read = record, hold = read_programme(run)
    return _status_of(record, hold, now), read


def _status_of(record, hold, now) -> str:
    if hold is not None:
        return "unavailable"
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
            status, read = lease_state(lease, now)
            if status not in HELD_LEASE_STATES:
                continue
            record, hold = read or read_programme(run)
            if hold is not None:
                found.append({"run": run, "home": home_path(run), "record": None, "hold": hold})
                continue
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


def closing_dir() -> str:
    return os.path.join(programmes_dir(), "closing")


def write_closing(run_id: str, sessions) -> None:
    sessions = sorted({s for s in sessions if isinstance(s, str) and s})
    if not sessions:
        return
    folder = _ensure_dir(closing_dir())

    def write(fh):
        json.dump({"run": run_id, "sessions": sessions}, fh, sort_keys=True)
        fh.write("\n")

    atomic_write(_contained(os.path.join(folder, check_run_id(run_id) + ".json")), write, ".closing.")


def closing_runs(session_id) -> list:
    """Runs whose closing entry names this session: ended programmes it may still approve dispositions for."""
    try:
        names = sorted(os.listdir(closing_dir()))
    except (OSError, ProgrammeHomeError):
        return []
    runs = []
    for name in names:
        if name.startswith(".") or not name.endswith(".json"):
            continue
        entry = read_lease(os.path.join(closing_dir(), name))
        if entry and not entry.get("corrupt") and session_id in (entry.get("sessions") or []):
            runs.append(entry.get("run"))
    return runs


def _end_locked(run_id: str, reason: str, now_iso: str, event=None) -> None:
    record, hold = read_programme(run_id)
    if hold is not None:
        raise ProgrammeHomeError(f"programme {run_id} cannot end: its authority is {hold['outcome']}")
    if record is not None:
        home = home_path(run_id)
        phase_key = load_lib_module("phase-grammar").LOOP_PHASE_KEY
        archive = load_lib_module("programme_archive")
        leases = [key for key, lease in iter_leases() if lease and lease.get("run") == run_id]
        ended_by = (event or {}).get("session_id")

        def mutate(rec):
            rec[phase_key] = "done"
            rec.setdefault("programme", {})["ended"] = {"at": now_iso, "reason": reason}
            archive.open_closure(rec, leases, ended_by, now_iso)

        load_lib_module("programme_authority").write(
            home, run_id, mutate, (lambda _result, _rec: event) if event else None)
        write_closing(run_id, [record.get("driving_session_id"), ended_by])
        archive.pause("after_end_commit")
        _release_leases(run_id)
        archive.settle_leases(run_id)
        return
    _release_leases(run_id)


def _with_leases_lock(body):
    _ensure_dir(programmes_dir())
    _ensure_dir(leases_dir())
    return run_record_core._flock_run(_leases_lock_path(), body)


def end_programme(run_id: str, reason: str, now=None) -> None:
    check_run_id(run_id)
    stamp = _iso(_now(now))
    _with_leases_lock(lambda: _end_locked(run_id, reason, stamp))


def _remit_keys(record) -> list:
    keys = []
    for space in ((record.get("programme") or {}).get("remit") or {}).get("spaces") or []:
        try:
            keys.append(space_key(space.get("server") or DEFAULT_SERVER, space.get("workspace")))
        except (ProgrammeHomeError, AttributeError):
            continue
    return keys


def _stale_remit(home, run_id) -> list:
    try:
        with open(run_record_core.run_record_path(home, run_id)) as fh:
            return _remit_keys(json.load(fh))
    except (OSError, ValueError, AttributeError):
        return []


def _claimants(now, stamp) -> dict:
    found = {}
    for entry in load_lib_module("_bootstrap").iter_programme_outcomes():
        run, home, record = entry["run_id"], entry["home"], entry["record"]
        if entry["outcome"] in AUTHORITY_HOLDS:
            keys = _stale_remit(home, run) + [k for k, lease in iter_leases()
                                               if lease and lease.get("run") == run]
            synthetic = {"run": run, "home": home, "session_id": None,
                         "programme_format": run_record_core.PROGRAMME_FORMAT}
            for key in keys:
                found.setdefault(key, {"lease": synthetic, "status": "unavailable", "record": None})
            continue
        if record is None or (record.get("programme") or {}).get("ended"):
            continue
        synthetic = {"run": run, "home": home, "session_id": record.get("driving_session_id"),
                     "programme_format": record.get("programme_format"),
                     "created_at": (record.get("programme") or {}).get("created_at") or stamp}
        status = lease_status(synthetic, now)
        if status == "expired":
            _end_locked(run, "agreement_unaccepted", stamp)
            continue
        if status in ("free", "ended"):
            continue
        for key in _remit_keys(record):
            found.setdefault(key, {"lease": synthetic, "status": status, "record": record})
    return found


def _republish(claim, server, workspace, stamp) -> None:
    lease = claim["lease"]
    if claim["record"] is None or read_lease(lease_path(server, workspace)) is not None:
        return
    _write_lease(server, workspace, lease["run"], lease["home"], lease["session_id"],
                 lease.get("created_at") or stamp)


def _test_pause(point) -> None:
    if not run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_LEASE_PAUSE_" + point.upper()):
        return
    run_record_core.test_pause("lease_" + point)


def reconcile_run_leases(run_id: str) -> list:
    check_run_id(run_id)

    def body():
        record, hold = read_programme(run_id)
        if hold is not None:
            raise ProgrammeHomeError(f"programme {run_id} authority is {hold['outcome']}: {hold['detail']}")
        if record is None or (record.get("programme") or {}).get("ended"):
            raise ProgrammeHomeError(f"programme {run_id} has no live record to reconcile from")
        home, sid = home_path(run_id), record.get("driving_session_id")
        written = []
        for key in _remit_keys(record):
            server, workspace = key.split(".", 1)
            lease = read_lease(lease_path(server, workspace))
            if lease and (lease.get("corrupt") or lease.get("run") != run_id):
                raise LeaseHeld(key, lease, lease_status(lease))
            if lease is None or lease.get("session_id") != sid or lease.get("home") != home:
                _write_lease(server, workspace, run_id, home, sid,
                             (lease or {}).get("created_at") or _iso(_now()))
                written.append(key)
                _test_pause("after_write")
        return written

    return _with_leases_lock(body)


def _mint_run_id(now) -> str:
    return f"prog-{now.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}"


def create_programme(spaces, session_id, *, run_id=None, now=None, predecessor=None) -> dict:
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
        claimants = _claimants(now, stamp)
        for server, workspace in parsed:
            lease = read_lease(lease_path(server, workspace))
            status = lease_status(lease, now)
            if status not in ("free", "ended"):
                raise LeaseHeld(space_key(server, workspace), lease, status)
            claim = claimants.get(space_key(server, workspace))
            if claim is not None:
                _republish(claim, server, workspace, stamp)
                raise LeaseHeld(space_key(server, workspace), claim["lease"], claim["status"])
        home = home_path(run_id)
        if os.path.exists(home):
            raise ProgrammeHomeError(f"programme home already exists: {home}")
        _ensure_dir(home)
        block = new_programme_block(parsed, stamp)
        if predecessor is not None:
            block["predecessor"] = dict(predecessor)
        run_record_core.init_run_record(
            home, run_id, backend="native", steps=[], loop_phase="work",
            run_kind="programme", programme=block,
            driving_session_id=session_id,
        )
        for server, workspace in parsed:
            _write_lease(server, workspace, run_id, home, session_id, stamp)
        return {"run": run_id, "home": home,
                "leases": [space_key(s, w) for s, w in parsed]}

    return _with_leases_lock(body)

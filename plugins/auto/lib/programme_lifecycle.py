#!/usr/bin/env python3
"""Programme lifecycle verbs: start, takeover, handover, end, expire and beat.

Takeover, handover and end act only on a request the prompt hook journaled from
the caller's own session. Moving a programme rewrites every lease of the run and
the record's driving session together, under the leases lock and then the
run-record lock.
"""

from __future__ import annotations

import functools
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
programme_journal = load_lib_module("programme_journal")
session_registry = load_lib_module("session_registry")
driver_session = load_lib_module("driver_session")
programme_sanitize = load_lib_module("programme_sanitize")
programme_carryover = load_lib_module("programme_carryover")
programme_terms = load_lib_module("programme_terms")
programme_worktree = load_lib_module("programme_worktree")

END_REASON = "ended_by_shawn"
EXPIRED_REASON = "agreement_unaccepted"
MOVABLE_STATES = ("live", "orphaned")
CONSUMING_KINDS = ("taken_over", "handed_over", "programme_ended")
REMIT_CAPS = {"spaces": 8, "repos": 20, "teams": 10, "projects": 20, "initiatives": 10}
REMIT_INPUT_CAP = 1 << 16
REMIT_NAME_CAP = 100
REMIT_ID_CAP = 64
_TEAM_KEY_RE = re.compile(r"[A-Z][A-Z0-9]{0,7}")
_GITHUB_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


class _Refused(Exception):
    def __init__(self, reason, status=None, ended=None):
        super().__init__(reason)
        self.reason = reason
        self.status = status
        self.ended = ended


def _tokens(argv) -> list:
    # A slash command passes "$ARGUMENTS" as one string; split it back into options.
    return list(argv[:1]) + [t for arg in argv[1:] for t in str(arg).split()]


def _caller(host) -> str:
    sid = driver_session.driving_session_id()
    if not sid:
        raise host.ProgrammeError("CLAUDE_CODE_SESSION_ID is unset; run this from the Claude session itself")
    return sid


def _stamp() -> str:
    return programme_home._iso(programme_home._now())


def _run_leases(run) -> list:
    return [(key, lease) for key, lease in programme_home.iter_leases()
            if lease and not lease.get("corrupt") and lease.get("run") == run]


def _lease_for(host, opts, sid):
    if opts.get("run"):
        run = programme_home.check_run_id(opts["run"])
        hits = _run_leases(run)
        if not hits:
            raise host.ProgrammeError(f"run {run!r} holds no lease; it has ended or never started")
        return hits[0][1]
    for lease in programme_home.leases_for_session(sid):
        return lease
    space = session_registry.space_of_session(sid, os.environ) if sid else None
    if not space:
        raise host.ProgrammeError("this session is not in a herdr space; pass --run <id>")
    key = programme_home.space_key(*space)
    lease = programme_home.read_lease(programme_home.lease_path(*space))
    if lease is None:
        raise host.ProgrammeError(f"no programme holds {key}")
    if lease.get("corrupt"):
        raise host.ProgrammeError(f"the lease for {key} is unreadable; nothing to take over")
    return lease


def _fresh_status(lease) -> str:
    current = programme_home.read_lease(programme_home.lease_path(lease["server"], lease["workspace"]))
    if not current or current.get("corrupt") or current.get("run") != lease.get("run"):
        return "free"
    return programme_home.lease_status(current)


def _request_ref(row) -> dict:
    cites = row.get("cites") or [None]
    return {"kind": row.get("kind"), "at": row.get("at"), "session_id": row.get("session_id"),
            "prompt_id": cites[0]}


def _requests(run, verb, sid) -> list:
    rows = programme_journal.read(run)
    unverified = programme_authority().UNVERIFIED
    used = [(r.get("payload") or {}).get("request") for r in rows
            if r.get("kind") in CONSUMING_KINDS and r.get("provenance") not in unverified]
    return [r for r in rows
            if r.get("kind") == f"{verb}_request" and r.get("session_id") == sid
            and r.get("provenance") not in unverified
            and programme_journal.prompt_origin(r) == "typed" and _request_ref(r) not in used]


def _cited_typed(run, request, sid) -> bool:
    cites = request.get("cites") or []
    if not (request.get("payload") or {}).get("driving") or not cites:
        return False
    row = programme_journal.find_prompt(run, cites[0])
    return bool(row) and row.get("session_id") == sid and row.get("provenance") not in programme_authority().UNVERIFIED \
        and programme_journal.prompt_origin(row) == "typed"


def _journal(run, kind, sid, payload, cites=None) -> None:
    if os.path.isdir(programme_home.home_path(run)):
        programme_journal.append(run, kind, sid, payload, cites=cites)


def _cleanup_lines(ended, run) -> None:
    watchers = ((programme_home._read_record(run) or {}).get("programme") or {}).get("watchers") or {}
    owner = {str(w.get("task_id")): wid for wid, w in sorted(watchers.items()) if isinstance(w, dict)}

    def then(task_id):
        return f"  (then release-resources --watcher {owner[task_id]})" if task_id in owner else ""

    for task_id in ended.get("cron_task_ids") or []:
        sys.stdout.write(f"Remove the cadence fallback: CronDelete {task_id}{then(task_id)}\n")
    for task_id in ended.get("monitor_task_ids") or []:
        sys.stdout.write(f"Stop the watcher Monitor: TaskStop {task_id}{then(task_id)}\n")
    for pid in ended.get("process_ids") or []:
        sys.stdout.write(f"Stop watcher process {pid} if it is still running.\n")


def _refuse(host, run, verb, sid, exc):
    if exc.ended is not None:
        _journal(run, "programme_ended", sid, exc.ended)
    _journal(run, "request_refused", sid,
             {"verb": verb, "reason": exc.reason, "lease_status": exc.status})
    if exc.ended is not None:
        if os.path.isdir(programme_home.home_path(run)):
            host.refresh_view(run, programme_home.home_path(run))
        _cleanup_lines(exc.ended, run)
    raise host.ProgrammeError(exc.reason)


def _move(run, new_sid, kind, sid, extra, cites=None) -> dict:
    home = programme_home.home_path(run)
    leases = _run_leases(run)
    seen = {}

    def mutate(rec):
        seen["moved"] = {"from_session": rec.get("driving_session_id"), "to_session": new_sid,
                         "leases": [key for key, _ in leases]}
        rec["driving_session_id"] = new_sid
        programme = rec.setdefault("programme", {})
        programme["owner_epoch"] = int(programme.get("owner_epoch") or 0) + 1
        rec.setdefault("loop", {})["last_beat_at"] = run_record_core.now_iso()
        seen["moved"].update(extra(seen["moved"], rec))

    def compose(_, rec):
        payload = dict(seen["moved"])
        if cites:
            payload["prompt_id"] = cites[0]
        return programme_journal.entry(kind, sid, payload, cites=cites)

    programme_authority().write(home, run, mutate, compose)
    for _, lease in leases:
        programme_home._write_lease(lease["server"], lease["workspace"], run, lease["home"], new_sid,
                                    lease.get("created_at") or _stamp())
    return seen["moved"]


def programme_authority():
    return load_lib_module("programme_authority")


def _rearm_list(record) -> dict:
    programme = record.get("programme") or {}
    waits = [{"item": item_id, "waiting_on": item.get("waiting_on")}
             for item_id, item in sorted((programme.get("items") or {}).items())
             if isinstance(item, dict) and item.get("state") == "waiting"]
    return {"waits": waits, "watchers": sorted((programme.get("watchers") or {}).keys())}


def _make_worktree(run, programme=None):
    programme = programme if programme is not None else \
        ((programme_home._read_record(run) or {}).get("programme") or {})
    repo = programme_worktree.remit_repo(programme)
    if programme_worktree.recorded(programme) or not repo:
        return None
    try:
        return programme_worktree.create(repo, run)
    except OSError as exc:
        return {"status": "failed", "path": None, "record": None, "error": f"could not create the worktree: {exc}"}


def _record_worktree(made, programme) -> dict:
    if not made:
        return {}
    if made["record"] and not programme_worktree.recorded(programme):
        programme["pm_worktree"] = made["record"]
        return {"pm_worktree": made["record"]}
    return {"pm_worktree_error": made["error"]} if made["error"] else {}


def _locked(body):
    return programme_home._with_leases_lock(body)


def _finish(host, run, kind, sid, payload, cites=None, journal=True) -> None:
    if journal:
        _journal(run, kind, sid, payload, cites=cites)
    host.refresh_view(run, programme_home.home_path(run))
    host._emit(dict({"ok": True, "run": run, "kind": kind}, **payload))


def _h_start(host, argv):
    positional, opts = host._parse(_tokens(argv), multi=("space",))
    sid = _caller(host)
    spaces = list(opts["space"]) + positional or [session_registry.space_of_session(sid, os.environ)]
    if not spaces[0]:
        raise host.ProgrammeError("this session is not in a herdr space; start from a herdr pane "
                                  "or pass --space <server.workspace>")
    made = programme_home.create_programme(spaces, sid)
    _finish(host, made["run"], "programme_started", sid,
            {"home": made["home"], "leases": made["leases"], "session": sid})
    return 0


def _replace_name(text) -> str | None:
    words = str(text or "").split()
    if "--replace" not in words:
        return None
    rest = words[words.index("--replace") + 1:]
    name = " ".join(rest[:next((i for i, w in enumerate(rest) if w.startswith("--")), len(rest))])
    return name.strip("'\"") or None


def _names_driver(name, presence) -> bool:
    wanted = " ".join(name.split()).casefold()
    return any(v and v.casefold() == wanted
               for v in (presence.get("session_id"), presence.get("pane_id"), presence.get("pane_label")))


def _driver(lease, run):
    return (programme_home._read_record(run) or {}).get("driving_session_id") or lease.get("session_id")


def _since_driver_changed(run, rows) -> list:
    # A request typed against an earlier PM must not later displace a different one.
    journal = programme_journal.read(run)
    last = max((i for i, r in enumerate(journal)
                if r.get("kind") in ("programme_started",) + CONSUMING_KINDS[:2]
                and r.get("provenance") not in programme_authority().UNVERIFIED), default=-1)
    later = [_request_ref(r) for r in journal[last + 1:]]
    return [r for r in rows if _request_ref(r) in later]


def _presence(lease, run) -> dict:
    sources = load_lib_module("programme_sources")
    driver = _driver(lease, run)
    snap, reason = sources.read_herdr()
    try:
        found = session_registry.driver_presence(driver, snap, sources.session_of,
                                                 current_server=sources.current_server())
    except (TypeError, ValueError, AttributeError) as exc:
        return {"state": "unknown", "session_id": driver, "herdr_reachable": snap is not None,
                "why": f"the session registry could not be read ({exc})"}
    if snap is None:
        found["why"] = f"herdr could not be read ({reason}), so auto cannot tell whether it is still running"
    return found


def _driver_words(presence) -> str:
    label, tab, pane = presence.get("pane_label"), presence.get("tab_label"), presence.get("pane_id")
    in_tab = f' in tab "{tab}"' if tab else ""
    if label:
        return f'the PM in pane "{label}"{in_tab} ({pane})'
    if pane:
        return f"the PM in pane {pane}{in_tab}"
    return f"the PM session {presence.get('session_id')}"


def _live_driver(lease, presence, name) -> str:
    label = presence.get("pane_label")
    typable = label and not any(w.startswith("--") for w in label.split()) and label[0] not in "'\"" \
        and label[-1] not in "'\""
    reply = (label if typable else None) or presence.get("pane_id") or presence.get("session_id")
    wrong = f"--replace {name} does not name the current PM. " if name else ""
    space = programme_home.space_key(lease.get("server"), lease.get("workspace"))
    return (f"{wrong}{_driver_words(presence)} is still the live PM for space {space}: "
            f"{presence.get('why')}. To replace it, type: /auto:programme-takeover --replace {reply}  "
            "This session then drives the programme, and that PM's next programme write is refused. "
            "If you type nothing, that PM keeps driving and this session changes nothing.")


def _h_takeover(host, argv):
    _, opts = host._parse(_tokens(argv), values=("run", "replace"))
    sid = _caller(host)
    lease = _lease_for(host, opts, sid)
    run = lease["run"]

    def orphan_asks(status):
        return [r for r in _since_driver_changed(run, _requests(run, "takeover", sid))
                if status == "orphaned" and (r.get("payload") or {}).get("lease_status") == "orphaned"]

    # herdr reads take seconds; they run before the leases lock and the driver is re-checked under it.
    status = _fresh_status(lease)
    presence = None if orphan_asks(status) or status not in MOVABLE_STATES else _presence(lease, run)
    asked_now = status in MOVABLE_STATES and _since_driver_changed(run, _requests(run, "takeover", sid))
    made = _make_worktree(run) if asked_now else None

    def move(request, reason, evidence):
        extra = {"reason": reason, "evidence": evidence} if evidence else {"reason": reason}
        return _move(run, sid, "taken_over", sid,
                     lambda moved, rec: dict(_rearm_list(rec), request=_request_ref(request),
                                             request_text=(request.get("payload") or {}).get("text"),
                                             **_record_worktree(made, rec["programme"]), **extra))

    def body():
        status = _fresh_status(lease)
        if status == "expired":
            ended = _watcher_ids(programme_home._read_record(run) or {})
            programme_home._end_locked(run, EXPIRED_REASON, _stamp())
            ended.update(reason=EXPIRED_REASON, lease_status=status, request=None)
            raise _Refused("the agreement was never accepted, so the programme has ended; "
                           "run /auto:programme to start a new one", status, ended)
        if status not in MOVABLE_STATES:
            raise _Refused(f"the lease for {lease.get('key') or run} is {status}; "
                           "takeover needs a live or orphaned lease", status)
        if lease.get("session_id") == sid:
            raise _Refused("this session already holds the lease", status)
        asked = _since_driver_changed(run, _requests(run, "takeover", sid))
        if not asked:
            raise _Refused("no typed takeover request from this session; "
                           "Shawn types /auto:programme-takeover in this session first", status)
        if orphan_asks(status):
            return move(orphan_asks(status)[-1], "orphaned", None)
        if presence is None or presence["session_id"] != _driver(lease, run):
            raise _Refused("the PM changed while auto was checking it; run the takeover again", status)
        if presence["state"] == "gone":
            return move(asked[-1], "driver_gone", presence)
        named = [(r, n) for r in asked for n in [_replace_name((r.get("payload") or {}).get("text"))]
                 if n and _names_driver(n, presence)]
        if named:
            return move(named[-1][0], "replaced", dict(presence, replace_name=named[-1][1]))
        raise _Refused(_live_driver(lease, presence, _replace_name((asked[-1].get("payload") or {}).get("text"))),
                       status)

    try:
        moved = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "takeover", sid, exc)
    _finish(host, run, "taken_over", sid, moved, journal=False)
    if moved.get("evidence"):
        sys.stdout.write(f"Took over from {_driver_words(moved['evidence'])}: {moved['evidence'].get('why')}.\n")
    sys.stdout.write(host.render_restore(run))
    sys.stdout.write("Re-arm the remit watcher, the cron fallback and every watcher listed above "
                     "from this session; the old session's watchers can no longer beat.\n")
    return 0


def _h_handover(host, argv):
    positional, opts = host._parse(_tokens(argv), values=("run",))
    if len(positional) != 1:
        raise ValueError("usage: handover <session-id> [--run <id>]")
    target = programme_home.check_segment(positional[0])
    sid = _caller(host)
    lease = _lease_for(host, opts, sid)
    run = lease["run"]
    made = _make_worktree(run) if session_registry.caller_drives(programme_home._read_record(run), sid) else None

    def body():
        status = _fresh_status(lease)
        if status not in MOVABLE_STATES:
            raise _Refused(f"the lease is {status}; only a live or orphaned programme is handed over", status)
        if not session_registry.caller_drives(programme_home._read_record(run), sid):
            raise _Refused("only the driving session may hand the programme over", status)
        if target == sid:
            raise _Refused("this session already drives the programme", status)
        asked = [r for r in _requests(run, "handover", sid)
                 if _cited_typed(run, r, sid)
                 and target in str((r.get("payload") or {}).get("text") or "").split()]
        if not asked:
            raise _Refused(f"no typed /auto:programme-handover {target} in the driving session", status)
        cites = list(asked[-1]["cites"])
        moved = _move(run, target, "handed_over", sid,
                      lambda moved, rec: dict(_record_worktree(made, rec["programme"]),
                                              request=_request_ref(asked[-1])), cites=cites)
        return dict(moved, prompt_id=cites[0])

    try:
        moved = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "handover", sid, exc)
    _finish(host, run, "handed_over", sid, moved, journal=False)
    _flag_for_successor(run, target)
    return 0


def _flag_for_successor(run, target) -> None:
    # The new driver never saw this programme's context; its first write waits for an ack of it.
    resume = load_lib_module("programme_resume")
    try:
        record, _ = resume.head(run)
        resume.mark(programme_home.home_path(run), target, "handover", resume.context_digest(run, record))
    except Exception as exc:
        sys.stderr.write(f"programme.py: handover could not flag the restore for {target}: {exc}\n")


def _end_request(run, sid, status):
    drives = session_registry.caller_drives(programme_home._read_record(run), sid)
    if drives:
        asked = [r for r in _requests(run, "end", sid) if _cited_typed(run, r, sid)]
    elif status == "orphaned":
        asked = _requests(run, "end", sid)
    else:
        raise _Refused("end needs a typed /auto:programme-end in the driving session, "
                       "or an orphaned lease", status)
    if not asked:
        raise _Refused("no typed /auto:programme-end from this session", status)
    return asked[-1]


def _watcher_ids(record) -> dict:
    watchers = (record.get("programme") or {}).get("watchers") or {}
    entries = [w for w in watchers.values() if isinstance(w, dict)]

    def task_ids(kind):
        return sorted({str(w["task_id"]) for w in entries
                       if w.get("task_id") and programme_home.watcher_kind(w) == kind})

    return {"cron_task_ids": task_ids("cron"), "monitor_task_ids": task_ids("monitor"),
            "process_ids": sorted({str(w["process_id"]) for w in entries if w.get("process_id")})}


def _h_end(host, argv):
    _, opts = host._parse(_tokens(argv), values=("run", "why"))
    sid = _caller(host)
    lease = _lease_for(host, opts, sid)
    run = lease["run"]

    def body():
        status = _fresh_status(lease)
        if status in ("free", "ended", "newer"):
            raise _Refused(f"the programme is {status}; nothing to end", status)
        if status == "expired":
            reason, request = EXPIRED_REASON, None
        else:
            reason, request = END_REASON, _end_request(run, sid, status)
        record = programme_home._read_record(run) or {}
        out = _watcher_ids(record)
        corrections = programme_terms.end_lines(record.get("programme") or {})
        if corrections:
            out["corrections"] = corrections
        out.update(reason=reason, why=opts.get("why"), lease_status=status,
                   request=request and _request_ref(request))
        cites = (request or {}).get("cites")
        programme_home._end_locked(run, reason, _stamp(),
                                   programme_journal.entry("programme_ended", sid, out, cites=cites))
        return out, cites

    try:
        out, cites = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "end", sid, exc)
    _finish(host, run, "programme_ended", sid, out, cites=cites, journal=False)
    sys.stdout.write(f"Programme {run} ended.\n")
    for line in out.get("corrections") or []:
        sys.stdout.write(f"Applied {line}\n")
    _cleanup_lines(out, run)
    sys.stdout.write(f"Then record each stop: release-resources --run {run} (add --watcher <watcher id> --stopped "
                     f"after each CronDelete or TaskStop), and check-archive --run {run} before archive.\n")
    return 0


def _h_expire(host, argv):
    _, opts = host._parse(argv, values=("run",))
    sid = driver_session.driving_session_id()
    lease = _lease_for(host, opts, sid)
    run = lease["run"]

    def body():
        status = _fresh_status(lease)
        if status != "expired":
            return status, None
        out = dict(_watcher_ids(programme_home._read_record(run) or {}), reason=EXPIRED_REASON, ended=True)
        programme_home._end_locked(run, EXPIRED_REASON, _stamp(),
                                   programme_journal.entry("programme_ended", sid, out))
        return status, out

    status, out = _locked(body)
    if out is None:
        host._emit({"ok": True, "run": run, "ended": False, "lease_status": status})
        return 0
    _finish(host, run, "programme_ended", sid, out, journal=False)
    return 0


def _h_beat(host, argv):
    _, opts = host._parse(argv, values=("run",))

    def change(programme, prompt, rec):
        stamp = run_record_core.now_iso()
        rec.setdefault("loop", {})["last_beat_at"] = stamp
        return {"last_beat_at": stamp}

    return host._write(opts, change, "beat", compact_exempt=True, journal=False)


def _remit_error(text):
    return programme_home.ProgrammeHomeError(f"set-remit: {text}")


def _capped(rows, part, cap) -> list:
    if not isinstance(rows, list):
        raise _remit_error(f"{part} must be a list")
    if len(rows) > cap:
        raise _remit_error(f"{part} holds {len(rows)} entries; at most {cap}")
    return rows


def _named_entry(raw, part, *, key_re=None):
    if not isinstance(raw, dict):
        raise _remit_error(f"each {part} entry is an object")
    name = programme_sanitize.clean(raw.get("name"), REMIT_NAME_CAP) or None
    ident = programme_sanitize.token(raw.get("id"), REMIT_ID_CAP) if raw.get("id") is not None else None
    entry = {"name": name, "id": ident}
    if key_re is not None:
        key = raw.get("key")
        if not isinstance(key, str) or not key_re.fullmatch(key):
            raise _remit_error(f"{part} key must be an issue prefix such as AI, got {key!r}")
        entry = dict(key=key, **entry)
    elif not (name or ident):
        raise _remit_error(f"each {part} entry needs a name or an id")
    return entry


def _repo_entry(raw):
    if not isinstance(raw, dict) or not isinstance(raw.get("path"), str):
        raise _remit_error("each repo is an object with a path")
    path = raw["path"]
    if not os.path.isabs(path) or ".." in path.split(os.sep) or not os.path.isdir(path):
        raise _remit_error(f"repo path must be an absolute directory, got {path!r}")
    github = raw.get("github")
    if github is not None and (not isinstance(github, str) or not _GITHUB_RE.fullmatch(github)):
        raise _remit_error(f"repo github must be owner/name, got {github!r}")
    return {"path": os.path.normpath(path), "github": github}


def parse_remit(doc, current) -> dict:
    if not isinstance(doc, dict):
        raise _remit_error("the remit is a JSON object")
    out = {"spaces": current.get("spaces") or [], "repos": current.get("repos") or [],
           "tracker": dict(current.get("tracker") or programme_home.empty_tracker_scope())}
    if "spaces" in doc:
        spaces = []
        for spec in _capped(doc["spaces"], "spaces", REMIT_CAPS["spaces"]):
            server, workspace = programme_home.parse_space(spec)
            if {"server": server, "workspace": workspace} not in spaces:
                spaces.append({"server": server, "workspace": workspace})
        if not spaces:
            raise _remit_error("the remit needs at least one herdr space")
        out["spaces"] = spaces
    if "repos" in doc:
        out["repos"] = [_repo_entry(r) for r in _capped(doc["repos"], "repos", REMIT_CAPS["repos"])]
    tracker = doc.get("tracker", {})
    if not isinstance(tracker, dict):
        raise _remit_error("tracker is an object of teams, projects and initiatives")
    for part in programme_home.TRACKER_SCOPE_PARTS:
        if part in tracker:
            rows = _capped(tracker[part], part, REMIT_CAPS[part])
            out["tracker"][part] = [_named_entry(r, part, key_re=_TEAM_KEY_RE if part == "teams" else None)
                                    for r in rows]
    return out


def _space_key(space) -> str:
    return f"{space['server']}.{space['workspace']}"


def _identity(part, entry) -> str:
    if part == "spaces":
        return _space_key(entry)
    if part == "repos":
        return entry["path"]
    if part == "teams":
        return entry["key"]
    return entry.get("id") or entry.get("name")


def _names(part, entry) -> tuple:
    if part == "spaces":
        return (entry["workspace"], _space_key(entry))
    if part == "repos":
        options = [os.path.basename(entry["path"])]
        if entry.get("github"):
            options += [entry["github"].split("/")[1], entry["github"]]
        return tuple(options)
    return tuple(o for o in (entry.get("key"), entry.get("name"), entry.get("id")) if o)


def remit_changes(before, after) -> list:
    changes = []
    pairs = [("spaces", before["spaces"], after["spaces"]), ("repos", before["repos"], after["repos"])]
    pairs += [(part, before["tracker"][part], after["tracker"][part])
              for part in programme_home.TRACKER_SCOPE_PARTS]
    for part, old, new in pairs:
        old_ids = {_identity(part, e): e for e in old}
        new_ids = {_identity(part, e): e for e in new}
        changes += [(part, "added", e) for k, e in new_ids.items() if k not in old_ids]
        changes += [(part, "removed", e) for k, e in old_ids.items() if k not in new_ids]
    return changes


def _move_leases(run, sid, home, changes) -> None:
    stamp = _stamp()
    moves = []
    for part, how, space in changes:
        if part != "spaces":
            continue
        path = programme_home.lease_path(space["server"], space["workspace"])
        lease = programme_home.read_lease(path)
        ours = bool(lease) and lease.get("run") == run
        if how == "added" and not ours:
            status = programme_home.lease_status(lease)
            if status not in ("free", "ended"):
                raise programme_home.LeaseHeld(_space_key(space), lease, status)
        moves.append((how, space, path, ours))
    for how, space, path, ours in moves:
        if how == "removed" and ours:
            os.unlink(path)
        elif how == "added" and not ours:
            programme_home._write_lease(space["server"], space["workspace"], run, home, sid, stamp)


def _h_set_remit(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if positional:
        raise ValueError("usage: set-remit [--prompt <id>] [--run <id>] < remit.json")
    raw = sys.stdin.read(REMIT_INPUT_CAP + 1) if not sys.stdin.isatty() else ""
    if len(raw) > REMIT_INPUT_CAP:
        raise ValueError(f"set-remit input is larger than {REMIT_INPUT_CAP} bytes")
    try:
        doc = json.loads(raw)
    except ValueError:
        raise ValueError("set-remit reads the remit as a JSON object on stdin") from None
    # git worktree add is slow: it runs on the remit-to-be before the leases lock, recorded under it.
    run, _, record = host._locate(opts)
    current = programme_home.normalize_programme(record.get("programme") or {})
    try:
        drives = session_registry.caller_drives(record, driver_session.driving_session_id())
        made = _make_worktree(run, dict(current, remit=parse_remit(doc, current["remit"]))) if drives else None
    except (ValueError, programme_home.ProgrammeHomeError):
        made = None

    def change(programme, prompt, rec):
        before = programme["remit"]
        after = parse_remit(doc, before)
        changes = remit_changes(before, after)
        accepted = programme["agreement"].get("accepted")
        if accepted and prompt is None:
            raise host.ProgrammeError("the agreement is accepted; set-remit needs --prompt <id> of a typed prompt")
        if accepted:
            host.require_named(prompt, *[_names(part, entry) for part, _, entry in changes])
        _move_leases(rec["run_id"], rec.get("driving_session_id"), programme_home.home_path(rec["run_id"]),
                     changes)
        programme["remit"] = dict(before, **after)
        term = programme["agreement"]["terms"]["remit"]
        term.update(set_by="shawn" if prompt else "proposal", set_at=_stamp())
        host.programme_proposals.settle_remit(term, changes)
        if prompt:
            term.update(prompt_id=prompt["prompt_id"], quote=prompt["quote"])
        out = {"remit": after,
               "changes": [{"part": part, "change": how, "entry": entry} for part, how, entry in changes]}
        if after["repos"]:
            out.update(_record_worktree(made, programme))
        if not accepted:
            carried, notices = programme_carryover.prefill(host, programme)
            out.update({"carried_over": carried} if carried else {}, **({"notices": notices} if notices else {}))
        return out

    return programme_home._with_leases_lock(
        lambda: host._write(opts, change, "remit_set", prompt_id=opts.get("prompt"),
                            verb="set-remit", target="remit"))


_SPECS = (
    ("start", _h_start, "[<server.workspace>|--space <server.workspace>]...",
     "a session outside a herdr space with no --space; a space whose lease is live, orphaned or "
     "newer (the error names the holding run and session). Takes the lease before anything else."),
    ("takeover", _h_takeover, "[--replace <pane name>] [--run <id>]",
     "no typed /auto:programme-takeover from this session; a request already used; a lease that is "
     "not live or orphaned; a driver herdr still shows (or cannot rule out) unless the typed request "
     "says --replace with its pane name, pane id or session id, and a heartbeat-orphaned lease "
     "needs no proof when the request was typed while it was orphaned. Refusals are journaled as "
     "request_refused."),
    ("handover", _h_handover, "<session-id> [--run <id>]",
     "a caller that is not the driving session; no typed /auto:programme-handover <session-id> in "
     "the driving session. Refusals are journaled as request_refused."),
    ("end", _h_end, "[--why <text>] [--run <id>]",
     "no typed /auto:programme-end from the driving session, unless the lease is orphaned; an "
     "ended programme. Prints CronDelete for each cron watcher and TaskStop for each Monitor "
     "watcher. Refusals are journaled."),
    ("expire", _h_expire, "[--run <id>]",
     "nothing: it ends the programme only when its agreement stayed unaccepted past one cadence."),
    ("set-remit", _h_set_remit, "[--prompt <id>] [--run <id>] < JSON {spaces, repos, tracker}",
     "input that is not a JSON object; a repo path that is not an absolute directory; a github "
     "name that is not owner/name; a team key that is not an issue prefix; a list over its cap; no "
     "space; a space another programme holds. Once the agreement is accepted it needs a typed "
     "--prompt that names each space, repo, team, project or initiative added or removed. A "
     "part left out keeps its value. Adding a space takes its lease; removing one releases it."),
    ("beat", _h_beat, "[--run <id>]",
     "a caller that is not the driving session. Stamps the driver beat that keeps the lease live; "
     "exempt from the compact flag; not journaled."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

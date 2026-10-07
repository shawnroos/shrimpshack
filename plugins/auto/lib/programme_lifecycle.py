#!/usr/bin/env python3
"""Programme lifecycle verbs: start, takeover, handover, end, expire and beat.

Takeover, handover and end act only on a request the prompt hook journaled from
the caller's own session. Moving a programme rewrites every lease of the run and
the record's driving session together, under the leases lock and then the
run-record lock.
"""

from __future__ import annotations

import functools
import os
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

END_REASON = "ended_by_shawn"
EXPIRED_REASON = "agreement_unaccepted"
MOVABLE_STATES = ("live", "orphaned")
CONSUMING_KINDS = ("taken_over", "handed_over", "programme_ended")


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
    used = [(r.get("payload") or {}).get("request") for r in rows if r.get("kind") in CONSUMING_KINDS]
    return [r for r in rows
            if r.get("kind") == f"{verb}_request" and r.get("session_id") == sid
            and (r.get("payload") or {}).get("origin") == "typed" and _request_ref(r) not in used]


def _cited_typed(run, request, sid) -> bool:
    cites = request.get("cites") or []
    if not (request.get("payload") or {}).get("driving") or not cites:
        return False
    row = programme_journal.find_prompt(run, cites[0])
    return bool(row) and row.get("session_id") == sid and (row.get("payload") or {}).get("origin") == "typed"


def _journal(run, kind, sid, payload, cites=None) -> None:
    if os.path.isdir(programme_home.home_path(run)):
        programme_journal.append(run, kind, sid, payload, cites=cites)


def _cleanup_lines(ended) -> None:
    for task_id in ended.get("cron_task_ids") or []:
        sys.stdout.write(f"Remove the cadence fallback: CronDelete {task_id}\n")
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
        _cleanup_lines(exc.ended)
    raise host.ProgrammeError(exc.reason)


def _move(run, new_sid) -> dict:
    home = programme_home.home_path(run)
    seen = {}

    def mutate(rec):
        seen["from"] = rec.get("driving_session_id")
        rec["driving_session_id"] = new_sid
        rec.setdefault("loop", {})["last_beat_at"] = run_record_core.now_iso()

    run_record_core._with_locked_run_record(home, run, mutate)
    keys = []
    for key, lease in _run_leases(run):
        programme_home._write_lease(lease["server"], lease["workspace"], run, lease["home"], new_sid,
                                    lease.get("created_at") or _stamp())
        keys.append(key)
    return {"from_session": seen["from"], "to_session": new_sid, "leases": keys}


def _rearm_list(record) -> dict:
    programme = record.get("programme") or {}
    waits = [{"item": item_id, "waiting_on": item.get("waiting_on")}
             for item_id, item in sorted((programme.get("items") or {}).items())
             if isinstance(item, dict) and item.get("state") == "waiting"]
    return {"waits": waits, "watchers": sorted((programme.get("watchers") or {}).keys())}


def _locked(body):
    return programme_home._with_leases_lock(body)


def _finish(host, run, kind, sid, payload, cites=None) -> None:
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


def _h_takeover(host, argv):
    _, opts = host._parse(argv, values=("run",))
    sid = _caller(host)
    lease = _lease_for(host, opts, sid)
    run = lease["run"]

    def body():
        status = _fresh_status(lease)
        if status == "expired":
            ended = _watcher_ids(programme_home._read_record(run) or {})
            programme_home._end_locked(run, EXPIRED_REASON, _stamp())
            ended.update(reason=EXPIRED_REASON, lease_status=status, request=None)
            raise _Refused("the agreement was never accepted, so the programme has ended; "
                           "run /auto:programme to start a new one", status, ended)
        if status != "orphaned":
            raise _Refused(f"the lease for {lease.get('key') or run} is {status}; "
                           "takeover needs an orphaned lease", status)
        if lease.get("session_id") == sid:
            raise _Refused("this session already holds the lease", status)
        asked = [r for r in _requests(run, "takeover", sid)
                 if (r.get("payload") or {}).get("lease_status") == "orphaned"]
        if not asked:
            raise _Refused("no typed takeover request from this session while the lease was orphaned; "
                           "Shawn types /auto:programme-takeover in this session first", status)
        moved = _move(run, sid)
        moved["request"] = _request_ref(asked[-1])
        moved["request_text"] = (asked[-1].get("payload") or {}).get("text")
        return moved

    try:
        moved = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "takeover", sid, exc)
    record = programme_home._read_record(run) or {}
    moved.update(_rearm_list(record))
    _finish(host, run, "taken_over", sid, moved)
    sys.stdout.write(host.render_rules(record))
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
        moved = _move(run, target)
        moved["request"] = _request_ref(asked[-1])
        moved["cites"] = list(asked[-1]["cites"])
        return moved

    try:
        moved = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "handover", sid, exc)
    cites = moved.pop("cites")
    moved["prompt_id"] = cites[0]
    _finish(host, run, "handed_over", sid, moved, cites=cites)
    return 0


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
    return {"cron_task_ids": sorted({str(w["task_id"]) for w in entries if w.get("task_id")}),
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
        out = _watcher_ids(programme_home._read_record(run) or {})
        programme_home._end_locked(run, reason, _stamp())
        out.update(reason=reason, why=opts.get("why"), lease_status=status,
                   request=request and _request_ref(request))
        return out, (request or {}).get("cites")

    try:
        out, cites = _locked(body)
    except _Refused as exc:
        _refuse(host, run, "end", sid, exc)
    _finish(host, run, "programme_ended", sid, out, cites=cites)
    sys.stdout.write(f"Programme {run} ended.\n")
    _cleanup_lines(out)
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
        out = _watcher_ids(programme_home._read_record(run) or {})
        programme_home._end_locked(run, EXPIRED_REASON, _stamp())
        return status, out

    status, out = _locked(body)
    if out is None:
        host._emit({"ok": True, "run": run, "ended": False, "lease_status": status})
        return 0
    out.update(reason=EXPIRED_REASON, ended=True)
    _finish(host, run, "programme_ended", sid, out)
    return 0


def _h_beat(host, argv):
    _, opts = host._parse(argv, values=("run",))

    def change(programme, prompt, rec):
        stamp = run_record_core.now_iso()
        rec.setdefault("loop", {})["last_beat_at"] = stamp
        return {"last_beat_at": stamp}

    return host._write(opts, change, "beat", compact_exempt=True, journal=False)


_SPECS = (
    ("start", _h_start, "[<server.workspace>|--space <server.workspace>]...",
     "a session outside a herdr space with no --space; a space whose lease is live, orphaned or "
     "newer (the error names the holding run and session). Takes the lease before anything else."),
    ("takeover", _h_takeover, "[--run <id>]",
     "a lease that is not orphaned; no typed /auto:programme-takeover from this session while the "
     "lease was orphaned; a request already used. Refusals are journaled as request_refused."),
    ("handover", _h_handover, "<session-id> [--run <id>]",
     "a caller that is not the driving session; no typed /auto:programme-handover <session-id> in "
     "the driving session. Refusals are journaled as request_refused."),
    ("end", _h_end, "[--why <text>] [--run <id>]",
     "no typed /auto:programme-end from the driving session, unless the lease is orphaned; an "
     "ended programme. Prints the cron task ids to remove. Refusals are journaled."),
    ("expire", _h_expire, "[--run <id>]",
     "nothing: it ends the programme only when its agreement stayed unaccepted past one cadence."),
    ("beat", _h_beat, "[--run <id>]",
     "a caller that is not the driving session. Stamps the driver beat that keeps the lease live; "
     "exempt from the compact flag; not journaled."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

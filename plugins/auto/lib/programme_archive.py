#!/usr/bin/env python3
"""End, checked archive and successor for a programme.

End commits the stop fence together with the resources the programme still owes
(leases, watchers, workers). Release receipts, item dispositions and a human's
acceptance of an uncertain action are recorded after it. Archiving checks a capture
revision C, publishes a candidate manifest, then seals in one store commit based on
C while every home writer is held out. A sealed home is read-only; more work goes to
a successor programme that links the archive and waits for its own acceptance.
Nothing here deletes retained data.
"""

from __future__ import annotations

import functools
import json
import os
import secrets
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")

CLOSURE = programme_home.CLOSURE
ARCHIVE = programme_home.ARCHIVE
sealed = programme_home.sealed
ITEM_DISPOSITIONS = ("stopped_unfinished", "handed_over")
UNCERTAIN_DISPOSITIONS = ("abandoned_unknown", "accepted_unknown")
UNFINISHED = ("open", "waiting")
MANIFEST_FORMAT = "programme-archive-manifest/1"
MANIFEST_MEDIA = "application/json"
MAX_ATTEMPTS = 20
RESUME_FILE = ".test-resume-archive"
PAUSE_POINTS = ("after_end_commit", "after_candidate", "view", "claim")
NOT_COMPLETED = "uncertainty accepted by a human; the action is not recorded as completed"


class ArchiveError(Exception):
    def __init__(self, message, code="archive_refused", checks=None):
        super().__init__(message)
        self.code = code
        self.checks = checks


class _Unchanged(Exception):
    pass


def _authority():
    return load_lib_module("programme_authority")


def _artifacts():
    return load_lib_module("programme_artifacts")


def _now() -> str:
    return run_record_core.now_iso()


def pause(point) -> None:
    if not run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_" + point.upper()):
        return
    resume = os.path.join(programme_home.programmes_dir(), RESUME_FILE + "-" + point)
    print("paused:archive_" + point, flush=True)
    for _ in range(600):
        if os.path.exists(resume):
            os.unlink(resume)
            return
        time.sleep(0.1)


def _resource(kind, **fields) -> dict:
    return dict({"kind": kind, "state": "pending", "receipts": []}, **fields)


def _owed(record, leases, ended_by) -> dict:
    programme = record.get("programme") or {}
    owed = {f"lease:{key}": _resource("lease", space=key) for key in leases}
    for wid, watcher in sorted((programme.get("watchers") or {}).items()):
        if not isinstance(watcher, dict):
            continue
        parts = [p for p, key in (("process", "process_id"), ("task", "task_id")) if watcher.get(key)]
        if parts:
            owed[f"watcher:{wid}"] = _resource(
                "watcher", watcher=wid, process_id=watcher.get("process_id"), task_id=watcher.get("task_id"),
                watcher_kind=programme_home.watcher_kind(watcher), parts={p: None for p in parts})
    closers = {record.get("driving_session_id"), ended_by}
    for key, item in sorted((programme.get("items") or {}).items()):
        sid = ((item or {}).get("owner") or {}).get("session_id")
        if sid and sid not in closers and f"worker:{sid}" not in owed:
            owed[f"worker:{sid}"] = _resource("worker", session_id=sid, item=key,
                                             pane=(item.get("owner") or {}).get("pane"))
    return owed


def open_closure(record, leases, ended_by, stamp) -> dict:
    """Called inside the end commit, so the fence and what the programme still owes commit together."""
    programme = record.setdefault("programme", {})
    if not isinstance(programme.get(CLOSURE), dict):
        programme[CLOSURE] = {"fenced_at": stamp, "ended_by": ended_by,
                              "resources": _owed(record, leases, ended_by), "dispositions": {}}
    return programme[CLOSURE]


def _closure(programme) -> dict:
    block = programme.get(CLOSURE)
    if not isinstance(block, dict):
        raise ArchiveError("this programme ended before closure tracking; run release-resources to record "
                           "what it owes", "no_closure")
    return block


def _receipt(resource, part, outcome, source, detail, sid) -> bool:
    if resource.get("state") == "released":
        return False
    last = next((r for r in reversed(resource.get("receipts") or []) if r.get("part") == part), None)
    entry = {"part": part, "outcome": outcome, "source": source, "detail": detail}
    if last and {k: last.get(k) for k in entry} == entry:
        return False
    resource.setdefault("receipts", []).append(dict(entry, at=_now(), by=sid))
    parts = resource.setdefault("parts", {part: None})
    parts[part] = outcome
    if all(v == "confirmed" for v in parts.values()):
        resource["state"] = "released"
    elif any(v in ("unconfirmed", "denied") for v in parts.values()):
        resource["state"] = "unconfirmed"
    else:
        resource["state"] = "pending"
    return True


def _lease_observation(run_id, space):
    server, workspace = space.split(".", 1)
    lease = programme_home.read_lease(programme_home.lease_path(server, workspace))
    if lease is None:
        return "confirmed", "lease_file", "the lease file is gone"
    if not lease.get("corrupt") and lease.get("run") != run_id:
        return "confirmed", "lease_file", f"the space is now held by {lease.get('run')}"
    return "pending", "lease_file", "the lease file still names this programme"


def _pid_observation(pid):
    try:
        number = int(pid)
    except (TypeError, ValueError):
        return "unconfirmed", f"{pid!r} is not a process id"
    if number <= 1:
        return "unconfirmed", f"{number} is not a watcher's process id"
    try:
        os.kill(number, 0)
    except ProcessLookupError:
        return "confirmed", "no process has this id"
    except PermissionError:
        return "unconfirmed", "a process with this id is running under another user; auto never stops it"
    return "unconfirmed", ("a process with this id is still running; it may be the watcher or a reused id, "
                           "and auto never stops it")


def _observe(run_id, resources, reports, rows, sid) -> bool:
    changed = False
    for rid, res in sorted(resources.items()):
        if res.get("state") == "released":
            continue
        kind = res.get("kind")
        if kind == "lease":
            outcome, source, detail = _lease_observation(run_id, res["space"])
            changed |= _receipt(res, "lease", outcome, source, detail, sid)
        elif kind == "watcher":
            if "process" in res.get("parts", {}) and res["parts"]["process"] != "confirmed":
                outcome, detail = _pid_observation(res.get("process_id"))
                changed |= _receipt(res, "process", outcome, "pid_probe", detail, sid)
            report = reports.get(res.get("watcher"))
            if "task" in res.get("parts", {}) and report:
                outcome = "confirmed" if report["result"] == "stopped" else "denied"
                changed |= _receipt(res, "task", outcome, "pm_reported_tool_result",
                                    report.get("why") or report["result"], sid)
        elif kind == "worker":
            if rows is None:
                outcome, detail = "unconfirmed", "herdr agent list is unavailable, so the worker cannot be seen"
            elif any(_row_session(r) == res.get("session_id") for r in rows):
                outcome, detail = "unconfirmed", "herdr still lists this worker session; stop it there"
            else:
                outcome, detail = "confirmed", "herdr no longer lists this worker session"
            changed |= _receipt(res, "worker", outcome, "herdr_agent_list", detail, sid)
    return changed


def _row_session(row) -> str | None:
    session = (row or {}).get("agent_session") or {}
    return session.get("value") if isinstance(session, dict) else None


def _reconcile(run_id, sid, reports, rows, *, leases_only=False) -> dict:
    home = programme_home.home_path(run_id)
    seen = {}

    def mutate(rec):
        programme = rec.setdefault("programme", {})
        if sealed(programme):
            raise ArchiveError("the programme is archived; its home is read-only", "sealed")
        if not programme.get("ended"):
            raise ArchiveError("the programme has not ended", "not_ended")
        if not isinstance(programme.get(CLOSURE), dict):
            leases = [k for k, lease in programme_home.iter_leases() if lease and lease.get("run") == run_id]
            open_closure(rec, leases, None, _now())
        resources = programme[CLOSURE]["resources"]
        unknown = sorted(w for w in reports if f"watcher:{w}" not in resources)
        if unknown:
            raise ArchiveError(f"no owed watcher {unknown[0]!r}", "unknown_resource")
        observed = {k: v for k, v in resources.items() if v.get("kind") == "lease"} if leases_only else resources
        if not _observe(run_id, observed, reports, rows, sid):
            raise _Unchanged()
        seen["summary"] = _summary(resources)

    def compose(_, rec):
        return programme_journal.entry("resources_reconciled", sid, seen["summary"])

    try:
        _authority().write(home, run_id, mutate, compose)
    except _Unchanged:
        pass
    record = programme_home._read_record(run_id) or {}
    return _summary(_closure(record.get("programme") or {})["resources"])


def _summary(resources) -> dict:
    out = {"released": [], "unconfirmed": [], "pending": []}
    for rid, res in sorted(resources.items()):
        out.setdefault(res.get("state"), []).append(rid)
    return out


def settle_leases(run_id) -> None:
    """After end unlinks the lease files: record which are confirmed gone. Callers hold the leases lock."""
    record = programme_home._read_record(run_id) or {}
    resources = ((record.get("programme") or {}).get(CLOSURE) or {}).get("resources") or {}
    if not any(r.get("kind") == "lease" and r.get("state") != "released" for r in resources.values()):
        return
    try:
        _reconcile(run_id, None, {}, None, leases_only=True)
    except (ArchiveError, run_record_core.RunRecordError) as exc:
        sys.stderr.write(f"programme archive: lease receipts for {run_id} not recorded: {exc}\n")


def _caller_may_close(record, sid, *, need_ended=True) -> None:
    programme = record.get("programme") or {}
    if sealed(programme):
        raise ArchiveError("the programme is archived; its home is read-only", "sealed")
    if need_ended and not programme.get("ended"):
        raise ArchiveError("the programme has not ended; end it first with /auto:programme-end", "not_ended")
    closers = {record.get("driving_session_id")}
    if programme.get("ended"):
        closers.add((programme.get(CLOSURE) or {}).get("ended_by"))
    if not sid or sid not in closers:
        raise ArchiveError("only the driving session, or the session that ended the programme, closes it",
                           "not_owner")


def _check(name, failures, remedy) -> dict:
    return {"check": name, "ok": not failures, "failures": failures, "remedy": remedy if failures else None}


def _integrity(run_id) -> list:
    store_mod = load_lib_module("programme_store")
    with store_mod.open_store(run_id) as store:
        report = store.check_integrity()
    if report["ok"]:
        return []
    return [{"id": "programme.db", "reason": "; ".join(str(x) for x in
                                                      report["integrity"] + report["foreign_keys"]
                                                      + report["references"])[:400]}]


def _unreadable(run_id, programme) -> list:
    artifacts = _artifacts()
    retained = programme.get("retained") or {}
    failures = []
    for section in ("results", "sources"):
        for identity, entry in sorted((retained.get(section) or {}).items()):
            try:
                artifacts.read_object(run_id, artifacts.ref_of(entry))
            except (artifacts.ArtifactError, load_lib_module("programme_store").StoreError) as exc:
                failures.append({"id": identity, "reason": getattr(exc, "code", "invalid")})
    return failures


def _preservation(run_id, programme) -> list:
    artifacts = _artifacts()
    retained = programme.get("retained") or {}
    failures = []
    for inventory_id in sorted(retained.get("inventories") or {}):
        verdict = artifacts.cleanup_allowed(run_id, inventory_id)
        if not verdict["allowed"]:
            failures.append({"id": inventory_id, "reason": "; ".join(verdict["reasons"])})
    code = retained.get("code") or {}
    if code:
        preserve = load_lib_module("programme_preserve")
        for source_id in sorted(code):
            verdict = preserve.cleanup_check(run_id, source_id)
            left = [r for r in verdict["reasons"] if r != "source_missing"]
            if left:
                failures.append({"id": source_id, "reason": ", ".join(left)})
    for failure in retained.get("code_failures") or []:
        if (code.get(failure.get("source_id")) or {}).get("status") != "complete":
            failures.append({"id": failure.get("source_id"), "reason": failure.get("code")})
    return failures


def _open_operations(programme) -> list:
    recovery = load_lib_module("programme_recovery")
    ops = recovery.operations(programme)
    return [{"id": f"op:{u['attempt']}", "reason": f"{u['kind']} is {u['state']}"}
            for u in recovery.unreconciled_admissions(programme)
            if not (ops.get(u["attempt"]) or {}).get("disposition")]


def _unreleased(programme) -> list:
    block = programme.get(CLOSURE)
    if not isinstance(block, dict):
        return [{"id": "closure", "reason": "no closure fence was recorded at end"}]
    out = []
    for rid, res in sorted((block.get("resources") or {}).items()):
        if res.get("state") != "released" and not res.get("disposition"):
            last = (res.get("receipts") or [{}])[-1]
            out.append({"id": rid, "reason": f"{res.get('state')}: {last.get('detail') or 'no receipt yet'}"})
    return out


def _undisposed(programme) -> list:
    dispositions = (programme.get(CLOSURE) or {}).get("dispositions") or {}
    return [{"id": key, "reason": f"{item.get('state')} with no disposition"}
            for key, item in sorted((programme.get("items") or {}).items())
            if (item or {}).get("state") in UNFINISHED and key not in dispositions]


def evaluate(run_id, record) -> list:
    programme = record.get("programme") or {}
    ended = programme.get("ended")
    return [
        _check("ended", [] if ended else [{"id": "programme", "reason": "the programme has not ended"}],
               "type /auto:programme-end in the driving session, then run end"),
        _check("authority", _integrity(run_id), "the database failed its integrity check; repair it first"),
        _check("operations", _open_operations(programme),
               "run reconcile-operations; an action that stays uncertain needs dispose-action --attempt"),
        _check("resources", _unreleased(programme),
               "stop each one, then run release-resources (report TaskStop/CronDelete with --watcher <id> "
               "--stopped); one that cannot be confirmed needs dispose-action --resource"),
        _check("results", _unreadable(run_id, programme),
               "restore each retained copy's bytes from its source (collect-result again when the copy is "
               "missing); a copy that fails its digest is never used"),
        _check("preservation", _preservation(run_id, programme),
               "rerun collect-result or preserve-code for each named entry, then check-preservation"),
        _check("dispositions", _undisposed(programme),
               "record each unfinished item with dispose-item <id> --as stopped_unfinished|handed_over"),
    ]


def _outcomes(programme) -> dict:
    dispositions = (programme.get(CLOSURE) or {}).get("dispositions") or {}
    out = {"completed": [], "handed_over": [], "stopped_unfinished": [], "dropped": [], "decided": []}
    for key, item in sorted((programme.get("items") or {}).items()):
        state = (item or {}).get("state")
        if state == "done":
            out["completed"].append(key)
        elif state in ("dropped", "decided"):
            out[state].append(key)
        elif key in dispositions:
            out[dispositions[key]["as"]].append(key)
        elif state == "handed":
            out["handed_over"].append(key)
    return out


def manifest(run_id, record, capture_revision, checks) -> dict:
    programme = record.get("programme") or {}
    retained = programme.get("retained") or {}
    closure = programme.get(CLOSURE) or {}
    acceptance = load_lib_module("programme_context").evaluate(programme)
    ops = load_lib_module("programme_recovery").operations(programme)
    return {
        "format": MANIFEST_FORMAT,
        "run_id": run_id,
        "capture_revision": capture_revision,
        "ended": programme.get("ended"),
        "closure": {"fenced_at": closure.get("fenced_at"), "ended_by": closure.get("ended_by")},
        "outcomes": _outcomes(programme),
        "dispositions": closure.get("dispositions") or {},
        "acceptance": {"requirements": acceptance["requirements"], "satisfied": acceptance["satisfied"],
                       "note": "archiving confirms no requirement; each result is as recorded at capture"},
        "retained": {
            "results": {k: (v.get("ref") or {}).get("digest") for k, v in sorted((retained.get("results") or {}).items())},
            "sources": {k: (v.get("ref") or {}).get("digest") for k, v in sorted((retained.get("sources") or {}).items())},
            "code": {k: {"receipt_id": v.get("receipt_id"), "generation": v.get("generation"),
                         "status": v.get("status")} for k, v in sorted((retained.get("code") or {}).items())},
            "receipts": {k: v.get("receipt_id") for k, v in sorted((retained.get("receipts") or {}).items())},
        },
        "resources": {k: {"state": v.get("state"), "disposition": v.get("disposition")}
                      for k, v in sorted((closure.get("resources") or {}).items())},
        "operations": {k: {"kind": v.get("kind"), "state": v.get("state"), "disposition": v.get("disposition")}
                       for k, v in sorted(ops.items()) if isinstance(v, dict)},
        "checks": [c["check"] for c in checks],
    }


def _record_attempt(run_id, sid, capture_revision, failed) -> None:
    home = programme_home.home_path(run_id)
    attempt = {"at": _now(), "capture_revision": capture_revision,
               "failed": [{"check": c["check"], "ids": [f["id"] for f in c["failures"]][:20]} for c in failed]}

    def mutate(rec):
        programme = rec.setdefault("programme", {})
        if sealed(programme):
            raise _Unchanged()
        block = programme.setdefault(ARCHIVE, {})
        block["attempts"] = (list(block.get("attempts") or []) + [attempt])[-MAX_ATTEMPTS:]

    try:
        _authority().write(home, run_id, mutate,
                           lambda _r, _rec: programme_journal.entry("archive_check_failed", sid, attempt))
    except _Unchanged:
        pass


def _seal_view(run_id) -> dict:
    record = _authority().read_record(run_id)
    block = (record.get("programme") or {}).get(ARCHIVE) or {}
    return {k: block.get(k) for k in ("sealed_at", "sealed_revision", "capture_revision", "operation_id",
                                     "manifest", "sealed_by")}


def seal(host, run_id, sid, operation_id=None) -> dict:
    authority, artifacts = _authority(), _artifacts()
    home = programme_home.home_path(run_id)
    if not authority.promoted(home, run_id):
        raise ArchiveError(f"programme {run_id} is not promoted; run `programme.sh promote` first",
                           "not_promoted")
    snap = authority.snapshot(run_id)
    record = snap["record"]
    if sealed(record.get("programme")):
        info = _seal_view(run_id)
        return dict(info, status="already_sealed", replayed=info.get("operation_id") == operation_id)
    _caller_may_close(record, sid)
    capture = snap["revision"]
    checks = evaluate(run_id, record)
    failed = [c for c in checks if not c["ok"]]
    if failed:
        _record_attempt(run_id, sid, capture, failed)
        names = ", ".join(c["check"] for c in failed)
        raise ArchiveError(f"archive refused at revision {capture}: {names} failed; the programme stays "
                           "ended and unarchived", "checks_failed", checks)
    body = json.dumps(manifest(run_id, record, capture, checks), sort_keys=True, indent=1).encode("utf-8")
    with artifacts.publisher(run_id):
        ref = artifacts.publish(run_id, body, MANIFEST_MEDIA, provenance="derived",
                                basis="archive candidate manifest")
    pause("after_candidate")
    op = operation_id or "seal-" + secrets.token_hex(8)
    stamp = _now()
    seal_row = {"capture_revision": capture, "manifest": ref.digest, "operation_id": op}

    def mutate(rec):
        artifacts.read_object(run_id, ref)
        programme = rec.setdefault("programme", {})
        block = programme.setdefault(ARCHIVE, {})
        block.update(sealed_at=stamp, sealed_revision=capture + 1, capture_revision=capture,
                     operation_id=op, manifest=ref.as_dict(), sealed_by=sid)

    def compose(_, rec):
        return programme_journal.entry("programme_archived", sid, {
            "capture_revision": capture, "sealed_revision": capture + 1, "manifest": ref.digest,
            "operation_id": op})

    def commit():
        try:
            out = authority.write(home, run_id, mutate, compose, operation_id=op, base_revision=capture,
                                  seal=seal_row, payload_refs=(ref,))
        except authority.AuthorityError as exc:
            if exc.code == "stale_revision":
                raise ArchiveError(f"the candidate for revision {capture} was superseded by a later write; "
                                   "nothing was sealed; run archive again", "superseded")
            if exc.code == "sealed":
                return {"replayed": False, "already": True}
            raise
        if not out["replayed"]:
            host._write_view(home, host.build_view(run_id, home, authority.read_record(run_id)))
        return out

    out = artifacts.exclude_publishers(run_id, commit)
    info = _seal_view(run_id)
    return dict(info, status="already_sealed" if out.get("already") else "sealed",
                replayed=bool(out.get("replayed")))


def _read_manifest(run_id, info) -> dict:
    artifacts = _artifacts()
    ref = load_lib_module("programme_store").PayloadRef(**info["manifest"])
    return json.loads(artifacts.read_object(run_id, ref).decode("utf-8"))


def _write(host, opts, change, kind, *, need_ended=True, prompt_id=None):
    run_id, home, _ = host._locate(opts)
    sid = load_lib_module("driver_session").driving_session_id()
    seen = {}

    def mutate(rec):
        _caller_may_close(rec, sid, need_ended=need_ended)
        prompt = host._typed_prompt(run_id, rec, prompt_id) if prompt_id else None
        seen["payload"] = change(rec.setdefault("programme", {}), prompt, rec)

    def compose(_, rec):
        return programme_journal.entry(kind, sid, seen["payload"],
                                       cites=[prompt_id] if prompt_id else None)

    out = _authority().write(home, run_id, mutate, compose, operation_id=host._OPERATION["id"])
    payload = seen.get("payload") if not out["replayed"] else (out["row"] or {}).get("payload")
    host.refresh_view(run_id, home)
    host._emit(dict({"ok": True, "run": run_id, "kind": kind, "replayed": out["replayed"]}, **(payload or {})))
    return 0


def _h_dispose_item(host, argv):
    positional, opts = host._parse(argv, values=("run", "as", "why"))
    if len(positional) != 1 or opts.get("as") not in ITEM_DISPOSITIONS or not opts.get("why"):
        raise ValueError("usage: dispose-item <id> --as stopped_unfinished|handed_over --why <text> --run <id>")
    item_id = positional[0]

    def change(programme, prompt, rec):
        items = programme.get("items") or {}
        key = item_id if item_id in items else next(
            (k for k, i in items.items() if item_id in ((i or {}).get("aliases") or [])), None)
        if key is None:
            raise ArchiveError(f"no item {item_id!r} in this programme", "unknown_item")
        state = items[key].get("state")
        if state not in UNFINISHED + ("handed",):
            raise ArchiveError(f"item {key!r} is {state}; only unfinished work takes a disposition",
                               "not_unfinished")
        entry = {"as": opts["as"], "why": programme_journal.redact(opts["why"])[:400], "at": _now(),
                 "item_state": state}
        _closure(programme).setdefault("dispositions", {})[key] = entry
        return dict(entry, item=key)

    return _write(host, opts, change, "item_disposed")


def _h_dispose_action(host, argv):
    _, opts = host._parse(argv, values=("run", "attempt", "resource", "as", "prompt"))
    target = opts.get("attempt") or opts.get("resource")
    if bool(opts.get("attempt")) == bool(opts.get("resource")) or opts.get("as") not in UNCERTAIN_DISPOSITIONS:
        raise ValueError("usage: dispose-action (--attempt <id>|--resource <id>) "
                         "--as abandoned_unknown|accepted_unknown --prompt <id> --run <id>")
    if not opts.get("prompt"):
        raise ValueError("dispose-action needs --prompt <id> of a typed prompt that names the attempt or resource")

    def change(programme, prompt, rec):
        host.require_named(prompt, target)
        if opts.get("attempt"):
            entry = load_lib_module("programme_recovery").operations(programme).get(target)
            if not isinstance(entry, dict) or entry.get("state") not in ("admitted", "uncertain"):
                raise ArchiveError(f"no admitted or uncertain operation {target!r}", "not_uncertain")
        else:
            if not programme.get("ended"):
                raise ArchiveError("resources are owed only after end", "not_ended")
            entry = (_closure(programme).get("resources") or {}).get(target)
            if not isinstance(entry, dict) or entry.get("state") == "released":
                raise ArchiveError(f"no unreleased resource {target!r}", "not_uncertain")
        verified = prompt.get("origin_verified") is True
        entry["disposition"] = {"as": opts["as"], "prompt_id": prompt["prompt_id"], "quote": prompt["quote"],
                                "origin_verified": verified, "at": _now(), "effect": NOT_COMPLETED}
        return {"target": target, "as": opts["as"], "state": entry.get("state"), "origin_verified": verified,
                "effect": NOT_COMPLETED}

    return _write(host, opts, change, "uncertainty_accepted", need_ended=False, prompt_id=opts["prompt"])


def _h_release(host, argv):
    _, opts = host._parse(argv, values=("run", "watcher", "why"), flags=("stopped", "denied"))
    reports = {}
    if opts.get("watcher"):
        if bool(opts.get("stopped")) == bool(opts.get("denied")):
            raise ValueError("--watcher <id> needs exactly one of --stopped or --denied")
        reports[programme_home.check_segment(opts["watcher"])] = {
            "result": "stopped" if opts.get("stopped") else "denied", "why": opts.get("why")}
    run_id, _, record = host._locate(opts)
    sid = load_lib_module("driver_session").driving_session_id()
    _caller_may_close(record, sid)
    owes_workers = any(r.get("kind") == "worker" and r.get("state") != "released"
                       for r in ((record.get("programme") or {}).get(CLOSURE) or {}).get("resources", {}).values())
    rows = load_lib_module("programme_sources").agent_rows() if owes_workers else []

    def body():
        programme_home._release_leases(run_id)
        return _reconcile(run_id, sid, reports, rows)

    summary = programme_home._with_leases_lock(body)
    host.refresh_view(run_id, programme_home.home_path(run_id))
    host._emit(dict({"ok": not (summary.get("unconfirmed") or summary.get("pending")), "run": run_id,
                     "kind": "resources_reconciled"}, **summary))
    return 0


def _h_check(host, argv):
    _, opts = host._parse(argv, values=("run",))
    run_id, _, _ = host._locate(opts)
    snap = _authority().snapshot(run_id)
    record = snap["record"]
    if sealed(record.get("programme")):
        info = _seal_view(run_id)
        try:
            body = _read_manifest(run_id, info)
            readable = True
        except Exception as exc:
            body, readable = {"error": str(exc)}, False
        host._emit({"ok": readable, "run": run_id, "sealed": True, "revision": snap["revision"],
                    "archive": info, "manifest": body})
        return 0 if readable else 1
    checks = evaluate(run_id, record)
    host._emit({"ok": True, "run": run_id, "sealed": False, "revision": snap["revision"],
                "ready": all(c["ok"] for c in checks), "checks": checks})
    return 0


def _h_archive(host, argv):
    _, opts = host._parse(argv, values=("run",))
    run_id, _, _ = host._locate(opts)
    sid = load_lib_module("driver_session").driving_session_id()
    try:
        out = seal(host, run_id, sid, host._OPERATION["id"])
    except ArchiveError as exc:
        host._emit({"ok": False, "run": run_id, "code": exc.code, "reason": str(exc),
                    "checks": exc.checks, "sealed": False})
        return 1
    host._emit(dict({"ok": True, "run": run_id, "sealed": True}, **out))
    return 0


def _h_successor(host, argv):
    positional, opts = host._parse(argv, multi=("space",))
    if len(positional) != 1:
        raise ValueError("usage: create-successor <archived-run> [--space <server.workspace>]...")
    source = programme_home.check_run_id(positional[0])
    sid = load_lib_module("driver_session").driving_session_id()
    if not sid:
        raise host.ProgrammeError("CLAUDE_CODE_SESSION_ID is unset; run this from the Claude session itself")
    record = _authority().read_record(source)
    programme = record.get("programme") or {}
    if not sealed(programme):
        raise ArchiveError(f"programme {source} is not archived; only a sealed archive has a successor",
                           "not_sealed")
    info = _seal_view(source)
    body = _read_manifest(source, info)
    spaces = opts["space"] or [f"{s.get('server')}.{s.get('workspace')}"
                               for s in (programme.get("remit") or {}).get("spaces") or []]
    link = {"run": source, "manifest": info["manifest"]["digest"], "sealed_revision": info["sealed_revision"],
            "sealed_at": info["sealed_at"],
            "unfinished": sorted(body["outcomes"]["stopped_unfinished"] + body["outcomes"]["handed_over"])}
    made = programme_home.create_programme(spaces, sid, predecessor=link)
    programme_journal.append(made["run"], "successor_created", sid, {"predecessor": link})
    host.refresh_view(made["run"], made["home"])
    host._emit({"ok": True, "run": made["run"], "kind": "successor_created", "predecessor": link,
                "leases": made["leases"], "agreement": "waits for acceptance (accept-agreement --prompt <id>)"})
    return 0


def _guarded(handler, host, argv):
    try:
        return handler(host, argv)
    except ArchiveError as exc:
        raise host.ProgrammeError(str(exc)) from None


_SPECS = (
    ("check-archive", _h_check, "--run <id>  (read-only: named archive checks, or the sealed manifest)",
     "nothing; it never writes. Prints each check with its failures and remedy; for a sealed archive "
     "it prints the manifest after checking its digest."),
    ("release-resources", _h_release, "--run <id> [--watcher <id> --stopped|--denied [--why <text>]]",
     "a programme that has not ended or is archived; a caller other than the driving session or the "
     "session that ended it. Removes leftover lease files, probes watcher process ids and worker "
     "sessions without stopping anything, and records a receipt for each; a live or unreadable one "
     "stays unconfirmed. Exempt from the compact flag."),
    ("dispose-item", _h_dispose_item, "<id> --as stopped_unfinished|handed_over --why <text> --run <id>",
     "a programme that has not ended or is archived; an item that is done or dropped. Records how "
     "unfinished work stopped; it confirms no requirement."),
    ("dispose-action", _h_dispose_action,
     "(--attempt <id>|--resource <id>) --as abandoned_unknown|accepted_unknown --prompt <id> --run <id>",
     "a prompt that is not typed in the driving session or does not name the attempt or resource; an "
     "archived programme; an operation that is not admitted or uncertain; a released resource. Records "
     "a human's acceptance of the uncertainty (origin_verified true: the transcript shows a human typed "
     "the prompt); the action is never recorded as completed."),
    ("archive", _h_archive, "--run <id> [--op <id>]",
     "a programme that has not ended; any failed check (named with its remedy; the programme stays "
     "ended and unarchived); a candidate superseded by a later write. Seals once: a retry returns the "
     "existing seal."),
    ("create-successor", _h_successor, "<archived-run> [--space <server.workspace>]...",
     "a run that is not sealed; a space another programme holds. Starts a new programme linked to "
     "the archive's manifest; its agreement waits for acceptance and the archive is never written."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(_guarded, handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}

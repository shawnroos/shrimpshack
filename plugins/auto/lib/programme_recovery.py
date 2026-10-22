#!/usr/bin/env python3
"""Fenced external dispatch, its reconciliation, and the replacement PM's recovery packet.

A worker launch or a pane prompt commits its admission (target, owner epoch, request
digest) before it runs and its receipt after. An admission without a settled receipt is
named uncertainty: a retry on the same item refuses by default and archiving waits.
The recovery packet is built from one committed store revision and is context, not approval.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_authority = load_lib_module("programme_authority")
programme_context = load_lib_module("programme_context")
programme_artifacts = load_lib_module("programme_artifacts")

OPS_KEY = "operations"
EPOCH_KEY = "owner_epoch"
KINDS = ("launch", "send")
ACTIONS = {"launch": "start_worker", "send": "prompt_item"}
OPEN = ("admitted", "uncertain")
SETTLED = ("completed", "failed", "not_executed")
RECEIPT_OUTCOMES = ("completed", "failed")
JOURNAL_KINDS = ("operation_admitted", "operation_settled", "operation_uncertain")
# Chosen, not measured: short enough that a packet over many decisions stays readable; full text is
# one `recover --get <id>` away.
TEXT_CAP = 160
RESUME_FILE = ".test-resume-dispatch"
PAUSE_POINTS = ("before_admission", "after_admission", "before_invoke", "after_invoke")
NOT_VERIFIED = programme_artifacts.NOT_VERIFIED


class _Unchanged(Exception):
    pass


class DispatchError(Exception):
    def __init__(self, message, code="dispatch_refused"):
        super().__init__(message)
        self.code = code


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def canonical_sha(value) -> str:
    return "sha256:" + hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def owner_epoch(programme) -> int:
    try:
        return int((programme or {}).get(EPOCH_KEY) or 0)
    except (TypeError, ValueError):
        return 0


def operations(programme) -> dict:
    ops = (programme or {}).get(OPS_KEY)
    return ops if isinstance(ops, dict) else {}


def request_digest(kind, item, target, request) -> str:
    return canonical_sha({"kind": kind, "item": item, "target": target, "request": request})


def unreconciled_admissions(programme) -> list:
    out = []
    for attempt, op in sorted(operations(programme).items()):
        if isinstance(op, dict) and op.get("state") in OPEN:
            out.append({"attempt": attempt, "kind": op.get("kind"), "item": op.get("item"),
                        "state": op.get("state"), "target": op.get("target"),
                        "owner_epoch": op.get("owner_epoch"), "reason": op.get("reason")})
    return out


def unreconciled_for(run_id) -> list:
    """Admissions still owed a receipt; an unreadable authority raises rather than reading as none."""
    state = programme_authority.outcome(run_id)
    if state["outcome"] in programme_authority.HOLDS:
        raise DispatchError(f"programme {run_id} authority is {state['outcome']}; its admissions cannot "
                            "be read, so none can be assumed reconciled", "authority_held")
    record = run_record_core.read_run_record(programme_home.home_path(run_id), run_id)
    return unreconciled_admissions((record or {}).get("programme") or {})


def authority_reason(record, op_like) -> str | None:
    programme = (record or {}).get("programme") or {}
    if programme.get("ended"):
        return "the programme has ended, so no new external action is admitted"
    if programme_home.sealed(programme):
        return "the programme home is sealed"
    if record.get("driving_session_id") != op_like.get("owner_session"):
        return (f"the driving session is now {record.get('driving_session_id')}, not "
                f"{op_like.get('owner_session')}; this dispatcher's authority is stale")
    if owner_epoch(programme) != op_like.get("owner_epoch"):
        return (f"ownership moved (epoch {op_like.get('owner_epoch')} -> {owner_epoch(programme)}); "
                "this dispatcher's authority is stale")
    return None


def artifact_holds(run_id, programme, item=None) -> dict:
    holds = {}
    results = ((programme or {}).get("retained") or {}).get("results") or {}
    for identity, entry in sorted(results.items()):
        if not isinstance(entry, dict) or (item is not None and entry.get("item") != item):
            continue
        ref = entry.get("ref") or {}
        try:
            programme_artifacts.read_object(run_id, programme_artifacts.ref_of(entry))
        except programme_artifacts.ArtifactError as exc:
            holds.setdefault(entry.get("item") or "programme", []).append(
                {"kind": "artifact_" + exc.code, "result": identity, "digest": ref.get("digest"),
                 "reason": str(exc)})
    return holds


def pause(run_id, point) -> None:
    if not run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_DISPATCH_PAUSE_" + point.upper()):
        return
    run_record_core.test_pause("dispatch_" + point, os.path.join(programme_home.home_path(run_id), RESUME_FILE),
                               consume=True)


def _admission_refusal(run_id, programme, op, despite) -> str | None:
    reason = programme_context.unsafe_reason(programme, op["item"], ACTIONS[op["kind"]])
    if reason:
        return reason
    for prior in unreconciled_admissions(programme):
        if prior["item"] == op["item"] and prior["kind"] == op["kind"] and prior["attempt"] not in despite:
            return (f"{op['kind']} {prior['attempt']} on {op['item']} is {prior['state']} and not reconciled; "
                    "it is not retried by default. Run reconcile-operations, or pass --despite "
                    f"{prior['attempt']} to act knowing it may have run")
    return None


def admit(host, opts, run_id, home, *, kind, item, target, request, expect_epoch, despite=()) -> dict:
    """Commits the admission before any external call; a replayed --op returns the existing one."""
    if kind not in KINDS:
        raise DispatchError(f"unknown operation kind {kind!r}")
    pause(run_id, "before_admission")
    record = run_record_core.read_run_record(home, run_id)
    # Checked before the commit, outside the record lock: a concurrent collect-result only adds objects.
    held = artifact_holds(run_id, (record or {}).get("programme") or {}, item).get(item)
    if held:
        raise host.ProgrammeError(f"dispatch refused: recovery hold on {item}: {held[0]['reason']}; "
                                  "continuation waits until the committed result is readable")
    attempt = "op-" + secrets.token_hex(8)
    seen = {}

    def mutate(rec):
        sid = host._guard(home, rec)
        rec.setdefault("loop", {})["last_beat_at"] = run_record_core.now_iso()
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        op = {"attempt": attempt, "kind": kind, "item": item, "target": dict(target),
              "digest": request_digest(kind, item, target, request), "owner_session": sid,
              "owner_epoch": expect_epoch, "state": "admitted", "admitted_at": run_record_core.now_iso(),
              "despite": sorted(despite) or None, "receipt": None, "observations": []}
        reason = authority_reason(rec, op) or _admission_refusal(run_id, programme, op, set(despite))
        if reason:
            raise host.ProgrammeError(f"dispatch refused: {reason}")
        programme.setdefault(OPS_KEY, {})[attempt] = op
        seen.update(sid=sid, op=op)

    def compose(_, rec):
        op = seen["op"]
        return programme_journal.entry("operation_admitted", seen["sid"], {
            k: op[k] for k in ("attempt", "kind", "item", "target", "digest", "owner_epoch")})

    out = programme_authority.write(home, run_id, mutate, compose, operation_id=host._OPERATION["id"])
    if out["replayed"]:
        attempt = ((out["row"] or {}).get("payload") or {}).get("attempt")
        record = run_record_core.read_run_record(home, run_id)
        op = operations((record or {}).get("programme") or {}).get(attempt)
        return dict(op or {"attempt": attempt}, replayed=True)
    pause(run_id, "after_admission")
    return dict(seen["op"], replayed=False)


def recheck(run_id, home, op) -> str | None:
    """Re-reads authority just before the external call; it narrows, never closes, the race with end."""
    record = run_record_core.read_run_record(home, run_id)
    reason = authority_reason(record, op)
    if reason is None:
        programme = programme_home.normalize_programme(record.get("programme") or {})
        reason = programme_context.unsafe_reason(programme, op["item"], ACTIONS[op["kind"]])
    pause(run_id, "before_invoke")
    return reason


def settle(run_id, home, attempt, *, outcome, facts, source, sid=None, journal_kind="operation_settled",
           payload=None, assign=None) -> dict:
    """Records a receipt for a known admission; ownership changes only under current authority."""
    if outcome not in SETTLED + ("uncertain",):
        raise DispatchError(f"unknown outcome {outcome!r}")
    seen = {}

    def mutate(rec):
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        op = operations(programme).get(attempt)
        if not isinstance(op, dict):
            raise DispatchError(f"no admitted operation {attempt!r}", "unadmitted")
        if op.get("state") in SETTLED:
            # write() commits a revision even for a no-op; raising keeps a repeated receipt from
            # moving the head, which would invalidate an archive candidate.
            raise _Unchanged(op)
        current = authority_reason(rec, op) is None
        op["state"] = outcome
        op["reason"] = facts.get("reason")
        op["receipt"] = {"source": source, "at": run_record_core.now_iso(), "facts": facts,
                         "authority_current": current}
        if outcome == "uncertain":
            op["observations"].append({"at": op["receipt"]["at"], "source": source,
                                       "reason": facts.get("reason")})
        seen["assigned"] = bool(assign and current and assign(programme, op))
        seen["op"] = op

    def compose(_, rec):
        op = seen["op"]
        late = not op["receipt"]["authority_current"]
        kind = journal_kind
        if late or kind == "operation_settled":
            kind = "operation_uncertain" if outcome == "uncertain" else "operation_settled"
        body = dict(payload or {}, attempt=attempt, operation_state=outcome, operation_kind=op["kind"],
                    item=op["item"], late=late, source=source)
        return programme_journal.entry(kind, sid, body)

    try:
        programme_authority.write(home, run_id, mutate, compose)
    except _Unchanged as same:
        return dict(same.args[0], unchanged=True, assigned=False)
    return dict(seen["op"], unchanged=False, assigned=seen.get("assigned", False))


def _match_target(op, target) -> str | None:
    for key, want in sorted((op.get("target") or {}).items()):
        if want and (target or {}).get(key) != want:
            return f"receipt {key} {target.get(key)!r} is not the admitted {want!r}"
    return None


def record_receipt(run_id, attempt, *, digest, target, outcome, source, sid=None, assign=None) -> dict:
    """A late or external receipt; it must name a known admission, its digest and its target."""
    if outcome not in RECEIPT_OUTCOMES:
        raise DispatchError(f"a receipt reports completed or failed, not {outcome!r}", "bad_outcome")
    home = programme_home.home_path(run_id)
    record = run_record_core.read_run_record(home, run_id)
    op = operations((record or {}).get("programme") or {}).get(attempt)
    if not isinstance(op, dict):
        raise DispatchError(f"no admitted operation {attempt!r}; an unadmitted receipt is not accounted",
                            "unadmitted")
    if digest != op.get("digest"):
        raise DispatchError(f"receipt digest does not match admission {attempt}", "wrong_digest")
    mismatch = _match_target(op, target)
    if mismatch:
        raise DispatchError(mismatch, "wrong_target")
    if op.get("state") in SETTLED and op["state"] != outcome:
        raise DispatchError(f"{attempt} is already {op['state']}", "conflict")
    facts = dict(target, reason=None)
    return settle(run_id, home, attempt, outcome=outcome, facts=facts, source=source, sid=sid,
                  assign=assign)


def reconcile(run_id, home, *, agent_rows, session_of, assign_launch, sid=None) -> list:
    """Settles admitted launches from live session identities; anything unproven stays uncertain."""
    record = run_record_core.read_run_record(home, run_id)
    pending = unreconciled_admissions((record or {}).get("programme") or {})
    rows = agent_rows() if any(p["kind"] == "launch" for p in pending) else []
    report = []
    for prior in pending:
        attempt, op = prior["attempt"], operations(record["programme"])[prior["attempt"]]
        if prior["kind"] == "launch" and rows is None:
            report.append({"attempt": attempt, "state": prior["state"], "reason": "herdr is unavailable"})
            continue
        if prior["kind"] == "launch":
            wanted = (op.get("target") or {}).get("session_id")
            row = next((r for r in rows if wanted and session_of(r) == wanted), None)
            if row is not None:
                target = {"session_id": wanted, "pane": row.get("pane_id"), "terminal_id": row.get("terminal_id")}
                done = record_receipt(run_id, attempt, digest=op["digest"], target=target, outcome="completed",
                                      source="herdr agent list", sid=sid, assign=assign_launch(target))
                report.append({"attempt": attempt, "state": done["state"], "assigned": done["assigned"],
                               "late": not done["receipt"]["authority_current"]})
                continue
            reason = (f"no live agent reports session {wanted}; its absence does not prove the launch "
                      "never ran")
        else:
            reason = "herdr gives no delivery receipt for a prompt; whether it arrived is unknown"
        if prior["state"] == "admitted":
            settle(run_id, home, attempt, outcome="uncertain", facts={"reason": reason},
                   source="reconcile-operations", sid=sid)
        report.append({"attempt": attempt, "state": "uncertain", "reason": reason})
    return report


def _cap(text):
    text = "" if text is None else str(text)
    return (text, False) if len(text) <= TEXT_CAP else (text[:TEXT_CAP], True)


def _capped(entry, fields, ref) -> dict:
    out, cut = dict(entry, id=ref), []
    for name in fields:
        if name in out and out[name] is not None:
            out[name], omitted = _cap(out[name])
            if omitted:
                cut.append(name)
    if cut:
        out.update(omitted_text=cut, full_via=f"recover --get {ref}")
    return out


def _decision_rows(ctx) -> list:
    rows = []
    for did, revisions in sorted(ctx["decisions"].items()):
        for rev in revisions or []:
            ref = f"decision:{did}@{rev.get('rev')}"
            limits = [_capped({"text": text, "binding": True}, ("text",), f"{ref}/limit/{n}")
                      for n, text in enumerate(rev.get("limits") or [])]
            row = _capped({k: rev.get(k) for k in ("state", "kind", "effect", "legacy", "scope", "reason",
                                                  "applies_to", "until", "requirements", "superseded_by",
                                                  "supersedes")}, ("scope", "reason"), ref)
            row.update(decision_id=did, rev=rev.get("rev"), limits=limits,
                       source=_source(rev))
            rows.append(row)
    return rows


def _source(rev) -> dict:
    src = rev.get("source") if isinstance(rev.get("source"), dict) else {}
    return dict({k: src.get(k) for k in ("class", "prompt_id", "origin_label")},
                origin_verified=src.get("origin_verified") is True)


def _requirement_rows(ctx) -> list:
    rows = []
    for rid, revisions in sorted(ctx["requirements"].items()):
        for rev in revisions or []:
            ref = f"requirement:{rid}@{rev.get('rev')}"
            row = _capped({k: rev.get(k) for k in ("state", "text", "checks", "decision_id")}, ("text",), ref)
            row.update(requirement_id=rid, rev=rev.get("rev"), source=_source(rev))
            rows.append(row)
    return rows


def _binding(ctx) -> dict:
    pauses = [_capped(dict(p, binding=True), ("reason",), f"pause:{p.get('id')}")
              for p in programme_context.active_pauses(ctx)]
    denials = [_capped(dict(d, binding=True), ("reason",), f"denial:{n}")
               for n, d in enumerate(ctx["denials"]) if isinstance(d, dict)]
    rulings = []
    for rid, revisions in sorted(ctx["decisions"].items()):
        # No clock here: the packet must stay deterministic for one revision, so an expired until still shows.
        if not programme_context.is_ruling(revisions) or programme_context.ruling_state(revisions, None) != "active":
            continue
        current = programme_context.in_force(revisions)
        entry = _capped({k: current.get(k) for k in ("kind", "effect", "legacy", "scope", "quote", "applies_to",
                                                     "until", "rev")}, ("scope", "quote"), f"ruling:{rid}")
        entry.update(binding=True, authorizes=False)
        rulings.append(entry)
    return {"pauses": pauses, "denials": denials, "rulings": rulings}


def _actions(programme) -> list:
    rows = []
    for key, item in sorted((programme.get("items") or {}).items()):
        if item.get("state") in programme_home.FINISHED_ITEM_STATES:
            continue
        row = _capped({"state": item.get("state"), "title": item.get("title"), "owner": item.get("owner"),
                       "waiting_on": item.get("waiting_on"),
                       "question": (item.get("handed") or {}).get("question")},
                      ("title", "question"), f"item:{key}")
        row["open_deliverables"] = sorted(name for name, d in (item.get("deliverables") or {}).items()
                                          if isinstance(d, dict) and d.get("result") != "confirmed")
        rows.append(row)
    return rows


def _results(programme) -> list:
    results = ((programme.get("retained") or {}).get("results") or {})
    return [{"id": f"result:{ident}", "item": e.get("item"), "attempt": e.get("attempt"),
             "digest": (e.get("ref") or {}).get("digest"), "size": (e.get("ref") or {}).get("size"),
             "authorizes": False, "verification": NOT_VERIFIED}
            for ident, e in sorted(results.items()) if isinstance(e, dict)]


def _evidence_limits(status) -> list:
    limits = [{"requirement": r["id"], "check": c.get("check"), "result": c.get("result")}
              for r in status["requirements"] for c in r.get("checks") or [] if c.get("result") != "confirmed"]
    limits.append({"retained_copies": NOT_VERIFIED,
                   "meaning": "retained or restored copies are never origin-verified and approve nothing"})
    return limits


def _pending(programme, status) -> list:
    rows = [dict(p, kind="context_pending") for p in status.get("pending") or []]
    if not (programme.get("agreement") or {}).get("accepted"):
        rows.append({"kind": "agreement_not_accepted"})
    rows += [{"kind": "handed", "item": key, "question": _cap((item.get("handed") or {}).get("question"))[0]}
             for key, item in sorted((programme.get("items") or {}).items()) if item.get("state") == "handed"]
    return rows


def packet(run_id, revision, record, *, objects=True) -> dict:
    """Deterministic over one committed revision plus the check that its retained objects are readable.

    objects=False skips that re-read (hooks under a timeout); its holds then read as not checked."""
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    try:
        ctx = programme_context.block(programme)
        status = programme_context.evaluate(programme)
    except programme_context.ContextError as exc:
        return {"run": run_id, "revision": revision, "authority": programme_context.AUTHORITY_NOTE,
                "hold": {"outcome": "corrupt_context", "detail": str(exc)}}
    body = {
        "run": run_id, "revision": revision, "authority": programme_context.AUTHORITY_NOTE,
        "approves_nothing": True,
        "lifecycle": {"ended": programme.get("ended"), "driving_session_id": record.get("driving_session_id"),
                      "owner_epoch": owner_epoch(programme), "sealed": programme_home.sealed(programme)},
        "pending_decisions": _pending(programme, status),
        "decisions": _decision_rows(ctx), "requirements": _requirement_rows(ctx),
        "acceptance": status["requirements"], "blockers": status["blockers"],
        "binding": _binding(ctx), "actions": _actions(programme),
        "assignments": ctx["assignments"], "results": _results(programme),
        "evidence_limits": _evidence_limits(status),
        "uncertain_effects": unreconciled_admissions(programme),
        "holds": artifact_holds(run_id, programme) if objects else {"not_checked": True},
    }
    body["packet_digest"] = canonical_sha(body)
    return body


def _revision_of(ctx_section, ident, rev):
    for entry in ctx_section.get(ident) or []:
        if str(entry.get("rev")) == rev:
            return entry
    return None


def lookup(record, ref) -> dict:
    """Full, uncapped text behind a packet id."""
    programme = programme_home.normalize_programme((record or {}).get("programme") or {})
    ctx = programme_context.block(programme)
    kind, _, rest = str(ref).partition(":")
    found = None
    if kind + "s" in programme_context.ID_FIELDS:
        head, _, limit = rest.partition("/limit/")
        ident, _, rev = head.partition("@")
        found = _revision_of(ctx[kind + "s"], ident, rev)
        if found is not None and limit:
            limits = found.get("limits") or []
            found = {"text": limits[int(limit)], "binding": True} if limit.isdigit() and int(limit) < len(limits) \
                else None
    elif kind == "pause":
        found = ctx["pauses"].get(rest)
    elif kind == "denial" and rest.isdigit() and int(rest) < len(ctx["denials"]):
        found = ctx["denials"][int(rest)]
    elif kind in ("ruling", "instruction"):
        # The context copy is canonical: close-ruling on an old instruction closes only that copy.
        revisions = ctx["decisions"].get(rest) or []
        found = programme_context.in_force(revisions) or (revisions[-1] if revisions else None)
    elif kind == "item":
        found = (programme.get("items") or {}).get(rest)
    elif kind == "op":
        found = operations(programme).get(rest)
    elif kind == "result":
        found = ((programme.get("retained") or {}).get("results") or {}).get(rest)
    if found is None:
        raise DispatchError(f"nothing in this programme is {ref!r}", "not_found")
    return {"id": ref, "entry": found}


def run_of(host, opts) -> str:
    run_id = opts.get("run") or host._run_from_leases(load_lib_module("driver_session").driving_session_id())
    return programme_home.check_run_id(run_id)


def recover_verb(host, argv) -> int:
    _, opts = host._parse(argv, values=("run", "get"), flags=("rebuild-projections",))
    run_id = run_of(host, opts)
    home = programme_home.home_path(run_id)
    state = programme_authority.outcome(run_id)
    if state["outcome"] in programme_authority.HOLDS:
        host._emit({"ok": False, "run": run_id, "authority": programme_context.AUTHORITY_NOTE,
                    "hold": {"outcome": state["outcome"], "detail": state["detail"]}})
        return 1
    if programme_authority.promoted(home, run_id):
        snap = programme_authority.snapshot(run_id)
        record, revision = snap["record"], snap["revision"]
    else:
        record, revision = run_record_core.read_run_record(home, run_id), None
    if run_record_core.run_kind(record) != "programme":
        raise host.ProgrammeError(f"run {run_id!r} is not a programme")
    if opts.get("get"):
        try:
            found = lookup(record, opts["get"])
        except (DispatchError, programme_context.ContextError) as exc:
            raise host.ProgrammeError(str(exc)) from None
        host._emit(dict({"ok": True, "run": run_id, "revision": revision,
                         "authority": programme_context.AUTHORITY_NOTE}, **found))
        return 0
    body = packet(run_id, revision, record)
    if opts.get("rebuild-projections") and "hold" not in body and not body["holds"] \
            and not body["lifecycle"]["sealed"] and revision is not None:
        body["projections_rebuilt"] = programme_authority._locked(
            home, run_id, lambda: programme_authority.export(home, run_id))
        host.refresh_view(run_id, home)
    host._emit(dict({"ok": "hold" not in body}, **body))
    return 0 if "hold" not in body else 1

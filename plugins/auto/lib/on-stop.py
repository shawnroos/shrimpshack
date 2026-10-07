#!/usr/bin/env python3
"""auto U7: decision logic behind .claude/hooks/on-stop.sh.

The engine's OWN deliberate-stop guard (U9 spike: native `/goal` has no external
predicate handoff — auto ships this). Reads every run-record under
<repo>/.claude/auto/ LOCK-FREE (atomic-rename => consistent snapshot) and
decides whether to BLOCK the stop.

BLOCK MECHANISM (U9 §4 + ralph-loop/hooks/stop-hook.sh:179-188):
    emit `{"decision":"block","reason":...}` on stdout, exit 0. NOT exit-2 — the
    codebase convention is decision-JSON + exit-0.

ACTIVE-RUN POLICY:
    BLOCK if ANY run has loop_phase != "done" AND exit_predicate_result.met ==
    false AND loop.driver == "self". `met` already encodes the all_steps_terminal
    gate (schema §5 I-2), so a lurking stalled/pending step (findings counters
    zero) keeps the stop blocked.

    Only the stopping session's own runs count: a task run holds its
    `driving_session_id`, a batch holds its `host_session_id`, and a programme
    holds the session its lease and record name. A task run or batch that
    records no session holds every session in the repo.

    The `driver == "self"` conjunct is the HANDOFF/MANUAL carve-out: the engine
    blocks premature stop only during ACTIVE work — a live pulse chain (driver ==
    "self") that expects to keep going. When the engine writes `driver:
    "manual"` it is SIGNALING a valid stop-point awaiting human input (a
    handoff pause emits action:"stop" + driver:"manual" deliberately; predicate-met
    and abort also set manual but are already filtered by phase == "done").
    Blocking a manual-driver run would self-conflict with the engine's own
    handoff-stop signal. (Brief/plan stated the simpler "phase != done AND !met"
    rule, which conflicts with the handoff; this carve-out resolves it — raised as a
    gap for the dispatcher.)

LOOP-SAFETY:
    Claude Code re-fires Stop after a block with stop_hook_active == true. We
    ALLOW the stop in that case (no decision JSON) and stay SILENT — the
    deterministic gate fires once per stop attempt, never an inescapable loop.
    The allow is quiet on purpose: if another gate (e.g. an operator-set native
    `/goal`) keeps re-inviting the model, this hook fires every re-invite, so a
    per-re-fire note would become one spam line per iteration of a loop auto is
    not driving. The run is durable on disk; the first real block says so once.

FRESHNESS: we read exit_predicate_result.met directly (the I-1-fresh field —
schema §5). No cached/derived `done` copy exists; a re-review reopening the
predicate (verdict-returned → pending) is reflected on that very write, so the
hook can never read a stale met:true and allow a premature stop.

STALE-CHAIN CARVE-OUT (Bug #9):
    The `driver == "self"` block above assumes a LIVE pulse chain. But a pulse can
    be killed AFTER it writes the beat and BEFORE it re-arms its successor. That
    leaves a run-record with driver=="self", met==false, and a fresh-ISH last_beat_at
    — a DEAD chain that, without a freshness check, would block EVERY session's
    stop in the repo until last_beat_at finally ages past GRACE (≈70 min, when
    is_orphaned surfaces it for resume). So we add a freshness gate: a
    driver=="self" run whose last_beat_at is older than DRIVER_SELF_STALE_SECONDS
    is treated as a DEAD chain → it does NOT block stop (it will be surfaced for
    resume by the SessionStart hook instead).

    THREE THRESHOLDS, reconciled (smallest → largest, no overlap of purpose):
      * DEFAULT_STALL_THRESHOLD_SECONDS = 600  — per-STEP dispatch timeout (pulse).
      * DRIVER_SELF_STALE_SECONDS       = 3900 — per-RUN dead-chain gate (THIS
            hook). Above the 3600s ScheduleWakeup max-pulse-delay + slack, so a
            healthy slow-paced chain (last beat ≤3600s ago) is NEVER misread as
            dead and prematurely un-blocked (a false un-block could let a real
            loop stop early). Below GRACE so a dead chain stops blocking BEFORE
            is_orphaned would surface it — the two purposes (anti-false-double-
            drive vs anti-stale-block) do not fight: by the time we DECLINE to
            block (3900s), the resume path has not yet (4200s) claimed it, so
            there is a clean ~300s hand-off window and no double-claim.
      * GRACE_SECONDS                   = 4200 — orphan/resume window (I-3).
"""

from __future__ import annotations

import datetime
import glob
import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    iter_worktree_run_records,
    load_run_record,
    load_run_record_safe,
    load_lib_module,
    resolve_shared_dir,
    test_hatch_enabled,
)

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")


CLAIMS_FILE = "claims.jsonl"
_SID_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")


def _hook_input(raw: str) -> dict:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _read_stop_hook_active(raw: str) -> bool:
    return bool(_hook_input(raw).get("stop_hook_active"))


def _read_session_id(raw: str):
    sid = _hook_input(raw).get("session_id")
    return sid if isinstance(sid, str) and sid else None


def _holds_session(owner, session_id) -> bool:
    # A stop with no session id stays held: an absent id must never drop a hold.
    if not owner or not session_id:
        return True
    return owner == session_id


def _is_blocking(led, *, run_record, skip_staleness, stale_threshold, now):
    """Single source of truth for 'does this run-record block stop?'

    Applies the four carve-outs uniformly across per-worktree run-records and
    batch-discovered sub-run run-records (the v0.4.0 U4 batch path originally
    duplicated this predicate and dropped two carve-outs; code-review round
    1 finding C-1 surfaced both gaps — manual-driver runs at the handoff, and
    stale-chain `driver == "self"` runs — would block stop indefinitely
    via the batch path while correctly allowing it via the per-worktree
    path). Returns the predicate dict when blocking, None otherwise.
    """
    if not isinstance(led, dict):
        return None
    if phase_grammar.current_phase(led) == "done":
        return None
    loop = led.get("loop") or {}
    # HANDOFF/MANUAL carve-out: a manual-driver run is the engine signaling
    # a valid stop-point awaiting human input.
    if loop.get("driver") == "manual":
        return None
    # Bug #9 STALE-CHAIN carve-out: a driver=="self" run whose
    # last_beat_at is older than DRIVER_SELF_STALE_SECONDS is a DEAD
    # chain — does NOT block (surfaced for resume by SessionStart hook).
    if not skip_staleness and loop.get("driver") == "self":
        last_beat = run_record.parse_iso(loop.get("last_beat_at"))
        if last_beat is None:
            return None
        if (now - last_beat).total_seconds() > stale_threshold:
            return None
    predicate = led.get("exit_predicate_result") or {}
    if not predicate.get("met"):
        return predicate
    return None


def _is_worktree_or_host(git_path: str) -> bool:
    """True iff `.git` (file or dir) belongs to a worktree-aware setup.

    Distinguishes the three cases via cheap fs probes (no subprocess):
      - Plain repo with no worktrees:    `.git` is a DIR; `.git/worktrees`
        does NOT exist → return False (slow path is pure waste here).
      - Host repo WITH worktrees:        `.git` is a DIR;
        `.git/worktrees` exists → return True.
      - Inside a WORKTREE:                `.git` is a FILE containing
        `gitdir: <host>/.git/worktrees/<name>` → return True.
      - Inside a SUBMODULE (round 3 R3-1): `.git` is a FILE containing
        `gitdir: <parent>/.git/modules/<name>` → return False (the
        gitdir path component is `modules/`, not `worktrees/`, so
        submodules don't pay the resolve_shared_dir() cost).
    """
    if os.path.isdir(git_path):
        return os.path.isdir(os.path.join(git_path, "worktrees"))
    if os.path.isfile(git_path):
        try:
            with open(git_path, "r") as fh:
                head = fh.read(200)
        except OSError:
            return False
        # `gitdir: <abs-or-rel-path>` — worktrees live under .../worktrees/<n>
        return "/worktrees/" in head or "\\worktrees\\" in head
    return False


def _blocking_runs(repo_root: str, now=None, session_id=None):
    """Return [(run_id, predicate_dict)] for every ACTIVE run that is NOT met.

    Lock-free: each run-record file is read as a whole via the atomic-rename
    invariant. A malformed/partial file is skipped silently (rel-001 — never let
    a bad run-record break the stop machinery).

    v0.4.0 U4: also walks committed multi-plan batch sidecars at
    `<shared-dir>/batches/*.json` and applies the SAME `_is_blocking`
    predicate to each sub-run run-record (sub-runs live in worktree-local
    run-record dirs the per-worktree glob can't reach).
    """
    if not repo_root:
        return []
    run_record = load_run_record()
    skip_staleness = test_hatch_enabled("CLAUDE_AUTO_TEST_NO_STALENESS_CHECK")
    stale_threshold = run_record.DRIVER_SELF_STALE_SECONDS

    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)

    blocking = []

    # Per-worktree run-records (the main scan) — iter_worktree_run_records owns the glob.
    for run_id, led in iter_worktree_run_records(repo_root):
        if not isinstance(led, dict) or led.get("run_kind") == "programme":
            continue
        if not _holds_session(led.get("driving_session_id"), session_id):
            continue
        predicate = _is_blocking(
            led, run_record=run_record, skip_staleness=skip_staleness,
            stale_threshold=stale_threshold, now=now,
        )
        if predicate is not None:
            blocking.append((run_id, predicate))

    # Multi-plan batches (committed sidecars only). Fast-path guard: skip
    # the git-rev-parse subprocess if there's no batches dir locally AND
    # this isn't a worktree (review round 1 E-1 — fork+exec waste in
    # projects that never use fanout; round 2 R2-1 — gitlink FILE inside
    # worktrees broke the original isdir(.git/worktrees) check; round 3
    # R3-1 — submodules ALSO have gitlink files but their target is
    # `.git/modules/...`, NOT `.git/worktrees/...`, so reading the
    # gitlink content distinguishes the two cases cheaply).
    local_batches = os.path.join(repo_root, ".claude", "auto", "batches")
    git_path = os.path.join(repo_root, ".git")
    if not os.path.isdir(local_batches) and not _is_worktree_or_host(git_path):
        return blocking
    shared = resolve_shared_dir(cwd=repo_root)
    if not shared:
        return blocking
    batches_dir = os.path.join(shared, "batches")
    if not os.path.isdir(batches_dir):
        return blocking
    for sidecar_path in sorted(glob.glob(os.path.join(batches_dir, "*.json"))):
        sidecar = load_run_record_safe(sidecar_path)
        if sidecar is None:  # load_run_record_safe returns None for non-dict too.
            continue
        if sidecar.get("status") != "committed":
            continue
        if not _holds_session(sidecar.get("host_session_id"), session_id):
            continue
        batch_id = sidecar.get("id", "?")
        for plan in sidecar.get("plans") or []:
            worktree = plan.get("worktree")
            run_id_hint = plan.get("suggested_run_id")
            if not worktree or not run_id_hint:
                continue
            # Prefix glob — sub-run may stamp a collision suffix.
            wt_run_record_dir = os.path.join(worktree, ".claude", "auto")
            for sub_path in sorted(glob.glob(
                os.path.join(wt_run_record_dir, f"{run_id_hint}*.json")
            )):
                sub = load_run_record_safe(sub_path)
                if sub is None:
                    continue
                predicate = _is_blocking(
                    sub, run_record=run_record, skip_staleness=skip_staleness,
                    stale_threshold=stale_threshold, now=now,
                )
                if predicate is not None:
                    sub_run_id = sub.get("run_id") or run_id_hint
                    blocking.append((f"{batch_id}:{sub_run_id}", predicate))
    return blocking


def _reason_for(blocking) -> str:
    chunks = []
    for run_id, predicate in blocking:
        blockers = int(predicate.get("blockers", 0) or 0)
        majors = int(predicate.get("majors", 0) or 0)
        all_terminal = bool(predicate.get("all_steps_terminal"))
        parts = []
        if blockers:
            parts.append(f"{blockers} blocker{'s' if blockers != 1 else ''}")
        if majors:
            parts.append(f"{majors} major{'s' if majors != 1 else ''}")
        if not all_terminal:
            parts.append("steps not yet terminal")
        detail = " / ".join(parts) if parts else "loop not complete"
        chunks.append(f"{run_id} ({detail})")
    # The block holds the session open; the reason message routes the driver's
    # next move. v0.2.0 (fix-pass G): make the harness re-invocation model
    # explicit so the driver does NOT read "continue the loop" as "act now."
    # The two viable paths from a blocked stop:
    #   1. Background `Agent` work is in flight → YIELD; the harness re-invokes
    #      on completion (the natural signal — do not ScheduleWakeup-poll).
    #   2. The loop is genuinely stalled outside its natural channel (rate-
    #      limited, waiting on external event) → ScheduleWakeup with a LONG
    #      delay calibrated to the wake event.
    # The driver knows which case it is in (it knows what it just dispatched);
    # the hook doesn't and shouldn't guess. Naming both cases explicitly lets
    # the driver route correctly.
    return (
        "auto: loop exit condition not met — "
        + "; ".join(chunks)
        + ". If you have background work in flight (Agent.run_in_background), "
        + "YIELD silently — the harness re-invokes you when a verdict lands. "
        + "Do NOT ScheduleWakeup-poll waiting for it. ScheduleWakeup is only "
        + "for genuine waits outside the agentic loop (rate-limit reset, "
        + "external deploy ETA) — long delays (1200s+), calibrated to the wake "
        + "event. `/auto-resume abort <run>` to stop early."
    )


def _programme_reason_texts(status) -> list:
    out = []
    for reason in status.get("reasons") or []:
        if not isinstance(reason, dict):
            continue
        target = reason.get("item") or reason.get("system") or reason.get("count")
        text = str(reason.get("kind"))
        out.append(f"{text} {target}" if target not in (None, "") else text)
    return sorted(out)


def _nag_signature(blocking, programmes=()) -> str:
    """A deterministic signature of the blocking set (U2 / finding #9).

    Two turn-ends have the "same" block iff the same runs are blocking with the
    same severity shape — that is what the driver already saw the full guidance
    for. Sorted so run order can't perturb it.
    """
    items = sorted(
        (
            rid,
            int(p.get("blockers", 0) or 0),
            int(p.get("majors", 0) or 0),
            bool(p.get("all_steps_terminal")),
        )
        for rid, p in blocking
    )
    if not programmes:
        return json.dumps(items, sort_keys=True)
    held = sorted((hold["run"], _programme_reason_texts(hold["status"])) for hold in programmes)
    return json.dumps({"task": items, "programme": held}, sort_keys=True)


def _nag_dir(repo_root: str, programmes=()) -> str | None:
    if repo_root:
        return os.path.join(repo_root, ".claude", "auto")
    for hold in programmes:
        return os.path.join(hold["home"], ".claude", "auto")
    return None


def _nag_state_path(nag_dir: str, session_id=None) -> str:
    # A DOTFILE, so the `*.json` run-record glob (glob excludes leading-dot names)
    # never sweeps it; U1's shape guard is a second backstop.
    if not session_id:
        return os.path.join(nag_dir, ".stop-nag.json")
    return os.path.join(nag_dir, f".stop-nag-{_SID_UNSAFE.sub('_', session_id)[:128]}.json")


def _load_last_nag(nag_dir: str, session_id=None):
    try:
        with open(_nag_state_path(nag_dir, session_id)) as fh:
            return json.load(fh).get("sig")
    except Exception:
        return None


def _store_nag(nag_dir: str, sig: str, session_id=None) -> None:
    try:
        path = _nag_state_path(nag_dir, session_id)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"sig": sig}, fh)
    except Exception:
        pass  # rel-001: never let nag-state I/O break the stop machinery.


def _clear_nag(nag_dir, session_id=None) -> None:
    if not nag_dir:
        return
    try:
        os.remove(_nag_state_path(nag_dir, session_id))
    except OSError:
        pass


def _terse_reason_for(blocking) -> str:
    """The DEDUPED one-liner (U2): the driver already saw the full guidance for
    this exact blocking state on a prior turn, so just remind — still blocking."""
    runs = ", ".join(rid for rid, _ in blocking)
    return (
        f"auto: still blocked — {runs} (unchanged). Yield for in-flight work "
        "(the harness re-invokes on a verdict), or `/auto-resume abort <run>` "
        "to stop early."
    )


def rules_block(record) -> str:
    return load_lib_module("programme").render_rules(record)


def _inbox_size(home: str) -> int:
    try:
        with open(os.path.join(home, CLAIMS_FILE), "rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def _driven_programmes(session_id, now) -> list:
    if not session_id:
        return []
    try:
        programme_home = load_lib_module("programme_home")
        programme_predicate = load_lib_module("programme_predicate")
        holds = programme_home.driven_runs(session_id, now)
    except Exception:
        return []
    found = []
    for hold in holds:
        try:
            status = programme_predicate.compute(hold["record"], now, _inbox_size(hold["home"]))
            if any(isinstance(r, dict) and r.get("kind") == "corrupt_record"
                   for r in status.get("reasons") or []):
                continue
            found.append(dict(hold, status=status))
        except Exception:
            continue
    return found


def _rules_suffix(hold) -> str:
    flag = os.path.join(hold["home"], load_lib_module("programme_home").COMPACT_FLAG)
    if not os.path.exists(flag):
        return ""
    try:
        return "\n\n" + rules_block(hold["record"])
    except Exception:
        return ""


def _programme_reason_for(hold) -> str:
    status = hold["status"]
    text = (
        f"auto: programme {hold['run']} may not stop yet — "
        + "; ".join(_programme_reason_texts(status))
        + ". Act on your next step, or give each wait a live watcher or a named "
        "person who reports back."
    )
    unwatched = status.get("unwatched_waits") or []
    if unwatched:
        text += (
            " Unwatched waits: " + ", ".join(unwatched) + ". Stopping again lets "
            "the stop through and journals them as stopped unwatched, for Shawn."
        )
    return text + _rules_suffix(hold)


def _terse_programme_reason_for(hold) -> str:
    return (
        f"auto: programme {hold['run']} still may not stop (unchanged): "
        + "; ".join(_programme_reason_texts(hold["status"]))
        + "." + _rules_suffix(hold)
    )


def _journal_stopped_unwatched(session_id, now) -> None:
    try:
        holds = _driven_programmes(session_id, now)
        if not holds:
            return
        programme_journal = load_lib_module("programme_journal")
    except Exception:
        return
    for hold in holds:
        unwatched = hold["status"].get("unwatched_waits") or []
        if not unwatched:
            continue
        try:
            programme_journal.append(hold["run"], "stopped_unwatched", session_id,
                                     {"items": list(unwatched)})
        except Exception:
            continue


def decide(repo_root: str, stdin_raw: str, now=None) -> dict | None:
    """Return the decision dict to print, or None to allow stop silently.

    Loop-safety: a re-fired Stop (stop_hook_active) always allows the stop.
    """
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    session_id = _read_session_id(stdin_raw)
    if _read_stop_hook_active(stdin_raw):
        # Re-fired after a prior block — allow the stop SILENTLY (return None =>
        # no decision, no systemMessage, stop proceeds). We used to emit a
        # "Stop re-fired … /auto-resume continues it" note here, but a re-fire
        # is not a once-per-run event: when SOME OTHER gate keeps re-inviting
        # the model after a stop (most commonly an operator-set native `/goal`,
        # which auto neither arms nor can clear — see docs/research/
        # native-goal-mechanism-spike.md), this hook fires on EVERY re-invite
        # and the note became one spam line per iteration. The run is durable on
        # disk regardless; the FIRST real block (below) already says so once.
        # Stay quiet on re-fire so auto adds no noise to a loop it isn't driving.
        _journal_stopped_unwatched(session_id, now)
        return None

    driven = _driven_programmes(session_id, now)
    programmes = [hold for hold in driven if not hold["status"].get("may_stop")]
    blocking = _blocking_runs(repo_root, now=now, session_id=session_id)
    nag_dir = _nag_dir(repo_root, programmes)
    if not blocking and not programmes:
        # reset so a future block re-emits full guidance.
        _clear_nag(nag_dir, session_id)
        for hold in driven:
            _clear_nag(_nag_dir("", [hold]), session_id)
        return None

    # U2 (finding #9): de-duplicate the ~10x identical nag across turns. The block
    # is ALWAYS preserved (deliberate-stop); only the MESSAGE is collapsed to a
    # terse reminder once the driver has already seen the full guidance for this
    # exact blocking state. A changed/cleared state re-emits the full guidance.
    sig = _nag_signature(blocking, programmes)
    repeat = sig == _load_last_nag(nag_dir, session_id)
    _store_nag(nag_dir, sig, session_id)

    if repeat:
        parts = [_terse_programme_reason_for(hold) for hold in programmes]
        if blocking:
            parts.append(_terse_reason_for(blocking))
        return {"decision": "block", "reason": "\n\n".join(parts)}

    parts = [_programme_reason_for(hold) for hold in programmes]
    if blocking:
        parts.append(_reason_for(blocking))
        message = (
            f"auto held the stop: {len(blocking)} run(s) have unmet loop exit "
            "conditions. If you have background work in flight, the harness "
            "will re-invoke you when a verdict lands — do not poll."
        )
    else:
        message = "auto held the stop: the programme has work it can still act on."
    return {"decision": "block", "reason": "\n\n".join(parts), "systemMessage": message}


def _cli(argv) -> int:
    repo_root = argv[0] if argv else os.getcwd()
    stdin_raw = ""
    if not sys.stdin.isatty():
        try:
            stdin_raw = sys.stdin.read()
        except Exception:
            stdin_raw = ""
    try:
        decision = decide(repo_root, stdin_raw)
    except Exception:
        decision = None  # any failure => allow stop (rel-001).
    if decision is not None:
        json.dump(decision, sys.stdout)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

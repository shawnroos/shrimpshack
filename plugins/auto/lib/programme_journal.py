#!/usr/bin/env python3
"""The programme journal: ``<home>/journal.jsonl``, one JSON object per line.

Entries are appended under a flock and never edited. The one rewrite is
``prune_uncited_prompts``, which drops captured prompts that no entry cites.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_prompt_source = load_lib_module("programme_prompt_source")

JOURNAL_NAME = "journal.jsonl"
CLAIMS_NAME = "claims.jsonl"
LOCK_NAME = ".journal.lock"
SECRETS_ENV = "CLAUDE_AUTO_SECRETS_FILE"
DEFAULT_SECRETS_FILE = "~/.secrets"
REDACTED = "[redacted]"
STORED_PROMPT_ORIGINS = ("typed", "cron", "unknown")
# "picked" is only ever resolved from a pick source record, never stored as a label.
PROMPT_ORIGINS = STORED_PROMPT_ORIGINS + ("picked",)
PRUNE_AFTER_SECONDS = 7 * 24 * 3600
# Shorter values (flags, ports, "true") would redact ordinary words in prompts.
MIN_SECRET_LEN = 6

KINDS = (
    "prompt",
    "takeover_request",
    "handover_request",
    "end_request",
    "blocked_driver_send",
    "blocked_tracker_write",
    "tracker_synced",
    "issues_recorded",
    "trajectory_changed",
    "remit_set",
    "prompts_pruned",
    "agreement_proposed",
    "agreement_accepted",
    "term_amended",
    "term_picked",
    "recommendations_taken",
    "setup_step_set",
    "setup_seen_recorded",
    "setup_step_kept",
    "term_proposed",
    "term_noted",
    "proposal_cleared",
    "project_term_edited",
    "project_term_amended",
    "term_corrected",
    "correction_undone",
    "corrections_kept",
    "correction_promoted",
    "instruction_recorded",
    "instruction_closed",
    "behaviour_recorded",
    "behaviour_proposed",
    "behaviour_moved",
    "behaviour_retired",
    "behaviour_reminded",
    "behaviours_kept",
    "rule_proposed",
    "rule_adopted",
    "rules_acked",
    "rules_loaded",
    "reread_requested",
    "stopped_unwatched",
    "item_added",
    "item_updated",
    "item_aliased",
    "item_merged",
    "item_dropped",
    "item_reopened",
    "item_waiting",
    "item_handed",
    "handed_answered",
    "ask_updated",
    "ask_answer_voided",
    "ask_shown",
    "ask_relayed",
    "pm_decided",
    "claim",
    "claims_read",
    "working_now",
    "queue_changed",
    "tested_build_recorded",
    "source_changed",
    "evidence_checked",
    "evidence_refuted",
    "validate_pass",
    "merge_pinned",
    "worker_started",
    "worker_start_failed",
    "prompt_sent",
    "prompt_refused",
    "programme_started",
    "taken_over",
    "handed_over",
    "programme_ended",
    "request_refused",
    "approval_refused",
    "effects_recorded",
    "legacy_imported",
    "foreign_write_absorbed",
    "result_collected",
    "result_collection_failed",
    "source_retained",
    "inventory_frozen",
    "preservation_checked",
    "decision_recorded",
    "requirement_defined",
    "context_accepted",
    "item_assigned",
    "blocker_raised",
    "blocker_cleared",
    "pause_raised",
    "pause_lifted",
    "denial_recorded",
    "code_captured",
    "code_capture_failed",
    "operation_admitted",
    "operation_settled",
    "operation_uncertain",
    "resources_reconciled",
    "item_disposed",
    "uncertainty_accepted",
    "archive_check_failed",
    "programme_archived",
    "successor_created",
    "permission_proposed",
    "permission_answered",
    "permission_verified",
    "permission_settled",
    "blocked_settings_write",
)

_TOKEN_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\blin_(?:api|oauth)_[A-Za-z0-9]{20,}"),
    re.compile(r"\bnpm_[A-Za-z0-9]{20,}"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"),
]
_ASSIGNMENT = re.compile(
    r"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY)[A-Z0-9_]*)(\s*[=:]\s*)"
    r"(\"[^\"]*\"|'[^']*'|\S+)"
)
_SECRETS_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


class JournalError(Exception):
    pass


class _RoutedToAuthority(Exception):
    pass


def secret_assignments(path=None, encoding=None) -> list:
    path = os.path.expanduser(path or os.environ.get(SECRETS_ENV) or DEFAULT_SECRETS_FILE)
    with open(path, encoding=encoding) as fh:
        lines = fh.read().splitlines()
    return [match.groups() for match in map(_SECRETS_LINE.match, lines) if match]


def unquote(value) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _secret_values(path=None) -> list:
    try:
        assignments = secret_assignments(path)
    except (OSError, UnicodeDecodeError):
        return []
    values = set()
    for _, value in assignments:
        value = unquote(value)
        if len(value) >= MIN_SECRET_LEN:
            values.add(value)
    return sorted(values, key=len, reverse=True)


def redact(text, secrets_path=None) -> str:
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    for value in _secret_values(secrets_path):
        text = text.replace(value, REDACTED)
    for pattern in _TOKEN_PATTERNS:
        text = pattern.sub(REDACTED, text)
    return _ASSIGNMENT.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)


def _iso(now=None) -> str:
    if now is None:
        return run_record_core.now_iso()
    return now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def journal_path(run_id: str) -> str:
    return os.path.join(programme_home.home_path(run_id), JOURNAL_NAME)


def _locked(path: str, body, timeout=None):
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    return run_record_core._flock_run(os.path.join(folder, LOCK_NAME), body, timeout)


def _write_line(path: str, entry: dict) -> None:
    line = (json.dumps(entry, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, line)
    finally:
        os.close(fd)


def _authority():
    return load_lib_module("programme_authority")


def _promoted(run_id) -> bool:
    return _authority().promoted(programme_home.home_path(run_id), run_id)


def _refuse_promoted(path: str) -> None:
    folder, name = os.path.split(os.path.abspath(path))
    if name not in (JOURNAL_NAME, CLAIMS_NAME):
        return
    run_id = os.path.basename(folder)
    try:
        home = programme_home.home_path(run_id)
    except programme_home.ProgrammeHomeError:
        return
    if os.path.realpath(home) == os.path.realpath(folder) and _authority().promoted(home, run_id):
        raise JournalError(f"{path} is an export of a promoted programme; write through programme.db")


def entry(kind: str, session_id, payload=None, *, cites=None, prompt_id=None, now=None) -> dict:
    if kind not in KINDS:
        raise JournalError(f"journal kind must be one of {list(KINDS)}; got {kind!r}")
    if payload is not None and not isinstance(payload, dict):
        raise JournalError("journal payload must be a dict")
    entry = {
        "kind": kind,
        "at": _iso(now),
        "session_id": session_id if isinstance(session_id, str) else None,
        "payload": dict(payload or {}),
    }
    if cites:
        entry["cites"] = [c for c in cites if isinstance(c, str)]
    if prompt_id:
        entry["prompt_id"] = prompt_id
    return entry


def append_to(path: str, kind: str, session_id, payload=None, *, cites=None,
              prompt_id=None, now=None) -> dict:
    row = entry(kind, session_id, payload, cites=cites, prompt_id=prompt_id, now=now)
    _refuse_promoted(path)

    def body():
        # promote holds this lock through its first export; a writer queued behind it must not
        # append to that export.
        _refuse_promoted(path)
        _write_line(path, row)

    _locked(path, body)
    return row


def claims_path(run_id: str) -> str:
    return os.path.join(programme_home.home_path(run_id), CLAIMS_NAME)


def append_row(run_id: str, row: dict, *, channel="journal", provenance="derived", guard=None,
               lock_timeout=None) -> dict:
    if isinstance(row, dict) and row.get("kind") == "prompt" and provenance != "derived":
        raise JournalError(f"a {provenance} copy is never journaled as a prompt; it approves nothing")
    if not _promoted(run_id):
        path = claims_path(run_id) if channel == "claims" else journal_path(run_id)

        def body():
            # promote holds this lock through its first export; a writer queued behind it would
            # append to that export and be absorbed as a foreign write. The authority takes the
            # run lock first, so re-route only after releasing this one.
            if _promoted(run_id):
                raise _RoutedToAuthority()
            _write_line(path, row)
            return row

        try:
            return _locked(path, body, lock_timeout)
        except _RoutedToAuthority:
            pass
    return _authority().append_row(run_id, row, channel=channel, provenance=provenance, guard=guard,
                                   lock_timeout=lock_timeout)


def append(run_id: str, kind: str, session_id, payload=None, *, cites=None, now=None,
           lock_timeout=None) -> dict:
    return append_row(run_id, entry(kind, session_id, payload, cites=cites, now=now),
                      lock_timeout=lock_timeout)


def _refuse_after_end(record) -> None:
    if ((record or {}).get("programme") or {}).get("ended"):
        raise JournalError("the programme has ended; a late claim is not recorded")


def append_claim(run_id: str, session_id, payload) -> dict:
    return append_row(run_id, entry("claim", session_id, payload), channel="claims",
                      provenance="worker_result", guard=_refuse_after_end)


def append_prompt(run_id: str, session_id, text: str, origin: str, now=None, *, source=None) -> dict:
    if origin not in STORED_PROMPT_ORIGINS:
        raise JournalError(f"prompt origin must be one of {list(STORED_PROMPT_ORIGINS)}; got {origin!r}")
    prompt_id = "p" + secrets.token_hex(3)
    payload = {"text": redact(text), "origin": origin}
    if source is not None:
        payload["source"] = source
    return append_row(run_id, entry("prompt", session_id, payload, prompt_id=prompt_id, now=now))


def prompt_origin(row) -> str:
    # A restored, legacy or foreign copy carries the label and source record of a row this
    # writer never journaled; its transcript may still verify, so refuse before reading it.
    if isinstance(row, dict) and row.get("provenance") in _authority().UNVERIFIED:
        return "unknown"
    return programme_prompt_source.origin(row)


def read_path(path: str) -> list:
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def read(run_id: str) -> list:
    if _promoted(run_id):
        return _authority().journal_rows(run_id)
    return read_path(journal_path(run_id))


def claims(run_id: str) -> list:
    if _promoted(run_id):
        return _authority().claims_rows(run_id)
    return read_path(claims_path(run_id))


def claims_count(run_id: str) -> int:
    if _promoted(run_id):
        return len(_authority().claims_rows(run_id))
    try:
        with open(claims_path(run_id), "rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def find_prompt(run_id: str, prompt_id: str, rows=None):
    for row in read(run_id) if rows is None else rows:
        if row.get("kind") == "prompt" and row.get("prompt_id") == prompt_id:
            return row
    return None


def _cited_ids(rows) -> set:
    cited = set()
    for row in rows:
        for ref in row.get("cites") or []:
            cited.add(ref)
        ref = (row.get("payload") or {}).get("prompt_id")
        if isinstance(ref, str) and row.get("kind") != "prompt":
            cited.add(ref)
    return cited


def _prunable(rows, now, max_age_seconds) -> list:
    cited = _cited_ids(rows)
    out = []
    for row in rows:
        when = run_record_core.parse_iso(row.get("at"))
        if (row.get("kind") == "prompt" and row.get("prompt_id") not in cited
                and when is not None and (now - when).total_seconds() > max_age_seconds):
            out.append(row)
    return out


def _prune_promoted(run_id, now, max_age_seconds) -> int:
    def row(rows):
        keep = load_lib_module("programme_artifacts").protected_prompts(run_id)
        dropped = [r.get("prompt_id") for r in _prunable(rows, now, max_age_seconds)
                   if r.get("prompt_id") not in keep]
        if not dropped:
            return None
        return entry("prompts_pruned", None, {"removed": len(dropped), "prompt_ids": dropped}, now=now)

    built = _authority().append_row(run_id, row)
    return built["payload"]["removed"] if built else 0


def prune_uncited_prompts(run_id: str, now=None, max_age_seconds=PRUNE_AFTER_SECONDS) -> int:
    path = journal_path(run_id)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if _promoted(run_id):
        return _prune_promoted(run_id, now, max_age_seconds)

    def body():
        rows = read_path(path)
        dropped = {id(r) for r in _prunable(rows, now, max_age_seconds)}
        keep = [r for r in rows if id(r) not in dropped]
        removed = len(dropped)
        if not removed:
            return 0

        def write(fh):
            for row in keep:
                fh.write(json.dumps(row, sort_keys=True) + "\n")

        programme_home.atomic_write(path, write, ".journal.")
        _write_line(path, {"kind": "prompts_pruned", "at": _iso(now), "session_id": None,
                           "payload": {"removed": removed}})
        return removed

    if not os.path.exists(path):
        return 0
    return _locked(path, body)


def _cli(argv) -> int:
    parser = argparse.ArgumentParser(prog="programme_journal")
    sub = parser.add_subparsers(dest="verb", required=True)
    prune = sub.add_parser("prune")
    prune.add_argument("--run", required=True)
    args = parser.parse_args(argv)
    if args.verb == "prune":
        try:
            removed = prune_uncited_prompts(args.run)
        except (JournalError, run_record_core.RunRecordError) as exc:
            sys.stderr.write(f"programme_journal: {exc}\n")
            return 1
        print(json.dumps({"removed": removed}))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

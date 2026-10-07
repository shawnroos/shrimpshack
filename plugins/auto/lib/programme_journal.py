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
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")

JOURNAL_NAME = "journal.jsonl"
LOCK_NAME = ".journal.lock"
SECRETS_ENV = "CLAUDE_AUTO_SECRETS_FILE"
DEFAULT_SECRETS_FILE = "~/.secrets"
REDACTED = "[redacted]"
PROMPT_ORIGINS = ("typed", "cron")
PRUNE_AFTER_SECONDS = 7 * 24 * 3600
# Shorter values (flags, ports, "true") would redact ordinary words in prompts.
MIN_SECRET_LEN = 6

KINDS = (
    "prompt",
    "takeover_request",
    "handover_request",
    "end_request",
    "blocked_driver_send",
    "prompts_pruned",
    "agreement_proposed",
    "agreement_accepted",
    "term_amended",
    "instruction_recorded",
    "instruction_closed",
    "rule_proposed",
    "rule_adopted",
    "rules_acked",
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
_SECRETS_LINE = re.compile(r"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*?)\s*$")


class JournalError(Exception):
    pass


def _secret_values(path=None) -> list:
    path = os.path.expanduser(path or os.environ.get(SECRETS_ENV) or DEFAULT_SECRETS_FILE)
    try:
        with open(path) as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    values = set()
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        match = _SECRETS_LINE.match(line)
        if not match:
            continue
        value = match.group(1)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
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


def _locked(path: str, body):
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    return run_record_core._flock_run(os.path.join(folder, LOCK_NAME), body)


def _write_line(path: str, entry: dict) -> None:
    line = (json.dumps(entry, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, line)
    finally:
        os.close(fd)


def append_to(path: str, kind: str, session_id, payload=None, *, cites=None,
              prompt_id=None, now=None) -> dict:
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
    _locked(path, lambda: _write_line(path, entry))
    return entry


def append(run_id: str, kind: str, session_id, payload=None, *, cites=None, now=None) -> dict:
    return append_to(journal_path(run_id), kind, session_id, payload, cites=cites, now=now)


def append_prompt(run_id: str, session_id, text: str, origin: str, now=None) -> dict:
    if origin not in PROMPT_ORIGINS:
        raise JournalError(f"prompt origin must be one of {list(PROMPT_ORIGINS)}; got {origin!r}")
    prompt_id = "p" + secrets.token_hex(3)
    return append_to(journal_path(run_id), "prompt", session_id,
                     {"text": redact(text), "origin": origin},
                     prompt_id=prompt_id, now=now)


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
    return read_path(journal_path(run_id))


def find_prompt(run_id: str, prompt_id: str):
    for row in read(run_id):
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


def prune_uncited_prompts(run_id: str, now=None, max_age_seconds=PRUNE_AFTER_SECONDS) -> int:
    path = journal_path(run_id)
    now = now or datetime.datetime.now(datetime.timezone.utc)

    def body():
        rows = read_path(path)
        cited = _cited_ids(rows)
        keep, removed = [], 0
        for row in rows:
            when = run_record_core.parse_iso(row.get("at"))
            if (row.get("kind") == "prompt" and row.get("prompt_id") not in cited
                    and when is not None and (now - when).total_seconds() > max_age_seconds):
                removed += 1
                continue
            keep.append(row)
        if not removed:
            return 0
        fd, tmp = tempfile.mkstemp(prefix=".journal.", suffix=".tmp", dir=os.path.dirname(path))
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as fh:
                for row in keep:
                    fh.write(json.dumps(row, sort_keys=True) + "\n")
            os.rename(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
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
        print(json.dumps({"removed": prune_uncited_prompts(args.run)}))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

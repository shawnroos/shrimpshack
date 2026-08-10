#!/usr/bin/env python3
"""telemetry.py — surfacing telemetry (RECALL.log) and application records.

The measurement split (KTD9): *surfacing* events go here, to `RECALL.log` in the
memory store; `MEMORY_USE.log` stays application-only. They are kept apart on
purpose. `memory_activation.use_counts` reads the use log, use raises activation,
activation lowers the recall floor, and a lower floor surfaces the memory more —
so logging "I showed this to an agent" into the use log would make a memory
surface itself, a rich-get-richer loop that corrupts the very write-vs-apply
signal this unit exists to measure. Nothing here is ever fed to `use_counts`.

`RECALL.log` line (whitespace-delimited, one event per line):

    <iso-timestamp> <session_id> <source> <memory-name> <layer> [k=v ...]

`source` is one of `seeded` / `nudge` / `cli` / `memories-cmd` / `regroup`.
Machine-written only — no human is expected to hand-edit this file.

`MEMORY_USE.log` application line (KTD9b — session-joinable):

    <iso-timestamp> <memory-name> applied [session:<id>] [annotation...]

Field 1 uses the `T`-separated ISO form deliberately: it keeps the timestamp a
single whitespace field, so the memory name stays in field 2 for every existing
reader, while carrying the time of day a date-only stamp throws away.

**Session identity is required for the join, never inferred.** A writer that
genuinely has no session id records that absence as `NO_SESSION`, and the join
refuses to match absence to absence — under the concurrent sessions this store
actually sees, session A's nudge would otherwise join to session B's unrelated
application and report success while both logs stay perfectly well-formed.

Everything here is **fail-open**: telemetry must never break retrieval. Every
writer returns True/False and raises nothing; every reader yields what it could
parse and skips what it could not.
"""
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import memory_activation as _ma  # noqa: E402

RECALL_LOG_NAME = "RECALL.log"
USE_LOG_NAME = "MEMORY_USE.log"

#: Surfacing sources. `seeded` = session-start hook, `nudge` = ambient mid-session
#: nudge, `cli` = `reflect_cli recall`, `memories-cmd` = `/memories`, `regroup` =
#: `/reflect regroup`.
SOURCES = ("seeded", "nudge", "cli", "memories-cmd", "regroup")

#: Recorded in place of a session id by a writer that genuinely has none. It is a
#: value, not a wildcard: `same_session()` never matches it — not even to itself.
#: Spelled the same as the `[session:unknown]` the Memory Protocol tells agents to
#: write, deliberately — a writer that follows the doc inherits the refuse-to-join
#: semantics instead of accidentally joining every id-less record to every other.
NO_SESSION = "unknown"

#: The only token an agent writes into MEMORY_USE.log (see memory_activation).
APPLIED_TOKEN = _ma.APPLIED_TOKEN


def _clean(value, fallback="-"):
    """Collapse a field to a single whitespace-free token so a line can never
    grow extra fields and shift the ones after it."""
    s = "" if value is None else str(value)
    s = "".join(ch for ch in s if ch.isprintable())
    s = "_".join(s.split())
    return s[:200] or fallback


def _now():
    return datetime.now().replace(microsecond=0).isoformat(sep="T")


def resolve_session_id(session_id=None):
    """The session id to record. Explicit argument wins (hooks parse it out of
    their stdin JSON); `CLAUDE_SESSION_ID` is a convenience fallback; absence is
    recorded as `NO_SESSION` rather than left blank or invented."""
    for candidate in (session_id, os.environ.get("CLAUDE_SESSION_ID")):
        if candidate not in (None, ""):
            cleaned = _clean(candidate, "")
            if cleaned:
                return cleaned
    return NO_SESSION


def _append_line(path, line):
    """Append one line with a single O_APPEND write — the kernel keeps a lone
    write under PIPE_BUF whole, so two processes appending concurrently can
    interleave *lines* but never split one. Fail-open: False, never an exception."""
    try:
        payload = (line.rstrip("\n") + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, payload)
        finally:
            os.close(fd)
        return True
    except Exception:
        return False


# --------------------------------------------------------------- RECALL.log

def format_recall(memory, source, layer, session_id=None, ts=None, **extra):
    """Render one RECALL.log line. Unknown sources are recorded verbatim rather
    than dropped — losing the event would be worse than an odd source label."""
    fields = [
        _clean(ts or _now()),
        _clean(resolve_session_id(session_id)),
        _clean(source),
        _clean(memory),
        _clean(layer),
    ]
    for key in sorted(extra):
        if extra[key] is None:
            continue
        fields.append("%s=%s" % (_clean(key), _clean(extra[key])))
    return " ".join(fields)


def append_recall(log_path, memory, source, layer, session_id=None, ts=None,
                  **extra):
    """Record a surfacing event. Returns True on write, False on any failure —
    an unwritable log must cost the caller nothing but this False."""
    try:
        line = format_recall(memory, source, layer, session_id=session_id,
                             ts=ts, **extra)
    except Exception:
        return False
    return _append_line(log_path, line)


def parse_recall_line(line):
    """Parse one RECALL.log line into a dict, or None if it is not one."""
    parts = line.split()
    if len(parts) < 5:
        return None
    rec = {
        "ts": parts[0],
        "session_id": parts[1],
        "source": parts[2],
        "memory": parts[3],
        "layer": parts[4],
        "extra": {},
    }
    for tok in parts[5:]:
        if "=" in tok:
            k, _, v = tok.partition("=")
            rec["extra"][k] = v
    return rec


def parse_recall(log_path):
    """All parseable RECALL.log records. Missing/unreadable log -> []."""
    try:
        lines = open(log_path, encoding="utf-8").read().splitlines()
    except Exception:
        return []
    out = []
    for ln in lines:
        rec = parse_recall_line(ln)
        if rec is not None:
            out.append(rec)
    return out


def counts_by(records, key):
    """Tally records by `source` or `memory` (or any record key)."""
    counts = {}
    for rec in records:
        k = rec.get(key)
        if k is None:
            continue
        counts[k] = counts.get(k, 0) + 1
    return counts


# ------------------------------------------------------------ MEMORY_USE.log

def format_applied(memory, session_id=None, annotation=None, ts=None):
    """Render one `applied` line: `<ts> <name> applied [session:<id>] [note]`."""
    line = "%s %s %s [session:%s]" % (
        _clean(ts or _now()),
        _clean(memory),
        APPLIED_TOKEN,
        _clean(resolve_session_id(session_id)),
    )
    if annotation:
        note = " ".join(str(annotation).split())[:200]
        line += " [%s]" % note.replace("[", "(").replace("]", ")")
    return line


def append_applied(use_log_path, memory, session_id=None, annotation=None,
                   ts=None):
    """Record that a memory was applied in reasoning. Fail-open like the rest."""
    try:
        line = format_applied(memory, session_id=session_id,
                              annotation=annotation, ts=ts)
    except Exception:
        return False
    return _append_line(use_log_path, line)


def parse_use_line(line):
    """Parse one MEMORY_USE.log line, historical shapes included.

    `counts` reports whether the line contributes to activation, under the same
    single rule `memory_activation.use_line_counts` states — imported, not
    restated, so the two can never drift apart."""
    parts = line.split()
    if len(parts) < 2:
        return None
    session = NO_SESSION
    for tok in parts[2:]:
        stripped = tok.strip("[]()")
        if stripped.startswith("session:"):
            session = stripped[len("session:"):] or NO_SESSION
            break
    return {
        "ts": parts[0],
        "date": parts[0][:10],
        "memory": parts[1],
        "token": parts[2] if len(parts) > 2 else None,
        "session_id": session,
        "counts": _ma.use_line_counts(parts),
    }


def parse_use(log_path):
    """All parseable MEMORY_USE.log records. Missing/unreadable log -> []."""
    try:
        lines = open(log_path, encoding="utf-8").read().splitlines()
    except Exception:
        return []
    out = []
    for ln in lines:
        rec = parse_use_line(ln)
        if rec is not None:
            out.append(rec)
    return out


# ------------------------------------------------------------------- the join

def same_session(a, b):
    """True only when two records share a real session id. `NO_SESSION` never
    matches — not even another `NO_SESSION`, because "both writers didn't know"
    is not evidence that they were the same session (KTD9b)."""
    if not a or not b:
        return False
    if a == NO_SESSION or b == NO_SESSION:
        return False
    return a == b


def join_surfaced_applied(recall_records, use_records):
    """Credit each surfacing event only when the SAME session later applied the
    same memory.

    A date-only join is the trap this exists to avoid: with concurrent sessions,
    session A's nudge would be credited to session B's unrelated application, and
    every count-based test would still pass. Returns one dict per surfacing
    event with `credited` and the matching application (if any)."""
    applied = [r for r in use_records
               if r.get("token") == APPLIED_TOKEN and r.get("memory")]
    out = []
    for rec in recall_records:
        match = None
        for use in applied:
            if use["memory"] != rec.get("memory"):
                continue
            if not same_session(rec.get("session_id"), use.get("session_id")):
                continue
            if use["ts"] < rec.get("ts", ""):
                continue
            match = use
            break
        out.append({
            "surfaced": rec,
            "applied": match,
            "credited": match is not None,
        })
    return out


def credited_fraction(joined):
    """Fraction of surfacing events with a same-session application — the U7
    success metric. No events -> 0.0."""
    if not joined:
        return 0.0
    return sum(1 for j in joined if j["credited"]) / float(len(joined))


if __name__ == "__main__":
    store = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.claude/projects/-Users-shawnroos/memory")
    surfaced = parse_recall(os.path.join(store, RECALL_LOG_NAME))
    uses = parse_use(os.path.join(store, USE_LOG_NAME))
    joined = join_surfaced_applied(surfaced, uses)
    print("surfaced: %d  by source: %s" % (len(surfaced), counts_by(surfaced, "source")))
    print("applied:  %d" % sum(1 for u in uses if u["token"] == APPLIED_TOKEN))
    print("credited (same-session): %.2f" % credited_fraction(joined))

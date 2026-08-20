#!/usr/bin/env python3
"""retro.py — the retro backlog: item format, the single writer, the only reader (U1).

A retro item records tool friction: the surface it belongs to, the specific thing,
a one-line symptom, the sessions that hit it, and a disposition. Items live in
`<memory-dir>/.retro/<slug>.md`.

WHY A DOT-DIRECTORY (KTD2)
--------------------------
`corpus.iter_bodies()` prunes dot-directories, and corpus is the single
enumeration of the store — activation scoring, index rendering, local BM25 and
trigger compilation all read it. qmd skips dot-directories too (verified against
the live binary). So one directory name buys index exclusion, recall exclusion
and trigger exclusion with no code change in any consumer (R5).

The consequence is the reason `list_items` exists: NO search surface over the
backlog exists at all. Every read of the backlog goes through this file.

WHY THE PROBE LIVES IN THE BODY (KTD3)
--------------------------------------
`memory_activation.parse_last_used` and `parse_pinned` scan the head of a file
with line-anchored regexes rather than parsing YAML. A multi-line `probe:` in
frontmatter holding a line that looks like `last_used:` or `pin: true` would be
read as that key. Retro items are outside the corpus so activation never scores
them, but the hazard is structural — the body is free of it. The parser here
reads the top fence block and nothing else, which is what keeps a `last_used:`
line inside the probe fence out of the item's frontmatter.

WHY ONE WRITER
--------------
`set_disposition` is the only way an item leaves `open`, and it requires a proof
argument naming what closed it. That makes "no item is closed without a recorded
proof" an invariant testable at the writer, rather than a convention two callers
happen to follow. `append_session`, `record_probe_approval` and `record_probe_run`
cover every non-disposition update. Nothing else edits an item file.
"""
import calendar
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "scoped-memory"))
from triggers import frontmatter_lines, _unquote  # noqa: E402

RETRO_DIRNAME = ".retro"

#: R2. An item leaves the backlog only by moving out of `open`.
DISPOSITIONS = ("open", "fixed", "culled", "wontfix")

SURFACES = ("plugin", "skill", "harness", "codebase")

PROBE_HEADING = "## Probe"

_FENCE_OPEN = "```bash"
_FENCE_CLOSE = "```"


class RetroError(ValueError):
    """A write this module refuses: an unknown disposition, a move with no proof."""


def retro_dir(store_dir):
    return os.path.join(store_dir, RETRO_DIRNAME)


def item_path(store_dir, name):
    return os.path.join(retro_dir(store_dir), name + ".md")


def probe_hash(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def _ensure_dir(store_dir):
    d = retro_dir(store_dir)
    os.makedirs(d, exist_ok=True)
    # chmod, not makedirs(mode=): the mode argument is masked by the umask, and
    # under the default umask this directory holds probe shell world-readable.
    os.chmod(d, 0o700)
    return d


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def _write_atomic(path, text):
    d = os.path.dirname(path)
    # A unique temp name, never a fixed `.tmp`: two sessions writing at once
    # would otherwise open the same name and the survivor is a file assembled
    # from both runs.
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".retro-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def parse_frontmatter(text):
    """Frontmatter as a flat dict; nested keys join with a dot (`metadata.type`).

    Fail-open throughout: an unterminated fence reads as absent frontmatter
    (`frontmatter_lines` already returns [] for it), so a malformed item degrades
    to no metadata rather than raising in a list walk.
    """
    out = {}
    parent = None
    for line in frontmatter_lines(text):
        m = re.match(r"^(\s*)([A-Za-z_][\w.-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        indent, key, value = len(m.group(1)), m.group(2), m.group(3)
        if indent == 0:
            parent = key if not value.strip() else None
            if value.strip():
                out[key] = _unquote(value)
        elif parent:
            out[f"{parent}.{key}"] = _unquote(value)
    return out


def parse_probe(text):
    """The probe's shell, byte-identical, or None when the item carries no probe.

    Absent and empty are different states (R3/R4): a probe that is present and
    empty proves nothing, and so does an absent one, but only the second is a
    normal item.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != PROBE_HEADING:
            continue
        for j in range(i + 1, len(lines)):
            if not lines[j].strip():
                continue
            if lines[j].strip() != _FENCE_OPEN:
                break
            for k in range(j + 1, len(lines)):
                if lines[k].strip() == _FENCE_CLOSE:
                    return "\n".join(lines[j + 1:k])
            break
    return None


def read_item(store_dir, name):
    path = item_path(store_dir, name)
    if not os.path.exists(path):
        raise RetroError(f"no retro item named {name!r} in {retro_dir(store_dir)}")
    text = _read(path)
    return {
        "name": name,
        "path": path,
        "frontmatter": parse_frontmatter(text),
        "probe": parse_probe(text),
        "text": text,
    }


def list_items(store_dir, disposition=None, surface=None):
    """Every item in the backlog, optionally filtered. The ONLY view of it.

    Returns `[{name, path, frontmatter}]` sorted by name. An absent or empty
    `.retro/` lists empty rather than raising — every caller is on a review-time
    path where a missing backlog means "nothing to work", not an error.
    """
    d = retro_dir(store_dir)
    try:
        names = sorted(fn for fn in os.listdir(d) if fn.endswith(".md"))
    except OSError:
        return []
    out = []
    for fn in names:
        path = os.path.join(d, fn)
        fm = parse_frontmatter(_read(path))
        if disposition is not None and fm.get("disposition") != disposition:
            continue
        if surface is not None and fm.get("surface") != surface:
            continue
        out.append({"name": fn[:-3], "path": path, "frontmatter": fm})
    return out


def _splice(text, key, value):
    """Set one top-level frontmatter key, leaving every other byte alone.

    Reserialising a parsed item instead would rewrite bytes no caller asked to
    change, which is how a field ends up placed three different ways by three
    different writers.
    """
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise RetroError("item has no frontmatter block to write into")
    close = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            close = i
            break
    if close is None:
        raise RetroError("item has an unterminated frontmatter fence")
    new = f"{key}: {value}\n"
    for i in range(1, close):
        if re.match(rf"^{re.escape(key)}\s*:", lines[i]):
            lines[i] = new
            return "".join(lines)
    lines.insert(close, new)
    return "".join(lines)


def write_item(store_dir, name, description, surface, thing, symptom,
               probe=None, sessions=(), capture="live", disposition="open",
               opened=None, links=(), cost=None):
    if disposition not in DISPOSITIONS:
        raise RetroError(
            f"disposition {disposition!r} is not one of {', '.join(DISPOSITIONS)}")
    if surface not in SURFACES:
        raise RetroError(f"surface {surface!r} is not one of {', '.join(SURFACES)}")
    d = _ensure_dir(store_dir)
    head = [
        "---",
        f"name: {name}",
        f"description: {description}",
        f"disposition: {disposition}",
        f"surface: {surface}",
        f"thing: {thing}",
        f"opened: {opened or time.strftime('%Y-%m-%d')}",
        f"sessions: {', '.join(sessions)}",
        f"capture: {capture}",
        "metadata:",
        "  type: retro",
        "---",
        "",
        symptom,
        "",
    ]
    if cost:
        head += [f"Cost so far: {cost}", ""]
    if links:
        head += ["Related: " + " ".join(f"[[{l}]]" for l in links), ""]
    if probe is not None:
        head += [PROBE_HEADING, "", _FENCE_OPEN, probe, _FENCE_CLOSE, ""]
    path = os.path.join(d, name + ".md")
    _write_atomic(path, "\n".join(head))
    return path


def set_disposition(store_dir, name, disposition, proof):
    """Move an item between dispositions. The proof is not optional (R4).

    Order matters: both arguments are validated before anything is written, so a
    refused move leaves the file byte-identical rather than half-updated.
    """
    if disposition not in DISPOSITIONS:
        raise RetroError(
            f"disposition {disposition!r} is not one of {', '.join(DISPOSITIONS)}")
    if not (proof or "").strip():
        raise RetroError(
            f"moving {name!r} to {disposition!r} needs a proof naming what closed it")
    item = read_item(store_dir, name)
    text = _splice(item["text"], "disposition", disposition)
    text = _splice(text, "proof", " ".join(proof.split()))
    _write_atomic(item["path"], text)
    return item["path"]


def append_session(store_dir, name, session_id):
    item = read_item(store_dir, name)
    current = [s for s in
               (p.strip() for p in item["frontmatter"].get("sessions", "").split(","))
               if s]
    if session_id in current:
        return item["path"]
    current.append(session_id)
    _write_atomic(item["path"],
                  _splice(item["text"], "sessions", ", ".join(current)))
    return item["path"]


def record_probe_approval(store_dir, name, digest, approved=None):
    item = read_item(store_dir, name)
    text = _splice(item["text"], "probe_approved",
                   approved or time.strftime("%Y-%m-%d"))
    text = _splice(text, "probe_hash", digest)
    _write_atomic(item["path"], text)
    return item["path"]


# ------------------------------------------------------- the probe runner (U4)
#
# A probe is stored shell, authored by an agent from transcript material the
# operator never wrote, executed later with the operator's full privileges. Three
# properties carry that risk, and all three are enforced here rather than stated:
#
# 1. Auto-close is default-deny, proven by a per-execution nonce (KTD4). Exit
#    status proves nothing on this machine: `timeout` does not exist, so
#    `timeout 480 bash foo.sh` fails command-not-found AND the shell reports 0;
#    `cp`/`mv`/`rm` are aliased `-i` and no-op at exit 0. This plugin has already
#    shipped a tally keyed on exit status that reported `embedded=5 failed=0`
#    over zero work. Requiring the token to own its line stops a probe echoing
#    its own source; it does NOT stop forwarded tool output that happens to
#    contain the token — only a nonce minted after the probe was authored does.
# 2. First execution requires an approval recorded against a hash of the probe
#    text. Nothing here prompts: an unapproved probe is refused, never asked
#    about. The approval decision belongs to the attended `/reflect:reflect-retro`
#    session, which shows the text and calls `record_probe_approval`.
# 3. Execution is attended (KTD9). Nothing under `hooks/` and nothing in
#    `reflect-run.sh` may reference this entry point, and
#    `tests/probe_boundary_check.sh` fails the harness if that changes.

PROBE_TOKEN = "RETRO-FIXED"

#: Absolute, not `bash`: a probe must not get whichever shell a PATH happens to
#: resolve, and the tests pin the same binary.
PROBE_SHELL = "/bin/bash"

PROBE_BUDGET_SECONDS = 120

#: A probe can double-fork out of its process group, survive the group kill, and
#: hold the stdout pipe open forever. After this second wait the output is
#: abandoned — an unkillable probe must not wedge the run it was called from.
PROBE_REAP_SECONDS = 5

PROBE_DETAIL_CHARS = 400


def _one_line(text, limit=PROBE_DETAIL_CHARS):
    # Redact BEFORE storing: a probe re-runs the broken tool, and a credential
    # in that tool's error output would otherwise become durable in an item that
    # later gets pasted into an issue. Collapsed to one line because `_splice`
    # writes a single frontmatter line.
    return " ".join(redact(text or "").split())[:limit]


def probe_is_approved(item):
    """Approved, and approved for THIS text (KTD9). An edited probe is neither."""
    fm = item["frontmatter"]
    return (bool(fm.get("probe_approved"))
            and fm.get("probe_hash") == probe_hash(item["probe"]))


def record_probe_run(store_dir, name, result, detail, ran=None):
    item = read_item(store_dir, name)
    text = _splice(item["text"], "probe_result", result)
    text = _splice(text, "probe_ran",
                   ran or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    text = _splice(text, "probe_detail", _one_line(detail))
    _write_atomic(item["path"], text)
    return item["path"]


def _kill_group(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except OSError:
        # The group is gone, or getpgid raced the exit. Fall back to the direct
        # child so a failure here can never leave the runner waiting.
        try:
            proc.kill()
        except OSError:
            pass


def run_probe(store_dir, name, budget=PROBE_BUDGET_SECONDS, cwd=None):
    """Execute one item's probe and close the item only on positive proof (R4).

    Returns what happened; the item file is the authority. Every outcome other
    than `proven` leaves the item `open`, including a non-zero exit, empty
    stdout, a nonce-less or stale token, a timeout, and a probe that could not
    start. Nothing here raises on a bad probe — a review-time run over the whole
    backlog must not stop at the first hostile item.
    """
    item = read_item(store_dir, name)
    probe = item["probe"]
    if probe is None or not probe.strip():
        return {"name": name, "result": "no-probe", "ran": False, "closed": False,
                "exit": None}
    if not probe_is_approved(item):
        record_probe_run(store_dir, name, "unapproved",
                         "probe text has no matching approval; not executed")
        return {"name": name, "result": "unapproved", "ran": False,
                "closed": False, "exit": None}

    nonce = secrets.token_hex(16)
    env = dict(os.environ)
    env["RETRO_NONCE"] = nonce
    try:
        # start_new_session: the probe leads its own process group, so the
        # timeout path can kill what it spawned. `subprocess.run(timeout=)`
        # SIGKILLs the direct child and orphans every grandchild — a defect this
        # plugin already fixed once in the qmd guard.
        proc = subprocess.Popen(
            [PROBE_SHELL, "-c", probe], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, errors="replace", env=env,
            cwd=cwd, start_new_session=True)
    except OSError as exc:
        record_probe_run(store_dir, name, "start-failed", str(exc))
        return {"name": name, "result": "start-failed", "ran": False,
                "closed": False, "exit": None}

    timed_out = False
    try:
        out, err = proc.communicate(timeout=budget)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_group(proc)
        try:
            out, err = proc.communicate(timeout=PROBE_REAP_SECONDS)
        except subprocess.TimeoutExpired:
            out, err = "", ""

    proven = (not timed_out and proc.returncode == 0
              and any(line == f"{PROBE_TOKEN} {nonce}"
                      for line in (out or "").splitlines()))
    result = "proven" if proven else ("timeout" if timed_out else "unproven")
    detail = (f"budget {budget}s exceeded; process group killed" if timed_out
              else f"exit {proc.returncode}; stdout: {_one_line(out)}"
                   f" | stderr: {_one_line(err)}")
    record_probe_run(store_dir, name, result, detail)
    if proven:
        set_disposition(
            store_dir, name, "fixed",
            f"probe exited 0 and printed {PROBE_TOKEN} with this run's nonce")
    return {"name": name, "result": result, "ran": True, "closed": proven,
            "exit": None if timed_out else proc.returncode}


def run_probes(store_dir, budget=PROBE_BUDGET_SECONDS, cwd=None):
    """Run every open item's probe. Items without one are left untouched."""
    out = {"attempted": 0, "closed": 0, "skipped": 0, "runs": []}
    for row in list_items(store_dir, disposition="open"):
        res = run_probe(store_dir, row["name"], budget=budget, cwd=cwd)
        if res["result"] == "no-probe":
            out["skipped"] += 1
            continue
        out["attempted"] += 1
        out["closed"] += 1 if res["closed"] else 0
        out["runs"].append(res)
    return out



# ---------------------------------------------------------------- the drain (U3)
#
# WHY THIS FILE DOES NO EXTRACTION
# --------------------------------
# The hooks queue rather than capture because a command hook cannot exercise
# judgment (KTD6). Moving that judgment here would only relocate the same
# problem: deciding whether a tool or the work was at fault is not a pattern
# match. So `drain` returns BOUNDED CANDIDATE MATERIAL and the agent decides
# what qualifies.
#
# The bound is the whole point. A drained transcript is a full pre-compaction
# session — 28 MB was the largest measured on this machine — arriving inside a
# reflect run whose output contract is silence. Every return therefore says how
# much it dropped: a silently truncated drain that reads like a quiet session is
# the failure this exists to prevent.

QUEUE_ENV = "REFLECT_RETRO_QUEUE"
QUEUE_DEFAULT = "~/.claude/.retro-queue"

#: The five fields `retro-queue.sh` writes, stored literally. There is no
#: encoding to decode: the hook strips tabs and newlines rather than escaping
#: them, deliberately, so a path containing a backslash survives intact.
QUEUE_FIELDS = ("session_id", "transcript_path", "cursor_uuid", "event", "ts")

#: Measured 2026-08-20 over the ten most recent transcripts on this machine
#: (2026-07-05 to 2026-08-20, ~46 days): the vent bar would have produced 13
#: items, 0-4 per transcript, about two a week. Reflect runs far more often than
#: fortnightly, so 14 days covers the real gap between runs with room to spare
#: while staying well inside Claude Code's own transcript pruning (~30 days),
#: past which a record can only be dropped as missing anyway.
EXPIRY_DAYS = 14

MAX_CANDIDATES = 40
MAX_EXCERPT_CHARS = 600

_REDACTED = "[redacted]"

# Applied to every excerpt this module returns, AFTER truncation. The drain
# reads whole transcripts of sessions nobody reviewed, from every project
# including work repos, and a retro item is precisely what later gets pasted
# into an issue — so a credential that appeared once in an error message would
# otherwise become durable and travel.
_SECRET_PATTERNS = (
    re.compile(r"-----BEGIN[^-\n]*PRIVATE KEY-----"),
    re.compile(r"\b(?:sk|rk)-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"),
    re.compile(r"(?i)\b(?:authorization|bearer|token|secret|password|passwd|"
               r"api[_-]?key|access[_-]?key|credential)s?\b\s*[:=]\s*\S+"),
    re.compile(r"\b[A-Fa-f0-9]{40,}\b"),
)


def redact(text):
    out = text or ""
    for pat in _SECRET_PATTERNS:
        out = pat.sub(_REDACTED, out)
    return out


#: `live_session_id=None` means "explicitly unknown"; this default means "ask the
#: harness". Collapsing the two would make an explicit unknown silently resolve
#: to whatever session the drain happens to run inside.
_FROM_ENV = object()


def queue_file(path=None):
    return path or os.environ.get(QUEUE_ENV) or os.path.expanduser(QUEUE_DEFAULT)


def live_session():
    """The session this process is running in, or None when the harness is silent.

    None means "drain everything and say so", never "skip everything": a silent
    skip is lost signal, while a duplicate candidate is absorbed by the bar.
    """
    return (os.environ.get("CLAUDE_CODE_SESSION_ID")
            or os.environ.get("CLAUDE_SESSION_ID") or None) or None


def parse_queue_line(line):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != len(QUEUE_FIELDS) or not parts[0] or not parts[1]:
        return None
    return dict(zip(QUEUE_FIELDS, parts))


def format_queue_line(rec):
    return "\t".join(rec.get(f, "") for f in QUEUE_FIELDS)


def read_queue_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return [ln for ln in fh.read().splitlines() if ln.strip()]
    except OSError:
        return []


def merge_queue_lines(first_read, keep, current):
    """Survivors, plus anything appended while the drain was reading transcripts.

    Scanning a queue's worth of transcripts takes seconds, and other sessions
    append to this one file throughout (the reason KTD8 makes each append a
    single atomic write). A read-once-then-replace would silently delete every
    record written in that window.
    """
    if current[:len(first_read)] == first_read:
        tail = current[len(first_read):]
    else:
        seen = set(first_read)
        tail = [ln for ln in current if ln not in seen]
    return list(keep) + [ln for ln in tail if ln not in set(keep)]


def _iter_transcript(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec


def _block_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and isinstance(b.get("text"), str):
                parts.append(b["text"])
            elif isinstance(b, str):
                parts.append(b)
        return "\n".join(parts)
    return "" if content is None else str(content)


def _failures(rec, tool_names):
    """Failure-shaped material in one transcript record, or an empty list.

    Failure-shaped ONLY. Ordinary successful turns are never returned: the drain
    path may write an item only for an explicit tool failure it can name, so an
    ordinary turn cannot justify one — it would add material (and user prompts
    are where secrets live) for no item it could produce.
    """
    out = []
    msg = rec.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("id"):
                tool_names[block["id"]] = block.get("name") or ""
            elif block.get("type") == "tool_result" and block.get("is_error"):
                out.append(("tool_error",
                            tool_names.get(block.get("tool_use_id"), ""),
                            _block_text(block.get("content"))))
    if rec.get("type") == "system":
        errs = rec.get("hookErrors")
        if errs:
            out.append(("hook_error", "hook", _block_text(errs)))
        elif rec.get("level") == "error":
            out.append(("system_error", "", _block_text(rec.get("content"))))
    return out


def scan_transcript(path, cursor_uuid="", max_candidates=MAX_CANDIDATES,
                    max_excerpt_chars=MAX_EXCERPT_CHARS):
    """Bounded failure-shaped candidates from one transcript, after `cursor_uuid`.

    A cursor that is not in the transcript falls back to the whole file with
    `cursor_found` false. A skip-until-found loop that never matches returns
    zero candidates, which reads exactly like a quiet session — the one thing
    the bound must never be mistaken for.
    """
    tool_names = {}
    after, whole = [], []
    found = not cursor_uuid
    after_found = whole_found = 0
    scanned = 0
    last_uuid = ""
    cwd = branch = ""
    for rec in _iter_transcript(path):
        scanned += 1
        if rec.get("uuid"):
            last_uuid = rec["uuid"]
        cwd = rec.get("cwd") or cwd
        branch = rec.get("gitBranch") or branch
        hits = _failures(rec, tool_names)
        for kind, tool, text in hits:
            excerpt = redact(text[:max_excerpt_chars])
            item = {
                "uuid": rec.get("uuid", ""),
                "timestamp": rec.get("timestamp", ""),
                "kind": kind,
                "tool": tool,
                "excerpt": excerpt,
                "truncated": len(text) > max_excerpt_chars,
            }
            whole_found += 1
            if len(whole) < max_candidates:
                whole.append(item)
            if found:
                after_found += 1
                if len(after) < max_candidates:
                    after.append(item)
        # After the hits, so the cursor record itself is never re-reported.
        if not found and rec.get("uuid") == cursor_uuid:
            found = True
    candidates = after if found else whole
    total = after_found if found else whole_found
    return {
        "candidates": candidates,
        "candidates_found": total,
        "candidates_returned": len(candidates),
        "candidates_dropped": total - len(candidates),
        "excerpts_truncated": sum(1 for c in candidates if c["truncated"]),
        "records_scanned": scanned,
        "last_uuid": last_uuid,
        "cursor_found": bool(found or not cursor_uuid),
        "cwd": cwd,
        "git_branch": branch,
    }


def transcript_tail_uuid(path):
    last = ""
    for rec in _iter_transcript(path):
        if rec.get("uuid"):
            last = rec["uuid"]
    return last


def _epoch(ts):
    # timegm, not mktime: the hook stamps UTC, and mktime would read it as local
    # time and shift the expiry bound by the offset — silently, and by an hour
    # more or less depending on the season.
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return None


def drain(queue=None, live_session_id=_FROM_ENV, now=None, expiry_days=EXPIRY_DAYS,
          max_candidates=MAX_CANDIDATES, max_excerpt_chars=MAX_EXCERPT_CHARS):
    """Read the queue, hand back bounded candidate material, leave the queue clean.

    Two fates, and the record's session decides which — never its `event`, since
    a SessionEnd record can belong to a session that is still live:

    - the live session's record is KEPT with its cursor stamped to the
      transcript's current tail. That stamp is the only non-empty cursor the
      system ever produces (the hook always writes it empty), and it is what
      makes a second compaction collapse into a cursor advance instead of a
      second record. It also stops the eventual drain of this session from
      re-surfacing friction the live vent pass already wrote items for.
    - every other record is drained and dropped.

    Plus the three hygiene drops: expired, transcript gone, unparseable.
    """
    path = queue_file(queue)
    if live_session_id is _FROM_ENV:
        live_session_id = live_session()
    now = now if now is not None else time.time()
    cutoff = now - expiry_days * 86400

    first_read = read_queue_lines(path)
    groups, order, malformed = {}, [], 0
    for line in first_read:
        rec = parse_queue_line(line)
        if rec is None:
            malformed += 1
            continue
        sid = rec["session_id"]
        if sid not in groups:
            groups[sid] = []
            order.append(sid)
        groups[sid].append(rec)

    result = {
        "queue": path,
        "live_session": live_session_id,
        "live_session_known": bool(live_session_id),
        "expiry_days": expiry_days,
        "records_seen": len(first_read),
        "sessions_seen": len(order),
        "collapsed": 0,
        "stamped": 0,
        "dropped_malformed": malformed,
        "dropped_missing": [],
        "dropped_expired": [],
        "drained": [],
        "kept": 0,
    }
    keep = []

    for sid in order:
        recs = groups[sid]
        result["collapsed"] += len(recs) - 1
        newest = max(recs, key=lambda r: r.get("ts", ""))
        # Furthest-advanced cursor wins: only a previous drain writes one, so at
        # most one record in the group carries it.
        stamped = [r for r in recs if r.get("cursor_uuid")]
        cursor = (max(stamped, key=lambda r: r.get("ts", ""))["cursor_uuid"]
                  if stamped else "")
        rec = dict(newest)
        rec["cursor_uuid"] = cursor
        events = ", ".join(r.get("event", "") for r in recs if r.get("event"))
        tpath = rec["transcript_path"]
        exists = os.path.exists(tpath)
        is_live = bool(live_session_id) and sid == live_session_id

        if is_live:
            if not exists:
                result["dropped_missing"].append(
                    {"session_id": sid, "transcript_path": tpath, "live": True})
                continue
            rec["cursor_uuid"] = transcript_tail_uuid(tpath) or cursor
            keep.append(format_queue_line(rec))
            result["stamped"] += 1
            continue

        stamp = _epoch(rec.get("ts", ""))
        if stamp is not None and stamp < cutoff:
            result["dropped_expired"].append(
                {"session_id": sid, "ts": rec.get("ts", ""),
                 "records": len(recs)})
            continue
        if not exists:
            result["dropped_missing"].append(
                {"session_id": sid, "transcript_path": tpath, "live": False})
            continue

        try:
            scan = scan_transcript(tpath, cursor, max_candidates,
                                   max_excerpt_chars)
        except OSError:
            result["dropped_missing"].append(
                {"session_id": sid, "transcript_path": tpath, "live": False})
            continue
        scan.update({
            "session_id": sid,
            "event": events,
            "ts": rec.get("ts", ""),
            "cursor_uuid": cursor,
            "records_collapsed": len(recs),
            "capture": "drained",
        })
        result["drained"].append(scan)

    result["kept"] = len(keep)
    current = read_queue_lines(path)
    final = merge_queue_lines(first_read, keep, current)
    if final or os.path.exists(path):
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        _write_atomic(path, "".join(ln + "\n" for ln in final))
    return result


if __name__ == "__main__":
    # `probe` is the attended entry point (KTD9): it is invoked by hand inside
    # /reflect:reflect-retro and by nothing else. tests/probe_boundary_check.sh
    # fails the harness if a hook or reflect-run.sh ever names it.
    if len(sys.argv) > 2 and sys.argv[1] == "probe":
        json.dump(run_probes(sys.argv[2]), sys.stdout, indent=1)
        print()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "drain":
        json.dump(drain(), sys.stdout, indent=1)
        print()
        sys.exit(0)
    store = (sys.argv[1] if len(sys.argv) > 1
             else os.environ.get("MEMORY_DIR") or os.path.expanduser(
                 "~/.claude/projects/-"
                 + os.path.expanduser("~").lstrip("/").replace("/", "-") + "/memory"))
    rows = list_items(store, disposition="open")
    for row in rows:
        fm = row["frontmatter"]
        print(f"{fm.get('surface', '-'):9s}  {row['name']:40s}  "
              f"{fm.get('description', '')}")
    print(f"\n{len(rows)} open retro items in {retro_dir(store)}", file=sys.stderr)

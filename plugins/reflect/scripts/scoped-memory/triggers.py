#!/usr/bin/env python3
"""triggers.py — declared triggers: frontmatter parse, validation, manifest, match.

A memory may declare the situations it applies to. A declared trigger that matches
the command an agent just ran surfaces a NUDGE — precision by construction, no
ranking, no qmd, milliseconds (plan U3 / KTD7).

THE SCHEMA (KTD17 — a bare string is never guessed at)
------------------------------------------------------
`triggers:` is a list of TYPED entries. Every entry declares itself:

    triggers:
      - literal: gh pr view --json
      - literal: statusCheckRollup
      - regex: gh\\s+pr\\s+view\\b

An untyped entry (`- gh pr view`) is REJECTED, not guessed at. Read as a literal
it means one thing; read as a regex, `.`/`[`/`(`/`+`/`?` silently change meaning —
and BOTH readings pass the motivating Case 1 test, so the ambiguity would ship
undetected. Typing it is the whole point.

The five things the schema fixes, so no reader has to infer them:

* **Engine** — Python's `re` module, `re.search`, `re.IGNORECASE`. One engine, one
  dialect; nothing here is fed to grep.
* **Anchoring** — patterns are NOT anchored. A pattern matches anywhere in the
  situation text (substring semantics, which is what "this command mentions X"
  means). Anchor explicitly with `^` / `$` / `\\b` in a `regex:` entry.
* **Escaping** — a `literal:` value is `re.escape`d at compile time and stored as
  escaped regex source, so every metacharacter matches itself. For BOTH kinds the
  value is taken VERBATIM after at most one layer of surrounding matched quotes is
  removed: no YAML escape processing, no comment stripping. So `regex: a\\s+b`
  reaches the engine as `a\\s+b`, not as `a<space>b`.
* **Maximum pattern length** — `MAX_PATTERN_LEN` characters, and at most
  `MAX_PATTERNS_PER_MEMORY` patterns per memory. Both bound the ambient budget:
  this runs on every Bash call.
* **Per-pattern evaluation bound** — `PATTERN_BUDGET_S` of wall clock per pattern,
  enforced with `SIGALRM` (see `_search_bounded`). Load-bearing: one pathological
  pattern that ate the hook's whole timeout would make every LATER pattern vanish
  with a clean exit 0 — this plan's signature failure mode (silence indistinguish-
  able from "nothing matched") reproduced inside its own precision mechanism. A
  pattern that blows its budget is skipped; the ones after it still evaluate.

Validation additionally REJECTS any pattern containing `description:`. The index
renderer's `orphan_hook` scans the first 20 lines of a body for `description\\s*:`
BEFORE parsing frontmatter, so such a pattern would be lifted into MEMORY.md as
that memory's hook. A malformed pattern is skipped with the memory named on
stderr — never fatal, never a failed compile.

THE MANIFEST
------------
Compiled to `TRIGGERS.json` beside `MEMORY.md` in the store. Non-`.md` on purpose:
`memory_activation.score_dir` doesn't score it, the renderer gives it no index
pointer, and qmd doesn't embed it (`corpus.EXCLUDED_NAMES` names it explicitly).

Written via a UNIQUE temp file in the destination directory plus `os.replace`
(KTD18). The repo's established fixed-`.tmp` idiom gives READERS atomicity and
concurrent WRITERS nothing: two sessions compiling at once open the same temp
name, and the survivor is valid JSON assembled from the wrong run — the hook then
quietly matches stale or half-written triggers.

Enumeration is `corpus.iter_bodies()` (U10). A flat `os.listdir` would leave the
287 bodies under `_scope/**` unable to declare a trigger at all.

MATCHING
--------
Scope is filtered at MATCH time, not compile time (KTD13): one manifest is read
from every repo and cannot be pre-filtered for a cwd it does not know. Each entry
carries its scope slug; `scope.classify()` drops `sibling` entries. Global
(unscoped) memories always pass. Without this, one Slate memory's `gh pr view`
trigger nudges in every repo you work in.

The nudge is a POINTER — title, one-line hook, how to fetch the body. Never the
body itself (R5).

CLI:
    triggers.py match  [--store DIR] [--cwd DIR] [--session ID] [--all] [--plain]
                       # situation text on STDIN; prints hook JSON, or nothing
    triggers.py compile [--store DIR]     # see compile-triggers.py for the hook
"""
import hashlib
import json
import os
import re
import signal
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus  # noqa: E402
import scope  # noqa: E402

try:
    import telemetry  # noqa: E402
except Exception:                                    # pragma: no cover
    telemetry = None                                 # telemetry is never load-bearing

MANIFEST_NAME = corpus.TRIGGER_MANIFEST
SCHEMA_VERSION = 1

#: Longest accepted pattern, and the most patterns one memory may declare.
MAX_PATTERN_LEN = int(os.environ.get("MEMORY_TRIGGER_MAX_LEN", "200"))
MAX_PATTERNS_PER_MEMORY = int(os.environ.get("MEMORY_TRIGGER_MAX_PATTERNS", "8"))

#: Per-pattern wall-clock bound, and a whole-run bound as a second fence.
PATTERN_BUDGET_S = float(os.environ.get("MEMORY_TRIGGER_PATTERN_BUDGET", "0.05"))
MATCH_BUDGET_S = float(os.environ.get("MEMORY_TRIGGER_MATCH_BUDGET", "1.5"))

#: Situation text is truncated before matching — a 200KB heredoc pasted into a
#: Bash call must not become 200KB of regex input on the ambient path.
MAX_SITUATION = int(os.environ.get("MEMORY_TRIGGER_MAX_SITUATION", "4000"))

#: Nudges emitted per event. Beyond this the output says how to see the rest.
NUDGE_CAP = int(os.environ.get("MEMORY_TRIGGER_NUDGE_CAP", "2"))

HOOK_CAP = 150
_FM_READ_BYTES = 8192

KINDS = ("literal", "regex")

#: `orphan_hook` matches `description\s*:` in the first 20 lines, before any
#: frontmatter parsing — so this is checked against the whitespace-normalized
#: pattern, not the raw one. `description :` must be caught too.
_DESCRIPTION_RE = re.compile(r"description\s*:", re.IGNORECASE)


# --------------------------------------------------------------- frontmatter

def read_head(path):
    """First `_FM_READ_BYTES` of a body, or "" if unreadable. Fail-open."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(_FM_READ_BYTES)
    except Exception:
        return ""


def frontmatter_lines(text):
    """Lines between the leading `---` fences, or [] when there is no block."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    out = []
    for line in lines[1:]:
        if line.strip() == "---":
            return out
        out.append(line)
    return []                       # unterminated block: treat as absent


def _unquote(value):
    """Strip at most ONE layer of matched surrounding quotes. No escape
    processing — the value reaches the regex engine exactly as written."""
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def parse_triggers(fm_lines):
    """Typed trigger entries declared in a frontmatter block.

    Returns `[(kind, value), ...]` for well-formed typed entries and
    `[(None, raw), ...]` for entries that declared no type — those are surfaced
    as validation failures rather than guessed at (KTD17).
    """
    entries = []
    indent = None
    for line in fm_lines:
        stripped = line.strip()
        if indent is None:
            m = re.match(r"^(\s*)triggers\s*:\s*(.*)$", line)
            if m and not m.group(2).strip():
                indent = len(m.group(1))
            continue
        if not stripped or stripped.startswith("#"):
            continue
        cur = len(line) - len(line.lstrip())
        if cur <= indent:
            break                                   # block ended
        item = re.match(r"^\s*-\s*(.*)$", line)
        if not item:
            break
        raw = item.group(1).rstrip()
        typed = re.match(r"^(%s)\s*:\s*(.*)$" % "|".join(KINDS), raw)
        if typed:
            entries.append((typed.group(1), _unquote(typed.group(2))))
        else:
            entries.append((None, raw))
    return entries


def hook_of(text, fallback):
    """The memory's one-line hook: its `description:`, else its first body line."""
    fm = frontmatter_lines(text)
    for line in fm:
        m = re.match(r"\s*description\s*:\s*(.+)", line)
        if m:
            return " ".join(_unquote(m.group(1)).split())[:HOOK_CAP]
    body = text.split("\n---\n", 1)[-1] if text.startswith("---\n") else text
    for line in body.splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            return " ".join(s.split())[:HOOK_CAP]
    return fallback


# ---------------------------------------------------------------- validation

def validate_pattern(kind, value):
    """`(regex_source, None)` for an accepted pattern, `(None, reason)` otherwise.

    Every rejection reason is a sentence a human can act on — it is printed with
    the memory named, and a rejected pattern never fails the compile.
    """
    if kind not in KINDS:
        return None, ("untyped entry %r — declare it as `literal:` or `regex:` "
                      "(a bare string is never guessed at)" % (value or "")[:60])
    if not value:
        return None, "empty %s pattern" % kind
    if len(value) > MAX_PATTERN_LEN:
        return None, "pattern longer than %d characters" % MAX_PATTERN_LEN
    if _DESCRIPTION_RE.search(" ".join(value.split())):
        return None, ("pattern contains `description:`, which the index renderer "
                      "would lift into MEMORY.md as this memory's hook")
    if kind == "literal":
        return re.escape(value), None
    try:
        re.compile(value)
    except re.error as exc:
        return None, "invalid regex: %s" % exc
    return value, None


# ------------------------------------------------------------------ manifest

def compile_manifest(store_dir):
    """`(manifest, problems)` for every body under `store_dir`.

    `problems` is `[(relpath, pattern_value, reason), ...]`; the caller prints it
    with the memory named. A memory whose every pattern is rejected contributes
    no entry — it is not an error.
    """
    entries, problems = [], []
    for relpath, slug in corpus.iter_bodies(store_dir):
        text = read_head(os.path.join(store_dir, relpath))
        fm = frontmatter_lines(text)
        if not fm:
            continue
        declared = parse_triggers(fm)
        if not declared:
            continue
        patterns = []
        for kind, value in declared:
            if len(patterns) >= MAX_PATTERNS_PER_MEMORY:
                problems.append((relpath, value,
                                 "more than %d patterns declared; the rest are "
                                 "ignored" % MAX_PATTERNS_PER_MEMORY))
                break
            src, reason = validate_pattern(kind, value)
            if reason:
                problems.append((relpath, value, reason))
                continue
            patterns.append({"kind": kind, "re": src})
        if not patterns:
            continue
        name = os.path.basename(relpath)
        entries.append({
            "memory": name[:-3] if name.endswith(".md") else name,
            "path": relpath,
            "scope": slug,
            "hook": hook_of(text, ""),
            "patterns": patterns,
        })
    manifest = {
        "version": SCHEMA_VERSION,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "count": len(entries),
        "entries": entries,
    }
    return manifest, problems


def write_manifest(store_dir, manifest):
    """Atomically replace `TRIGGERS.json`. True on write, False on any failure.

    The temp file is UNIQUE and lives in the destination directory (KTD18), so two
    sessions compiling concurrently cannot assemble one file out of two runs. Its
    name starts with `.` so `corpus.iter_bodies` skips it even mid-window.
    """
    dest = os.path.join(store_dir, MANIFEST_NAME)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=store_dir, prefix=".%s." % MANIFEST_NAME,
                                   suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, dest)
        # Stamp the manifest AFTER the replace. `os.replace` bumps the store
        # directory's own mtime, and the freshness test folds directory mtimes in
        # (so a DELETED memory invalidates the manifest). Without this the
        # manifest is born one instant older than the directory it just changed,
        # and every compile would decide it was stale — the mtime skip would
        # silently never skip.
        try:
            os.utime(dest, None)
        except OSError:
            pass
        return True
    except Exception:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False


def load_manifest(store_dir):
    """The compiled manifest, or None when it is missing, unreadable, or not a
    manifest of a version this code understands. Fail-open everywhere."""
    try:
        with open(os.path.join(store_dir, MANIFEST_NAME), encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, dict) or data.get("version") != SCHEMA_VERSION:
        return None
    if not isinstance(data.get("entries"), list):
        return None
    return data


# ------------------------------------------------------------------ matching

class _PatternTimeout(Exception):
    pass


def _alarm(signum, frame):                            # pragma: no cover - trivial
    raise _PatternTimeout()


def _can_alarm():
    """SIGALRM is usable only on the main thread of the main interpreter."""
    return (hasattr(signal, "setitimer")
            and threading.current_thread() is threading.main_thread())


_CACHE = {}


def _compiled(src):
    rx = _CACHE.get(src, False)
    if rx is False:
        try:
            rx = re.compile(src, re.IGNORECASE)
        except re.error:
            rx = None
        _CACHE[src] = rx
    return rx


def _search_bounded(src, text, budget=None):
    """True / False / None, where None means the pattern blew its budget.

    Verified on this machine's CPython (3.14.6): a Python-level SIGALRM handler
    DOES interrupt a catastrophically backtracking `re.search` — the interpreter
    checks for signals inside the sre loop. If SIGALRM is ever unavailable (a
    non-main thread), matching still runs; the bound then degrades to the whole-
    run budget and the hook's own timeout, which is stated rather than pretended.
    """
    rx = _compiled(src)
    if rx is None:
        return False
    if not _can_alarm():
        return rx.search(text) is not None
    budget = PATTERN_BUDGET_S if budget is None else budget
    previous = signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, budget)
    try:
        return rx.search(text) is not None
    except _PatternTimeout:
        return None
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def match(manifest, situation, cwd=None, budget=None):
    """`(matched_entries, timed_out_patterns)` for one situation string.

    Scope filtering happens HERE (KTD13): entries `scope.classify()` rates
    `sibling` against the current repo are dropped. Global bodies classify as
    `ancestor` and always pass.
    """
    if not manifest or not situation:
        return [], []
    text = situation[:MAX_SITUATION]
    cur = scope.resolve_repo_slug(cwd or os.getcwd())
    deadline = time.monotonic() + (MATCH_BUDGET_S if budget is None else budget)
    hits, timeouts = [], []
    for entry in manifest.get("entries", []):
        try:
            if scope.classify(entry.get("path", ""), cur) == "sibling":
                continue
        except Exception:
            continue
        for pat in entry.get("patterns", []):
            if time.monotonic() >= deadline:
                return hits, timeouts
            result = _search_bounded(pat.get("re", ""), text)
            if result is None:
                timeouts.append((entry.get("memory"), pat.get("re")))
                continue                      # the NEXT pattern still evaluates
            if result:
                hits.append(entry)
                break
    return hits, timeouts


# -------------------------------------------------------------- session state

def flag_dir():
    base = os.environ.get("MEMORY_TRIGGER_FLAG_DIR")
    if base:
        return base
    return os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-trigger-nudge")


def _flag_path(session_id, memory):
    key = hashlib.sha1((session_id or "no-session").encode()).hexdigest()
    mem = hashlib.sha1((memory or "").encode()).hexdigest()
    return os.path.join(flag_dir(), key, mem)


def already_nudged(session_id, memory):
    try:
        return os.path.exists(_flag_path(session_id, memory))
    except Exception:
        return False


def mark_nudged(session_id, memory):
    try:
        path = _flag_path(session_id, memory)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()
        return True
    except Exception:
        return False


# --------------------------------------------------------------- nudge output

def nudge_text(hits, store_dir, extra=0):
    """The pointer lines. Title + one-line hook + how to fetch the body — never
    the body (R5). `extra` is how many further memories matched but were capped."""
    lines = ["Declared memory triggers matched that command. Not loaded — pointers only:"]
    for entry in hits:
        hook = entry.get("hook") or ""
        lines.append("- %s%s" % (entry.get("memory", "?"),
                                 (" — " + hook) if hook else ""))
        lines.append('  read: cat "%s"'
                     % os.path.join(store_dir, entry.get("path", "")))
    if extra > 0:
        lines.append('%d more matched. To see them: printf %%s "<the command>" | '
                     'python3 "%s" match --all --plain'
                     % (extra, os.path.abspath(__file__)))
    return "\n".join(lines)


def hook_payload(text):
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": text,
    }})


# ----------------------------------------------------------------------- CLI

def default_store():
    slug = "-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
    return os.path.expanduser("~/.claude/projects/%s/memory" % slug)


def _arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else default


def cmd_match(argv):
    """Read situation text from stdin, emit the hook JSON (or nothing) on stdout."""
    store = _arg(argv, "--store") or os.environ.get("MEMORY_DIR") or default_store()
    cwd = _arg(argv, "--cwd") or os.getcwd()
    session = _arg(argv, "--session") or ""
    show_all = "--all" in argv
    plain = "--plain" in argv
    try:
        situation = sys.stdin.read()
    except Exception:
        return 0
    manifest = load_manifest(store)
    if manifest is None:
        return 0
    hits, timeouts = match(manifest, situation, cwd=cwd)
    for memory, src in timeouts:
        print("triggers: %s — pattern exceeded its %.3fs evaluation bound, skipped: %s"
              % (memory, PATTERN_BUDGET_S, src[:80]), file=sys.stderr)
    if not hits:
        return 0
    if not show_all:
        hits = [h for h in hits if not already_nudged(session, h.get("memory"))]
        if not hits:
            return 0
    extra = 0 if show_all else max(0, len(hits) - NUDGE_CAP)
    shown = hits if show_all else hits[:NUDGE_CAP]
    text = nudge_text(shown, store, extra=extra)
    print(text if plain else hook_payload(text))
    if not show_all:
        log = os.path.join(store, "RECALL.log")
        for entry in shown:
            mark_nudged(session, entry.get("memory"))
            if telemetry is not None:
                telemetry.append_recall(log, entry.get("memory"), "nudge",
                                        "trigger", session_id=session or None)
    return 0


def cmd_compile(argv):
    store = _arg(argv, "--store") or os.environ.get("MEMORY_DIR") or default_store()
    manifest, problems = compile_manifest(store)
    for relpath, value, reason in problems:
        print("triggers: %s: skipped trigger %r — %s" % (relpath, value, reason),
              file=sys.stderr)
    if not write_manifest(store, manifest):
        print("triggers: FAILED to write %s in %s" % (MANIFEST_NAME, store),
              file=sys.stderr)
        return 1
    print("triggers: %d memories with triggers, %d patterns skipped"
          % (manifest["count"], len(problems)))
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "match":
        sys.exit(cmd_match(args))
    if args and args[0] == "compile":
        sys.exit(cmd_compile(args))
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    print("usage: triggers.py {match|compile} [--store DIR] ...", file=sys.stderr)
    sys.exit(2)

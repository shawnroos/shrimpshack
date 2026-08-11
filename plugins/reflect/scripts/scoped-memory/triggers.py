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
  dialect, for MATCHING. Separately, a WIDENED projection of these patterns is fed
  to `grep -Ef` as a reject-only prefilter so the hook can skip starting Python on
  the ~80% of commands nothing can match (see `write_prefilter`). That projection
  is the only place a second regex dialect exists, and it is allowed to say "maybe"
  but never "no" — so any construct grep might read differently suppresses the
  whole prefilter via `prefilter_is_safe`. If you add a construct to the pattern
  language, check it against `_UNSAFE_FOR_GREP`; an unrecognised one is treated as
  unsafe by design, which costs speed, never correctness.
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

THE LIFECYCLE (plan U6 / KTD10 / KTD14)
---------------------------------------
A field nobody maintains is worse than no field, so `triggers:` has three
maintenance points, two of which live here as REPORTS and one as a WRITER.

* **Backfill candidates** (`report --backfill`) — memories with `MIN_USE_DAYS`+
  distinct *application* days, plus the pinned and hot-index tier. Roughly a
  third of the store. The rest are NOT candidates: an undeclared memory falls to
  ranked-gated search, which is the design (KTD5), not debt — and a big-bang
  backfill of everything would manufacture low-conviction trigger sets that decay
  into noise (KTD10). This is a report, not a script that writes triggers:
  authoring a trigger is a judgment call, made by `/reflect` reading the body.

* **Never-acted-on triggers** (`report --misfire`) — nudges joined against
  applications **on `session_id`** via `telemetry.join_surfaced_applied`. Never
  on date: with concurrent sessions a date join credits session A's nudge to
  session B's unrelated application, and both logs still look well-formed
  (KTD9b). A trigger that has fired `MIN_MISFIRE_NUDGES` times with zero
  same-session applications is surfaced for prune-or-sharpen.

* **The writer** (`add`) — `add_triggers()` is the only sanctioned way to put a
  `triggers:` field into an existing body, and it exists because of KTD14:
  **an automated write to a memory file must preserve `st_mtime`.** Activation
  weights mtime at 0.3 with a 60-day half-life *as "last reinforcement"*, so
  writing a field into ~200 files would reset ~200 mtimes to today, spike their
  activation, reshuffle `MEMORY.md`'s hot/cold cut and lower their recall floors
  — surfacing them more for no reason but the write. `st_mode` is restored too:
  `mkstemp` creates 0600, and a body silently demoted from 0644 is a second
  unwanted side effect of the same write.

  Restoring the file mtime does NOT hide the edit from the manifest.
  `compile-triggers.is_current` folds DIRECTORY mtimes in, and `os.replace` into
  the body's own directory bumps that directory — so the write is invisible to
  activation and visible to the freshness test, which is exactly the split this
  unit needs.

CLI:
    triggers.py match  [--store DIR] [--cwd DIR] [--session ID] [--all] [--plain]
                       [--prefilter-rejected]
                       # situation text on STDIN; prints hook JSON, or nothing.
                       # --prefilter-rejected says "the grep prefilter said NO about
                       # this command"; the hook sets it under
                       # MEMORY_TRIGGER_PREFILTER_AUDIT=1, and any match then means
                       # the prefilter was WRONG — reported on stderr and logged to
                       # RECALL.log as `prefilter-disagreement`.
    triggers.py compile [--store DIR]     # see compile-triggers.py for the hook
    triggers.py report [--store DIR] [--backfill] [--misfire] [--json]
                       # lifecycle reports; both sections by default
    triggers.py add    --memory RELPATH [--store DIR] [--literal V]... [--regex V]...
                       [--replace] [--no-compile]     # the mtime-preserving writer
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
PREFILTER_NAME = corpus.TRIGGER_PREFILTER
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
        # Word-boundary the ends, so a literal matches a COMMAND rather than any text
        # that happens to contain those characters. Measured against 480 real Bash
        # calls from one session: the bare substring `ng test` fired on the prose
        # "how to fix the faili|ng test|", and `gh pr merge` fired on a commit message
        # merely mentioning it. Same false-positive class the PostToolUse matcher was
        # anchored for; declared triggers had the identical hole.
        #
        # \b is only applied where the adjacent character is word-ish: a pattern like
        # `--squash` or `ps -o comm` starts/ends on punctuation, where \b would mean
        # the opposite of what is wanted and could never match.
        esc = re.escape(value)
        if value[:1].isalnum() or value[:1] == "_":
            esc = r"\b" + esc
        if value[-1:].isalnum() or value[-1:] == "_":
            esc = esc + r"\b"
        return esc, None
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


#: `\b` is stripped from prefilter patterns on purpose. The prefilter must be a
#: SUPERSET of the real matcher — it may say "maybe" when the answer is no, but must
#: never say "no" when the answer is yes, or a nudge disappears with nothing to show
#: it did. Dropping the word boundaries widens each pattern, which is the safe
#: direction, and it also drops the one construct BSD grep does not portably support.
#: Strip only a REAL `\b`, never the `b` of an escaped backslash. `foo\\bar` matches
#: a literal `foo\bar`; a naive strip turns it into `foo\ar`, which NARROWS the
#: prefilter — the unsafe direction — and a source ending `\\b` strips to a lone
#: trailing backslash, an invalid ERE that poisons the whole `-f` file. The lookbehind
#: plus the even-backslash group keeps escaped pairs intact.
_PREFILTER_STRIP = re.compile(r"(?<!\\)((?:\\\\)*)\\b")


def prefilter_lines(manifest):
    """The manifest projected to one ERE per line, deduped and widened.

    Deliberately carries NO memory names, scopes or hooks: this file answers exactly
    one question — could anything match this command? — and the moment it carries
    more, something will start using it as a second source of truth for what the
    manifest says.
    """
    out = []
    seen = set()
    for entry in manifest.get("entries", []):
        for pat in entry.get("patterns", []):
            src = pat.get("re", "")
            # ORDER IS LOAD-BEARING, and each step has to run on the right string.
            #
            # 1. Nested `[` on the RAW source, because the rewrite below destroys the
            #    evidence: `[a[^\n]]` becomes `[a.]`, which looks perfectly ordinary
            #    and would then be emitted NARROWER than the pattern it came from.
            if _bracket_scan(src)[0]:
                return None
            # 2. Rewrite `[^\n]` BEFORE looking for backslashes in brackets — it is
            #    itself a backslash inside a bracket, and the two live patterns that
            #    use it are safe. Checking first would suppress the prefilter for the
            #    whole store, which is the regression the old exemption existed to
            #    stop. After the rewrite the construct is a plain `.` and is gone.
            rx = _NEGATED_NEWLINE_CLASS.sub(".", src)
            # 3. NOW any surviving backslash inside a bracket expression is a real
            #    hazard: POSIX gives it no special meaning, so `[a\]b]` is the set
            #    {a,\,b} plus a literal `]` to grep but {a,],b} to Python. It also
            #    covers `\b` inside a class, where Python means BACKSPACE and the
            #    strip below would blindly delete it — narrowing the pattern.
            if _bracket_scan(rx)[1]:
                return None
            # 4. Strip `\b` last, once no bracket can still contain one.
            rx = _PREFILTER_STRIP.sub(r"\1", rx)
            if not rx:
                # A pattern that strips to nothing (e.g. a bare `\b`) would be
                # DROPPED here while staying live in the manifest — the prefilter
                # would then reject commands the matcher matches. It is still live,
                # so the prefilter must not exist at all rather than exist narrowed.
                return None
            if rx not in seen:
                seen.add(rx)
                out.append(rx)
    return out


#: Constructs a line-oriented POSIX grep cannot be trusted to read the way Python
#: `re` reads them. An ALLOWLIST, not a denylist, and that shape is the point: the
#: prefilter's one guarantee is that it never says "no" where the matcher says
#: "yes", so an unrecognised construct has to land on the suppress side. The
#: previous denylist enumerated `\A \Z \d \s \w \W \D \S`, `(?` and `\n` — and
#: shipped two live bugs through the gaps it left (see below). Enumerating the
#: hazards means the next one ships too.
#:
#: Two rules:
#:
#:   * **Any backslash escape outside `_ESCAPE_OK`.** A denylist of known-bad
#:     escapes is the wrong shape and was tried first: it enumerated `\A \Z \d \s
#:     \w \W \D \S`, then grew an alphanumeric rule, and BOTH times something not
#:     on the list shipped — most recently `\<` and `\>`, which are literal `<`/`>`
#:     to Python and word-boundary ANCHORS to BSD grep, GNU grep and ugrep alike.
#:     So the rule is inverted: a backslash may only precede a character we have
#:     actually verified reads as that literal in both dialects. Everything else —
#:     `\A`, `\s`, `\t`, `\B`, `\x41`, backreferences, `\<`, GNU's `\``/`\'` buffer
#:     anchors, whatever `re` gains next — is unsafe by default.
#:     The even-backslash guard keeps `foo\\bar` (a literal backslash, then a
#:     literal `b`) from reading as an escape.
#:   * **Any negated character class.** `[^;]` matches a newline in Python; grep is
#:     line-oriented and can never match across one, so `rm -rf[^;]*node_modules`
#:     matches a line-continuation command in the matcher and is REJECTED by the
#:     prefilter. 457 of 480 recorded commands were multi-line, so this is the
#:     common shape, not an edge. Note the escape rule alone does NOT catch this —
#:     `[^;]` contains no escape at all.
#:   * **`{,n}`** — a `{0,n}` quantifier to Python, a LITERAL `{,n}` to both greps
#:     (POSIX leaves the omitted lower bound undefined). No escape, no bracket, so
#:     nothing else here sees it. `{m,n}` with an explicit lower bound is fine.
#:   * **Bracket-expression internals** (`_bracket_scan`) — a nested `[` covers POSIX
#:     classes and collating elements (`[[:alpha:]]`, `[[.a.]]`, `[[=a=]]`), which
#:     grep reads as a character class and Python as an ordinary set of literals; a
#:     backslash inside a bracket covers `[a\]b]` and `[x\b]`, where POSIX gives the
#:     backslash no meaning at all. Python emits a FutureWarning for some of these,
#:     but that is not usable as a detector: `re` caches compiled patterns, so the
#:     warning fires once per process and then never again.
#:   * **Any non-ASCII character** (in `prefilter_is_safe`) — a CONTENT hazard rather
#:     than a syntax one: `grep -i` folds case per locale, `re.I` folds Unicode.
#:
#: `[^\n]` never reaches here: `prefilter_lines` rewrites it to `.` first, which is
#: exactly equivalent in both engines. Writing it through verbatim was the second
#: shipped bug — POSIX gives backslash no meaning inside a bracket expression, so
#: grep reads `[^\n]` as "not a backslash and not the letter n", and the two live
#: patterns using it silently lost every nudge whose span contained an `n`.
#:
#: Detected rather than probed. An earlier version ran each pattern through grep
#: with a synthesised probe string, and the synthesis was unsound: it turned
#: `[^\n]` into `[^n]`, which the pattern then genuinely could not match, so the
#: whole prefilter was suppressed on the live store for no reason. A flaky guard
#: that disables the optimization is worse than no guard.

#: Exactly the characters `re.escape` emits a backslash before, and nothing else.
#: Every one is verified — by `tests/trigger_test.py` — to read as that literal
#: character in Python `re` AND in every grep on the box. Allowing precisely this
#: set is what keeps literal triggers prefilterable (`re.escape` escapes `-` and
#: space, so `gh pr --json` would otherwise suppress the whole store's prefilter)
#: without admitting an escape whose meaning we have not checked.
_ESCAPE_OK = "()[]{}?*+-|^$.&~# \\\t\n\r\v\f"

_UNSAFE_FOR_GREP = re.compile(
    r"(?<!\\)(?:\\\\)*\\[^%s]" % re.escape(_ESCAPE_OK)   # unverified escape
    + r"|\(\?"                                            # Python-only group syntax
    + r"|\{,"                                             # {,n}: literal to grep
    + r"|\[\^"                                            # negated class: see above
)


def _bracket_scan(line):
    """`(nested_bracket, backslash_inside)` for the bracket expressions in `line`.

    Two separate hazards, reported separately because `prefilter_lines` has to check
    them at different points (see the ordering note there):

    * **nested `[`** — POSIX class / collating-element territory (`[[:alpha:]]`,
      `[[.a.]]`), where grep reads one construct and Python reads a set of literal
      characters. Whole-construct disagreement.
    * **backslash inside a bracket** — POSIX gives backslash no special meaning
      there, so `[a\\]b]` is {a,\\,b} then a literal `]` to grep and {a,],b} to
      Python; `[x\\b]` is a BACKSPACE to Python and {x,\\,b} to grep. This is the
      round-1 "known non-goal" that used to be documented and unenforced.

    Deliberately crude: it over-reports rather than implement POSIX bracket parsing,
    and over-reporting only ever costs the optimization.
    """
    i, n, inside = 0, len(line), False
    nested = backslash_inside = False
    while i < n:
        c = line[i]
        if c == "\\":
            if inside:
                backslash_inside = True
            i += 2
            continue
        if c == "[":
            if inside:
                nested = True
            else:
                inside = True
                # A `]` right after `[` or `[^` is a literal member, not the end.
                i += 1
                if i < n and line[i] == "^":
                    i += 1
                if i < n and line[i] == "]":
                    i += 1
                continue
        elif c == "]" and inside:
            inside = False
        i += 1
    return nested, backslash_inside

#: Rewritten to `.` — not exempted — before the unsafe scan ever sees it. Python's
#: `[^\n]` and ERE's `.` both mean "any character except newline", and a `.` needs
#: no bracket parsing, so the projection is neither widened nor narrowed. The two
#: live patterns that use this construct keep their prefilter; passing them through
#: as-is is what broke them.
_NEGATED_NEWLINE_CLASS = re.compile(r"\[\^\\n\]")


def prefilter_is_safe(lines):
    """Can a line-oriented grep stand in for the matcher over THESE patterns?

    All-or-nothing on purpose: dropping just the offending line would leave a
    prefilter NARROWER than the matcher, which is the one direction that loses a
    nudge. Better to write nothing and let every command reach python.
    """
    if not lines:
        return False
    for line in lines:
        if _UNSAFE_FOR_GREP.search(line):
            return False
        if any(_bracket_scan(line)):
            # Dead on the production path — `prefilter_lines` already returned None
            # for both bracket hazards before anything reaches here. Kept anyway so
            # this function is a COMPLETE oracle on its own: the question in the
            # docstring is "can grep stand in for the matcher over these patterns",
            # and a version that answers "yes" for `x[[:alpha:]]y` unless you happen
            # to have called it through one specific caller is a trap for the next
            # test or tool that asks it directly. A stale safety contract on this
            # gate has already shipped one bug.
            return False
        if any(ord(c) > 127 for c in line):
            # Case folding is Unicode in Python `re.I` and LOCALE-dependent in
            # `grep -i`. Under LC_ALL=C — which a hook process can easily inherit,
            # since it does not get an interactive shell's environment — grep folds
            # ASCII bytes only, so a pattern like `naïve` misses `NAÏVE` while the
            # matcher hits it. This is the one hazard that is about pattern CONTENT
            # rather than syntax, so nothing else here can see it. Zero of the live
            # store's patterns are non-ASCII, so suppressing costs nothing today.
            return False
    return True


def _grep_parses(lines):
    """Can the grep the HOOK resolves actually PARSE this file?

    Not per-pattern: an unparseable file makes grep exit 2 for EVERY command. The
    hook already treats exit >=2 as "maybe" and falls through, so this is a second
    belt — but a cheap one, and it keeps a known-broken artifact off disk.
    """
    # Imported here, not at module scope: this is the only use site and it runs on
    # the COMPILE path, while the module is imported afresh on every Bash call by the
    # match path — which is the latency this whole prefilter exists to cut. Costs
    # ~5ms of interpreter start that the hot path was paying for nothing.
    import subprocess

    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(suffix=".prefilter-probe")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        r = subprocess.run(["grep", "-qiEf", tmp], input="\n",
                           text=True, capture_output=True)
        return r.returncode < 2
    except Exception:
        return False
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _unlink_quietly(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _atomic_store_write(store_dir, name, write_fn,
                        after_replace=None, unlink_dest_on_failure=False):
    """Replace `store_dir/name` atomically. True on success, False on any failure.

    Stated once because it is subtle and was living in two copies that had already
    started to diverge. The load-bearing parts:

    * **A UNIQUE temp file in the DESTINATION directory** (KTD18). The repo's older
      fixed-`.tmp` idiom gives readers atomicity and concurrent writers nothing: two
      sessions compiling at once open the same temp name and the survivor is a valid
      file assembled from two different runs.
    * **A `.`-prefixed temp name**, so `corpus.iter_bodies` skips it even mid-window.
    * **fsync before replace**, so a crash cannot leave a truncated file live.
    * **`os.utime` AFTER the replace, and after `after_replace`.** `os.replace` bumps
      the destination DIRECTORY's mtime and the freshness test folds directory mtimes
      in, so a file stamped before anything else touches that directory is born older
      than it and every compile decides it is stale — the mtime skip silently never
      skips. `after_replace` exists precisely for work that writes another file into
      the same directory (the manifest writing its prefilter); doing it before the
      stamp is what keeps the skip honest.

    The two callers deliberately differ on `unlink_dest_on_failure`, and the asymmetry
    is the point rather than an oversight:

    * the **prefilter** passes True — it is a pure optimization, "missing" means
      "maybe" and falls through to the matcher, so gone is always safer than stale.
    * the **manifest** passes False — it is the source of truth, and deleting it on a
      failed write turns "some triggers may be stale" into "no memory nudges at all".
      A stale manifest still nudges correctly for every memory that did not change.

    `write_fn(fh)` writes the body; everything else is handled here.
    """
    dest = os.path.join(store_dir, name)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=store_dir, prefix=".%s." % name, suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            write_fn(fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, dest)
        if after_replace is not None:
            after_replace()
        try:
            os.utime(dest, None)
        except OSError:
            pass
        return True
    except Exception:
        if tmp:
            _unlink_quietly(tmp)
        if unlink_dest_on_failure:
            # Every failure mode converges on "no prefilter". Removing only the temp
            # would leave the PREVIOUS manifest's prefilter live beside a manifest
            # already replaced — and `write_manifest` discards this False and stamps
            # the manifest anyway, so the freshness skip would call the mismatched
            # pair current and never retry. That prefilter rejects exactly the
            # commands the new memory exists to nudge on, for as many sessions as it
            # takes the store to change again.
            _unlink_quietly(dest)
        return False


def write_prefilter(store_dir, manifest):
    """Write the grep-able prefilter beside the manifest. Best-effort by design.

    A missing or stale prefilter must never suppress a nudge, so the hook treats
    absence as "maybe" and falls through to the real matcher. That makes this file a
    pure optimization: worst case it is not there and the hook is exactly as slow as
    it was before.
    """
    dest = os.path.join(store_dir, PREFILTER_NAME)

    lines = prefilter_lines(manifest)
    if lines is None or not prefilter_is_safe(lines) or not _grep_parses(lines):
        # No prefilter beats a narrow one. Remove any stale file so the hook reads
        # "missing" — which it treats as "maybe" and falls through to python — rather
        # than trusting an artifact that describes a different manifest.
        _unlink_quietly(dest)
        return False

    return _atomic_store_write(
        store_dir, PREFILTER_NAME,
        lambda fh: fh.write("\n".join(lines) + "\n"),
        unlink_dest_on_failure=True)


#: Serialises the manifest+prefilter PAIR. Dot-prefixed so `corpus.iter_bodies`
#: skips it, same as the KTD18 temp files.
PAIR_LOCK_NAME = ".TRIGGERS.lock"

#: How long a compile waits for a peer's pair write before giving up and proceeding
#: unserialised. Two seconds is ~100x a normal compile and a fifth of the hook's own
#: 10s timeout, so a wedged holder costs a bounded pause instead of a killed hook.
#: A parameter rather than a bare constant so tests can inject a short deadline —
#: otherwise proving the expiry path means a real 2s sleep in the suite.
PAIR_LOCK_TIMEOUT_S = 2.0
PAIR_LOCK_POLL_S = 0.01


def _acquire_pair_lock(store_dir, timeout=None):
    """Hold an exclusive lock across the whole manifest+prefilter write, or None.

    Each `os.replace` is already atomic (KTD18), but the PAIR is not — and the pair
    is what the hook trusts. Two sessions compiling at once can interleave as
    A.manifest -> B.manifest -> B.prefilter -> A.prefilter, leaving B's manifest live
    beside A's prefilter. If B's snapshot carries a trigger A's snapshot predates,
    the prefilter is NARROWER than the live manifest and the hook silently rejects
    exactly that trigger's commands. It persists, too: `write_manifest` stamps the
    manifest mtime regardless, so the compile-side freshness skip calls the
    mismatched pair current until the store happens to change again.

    We WAIT rather than skip. A non-blocking "someone else is compiling, so skip"
    is wrong: the process that loses the race may be the one holding the FRESHER
    snapshot, and skipping its write leaves the staler pair stamped current — the
    exact persistence this exists to prevent. A compile is milliseconds, so in the
    normal case the wait is one compile.

    But the wait is BOUNDED, because an unbounded one has a bad tail: a compile
    wedged while holding the lock (an fsync stall, a stopped process) would make
    every later SessionStart block until the hook's own 10s timeout killed it —
    a silent +10s per session start, for as long as the holder lives. On expiry we
    proceed unserialised, which is exactly the behaviour that shipped before this
    lock existed, so the degradation is bounded on both axes.

    Best-effort throughout: if locking is unavailable at all, the write proceeds
    unserialised too.
    """
    if timeout is None:
        timeout = PAIR_LOCK_TIMEOUT_S
    try:
        import fcntl
    except ImportError:
        return None
    try:
        fd = os.open(os.path.join(store_dir, PAIR_LOCK_NAME),
                     os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return None
    deadline = time.monotonic() + max(0.0, timeout)
    expired = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                expired = True
                break
            try:
                time.sleep(PAIR_LOCK_POLL_S)
            except Exception:
                break
        except Exception:
            break
    try:
        os.close(fd)
    except OSError:
        pass
    if expired:
        # Say so. Proceeding unserialised is the sanctioned degradation, but it is
        # also exactly the mismatched-pair scenario the lock exists to prevent, and
        # it happens precisely when two writers hold different fresh snapshots. An
        # expiry that leaves no trace is indistinguishable from a lock that is never
        # contended — and from one that is permanently broken (bad permissions, a
        # holder wedged for days). This module's rule is that a silent failure mode
        # has to be askable; the prefilter got an audit channel, so does this.
        print("triggers: pair lock timed out after %.1fs — writing the manifest and "
              "prefilter UNSERIALISED. A concurrent compile may leave the two "
              "describing different states." % timeout, file=sys.stderr)
        if telemetry is not None:
            try:
                telemetry.append_recall(os.path.join(store_dir, "RECALL.log"),
                                        None, "pair-lock-timeout", "trigger")
            except Exception:
                pass
    return None


def _release_pair_lock(fd):
    """Closing the descriptor releases the flock."""
    if fd is None:
        return
    try:
        os.close(fd)
    except OSError:
        pass


def write_manifest(store_dir, manifest):
    """Atomically replace `TRIGGERS.json`. True on write, False on any failure.

    The temp file is UNIQUE and lives in the destination directory (KTD18), so two
    sessions compiling concurrently cannot assemble one file out of two runs. Its
    name starts with `.` so `corpus.iter_bodies` skips it even mid-window. The
    manifest and its prefilter are written under one lock so the PAIR is consistent
    too, not just each file (see `_acquire_pair_lock`).
    """
    lock_fd = _acquire_pair_lock(store_dir)
    try:
        def write_json(fh):
            json.dump(manifest, fh, indent=1, sort_keys=True)
            fh.write("\n")

        # The prefilter is written from the SAME call, under the SAME lock, so the
        # two cannot drift: a prefilter describing a manifest that no longer exists
        # rejects nudges the matcher would have made. The lock is what makes that
        # true across processes — within one process the ordering alone never was.
        #
        # It runs as `after_replace`, i.e. between the manifest's replace and its
        # mtime stamp, because writing it bumps the store directory's mtime. Stamping
        # the manifest first would leave it older than the directory it just changed
        # and the freshness skip would never skip.
        return _atomic_store_write(
            store_dir, MANIFEST_NAME, write_json,
            after_replace=lambda: write_prefilter(store_dir, manifest))
    finally:
        _release_pair_lock(lock_fd)


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
    entries = manifest.get("entries", []) if manifest else []
    if not entries or not situation:
        return [], []
    text = situation[:MAX_SITUATION]

    # Resolve the current repo LAZILY. This runs on every Bash tool call — 453 times
    # in the session that motivated this plugin — and `scope.resolve_repo_slug`
    # shells out to `git rev-parse` (scope.py:61), a real subprocess. Nothing needs
    # it until an entry actually carries a scope: `scope.classify` returns "ancestor"
    # immediately for a global body without reading the slug at all. Most memories
    # are global, so resolving up front paid for a process spawn per call to answer a
    # question no entry asked. Same verdicts, because the global path never consulted
    # it.
    cur = None
    deadline = time.monotonic() + (MATCH_BUDGET_S if budget is None else budget)
    hits, timeouts = [], []
    for entry in entries:
        try:
            if entry.get("scope"):
                if cur is None:
                    cur = scope.resolve_repo_slug(cwd or os.getcwd())
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
    """Directory holding the once-per-session nudge flags.

    Store-adjacent, NOT `$TMPDIR`-relative, for the reason retrieval.py's module
    docstring already spells out for the cooldown stamp: the PostToolUse hook runs in
    the hook executor while `triggers.py match` can be invoked straight from the Bash
    tool, and those are not guaranteed the same `TMPDIR` — this session has an
    overridden scratch path proving it. Divergent paths mean a memory marked "already
    nudged" in one context is invisible in the other, so the same nudge repeats, or a
    stale flag suppresses one that should fire. Same bug class, same fix.
    """
    base = os.environ.get("MEMORY_TRIGGER_FLAG_DIR")
    if base:
        return base
    home = os.path.expanduser("~")
    return os.path.join(home, ".claude", "projects", scope.slugify(home),
                        "trigger-nudge-state")


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


# ----------------------------------------------------------------- lifecycle

#: Distinct application days that earn a memory a place on the backfill list.
MIN_USE_DAYS = int(os.environ.get("MEMORY_TRIGGER_MIN_USE_DAYS", "2"))

#: Nudges a trigger may fire with zero same-session applications before it is
#: reported for prune-or-sharpen.
MIN_MISFIRE_NUDGES = int(os.environ.get("MEMORY_TRIGGER_MIN_MISFIRE", "3"))

#: The use log records a memory by a NAME, and the name it records drifts: the
#: same body appears as `squash_on_pr_landing` and `feedback_squash_on_pr_landing`,
#: with `-` where the filename has `_`. Measured on the live log: matching names
#: to bodies verbatim resolves 167 of 213 multi-day names; normalizing case,
#: separator and this type prefix resolves 206. The 7 that remain are memories
#: since deleted plus two junk lines — which is the honest residue, not a bug.
_TYPE_PREFIX_RE = re.compile(r"^(feedback|reference|project|user|idea)_")

#: MEMORY.md pointer line: `- [Title](file.md) — hook`.
_INDEX_LINK_RE = re.compile(r"\]\(([^)\s]+\.md)\)")


def _norm_name(name):
    """Fold a use-log name or a filename to its comparison key."""
    n = (name or "").strip().lower()
    if n.endswith(".md"):
        n = n[:-3]
    return n.replace("-", "_")


def _name_keys(name):
    """Lookup keys for a name, most specific first: the normalized name, then
    the same with a `type_` prefix stripped."""
    exact = _norm_name(name)
    stripped = _TYPE_PREFIX_RE.sub("", exact)
    return (exact,) if stripped == exact else (exact, stripped)


def body_index(store_dir, bodies=None):
    """`{name key: relpath}` over every body in the store.

    Exact keys are claimed in a first pass so a prefix-stripped alias can never
    shadow a real filename — `foo.md` and `feedback_foo.md` can both exist.

    `bodies` accepts an already-walked list so one operation enumerates the store
    once. Callers that have no list still walk here, unchanged.
    """
    if bodies is None:
        bodies = [relpath for relpath, _ in corpus.iter_bodies(store_dir)]
    else:
        bodies = [relpath for relpath, _ in bodies]
    index = {}
    for relpath in bodies:
        index[_norm_name(os.path.basename(relpath))] = relpath
    for relpath in bodies:
        for key in _name_keys(os.path.basename(relpath)):
            index.setdefault(key, relpath)
    return index


def _resolve(index, name):
    for key in _name_keys(name):
        if key in index:
            return index[key]
    return None


def use_days(store_dir, use_log_path=None, bodies=None):
    """`{relpath: set(dates)}` of ACTIVATION-BEARING use days per body.

    Days are unioned per resolved BODY, not per log name: two aliases of one
    memory used on one day each are one memory used on two days, and thresholding
    per name would miss it.
    """
    if telemetry is None:
        return {}
    path = use_log_path or os.path.join(store_dir, "MEMORY_USE.log")
    index = body_index(store_dir)
    days = {}
    for rec in telemetry.parse_use(path):
        if not rec.get("counts"):
            continue
        relpath = _resolve(index, rec.get("memory"))
        if relpath is None:
            continue
        days.setdefault(relpath, set()).add(rec.get("date"))
    return days


def hot_paths(store_dir):
    """Relpaths pointed at by `MEMORY.md` — the rendered hot tier. An absent or
    unreadable index yields an empty set: the report degrades to the use-history
    and pinned tiers rather than failing."""
    try:
        text = open(os.path.join(store_dir, "MEMORY.md"),
                    encoding="utf-8", errors="replace").read()
    except Exception:
        return set()
    out = set()
    for target in _INDEX_LINK_RE.findall(text):
        out.add(target.lstrip("./"))
    return out


def declares_triggers(text):
    """Does this body text declare a `triggers:` block at all? A body whose every
    pattern is rejected still counts as declared — it needs sharpening, not a
    backfill."""
    return bool(parse_triggers(frontmatter_lines(text)))


def _pinned(path):
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        import memory_activation                       # noqa: PLC0415
        return bool(memory_activation.parse_pinned(path))
    except Exception:
        return False


def backfill_candidates(store_dir, min_days=None, include_declared=False,
                        use_log_path=None):
    """Memories whose history earns them a declared trigger (KTD10).

    Returns one dict per candidate: `path`, `memory`, `use_days`, `reasons`
    (`used` / `pinned` / `hot`), `has_triggers`. Already-declared memories are
    filtered out by default, which is what keeps the report re-runnable after a
    backfill pass has executed.
    """
    min_days = MIN_USE_DAYS if min_days is None else min_days
    # Walk the store ONCE for this report: use_days -> body_index would otherwise
    # enumerate it a second time inside the same call.
    bodies = list(corpus.iter_bodies(store_dir))
    days = use_days(store_dir, use_log_path=use_log_path, bodies=bodies)
    hot = hot_paths(store_dir)
    out = []
    for relpath, _slug in bodies:
        full = os.path.join(store_dir, relpath)
        n_days = len(days.get(relpath, ()))
        reasons = []
        if n_days >= min_days:
            reasons.append("used")
        if _pinned(full):
            reasons.append("pinned")
        if relpath in hot:
            reasons.append("hot")
        if not reasons:
            continue
        text = read_head(full)
        has = declares_triggers(text)
        if has and not include_declared:
            continue
        name = os.path.basename(relpath)
        out.append({
            "path": relpath,
            "memory": name[:-3] if name.endswith(".md") else name,
            "use_days": n_days,
            "reasons": reasons,
            "has_triggers": has,
            "hook": hook_of(text, ""),
        })
    out.sort(key=lambda c: (-c["use_days"], c["path"]))
    return out


def never_acted_on(store_dir, min_nudges=None):
    """Triggers that keep firing and never get applied.

    The join is `telemetry.join_surfaced_applied`, used unchanged — it credits a
    nudge only when the SAME session later applied that memory (KTD9b). Nudge
    records carry the manifest's canonical memory name and forward-going
    `applied` lines are written with the same name, so no normalization belongs
    here; loosening the match would loosen the attribution the join exists to
    keep honest.
    """
    if telemetry is None:
        return []
    min_nudges = MIN_MISFIRE_NUDGES if min_nudges is None else min_nudges
    surfaced = [r for r in telemetry.parse_recall(
        os.path.join(store_dir, telemetry.RECALL_LOG_NAME))
        if r.get("source") == "nudge"]
    uses = telemetry.parse_use(os.path.join(store_dir, telemetry.USE_LOG_NAME))
    tally = {}
    for joined in telemetry.join_surfaced_applied(surfaced, uses):
        name = joined["surfaced"].get("memory")
        rec = tally.setdefault(name, {"memory": name, "nudges": 0, "credited": 0})
        rec["nudges"] += 1
        if joined["credited"]:
            rec["credited"] += 1
    out = [r for r in tally.values()
           if r["credited"] == 0 and r["nudges"] >= min_nudges]
    out.sort(key=lambda r: (-r["nudges"], r["memory"] or ""))
    return out


# ------------------------------------------------------ the mtime-safe writer

def render_block(entries, indent=""):
    """The `triggers:` frontmatter block for `[(kind, value), ...]`."""
    lines = ["%striggers:" % indent]
    for kind, value in entries:
        lines.append("%s  - %s: %s" % (indent, kind, value))
    return lines


def _splice_triggers(text, entries, replace):
    """`(new_text, None)` or `(None, reason)`.

    The block is spliced into the frontmatter as text. Nothing else in the file
    is re-serialized: a YAML round-trip would rewrite a store of hand-written
    bodies wholesale, and this writer's whole purpose is to be invisible.
    """
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, "no frontmatter block to write into"
    close = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            close = i
            break
    if close is None:
        return None, "unterminated frontmatter block"

    start = end = None
    indent = ""
    for i in range(1, close):
        m = re.match(r"^(\s*)triggers\s*:\s*(.*)$", lines[i])
        if not m or m.group(2).strip():
            continue
        indent, start = m.group(1), i
        end = close
        for j in range(i + 1, close):
            stripped = lines[j].strip()
            if not stripped:
                continue
            if len(lines[j]) - len(lines[j].lstrip()) <= len(indent):
                end = j
                break
        break

    block = render_block(entries, indent)
    if start is None:
        return "\n".join(lines[:close] + block + lines[close:]), None
    if not replace:
        return None, "already declares triggers (pass --replace to overwrite)"
    return "\n".join(lines[:start] + block + lines[end:]), None


def add_triggers(path, entries, replace=False):
    """Write a validated `triggers:` block into a body, preserving mtime + mode.

    `entries` is `[(kind, value), ...]`. Every pattern is validated first and a
    rejected one aborts the whole write — half a trigger set is worse than none.
    Returns `(True, None)` or `(False, reason)`.
    """
    if not entries:
        return False, "no trigger patterns given"
    if len(entries) > MAX_PATTERNS_PER_MEMORY:
        return False, ("more than %d patterns" % MAX_PATTERNS_PER_MEMORY)
    for kind, value in entries:
        _src, reason = validate_pattern(kind, value)
        if reason:
            return False, "%r — %s" % (value, reason)
    try:
        original = os.stat(path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return False, "unreadable: %s" % exc

    new_text, reason = _splice_triggers(text, entries, replace)
    if reason:
        return False, reason

    directory = os.path.dirname(os.path.abspath(path))
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".triggers-add.",
                                   suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
    except Exception as exc:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False, "write failed: %s" % exc

    # KTD14. The mtime restore is the load-bearing line of this function: without
    # it a bulk backfill reads to `memory_activation` as ~200 memories reinforced
    # today. `mkstemp` also created the replacement 0600, so the mode goes back
    # too. Both are restored on a best effort — a failure here is worth reporting,
    # never worth discarding a written file over.
    try:
        os.chmod(path, original.st_mode & 0o7777)
    except OSError:
        pass
    try:
        os.utime(path, (original.st_atime, original.st_mtime))
    except OSError:
        return False, "written, but mtime could not be restored"
    return True, None


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
    #: The hook sets this only under MEMORY_TRIGGER_PREFILTER_AUDIT=1, and only when
    #: the grep prefilter said NO. Reaching here at all therefore means the cheap
    #: reject would have ended the call — so any hit below is a pattern the prefilter
    #: got WRONG, which is the one failure mode this mechanism otherwise cannot show
    #: anyone. Without the marker an audit run is indistinguishable from a normal one.
    prefilter_rejected = "--prefilter-rejected" in argv
    try:
        situation = sys.stdin.read()
    except Exception:
        return 0
    manifest = load_manifest(store)
    if manifest is None:
        return 0
    hits, timeouts = match(manifest, situation, cwd=cwd)
    if prefilter_rejected and hits:
        # RECALL.log is the channel that matters — the hook runs this with stderr
        # redirected to /dev/null (fail-open, deliberately), so the message below is
        # only visible when running `triggers.py match --prefilter-rejected` directly.
        # Every line recorded here is a nudge that IS being lost, silently, in every
        # session not running the audit.
        names = ",".join(str(h.get("memory")) for h in hits)
        print("triggers: PREFILTER DISAGREEMENT — grep rejected a command the "
              "matcher matches (%s). The prefilter is narrower than the matcher; "
              "nudges are being lost silently outside audit mode." % names,
              file=sys.stderr)
        if telemetry is not None:
            for h in hits:
                telemetry.append_recall(os.path.join(store, "RECALL.log"),
                                        h.get("memory"), "prefilter-disagreement",
                                        "trigger", session_id=session or None)
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


def _args(argv, name):
    """Every value given for a repeatable `--flag VALUE` option."""
    out = []
    for i, tok in enumerate(argv):
        if tok == name and i + 1 < len(argv):
            out.append(argv[i + 1])
    return out


def cmd_report(argv):
    """The lifecycle reports. Exit 0 always — this is a report, not a gate."""
    store = _arg(argv, "--store") or os.environ.get("MEMORY_DIR") or default_store()
    want_backfill = "--backfill" in argv or "--misfire" not in argv
    want_misfire = "--misfire" in argv or "--backfill" not in argv
    as_json = "--json" in argv

    payload = {}
    if want_backfill:
        payload["backfill"] = backfill_candidates(
            store, include_declared="--include-declared" in argv)
    if want_misfire:
        payload["misfire"] = never_acted_on(store)

    if as_json:
        print(json.dumps(payload, indent=1, sort_keys=True))
        return 0

    if want_backfill:
        rows = payload["backfill"]
        print("backfill candidates: %d (>=%d use days, or pinned, or in the "
              "hot index; already-declared excluded)" % (len(rows), MIN_USE_DAYS))
        for row in rows:
            # Never truncate the NAME. This report is read by a human deciding what
            # to backfill, and by whatever they hand the list to — a clipped name
            # resolves to no file. A backfill pass hit exactly that: six memories
            # whose names exceed the old 58-char column silently proposed nothing,
            # because the worker could not find the files and correctly refused to
            # guess. Names here run to 74 characters.
            print("  %-74s days=%-3d %s" % (row["memory"], row["use_days"],
                                            ",".join(row["reasons"])))
    if want_misfire:
        rows = payload["misfire"]
        print("never-acted-on triggers: %d (>=%d nudges, zero same-session "
              "applications — prune or sharpen)" % (len(rows), MIN_MISFIRE_NUDGES))
        for row in rows:
            print("  %-74s nudges=%d" % ((row["memory"] or "?"), row["nudges"]))
    return 0


def cmd_add(argv):
    """Write triggers into one body without touching its mtime (KTD14)."""
    store = _arg(argv, "--store") or os.environ.get("MEMORY_DIR") or default_store()
    relpath = _arg(argv, "--memory")
    if not relpath:
        print("triggers: add needs --memory RELPATH", file=sys.stderr)
        return 2
    entries = ([("literal", v) for v in _args(argv, "--literal")]
               + [("regex", v) for v in _args(argv, "--regex")])
    path = relpath if os.path.isabs(relpath) else os.path.join(store, relpath)
    ok, reason = add_triggers(path, entries, replace="--replace" in argv)
    if not ok:
        print("triggers: %s: not written — %s" % (relpath, reason), file=sys.stderr)
        return 1
    print("triggers: %s: %d pattern(s) written (mtime preserved)"
          % (relpath, len(entries)))
    if "--no-compile" in argv:
        return 0
    return cmd_compile(["compile", "--store", store])


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "match":
        sys.exit(cmd_match(args))
    if args and args[0] == "compile":
        sys.exit(cmd_compile(args))
    if args and args[0] == "report":
        sys.exit(cmd_report(args))
    if args and args[0] == "add":
        sys.exit(cmd_add(args))
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    print("usage: triggers.py {match|compile|report|add} [--store DIR] ...",
          file=sys.stderr)
    sys.exit(2)

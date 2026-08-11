#!/usr/bin/env python3
"""trigger_test.py — declared triggers: schema, manifest, matcher, nudge hook (U3).

Covers the properties that make declared triggers trustworthy rather than
decorative: a literal really is literal, a pathological pattern cannot silence the
patterns behind it, a rejected pattern never fails a compile, a sibling repo's
memory never nudges here, two concurrent compilers cannot assemble one file from
two runs, and a missing manifest costs nothing.

Needs no qmd and no network, and never touches the live store — every fixture is
a tempdir. Run: `python3 tests/trigger_test.py`.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                       # plugins/reflect
sys.path.insert(0, os.path.join(REPO, "scripts"))
sys.path.insert(0, os.path.join(REPO, "scripts", "scoped-memory"))
import scope  # noqa: E402
import triggers as tg  # noqa: E402

HOOK = os.path.join(REPO, "hooks", "trigger-nudge.sh")
COMPILE = os.path.join(REPO, "scripts", "compile-triggers.py")
TRIGGERS_PY = os.path.join(REPO, "scripts", "scoped-memory", "triggers.py")
HOOKS_JSON = os.path.join(REPO, ".claude", "hooks", "hooks.json")

CASE1_CMD = "gh pr view 29 --json statusCheckRollup,mergeable"

PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def memory(name, description, triggers_block, body="Some body text.\n"):
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        "metadata:\n"
        "  type: reference\n"
        f"{triggers_block}"
        "---\n\n"
        f"{body}"
    )


LITERAL_MEM = memory(
    "reference_gh_conflicting_blocks_ci_silently",
    "A PR at mergeable=CONFLICTING runs ZERO pull_request workflows",
    "triggers:\n  - literal: gh pr view --json\n  - literal: statusCheckRollup\n",
)


def run_hook(store, command, session="sessA", cwd=None, flag_dir=None, env_extra=None):
    """Invoke the SHIPPED hook with a stdin payload. Returns (rc, stdout, stderr)."""
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = REPO
    env["MEMORY_DIR"] = store
    if flag_dir:
        env["MEMORY_TRIGGER_FLAG_DIR"] = flag_dir
    if env_extra:
        env.update(env_extra)
    payload = json.dumps({
        "tool_name": "Bash",
        "session_id": session,
        "tool_input": {"command": command},
        "tool_response": {"stdout": ""},
    })
    proc = subprocess.run(["/bin/bash", HOOK], input=payload, text=True,
                          capture_output=True, cwd=cwd or REPO, env=env, timeout=30)
    return proc.returncode, proc.stdout, proc.stderr


def envelope_field(stdout, field):
    """One field of the hookSpecificOutput envelope, or None.

    Never raises: a hook that emitted raw stdout instead of the envelope must make
    an ASSERTION go red, not abort the suite before the summary line.
    """
    try:
        return json.loads(stdout)["hookSpecificOutput"][field]
    except Exception:
        return None


def additional_context(stdout):
    """The nudge text out of the hookSpecificOutput envelope, or None."""
    return envelope_field(stdout, "additionalContext")


# ------------------------------------------------------- schema: typed entries
print("== schema ==")
fm = tg.frontmatter_lines(LITERAL_MEM)
parsed = tg.parse_triggers(fm)
check("a typed trigger block parses into (kind, value) pairs",
      parsed == [("literal", "gh pr view --json"),
                 ("literal", "statusCheckRollup")])

untyped = tg.parse_triggers(tg.frontmatter_lines(
    memory("m", "d", "triggers:\n  - gh pr view --json\n")))
src, reason = tg.validate_pattern(*untyped[0])
check("an UNTYPED entry is rejected, never guessed at (KTD17)",
      src is None and "untyped" in reason)

check("a regex entry compiles to itself",
      tg.validate_pattern("regex", r"gh\s+pr")[0] == r"gh\s+pr")
check("an over-long pattern is rejected",
      tg.validate_pattern("literal", "x" * (tg.MAX_PATTERN_LEN + 1))[0] is None)
check("an empty pattern is rejected",
      tg.validate_pattern("literal", "")[0] is None)
check("an invalid regex is rejected with the engine's reason",
      tg.validate_pattern("regex", "gh pr (view")[0] is None)
check("a pattern containing `description:` is rejected",
      tg.validate_pattern("literal", "description: something")[0] is None)
check("`description :` (spaced, as orphan_hook's regex tolerates) is also rejected",
      tg.validate_pattern("regex", "description  : x")[0] is None)
check("a quoted value keeps its content and loses only the quotes",
      tg.parse_triggers(tg.frontmatter_lines(
          memory("m", "d", "triggers:\n  - regex: 'gh\\s+pr'\n")))
      == [("regex", r"gh\s+pr")])

# ------------------------------------------- KTD17: a literal really is literal
print("== literal semantics (KTD17) ==")
meta = "v1.2 (build) [x] a+b?"
lit_src = tg.validate_pattern("literal", meta)[0]
check("a literal with regex metacharacters matches itself",
      tg._search_bounded(lit_src, "running v1.2 (build) [x] a+b? now") is True)
check("a literal with metacharacters does NOT match what the regex reading would",
      tg._search_bounded(lit_src, "running v1x2 buildx ab now") is False)
check("the literal is stored ESCAPED, so its meaning cannot change downstream",
      lit_src != meta and "\\(" in lit_src)

# The consequence of literal-substring semantics, asserted so nobody rediscovers
# it by writing a trigger that never fires: `gh pr view --json` does NOT match
# `gh pr view 29 --json`, because a literal is contiguous. That is exactly why
# Case 1's memory declares BOTH `gh pr view --json` and `statusCheckRollup` —
# the second is what actually matches the real command.
check("a literal is CONTIGUOUS: 'gh pr view --json' misses 'gh pr view 29 --json'",
      tg._search_bounded(tg.validate_pattern("literal", "gh pr view --json")[0],
                         CASE1_CMD) is False)
check("a regex trigger spans the gap where a literal cannot",
      tg._search_bounded(tg.validate_pattern("regex", r"gh\s+pr\s+view\b.*--json")[0],
                         CASE1_CMD) is True)

# ------------------------------------------------ the per-pattern bound (KTD17)
print("== per-pattern evaluation bound ==")
EVIL = r"(a+)+$"
HAY = "a" * 42 + "b"
t0 = time.monotonic()
bounded = tg._search_bounded(EVIL, HAY, budget=0.05)
elapsed = time.monotonic() - t0
check("a pathological pattern returns None (bound hit), not a hang",
      bounded is None)
check("the bound is honoured in wall clock (<1s for a 2^42 backtrack)",
      elapsed < 1.0)

# ...and the pattern AFTER it still evaluates. This is the assertion that matters:
# one bad pattern consuming the timeout would make every later match vanish with a
# clean exit 0 — silence indistinguishable from "nothing matched".
mixed = {"version": tg.SCHEMA_VERSION, "entries": [
    {"memory": "m_evil", "path": "m_evil.md", "scope": None, "hook": "evil",
     "patterns": [{"kind": "regex", "re": EVIL}]},
    {"memory": "m_good", "path": "m_good.md", "scope": None, "hook": "good",
     "patterns": [{"kind": "literal", "re": "aaab"}]},
]}
hits, timeouts = tg.match(mixed, HAY, cwd=REPO)
check("a pattern after a pathological one still evaluates and still matches",
      [h["memory"] for h in hits] == ["m_good"])
check("the timed-out pattern is reported rather than swallowed",
      len(timeouts) == 1 and timeouts[0][0] == "m_evil")

# ------------------------------------------------------------ manifest compile
print("== manifest compile ==")
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"),
          LITERAL_MEM)
    write(os.path.join(store, "reference_bad_regex.md"),
          memory("reference_bad_regex", "has a broken pattern",
                 "triggers:\n  - regex: gh pr (view\n"))
    write(os.path.join(store, "reference_desc_injection.md"),
          memory("reference_desc_injection", "tries to inject an index hook",
                 "triggers:\n  - literal: description: HIJACKED\n"))
    write(os.path.join(store, "reference_no_triggers.md"),
          memory("reference_no_triggers", "declares nothing", ""))
    scoped_rel = os.path.join("_scope", "-Users-nobody-projects-elsewhere",
                              "reference_sibling.md")
    write(os.path.join(store, scoped_rel),
          memory("reference_sibling", "another repo's memory",
                 "triggers:\n  - literal: gh pr view --json\n"))

    manifest, problems = tg.compile_manifest(store)
    names = sorted(e["memory"] for e in manifest["entries"])
    check("a memory declaring valid triggers lands in the manifest",
          "reference_gh_conflicting_blocks_ci_silently" in names)
    check("a memory declaring no triggers contributes no entry",
          "reference_no_triggers" not in names)
    check("an invalid regex is skipped and its memory contributes no entry",
          "reference_bad_regex" not in names)
    check("other memories' triggers survive one memory's bad pattern",
          len(manifest["entries"]) == 2)
    check("every rejection names the memory it came from",
          all(p[0] for p in problems)
          and any("reference_bad_regex.md" == p[0] for p in problems)
          and any("reference_desc_injection.md" == p[0] for p in problems))
    check("the `description:` rejection is reported with its reason",
          any("description:" in p[2] for p in problems
              if p[0] == "reference_desc_injection.md"))
    check("a scoped body under _scope/** CAN declare a trigger (recursive walk)",
          any(e["path"] == scoped_rel for e in manifest["entries"]))
    check("each entry carries its scope slug for match-time filtering (KTD13)",
          next(e for e in manifest["entries"] if e["path"] == scoped_rel)["scope"]
          == "-Users-nobody-projects-elsewhere")
    check("each entry carries the memory's one-line hook, not its body",
          next(e for e in manifest["entries"]
               if e["memory"].startswith("reference_gh"))["hook"].startswith(
                   "A PR at mergeable=CONFLICTING"))

    check("write_manifest reports success and produces readable JSON",
          tg.write_manifest(store, manifest) is True
          and tg.load_manifest(store) is not None)
    check("the manifest is NOT a .md file, so no scorer or renderer sees it",
          os.path.exists(os.path.join(store, "TRIGGERS.json")))

    # compile-triggers.py as shipped, plus its mtime skip. `--force` here because
    # `write_manifest` above already left the manifest current — without it this
    # run would skip and the stderr assertion would pass vacuously on an empty
    # stderr, which is the same string a working compile that found no problems
    # would produce.
    proc = subprocess.run([sys.executable, COMPILE, store, "--force"],
                          capture_output=True, text=True, timeout=60)
    check("compile-triggers.py exits 0 despite invalid patterns in the store",
          proc.returncode == 0)
    check("compile-triggers.py names the offending memory on stderr",
          "reference_bad_regex.md" in proc.stderr)

    proc2 = subprocess.run([sys.executable, COMPILE, store], capture_output=True,
                           text=True, timeout=60)
    check("a second run skips recompiling an unchanged store (mtime skip)",
          "current, no recompile" in proc2.stdout)

    os.unlink(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"))
    proc3 = subprocess.run([sys.executable, COMPILE, store], capture_output=True,
                           text=True, timeout=60)
    check("DELETING a memory invalidates the manifest (dir mtime, not body mtime)",
          "current, no recompile" not in proc3.stdout)
    check("the deleted memory's trigger is gone from the manifest",
          all(not e["memory"].startswith("reference_gh")
              for e in tg.load_manifest(store)["entries"]))

# ----------------------------------------------- concurrent compilers (KTD18)
print("== concurrent compilers (KTD18) ==")
# The contention has to be WIDE to be deterministic. At 4 writers over 40 bodies
# the fixed-`.tmp` idiom this guards against passes about as often as it fails —
# a flaky guard is worse than none, because a green run then proves nothing.
# CONCURRENT writers over CONCURRENT_BODIES bodies keeps every writer inside its
# write window long enough that the shared-temp collision actually happens.
CONCURRENT = 8
CONCURRENT_BODIES = 250

with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    for i in range(CONCURRENT_BODIES):
        write(os.path.join(store, f"reference_c{i:03d}.md"),
              memory(f"reference_c{i:03d}", f"memory number {i}",
                     f"triggers:\n  - literal: marker-{i:03d}\n"))
    expected = sorted(f"reference_c{i:03d}" for i in range(CONCURRENT_BODIES))
    procs = [subprocess.Popen([sys.executable, COMPILE, store, "--force"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) for _ in range(CONCURRENT)]
    rcs = [p.wait(timeout=180) for p in procs]
    check("no concurrent writer falsely reports success or failure",
          all(rc == 0 for rc in rcs))
    survivor = tg.load_manifest(store)
    check("the surviving manifest parses as complete JSON",
          survivor is not None and survivor["count"] == CONCURRENT_BODIES)
    check("the surviving manifest holds every memory, not a mix of two runs",
          survivor is not None
          and sorted(e["memory"] for e in survivor["entries"]) == expected)
    leftovers = [f for f in os.listdir(store) if ".tmp" in f]
    check("no temp files are left behind in the store",
          leftovers == [])

    # The race above is a BACKSTOP, not a proof: whether a fixed shared temp name
    # actually collides depends on timing, and it survives roughly one run in
    # three. So the property the race depends on is asserted directly and
    # deterministically — two writes must never share a temp path.
    seen = []
    real_replace = os.replace

    def spy_replace(src, dst):
        seen.append(src)
        return real_replace(src, dst)

    os.replace = spy_replace
    try:
        tg.write_manifest(store, survivor)
        tg.write_manifest(store, survivor)
    finally:
        os.replace = real_replace
    # Count the replaces rather than pinning a number: `write_manifest` also emits
    # the grep prefilter, so one call now produces two atomic replaces. The PROPERTY
    # is what KTD18 turns on — every temp path unique, in the destination directory,
    # dotfile-named — and it must hold for however many artifacts a write produces.
    check("every write uses a DISTINCT temp path — the property KTD18 turns on",
          len(seen) >= 2 and len(set(seen)) == len(seen))
    check("both artifacts are written (manifest + prefilter) per call",
          len(seen) == 4)
    check("every temp file sits in the DESTINATION directory, so replace is atomic",
          seen and all(os.path.dirname(s) == store for s in seen))
    check("every temp name is a dotfile, so a mid-window corpus walk never sees it",
          seen and all(os.path.basename(s).startswith(".") for s in seen))

# ------------------------------------------- prefilter is a SUPERSET (perf guard)
# The nudge hook rejects a command with `grep -qiEf TRIGGERS.prefilter` before it
# starts python, so the prefilter must never say "no" where the matcher says "yes" —
# a lost nudge is invisible, the failure this plugin exists to remove.
#
# These assertions run the REAL grep, not a python re-implementation. An earlier
# version of this block compiled the prefilter with `re.compile(l, re.I)` and
# compared python to python, which by construction could not see the entire real
# failure class: python `re` and POSIX ERE are different languages.
print("== prefilter never loses a nudge ==")


#: EVERY grep we can reach, not just the one on PATH. This is load-bearing: on this
#: box PATH resolves ugrep, which reads `[^\n]` Perl-style and therefore MATCHES the
#: patterns a POSIX grep rejects. A PATH-only check was green both before and after
#: the `[^\n]` -> `.` fix, so it discriminated nothing — the bug it missed was live
#: in the compiled store. The hook runs whatever `grep` its own PATH resolves, so
#: the prefilter has to be correct under every dialect a user might have.
GREPS = ["grep"] + ([p for p in ["/usr/bin/grep"] if os.path.exists(p)])


def grep_says_match(prefilter_path, cmd):
    """(matched-under-EVERY-grep, worst exit code).

    Conjunction, not disjunction: the superset guarantee has to hold for whichever
    grep the hook resolves, so one dialect rejecting is a failure even if another
    accepts.
    """
    matched, worst = True, 0
    for g in GREPS:
        r = subprocess.run([g, "-qiEf", prefilter_path], input=cmd,
                           text=True, capture_output=True)
        matched = matched and r.returncode == 0
        worst = max(worst, r.returncode)
    return matched, worst


with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_case.md"),
          memory("reference_case", "the case-1 memory",
                 "triggers:\n"
                 "  - literal: gh pr view\n"
                 "  - literal: NG8002\n"
                 "  - regex: gh pr (create|merge)\n"))
    man, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man)
    pre_path = os.path.join(store, tg.PREFILTER_NAME)

    check("write_manifest emits the prefilter beside the manifest",
          os.path.exists(pre_path))
    pre = [l for l in open(pre_path).read().splitlines() if l]
    check("the prefilter carries ONLY patterns — no names, scopes or hooks",
          all("reference_case" not in l for l in pre))

    # Superset, judged by the REAL grep against commands the matcher matches.
    for cmd in ["gh pr view 5159 --json statusCheckRollup",
                "GH PR VIEW 5159",
                "cd /tmp && gh pr merge 34 --squash",
                "ng build 2>&1 | grep NG8002"]:
        hits, _ = tg.match(man, cmd, cwd="/tmp")
        check("matcher DOES match %r (guards against a vacuous check)" % cmd[:30],
              bool(hits))
        matched, rc = grep_says_match(pre_path, cmd)
        check("real grep agrees, so the prefilter cannot drop it: %r" % cmd[:30],
              matched)

    check("and grep still rejects an unrelated command",
          not grep_says_match(pre_path, "echo hello world")[0])

    # MULTI-LINE commands are the common shape (457 of 480 recorded Bash calls), and
    # they are exactly where line-oriented grep can diverge from `re.search`. Every
    # command above is single-line, which is why the negated-class bug shipped green.
    for cmd in ["cd /tmp && \\\n  gh pr view 5159",
                "set -e\ngh pr merge 34 --squash\necho done",
                "echo first\nng build 2>&1 | grep NG8002"]:
        hits, _ = tg.match(man, cmd, cwd="/tmp")
        check("matcher DOES match multi-line %r" % cmd[:24], bool(hits))
        check("real grep agrees on multi-line %r" % cmd[:24],
              grep_says_match(pre_path, cmd)[0])

# `[^\n]` must be TRANSLATED to `.`, not passed through. POSIX gives backslash no
# meaning inside a bracket expression, so a POSIX grep reads `[^\n]` as "not a
# backslash and not the letter n" — narrower than Python's "not a newline". Two live
# store patterns used this, and every invocation with an `n` in the matched span
# silently lost its nudge. The `n`-bearing command below is the whole point.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_negnl.md"),
          memory("reference_negnl", "the live [^\\n] shape",
                 "triggers:\n  - regex: gh run rerun[^\\n]*--failed\n"))
    man4, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man4)
    pre4 = os.path.join(store, tg.PREFILTER_NAME)

    check("a [^\\n] pattern still gets a prefilter (optimization preserved)",
          os.path.exists(pre4))
    check("[^\\n] is rewritten to `.` rather than emitted verbatim",
          "[^" not in open(pre4).read())
    for cmd in ["gh run rerun --repo owner/name 99 --failed",
                "gh run rerun $run_id --failed",
                "gh run rerun 12345 --failed"]:
        hits, _ = tg.match(man4, cmd, cwd="/tmp")
        check("matcher DOES match %r" % cmd[:34], bool(hits))
        check("EVERY grep agrees (the n-in-span case): %r" % cmd[:34],
              grep_says_match(pre4, cmd)[0])
    check("and the rewrite still cannot cross a newline",
          not grep_says_match(pre4, "gh run rerun \nfoo --failed")[0])

# Any OTHER negated class must suppress the prefilter entirely. `[^;]` matches a
# newline in Python and can never match across one in grep, so a multi-line command
# matches the matcher and is rejected by the prefilter — a silent lost nudge. Note
# this class contains no escape at all, so the backslash rule alone does not see it.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_negcls.md"),
          memory("reference_negcls", "negated class spans lines",
                 "triggers:\n  - regex: rm -rf[^;]*node_modules\n"))
    man5, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man5)
    check("a negated character class writes NO prefilter",
          not os.path.exists(os.path.join(store, tg.PREFILTER_NAME)))
    check("...and the trigger is still live in the manifest (matcher unaffected)",
          bool(tg.match(man5, "rm -rf \\\n  node_modules", cwd="/tmp")[0]))

# The safety gate is an ALLOWLIST, so each hazard class has to be named individually.
# Neutering `prefilter_is_safe` to `return bool(lines)` previously left the suite
# green: every hazard below then reaches grep, which reads it narrower than Python.
for hazard, why in [("\\Agh pr", "python-only anchor, a literal A to grep"),
                    ("git\\s+push", "can span a line"),
                    ("git\\tpush", "unverified escape, dialect-dependent"),
                    ("x\\By", "unverified escape, dialect-dependent"),
                    ("gh\\x20pr", "hex escape, not portable"),
                    # Found by review AFTER the allowlist shipped, which is the
                    # argument for the allowlist: each of these is literal to
                    # Python and something else entirely to a real grep, and none
                    # was on any denylist anyone wrote.
                    ("cat \\<\\<EOF", "\\< is a WORD BOUNDARY to every grep"),
                    ("x\\>y", "\\> is a word boundary to every grep"),
                    ("a{,3}b", "{,n} is a quantifier to Python, literal to grep"),
                    ("x[[:alpha:]]y", "POSIX class: grep reads a class, Python a set"),
                    ("x[[.a.]]y", "collating element, same divergence"),
                    ("[a[^\\n]]", "nested set — the [^\\n] rewrite must not hide it"),
                    ("rm [x\\b]y", "\\b inside a class is BACKSPACE, not a boundary"),
                    ("a[a\\]b]c", "backslash inside a class has no POSIX meaning"),
                    ("gh café", "non-ASCII: grep -i folds per LOCALE, re.I per Unicode")]:
    with tempfile.TemporaryDirectory() as store:
        write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
        write(os.path.join(store, "reference_hz.md"),
              memory("reference_hz", "hazard",
                     "triggers:\n  - regex: %s\n" % hazard))
        manh, _ = tg.compile_manifest(store)
        tg.write_manifest(store, manh)
        check("NO prefilter for %r (%s)" % (hazard, why),
              not os.path.exists(os.path.join(store, tg.PREFILTER_NAME)))

# ...while the constructs `re.escape` actually emits must stay prefilterable, or the
# gate would suppress the optimization for the entire store — correct but pointless.
# `re.escape` escapes `-` and space, so `gh pr --json` alone would do it.
for benign in ["gh\\ pr\\ view", "foo\\\\bar", "gh\\ pr\\ (view|merge)", "a\\.b\\*c",
               re.escape("gh pr view --json"), "a[0-9]b", "a{2,3}b"]:
    with tempfile.TemporaryDirectory() as store:
        write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
        write(os.path.join(store, "reference_ok.md"),
              memory("reference_ok", "benign",
                     "triggers:\n  - regex: %s\n" % benign))
        manb, _ = tg.compile_manifest(store)
        tg.write_manifest(store, manb)
        check("prefilter IS written for benign %r" % benign,
              os.path.exists(os.path.join(store, tg.PREFILTER_NAME)))

# `prefilter_is_safe` must be a COMPLETE oracle on its own, not merely correct when
# reached through `prefilter_lines`. Every test above goes through the full pipeline,
# where prefilter_lines returns None for bracket hazards before this function is
# called — so a version of it that answers "safe" for a POSIX class passes all of
# them. Ask it directly. The next test or tool to use it as the safety oracle will.
for hazard in ["x[[:alpha:]]y", "x[[.a.]]y", "a[a\\]b]c", "rm [x\\b]y"]:
    check("prefilter_is_safe rejects %r when asked DIRECTLY" % hazard,
          not tg.prefilter_is_safe([hazard]))
for ok in ["gh\\ pr\\ view", "a[0-9]b", "gh run rerun.*--failed"]:
    check("prefilter_is_safe still accepts %r directly" % ok,
          tg.prefilter_is_safe([ok]))

# The allowlist rests on a factual claim: every character `re.escape` puts a
# backslash in front of reads as that literal character in Python AND in every grep.
# That claim was WRONG once already — the previous gate allowed all escaped
# punctuation on the same reasoning, and `\<` / `\>` turned out to be word-boundary
# anchors in BSD grep, GNU grep and ugrep alike. So check it rather than assert it:
# if a future Python widens `re.escape`, or a grep reinterprets one of these, this
# fails here instead of silently dropping nudges in the field.
for ch in "()[]{}?*+-|^$.&~# ":
    esc = re.escape(ch)
    check("re.escape(%r)=%r is in the verified-safe escape set" % (ch, esc),
          len(esc) < 2 or esc[1] in tg._ESCAPE_OK)
    if len(esc) < 2:
        continue                      # this Python does not escape it at all
    with tempfile.TemporaryDirectory() as d:
        pf = os.path.join(d, "pf")
        write(pf, "a%sb\n" % esc)
        text = "a%sb" % ch
        check("EVERY grep reads %r as the literal %r, as Python does" % (esc, ch),
              bool(re.search("a%sb" % esc, text, re.I))
              and grep_says_match(pf, text)[0])

# A store that compiles safe once and LATER gains an unsafe pattern must lose its
# prefilter. Every suppression test above starts from a fresh tempdir, so none of
# them can see a stale file — deleting write_prefilter's unlink left the suite green
# while a prefilter describing an older manifest stayed live on disk.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_safe.md"),
          memory("reference_safe", "safe first",
                 "triggers:\n  - literal: gh pr view\n"))
    man6, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man6)
    stale = os.path.join(store, tg.PREFILTER_NAME)
    check("prefilter exists after the safe compile", os.path.exists(stale))

    write(os.path.join(store, "reference_unsafe.md"),
          memory("reference_unsafe", "now unsafe",
                 "triggers:\n  - regex: git\\s+push\n"))
    man7, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man7)
    check("recompiling into an unsafe store REMOVES the stale prefilter",
          not os.path.exists(stale))

# The WRITE-FAILURE path has to drop the stale file too, and it is a different branch
# from the unsafe one above — deleting its unlink left the suite green, because no
# test ever entered `except Exception`. Force it by making mkstemp raise.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_safe2.md"),
          memory("reference_safe2", "safe",
                 "triggers:\n  - literal: gh pr view\n"))
    man8, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man8)
    pre8 = os.path.join(store, tg.PREFILTER_NAME)
    check("prefilter exists before the forced write failure (guard)",
          os.path.exists(pre8))

    # Patch os.replace, NOT mkstemp. `_grep_parses` calls mkstemp first, so a broken
    # mkstemp fails the SAFETY probe and routes into the unsafe branch — which has
    # its own, older unlink. The test then passes with the exception-path unlink
    # deleted, i.e. for entirely the wrong reason. os.replace is reached only after
    # the probe, inside the write itself, so it targets the intended branch.
    real_replace = tg.os.replace
    def boom(*a, **k):
        raise OSError("forced write failure")
    tg.os.replace = boom
    try:
        ok8 = tg.write_prefilter(store, man8)
    finally:
        tg.os.replace = real_replace
    check("a failed prefilter write reports False", ok8 is False)
    check("a failed prefilter write REMOVES the stale prefilter "
          "(never leave one beside a newer manifest)", not os.path.exists(pre8))
    check("the os.replace monkeypatch was really undone (guard)",
          tg.os.replace is real_replace)

# The pair lock guarantees manifest+prefilter consistency across processes. Stubbing
# `_acquire_pair_lock` to `return None` left the suite green — ~50 lines of new
# concurrency code could be disabled with nothing noticing.
with tempfile.TemporaryDirectory() as store:
    # write_manifest must actually TAKE the lock, not merely be able to: stubbing
    # `lock_fd = _acquire_pair_lock(...)` to `lock_fd = None` at the call site passes
    # every direct test of the lock functions themselves. The lock file only comes
    # into existence if the call really happens.
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_lk.md"),
          memory("reference_lk", "lock", "triggers:\n  - literal: gh pr view\n"))
    man_lk, _ = tg.compile_manifest(store)
    check("no lock file before the first write (guard)",
          not os.path.exists(os.path.join(store, tg.PAIR_LOCK_NAME)))
    tg.write_manifest(store, man_lk)
    check("write_manifest takes the pair lock (the pair, not just each file)",
          os.path.exists(os.path.join(store, tg.PAIR_LOCK_NAME)))

    # The manifest's mtime stamp must land AFTER the prefilter is written, because
    # writing the prefilter replaces a file in this same directory and so bumps the
    # directory's mtime — which is what the freshness test compares against. Stamp
    # first and the manifest is born older than the directory it just changed, so
    # `is_current` is False forever and the compile-side skip silently never skips.
    man_dir = os.path.dirname(os.path.abspath(tg.__file__))
    ct_path = os.path.join(man_dir, "..", "compile-triggers.py")
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location("ct_mod", os.path.abspath(ct_path))
    _ct = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_ct)
    check("the manifest is CURRENT right after write_manifest "
          "(prefilter written before the mtime stamp)", _ct.is_current(store))
    tg.write_manifest(store, man_lk)
    check("...and stays current across a recompile, so the skip actually skips",
          _ct.is_current(store))

with tempfile.TemporaryDirectory() as store:
    fd = tg._acquire_pair_lock(store)
    check("the pair lock is actually acquired on this platform", fd is not None)
    check("the lock file is dot-prefixed so corpus iteration skips it",
          tg.PAIR_LOCK_NAME.startswith(".")
          and os.path.exists(os.path.join(store, tg.PAIR_LOCK_NAME)))
    # The wait is BOUNDED. An unbounded LOCK_EX behind a wedged holder would block
    # every later SessionStart until the hook's own 10s timeout killed it — a silent
    # +10s per session for as long as the holder lives. On expiry we proceed
    # unserialised, which is exactly what shipped before the lock existed.
    # Run it on a thread with a join deadline: if the bounded wait ever regresses to
    # a blocking LOCK_EX, this must FAIL, not hang. A suite that hangs reads as a
    # mysterious slow CI run and gets retried rather than diagnosed.
    import threading as _th
    box = {}
    th = _th.Thread(target=lambda: box.setdefault(
        "r", tg._acquire_pair_lock(store, timeout=0.05)), daemon=True)
    th.start()
    th.join(5.0)
    check("a contended pair lock GIVES UP rather than blocking forever",
          not th.is_alive())
    check("...and gives up by returning None, so the write proceeds unserialised",
          box.get("r", "still-running") is None)
    # An expiry that leaves no trace is indistinguishable from a lock that is never
    # contended — and from one that is permanently broken. Proceeding unserialised is
    # sanctioned, but it is also exactly the mismatched-pair case the lock exists to
    # prevent, so it has to be countable.
    try:
        lock_log = open(os.path.join(store, "RECALL.log"), encoding="utf-8").read()
    except OSError:
        lock_log = ""
    check("a pair-lock timeout is RECORDED, not silent",
          "pair-lock-timeout" in lock_log)

    tg._release_pair_lock(fd)
    # Assert the descriptor is CLOSED rather than re-acquiring: a second blocking
    # acquire against an unreleased lock would hang the suite instead of failing it,
    # and a hang reads as a mysterious slow CI run, not as this regression.
    closed = False
    try:
        os.fstat(fd)
    except OSError:
        closed = True
    check("releasing the pair lock closes the descriptor (so the flock drops)",
          closed)
    # Threaded for the same reason as above, and it is not redundant: if the wait
    # regresses to blocking, the earlier contended acquire is still parked on the
    # lock and grabs it the moment we release — so a direct call here would hang the
    # whole suite rather than report the regression.
    box2 = {}
    th2 = _th.Thread(target=lambda: box2.setdefault(
        "r", tg._acquire_pair_lock(store, timeout=0.05)), daemon=True)
    th2.start()
    th2.join(5.0)
    after = box2.get("r")
    check("...so the next writer can take it", not th2.is_alive() and after is not None)

    # The SHIPPED default has to wait, and no test above exercises it — both threaded
    # acquires pass timeout=0.05, and every uncontended acquire succeeds on the first
    # LOCK_NB try without consulting the deadline at all. So setting
    # PAIR_LOCK_TIMEOUT_S = 0 left the suite green while every contended real compile
    # would proceed unserialised immediately, re-opening the pair-drift race.
    check("the shipped pair-lock timeout is a real wait, not zero",
          tg.PAIR_LOCK_TIMEOUT_S > 0)
    waiter = {}
    tw = _th.Thread(target=lambda: waiter.setdefault(
        "r", tg._acquire_pair_lock(store)), daemon=True)      # NO timeout: the default
    tw.start()
    time.sleep(0.2)                                            # still waiting on us
    still_waiting = tw.is_alive()
    tg._release_pair_lock(after)
    tw.join(5.0)
    check("a waiter using the DEFAULT timeout blocks until the holder releases",
          still_waiting)
    check("...and then acquires, rather than having given up immediately",
          not tw.is_alive() and waiter.get("r") is not None)
    tg._release_pair_lock(waiter.get("r"))

# The prefilter's one failure mode is invisible by construction: a wrong reject
# produces no error, no log line, no nudge. The audit flag is the way to ASK whether
# it is honest, and it is only worth having if it actually reports a disagreement.
print("== prefilter audit mode ==")
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"),
          LITERAL_MEM)
    man_a, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man_a)
    # A prefilter that cannot match what the matcher matches — i.e. exactly the bug
    # class that shipped three times, made deliberate so it can be detected.
    write(os.path.join(store, tg.PREFILTER_NAME), "zzz-nothing-can-match-this\n")

    with tempfile.TemporaryDirectory() as flags:
        rc_off, out_off, _e = run_hook(store, CASE1_CMD, session="sOFF",
                                       flag_dir=flags)
        check("audit OFF: the wrong reject silently loses the nudge (the bug shape)",
              rc_off == 0 and out_off.strip() == "")

    with tempfile.TemporaryDirectory() as flags:
        rc_on, out_on, _e2 = run_hook(store, CASE1_CMD, session="sON",
                                      flag_dir=flags,
                                      env_extra={"MEMORY_TRIGGER_PREFILTER_AUDIT": "1"})
        check("audit ON: the hook falls through and the nudge fires anyway",
              rc_on == 0 and additional_context(out_on) is not None)
        try:
            recall = open(os.path.join(store, "RECALL.log"), encoding="utf-8").read()
        except OSError:
            recall = ""
        check("audit ON: the disagreement is RECORDED, not just recovered",
              "prefilter-disagreement" in recall)

    # A NON-ASCII command must never be judged by grep. Case folding is symmetric, so
    # an all-ASCII pattern can match a non-ASCII command in Python (`re.I` folds
    # U+0131 dotless-i onto `i`) while no grep folds it under any locale. The
    # compile-side gate cannot see this: it inspects the PATTERN's bytes, and the
    # pattern here is pure ASCII. Restore the honest prefilter first so the only
    # thing under test is the command's encoding.
    tg.write_manifest(store, man_a)

    # ...and a prefilter that is CORRECT must produce no disagreement, or the signal
    # is noise and nobody will trust it.
    tg.write_manifest(store, man_a)          # restores the real prefilter
    with tempfile.TemporaryDirectory() as flags:
        run_hook(store, CASE1_CMD, session="sOK", flag_dir=flags,
                 env_extra={"MEMORY_TRIGGER_PREFILTER_AUDIT": "1"})
        recall2 = open(os.path.join(store, "RECALL.log"), encoding="utf-8").read()
        check("an HONEST prefilter logs no disagreement under audit",
              recall2.count("prefilter-disagreement") == 1)   # still just the earlier one

# A pattern that is valid PYTHON and invalid ERE must not produce a prefilter at
# all: a file grep cannot parse makes it exit 2 for EVERY command, and a hook that
# read exit 2 as "no match" would suppress every nudge in the store.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_look.md"),
          memory("reference_look", "python-valid, ERE-invalid",
                 "triggers:\n  - regex: gh(?= pr)\n"))
    man2, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man2)
    pre2 = os.path.join(store, tg.PREFILTER_NAME)
    if os.path.exists(pre2):
        _, rc = grep_says_match(pre2, "gh pr view 1")
        check("if a prefilter was written, the resolved grep can PARSE it (rc<2)",
              rc < 2)
    else:
        check("no prefilter written for an ERE-incompatible pattern (fail-safe)", True)

# A pattern stripping to empty must suppress the whole prefilter, not silently
# narrow it — it stays live in the manifest either way.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_bare.md"),
          memory("reference_bare", "bare boundary",
                 "triggers:\n  - regex: \\b\n"))
    man3, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man3)
    check("a pattern that strips to nothing writes NO prefilter",
          not os.path.exists(os.path.join(store, tg.PREFILTER_NAME)))

# \b stripping must not eat an ESCAPED backslash, which would narrow the pattern
# or emit a trailing lone backslash (an invalid ERE).
check("stripping keeps an escaped backslash intact",
      tg._PREFILTER_STRIP.sub(r"\1", r"foo\\bar") == r"foo\\bar")
check("stripping never leaves a trailing lone backslash",
      not tg._PREFILTER_STRIP.sub(r"\1", r"x\\b").endswith("\\")
      or tg._PREFILTER_STRIP.sub(r"\1", r"x\\b") == r"x\\b")

# ------------------------------------------------------- scope filter (KTD13)
print("== scope filter at match time (KTD13) ==")
with tempfile.TemporaryDirectory() as store:
    here_slug = scope.resolve_repo_slug(REPO)
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "_scope", "-Users-nobody-projects-elsewhere",
                       "reference_sibling.md"),
          memory("reference_sibling", "another repo's memory",
                 "triggers:\n  - literal: statusCheckRollup\n"))
    write(os.path.join(store, "_scope", here_slug, "reference_here.md"),
          memory("reference_here", "this repo's memory",
                 "triggers:\n  - literal: statusCheckRollup\n"))
    manifest, _ = tg.compile_manifest(store)
    tg.write_manifest(store, manifest)
    check("the fixture really does hold BOTH scoped memories (guards the next)",
          len(manifest["entries"]) == 2)

    hits, _ = tg.match(manifest, CASE1_CMD, cwd=REPO)
    check("a sibling repo's memory does NOT match from an unrelated cwd",
          [h["memory"] for h in hits] == ["reference_here"])

    with tempfile.TemporaryDirectory() as flags:
        rc, out, _err = run_hook(store, CASE1_CMD, cwd=REPO, flag_dir=flags)
        ctx = additional_context(out)
        check("the hook drops the cross-repo leak and keeps the local memory",
              rc == 0 and ctx is not None
              and "reference_here" in ctx and "reference_sibling" not in ctx)

# ------------------------------------------------------------- the nudge hook
print("== nudge hook ==")
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"),
          LITERAL_MEM)
    manifest, _ = tg.compile_manifest(store)
    tg.write_manifest(store, manifest)

    with tempfile.TemporaryDirectory() as flags:
        t0 = time.monotonic()
        rc, out, _err = run_hook(store, CASE1_CMD, session="s1", flag_dir=flags)
        case1_elapsed = time.monotonic() - t0
        ctx = additional_context(out)
        check("Case 1's command produces exactly one nudge naming that memory",
              rc == 0 and ctx is not None
              and ctx.count("- reference_gh_conflicting_blocks_ci_silently") == 1)
        check("the nudge is a POINTER — title, hook, and how to fetch (never the body)",
              ctx is not None and "A PR at mergeable=CONFLICTING" in ctx
              and "read: cat " in ctx and "Some body text." not in ctx)
        check("the nudge rides hookSpecificOutput.additionalContext, not raw stdout",
              envelope_field(out, "hookEventName") == "PostToolUse")
        check("Case 1 end-to-end completes well inside the hook's 5s timeout, qmd-free",
              case1_elapsed < 5.0)

        # Case-insensitivity has to be asserted through the HOOK's own grep line.
        # It was asserted only via the test-local helper, which hardcodes its own
        # `-qiEf` — so the helper agreed with itself and dropping `-i` from the hook
        # left the suite green while real nudges were lost (2 of 480 measured).
        rc_up, out_up, _eu = run_hook(store, CASE1_CMD.upper(), session="sUP",
                                      flag_dir=flags)
        check("the hook's own grep is case-insensitive (prefilter must not narrow)",
              rc_up == 0 and additional_context(out_up) is not None)

        rc2, out2, _e2 = run_hook(store, CASE1_CMD, session="s1", flag_dir=flags)
        check("the same memory does not nudge twice in one session (dedupe)",
              rc2 == 0 and out2.strip() == "")

        rc3, out3, _e3 = run_hook(store, CASE1_CMD, session="s2", flag_dir=flags)
        check("a NEW session nudges again (dedupe is session-scoped, not permanent)",
              rc3 == 0 and additional_context(out3) is not None)

    with tempfile.TemporaryDirectory() as flags:
        rc, out, _err = run_hook(store, "git status --short", flag_dir=flags)
        check("a command matching no trigger emits nothing and exits 0",
              rc == 0 and out.strip() == "")

    # RECALL.log telemetry
    with tempfile.TemporaryDirectory() as flags:
        run_hook(store, CASE1_CMD, session="s9", flag_dir=flags)
        try:
            log = open(os.path.join(store, "RECALL.log"), encoding="utf-8").read()
        except OSError:
            log = ""
        check("each nudge is logged to RECALL.log with source `nudge` and the session",
              " s9 nudge reference_gh_conflicting_blocks_ci_silently trigger" in log)

# The hook must treat a prefilter it cannot use as "maybe" and fall through to
# python. An unparseable file makes grep exit 2 for EVERY command, so reading exit 2
# as "nothing matched" would let ONE bad pattern silently suppress every nudge in the
# store. Widening the hook's gate to `1|2|127` previously left the suite green:
# nothing ever planted a corrupt prefilter, so that branch was never executed.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"),
          LITERAL_MEM)
    man_p, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man_p)
    pre_bad = os.path.join(store, tg.PREFILTER_NAME)
    write(pre_bad, "gh(?= pr)\n")          # python-valid, ERE-invalid -> grep rc=2
    check("the corrupt-prefilter fixture really does make grep exit >=2 (guard)",
          grep_says_match(pre_bad, CASE1_CMD)[1] >= 2)
    with tempfile.TemporaryDirectory() as flags:
        rc_b, out_b, _eb = run_hook(store, CASE1_CMD, session="sBAD", flag_dir=flags)
        check("an unparseable prefilter falls THROUGH to python, nudge still fires",
              rc_b == 0 and additional_context(out_b) is not None)

    # Same contract for a prefilter that is simply absent: missing means "maybe".
    os.unlink(pre_bad)
    with tempfile.TemporaryDirectory() as flags:
        rc_m, out_m, _em = run_hook(store, CASE1_CMD, session="sMISS", flag_dir=flags)
        check("a MISSING prefilter falls through to python, nudge still fires",
              rc_m == 0 and additional_context(out_m) is not None)

# A NON-ASCII command must never be judged by grep. Case folding is symmetric: the
# compile-side gate checks the PATTERN's bytes, but Python's `re.I` (no `re.ASCII`)
# folds U+0131 dotless-i onto `i`, so the pure-ASCII pattern `pip install` matches the
# command `pıp install` while no grep folds it under any locale. Pattern-side rules
# cannot see this, because the pattern is entirely innocent.
#
# The trigger span itself has to carry the non-ASCII character. An earlier version of
# this test reused a fixture whose matched span was plain ASCII, so grep matched
# regardless and the guard was never exercised — and it asserted `rc == 0`, which the
# hook returns on EVERY path by design. It passed with the guard deleted.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_uni.md"),
          memory("reference_uni", "the unicode-fold memory",
                 "triggers:\n  - literal: pip install\n"))
    man_u, _ = tg.compile_manifest(store)
    tg.write_manifest(store, man_u)
    UNI_CMD = "pıp install numpy"          # U+0131, folds to `i` in Python only

    # Guard the fixture: the hazard must actually exist, or the check below is empty.
    check("the matcher DOES match the non-ASCII command (Unicode fold)",
          bool(tg.match(man_u, UNI_CMD, cwd="/tmp")[0]))
    check("...and every grep does NOT (that is the whole hazard)",
          not grep_says_match(os.path.join(store, tg.PREFILTER_NAME), UNI_CMD)[0])

    with tempfile.TemporaryDirectory() as flags:
        rc_u, out_u, _eu = run_hook(store, UNI_CMD, session="sUNI", flag_dir=flags)
        check("a non-ASCII command is NOT rejected on grep's word — the nudge fires",
              rc_u == 0 and additional_context(out_u) is not None)

    # ...and the guard must not become "always fall through": an ASCII command that
    # genuinely matches nothing still has to take the cheap reject.
    with tempfile.TemporaryDirectory() as flags:
        rc_n, out_n, _en = run_hook(store, "echo entirely unrelated", session="sASC",
                                    flag_dir=flags)
        check("an ASCII no-match command still rejects cheaply",
              rc_n == 0 and out_n.strip() == "")

# ------------------------------------------------------------ cap and fail-open
print("== cap and fail-open ==")
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    for i in range(5):
        write(os.path.join(store, f"reference_many{i}.md"),
              memory(f"reference_many{i}", f"the {i}th matching memory",
                     "triggers:\n  - literal: statusCheckRollup\n"))
    manifest, _ = tg.compile_manifest(store)
    tg.write_manifest(store, manifest)
    with tempfile.TemporaryDirectory() as flags:
        rc, out, _err = run_hook(store, CASE1_CMD, flag_dir=flags)
        ctx = additional_context(out) or ""
        shown = sum(1 for ln in ctx.splitlines() if ln.startswith("- reference_many"))
        check("five matching memories respect the per-event cap",
              rc == 0 and shown == tg.NUDGE_CAP)
        check("the capped output states how to see the rest",
              "3 more matched" in ctx and "triggers.py" in ctx)

with tempfile.TemporaryDirectory() as store:
    with tempfile.TemporaryDirectory() as flags:
        t0 = time.monotonic()
        rc, out, _err = run_hook(store, CASE1_CMD, flag_dir=flags)
        check("a MISSING manifest exits 0 with no output, fast (fail-open)",
              rc == 0 and out.strip() == "" and time.monotonic() - t0 < 5.0)
    # The assertion above pins the OUTCOME but not the MECHANISM: removing the
    # shell's `[ -f TRIGGERS.json ] || exit 0` bail leaves it green, because
    # `load_manifest` fails open too. Fail-open is defended twice on purpose, but
    # the shell bail exists for LATENCY — this hook fires on every Bash call
    # (~453 in the motivating session) and must not spawn python3 for nothing.
    # A python3 shim that records having been invoked pins that from the other side.
    with tempfile.TemporaryDirectory() as shim:
        marker = os.path.join(shim, "spawned")
        write(os.path.join(shim, "python3"),
              f'#!/bin/sh\ntouch "{marker}"\nexit 0\n')
        os.chmod(os.path.join(shim, "python3"), 0o755)
        shim_path = shim + os.pathsep + os.environ.get("PATH", "")
        with tempfile.TemporaryDirectory() as flags:
            run_hook(store, CASE1_CMD, flag_dir=flags,
                     env_extra={"PATH": shim_path})
        check("a missing manifest does not even spawn python3 (the cheap bail)",
              not os.path.exists(marker))

    write(os.path.join(store, "TRIGGERS.json"), "{not json at all")
    with tempfile.TemporaryDirectory() as flags:
        rc, out, _err = run_hook(store, CASE1_CMD, flag_dir=flags)
        check("a CORRUPT manifest exits 0 with no output (fail-open)",
              rc == 0 and out.strip() == "")

    with tempfile.TemporaryDirectory() as shim:
        marker = os.path.join(shim, "spawned")
        write(os.path.join(shim, "python3"),
              f'#!/bin/sh\ntouch "{marker}"\nexit 0\n')
        os.chmod(os.path.join(shim, "python3"), 0o755)
        shim_path = shim + os.pathsep + os.environ.get("PATH", "")
        with tempfile.TemporaryDirectory() as flags:
            run_hook(store, CASE1_CMD, flag_dir=flags,
                     env_extra={"PATH": shim_path})
        check("the shim fixture proves python3 IS spawned once a manifest exists",
              os.path.exists(marker))

# jq absent -> exit 0, no output. Verify the fixture really hides jq first.
with tempfile.TemporaryDirectory() as store:
    write(os.path.join(store, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(store, "reference_gh_conflicting_blocks_ci_silently.md"),
          LITERAL_MEM)
    manifest, _ = tg.compile_manifest(store)
    tg.write_manifest(store, manifest)
    with tempfile.TemporaryDirectory() as nojq:
        probe = subprocess.run(["/bin/bash", "-c", "command -v jq"],
                               env={"PATH": nojq, "HOME": os.environ["HOME"]},
                               capture_output=True, text=True)
        check("the jq-absent fixture actually hides jq (guards the next assertion)",
              probe.returncode != 0)
        with tempfile.TemporaryDirectory() as flags:
            rc, out, _err = run_hook(store, CASE1_CMD, flag_dir=flags,
                                     env_extra={"PATH": nojq})
            check("jq absent -> fail-open (exit 0, no output)",
                  rc == 0 and out.strip() == "")

# ------------------------------------------------------------- hooks.json wiring
print("== hooks.json wiring ==")
cfg = json.load(open(HOOKS_JSON, encoding="utf-8"))
post = cfg["hooks"]["PostToolUse"]
bash_entries = [e for e in post if e.get("matcher") == "Bash"]
nudge = [e for e in bash_entries if "trigger-nudge.sh" in e["hooks"][0]["command"]]
check("a PostToolUse Bash entry runs trigger-nudge.sh",
      len(nudge) == 1)
check("the pre-existing PR matcher is still the FIRST Bash entry (harness reads it)",
      "reflect-trigger.sh" in bash_entries[0]["hooks"][0]["command"])
check("the nudge entry uses ${CLAUDE_PLUGIN_ROOT} and carries a timeout",
      "${CLAUDE_PLUGIN_ROOT}" in nudge[0]["hooks"][0]["command"]
      and isinstance(nudge[0]["hooks"][0].get("timeout"), int))
check("the nudge entry is fail-open (|| true) and never reads $TOOL_INPUT",
      "|| true" in nudge[0]["hooks"][0]["command"]
      and "TOOL_INPUT" not in nudge[0]["hooks"][0]["command"])
sess = [e for e in cfg["hooks"]["SessionStart"]
        if "compile-triggers.py" in e["hooks"][0]["command"]]
check("compilation has its OWN SessionStart entry with its own timeout (KTD18)",
      len(sess) == 1 and isinstance(sess[0]["hooks"][0].get("timeout"), int))
check("compilation does NOT ride inside memory-index-render.py",
      "compile" not in open(os.path.join(REPO, "scripts",
                                         "memory-index-render.py"),
                            encoding="utf-8").read().lower().replace(
          "compiled", "").replace("re.compile", ""))

print()
print(f"trigger_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)

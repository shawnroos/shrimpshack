---
title: "A default-allow safety gate on a regex dialect projection silently drops matches"
date: 2026-08-11
module: plugins/reflect
problem_type: logic_error
component: tooling
severity: high
category: logic-errors
symptoms:
  - "a grep prefilter projected from Python `re` patterns rejected commands the real matcher matches — no error, no log line, no nudge"
  - "`[^\\n]` written through verbatim: POSIX gives backslash no meaning inside a bracket, so grep read \"not backslash, not the letter n\""
  - "negated classes never match across a newline in line-oriented grep, so multi-line commands were rejected"
  - "a PATH-only grep test stayed green both before and after the fix, because PATH resolves ugrep here"
  - "four successive review rounds each found a new violation of the same invariant"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
  - development_workflow
tags:
  - default-deny
  - enumeration
  - regex
  - grep
  - posix-ere
  - hooks
  - silent-failure
  - unicode-case-fold
---

## Problem

`reflect`'s `trigger-nudge.sh` is a `PostToolUse(Bash)` hook, so it runs on every Bash
call an agent makes. To skip Python startup on commands that cannot match anything,
compile time projects each Python `re` trigger pattern into a POSIX ERE and writes
`TRIGGERS.prefilter` beside the manifest; the hook `grep -qiEf`s the command against it
and exits before spawning Python when grep says no.

That projection has one invariant: it may say "maybe" when the answer is no — which only
costs the optimization — but it must **never** say "no" where the matcher says "yes".

The gate deciding which patterns were safe to project was built by enumerating known-bad
constructs, so anything unenumerated defaulted to safe. Six violations followed.

Shipped in PR #35 ("reflect: reject the common case before starting Python") and hardened
in PR #38 ("reflect 0.4.2: close the remaining prefilter P3s"); both merged to `main`.

## Symptoms

None of these produce a symptom at the point of failure. That is the whole problem: a
wrong "no" means no error, no log line, no nudge — and `RECALL.log` is written by Python,
which a reject means we never start (`trigger-nudge.sh:19-22`, `126-133`).

Six violations. Per this session's review history — the round count is a session claim, not
something the tree records — they surfaced across four successive rounds, each round finding
a construct nobody had thought to enumerate:

1. **`[^\n]`** — POSIX gives backslash no meaning inside a bracket expression, so grep
   reads the set "not a backslash, not the letter `n`". Two patterns in the **live** store
   used it, so any invocation with an `n` in the matched span silently lost its nudge
   (`gh run rerun --repo owner/name 99 --failed`).
2. **Any other negated class** (`[^;]`) — matches a newline in Python; a line-oriented
   grep never can. Per the hook's own recorded figures (`trigger-nudge.sh:86-88`), 457 of
   480 recorded Bash calls were multi-line, so this is the common shape, not an edge.
   Note the escape rule cannot see it — `[^;]` contains no escape at all.
   *(Treat that ratio as self-reported: no replay corpus is committed, and the source gives
   the denominator as both ~453 and 480 in different comments. The shape of the claim —
   most real commands are multi-line — is what the design rests on, not the exact figure.)*
3. **`\<` / `\>`** — literal `<`/`>` to Python; word-boundary anchors to BSD grep, GNU
   grep and ugrep alike.
4. **`{,3}`** — a `{0,3}` quantifier to Python, a literal to both greps (POSIX leaves the
   omitted lower bound undefined).
5. **`[[:alpha:]]`** — a character class to grep, an ordinary set of literal characters to
   Python. Same for collating elements `[[.a.]]` / `[[=a=]]`.
6. **Unicode case-fold symmetry** — found only *after* the gate was inverted. The new rule
   checked the PATTERN's bytes for non-ASCII, but `re.I` folds Unicode, so the pure-ASCII
   pattern `pip install` matches the command `pıp install` (U+0131 dotless i) that no grep
   folds under any locale. K (U+212A) and ſ (U+017F) behave the same way.

## What Didn't Work

**Fixing the cited instances.** Rounds 2, 3 and 4 each found another construct. The
enumeration was the defect; patching members of it never converged.

**Trusting `command -v grep`.** The superset test ran whichever grep PATH resolved. On
this machine that is ugrep 7.5.0, which reads `[^\n]` Perl-style and therefore **passes
the broken code**. The test was green before and after the fix and discriminated nothing,
while the bug was live in the compiled store.

**Asserting that escaped punctuation is dialect-identical.** The inverted gate permitted
"escaped punctuation, because both dialects agree." That claim was simply false for `\<`
and `\>`.

**Guarding only the pattern side.** Case folding is symmetric; a pattern-side rule cannot
see a command-side hazard.

**A test that patched the wrong function.** A test for `write_prefilter`'s exception path
monkeypatched `tempfile.mkstemp` — but `_grep_parses` calls `mkstemp` first, so the patch
routed into a different branch with its own older cleanup. It passed with the code under
test deleted. Patching `os.replace`, which only the intended branch reaches, fixed it.

**A test asserting a fail-open exit code.** The non-ASCII guard's test asserted `rc == 0`;
the hook returns 0 on every path by design, so the assertion held whether or not the nudge
fired.

## Solution

**Invert the gate to default-deny.** Permit only escapes verified to read identically in
both dialects — `_ESCAPE_OK` (`triggers.py:473`) is exactly `re.escape`'s output set — and
reject every other escape, plus `(?`, `{,` and `[^` (`_UNSAFE_FOR_GREP`,
`triggers.py:475-480`). Anything unrecognised lands on the suppress side by construction.

The permit-list has to be exactly `re.escape`'s output and no narrower: `re.escape`
escapes `-` and space, so a plain literal trigger like `gh pr --json` would otherwise
suppress the whole store's prefilter — correct, and pointless.

**A bracket-internals scanner.** `_bracket_scan` (`triggers.py:483-524`) reports two
hazards separately: a nested `[` (POSIX classes, collating elements) and a backslash
inside a bracket. Deliberately crude; over-reporting only ever costs the optimization.

**Order is load-bearing** in `prefilter_lines` (`triggers.py:381-408`):

1. nested-bracket check on the **raw source** — the rewrite below destroys the evidence
   (`[a[^\n]]` becomes `[a.]`, which looks ordinary and would be emitted narrower than its
   source);
2. rewrite `[^\n]` → `.` (exactly equivalent in both engines, and needs no bracket parsing);
3. backslash-in-bracket check, now that the one safe instance is gone;
4. strip `\b` last, once no bracket can still contain one.

Getting this order wrong re-breaks the live store: checking backslash-in-bracket first
would suppress the prefilter for every pattern, because `[^\n]` **is** a backslash inside
a bracket.

**All-or-nothing, never per-line.** `prefilter_is_safe` and `write_prefilter`
(`triggers.py:534-565`, `669-690`) refuse to emit the file at all if any pattern is
unsafe. Dropping just the offending line would leave a prefilter narrower than the matcher
— the one direction that loses a nudge. Missing means "maybe", and the hook falls through
to Python.

**Fix the Unicode hazard on the side it lives on.** A non-ASCII command is never judged by
grep and falls straight through (`trigger-nudge.sh:110-116`). Non-ASCII commands are rare,
so the fast path is unchanged.

## Why This Works

An enumeration of known-bad constructs is *default-allow*: the surface is "everything
nobody thought of," which is unbounded. Default-deny inverts it, so the unenumerated case
is caught by construction rather than by foresight. The six violations were not six
oversights — they were one structural choice producing instances on demand.

The asymmetry is what makes the direction matter. Over-suppression costs latency and
announces itself in a benchmark. Under-suppression costs a memory nudge and announces
nothing at all.

## Prevention

**Verify the claim your permit-list rests on — don't assert it.** A test walks
`re.escape`'s output character by character and checks each escape against every grep on
the machine (`trigger_test.py:518-537`), so it fails loudly if a future Python widens
`re.escape` or a grep reinterprets one of them.

**Test against `/usr/bin/grep` explicitly, not just PATH grep.** `GREPS`
(`trigger_test.py:353`) is PATH grep plus `/usr/bin/grep` when that path exists, so on a
typical box it is effectively both, and the check is a conjunction — one dialect rejecting
is a failure even if another accepts.

**Make the invisible failure askable.** `MEMORY_TRIGGER_PREFILTER_AUDIT=1` makes a reject
fall through to Python anyway, marked, and Python logs any disagreement to `RECALL.log` as
`prefilter-disagreement` (`trigger-nudge.sh:134-138`, `triggers.py:1343-1366`). Off by
default and deterministic — a flag, not a sampling probability.

**Prove each rule is load-bearing by mutating the code.** Neutering `prefilter_is_safe` to
`return bool(lines)` previously left the suite green; the hazard table exists because that
mutation now fails. Every pipeline test also passes for a `prefilter_is_safe` that answers
"safe" for a POSIX class — because `prefilter_lines` returned `None` first — so the oracle
is asked **directly** as well (`trigger_test.py:506-516`).
*(auto memory [claude]: `feedback_mutation_test_not_inject_fail_proves_assertions` — only
mutating the CODE proves an assertion is load-bearing.)*

**Review the fix, not just the original change.** Rounds 2 and 4 each found a defect
introduced by the immediately preceding fix; a review scoped to the base diff would have
missed both by construction.

**Keep an honest residual rather than a test that proves nothing.** `LC_ALL=C` on the grep
invocation guards a glibc Turkish `I` → `ı` fold. It is untestable on macOS — no local
locale reproduces the divergence, and removing the pin does not fail the suite — so it
ships with a `KNOWINGLY UNTESTED` comment stating the argument it rests on
(`trigger-nudge.sh:101-109`). Proving it needs a glibc box with `tr_TR.UTF-8`.
*(auto memory [claude]: `feedback_enumeration_fixes_never_close_a_class` — invert to
default-deny, or declare the residual loudly.)*

## Related Issues

- `docs/solutions/architecture-patterns/command-and-skill-sharing-a-name.md` — a different
  mechanism, same failure shape: something that fails with no error signal, pinned by a
  test written so it cannot pass vacuously. See-also only; no guidance transfers.
- (session history) An adversarial plan review on this branch four days earlier flagged the
  same class in a different component — `use_counts()` counting non-application log events,
  raising activation and lowering the recall floor. Nothing errors, the suite stays green,
  and the only symptom is a memory that quietly never surfaces. That framing is why this
  gate needed a proof of no-narrowing rather than a check that it runs.
- The repo has no GitHub issues, open or closed, so none are linked.

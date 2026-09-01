---
title: "A clean test-count subtraction reconciles the total but doesn't prove nothing else broke"
date: 2026-08-12
module: plugins/spawn
problem_type: workflow_issue
component: testing_framework
severity: medium
category: workflow-issues
applies_when:
  - "a PR or refactor changes a test file's declared @test count and you're verifying the suite is intact by diffing totals between two commits"
  - "the commit under review also edits test files other than the one(s) whose deletion explains the total, so a clean subtraction is coincidental agreement"
  - "a review offers a test count as its evidence that a change was safe"
symptoms:
  - "spawn's bats suite went from 489 to 473 declared @tests after PR #43; 489-473=16 exactly matches the 16 @tests deleted with setup-gw.bats, so the subtraction reconciles cleanly"
  - "the same commit also changed setup.bats (32 lines) and surfaces.bats; a clean subtraction against the deleted file says nothing about those edits"
  - "declared @test count and passing count are different measurements, and subtraction between two declared totals cannot distinguish a deleted test from a silently skipped, renamed-to-no-op, or now-always-false-guarded one"
tags:
  - test-count-reconciliation
  - declared-vs-passing
  - bats
  - test-verification
  - silent-skip
  - spawn-plugin
  - review-evidence
---

## Context

The spawn plugin's unit suite declared 489 tests before PR #43 ("spawn: stop rewriting the
operator's gw") and declares 473 after. The drop is 16, and
`plugins/spawn/tests/unit/setup-gw.bats` declared exactly 16 tests before it was deleted.
489 − 16 = 473. The subtraction closes to zero.

That clean arithmetic is what made the drop look explained, and it is weaker evidence than
it looks. PR #43 touched three test files, not one:

```
plugins/spawn/tests/unit/setup-gw.bats | 507 ---------------------------------
plugins/spawn/tests/unit/setup.bats    |  32 +--
plugins/spawn/tests/unit/surfaces.bats |   1 -
```

`setup.bats` declared 21 tests before and 21 after. `surfaces.bats` declared 18 before and
18 after. Both are invisible to the subtraction — and both had assertions rewritten
underneath. In `setup.bats` the F1 test swapped one assertion for another:

```
-    jq -e '[.changed[].what] | index("wrapper") != null' "$OUT" >/dev/null
+    jq -e '[.changed[].what] | index("shell-rc") != null' "$OUT" >/dev/null
```

That is a correct change — nothing records a `wrapper` entry any more — but the totals
could not have told you whether it was correct, careless, or absent. The reconciliation
named a cause for the 16 and said nothing at all about the other two files.

## Guidance

Two steps, in order. The first explains the number; the second is the one that actually
holds.

**1. Reconcile the change to a named cause.** A count that moved needs a specific file and
a specific reason, not a plausible story:

```bash
cd /Users/shawnroos/projects/shrimpshack
T=$(mktemp -d)

# declared today, per file
grep -rc "^@test" plugins/spawn/tests/unit/*.bats

# declared at the revision you are comparing against
git archive ee393b2^ plugins/spawn/tests/unit | tar -x -C "$T"
grep -rc "^@test" "$T"/plugins/spawn/tests/unit/*.bats

# what the change actually did to the test tree
git show --stat ee393b2 -- plugins/spawn/tests
```

The per-file breakdown is the load-bearing part. A single total tells you the size of the
move; the per-file counts tell you which file moved, and `--stat` tells you which files
changed without moving. In PR #43 that is the difference between "one file deleted" and
"one file deleted plus two edited".

**2. Verify declared == passing on the branch.** This is the check that survives when the
subtraction lies.

The runner is `plugins/spawn/tests/run-tests.sh`. It loops per file
(`for test_file in "$SCRIPT_DIR/$dir"/*.bats`), runs `bats` on each, and prints only
`PASSED` or `FAILED` per file — it never prints a count, and `--verbose` maps to `--tap`,
still per file. So the reconciliation runs bats directly, alongside the normal
`./plugins/spawn/tests/run-tests.sh unit`:

```bash
# declared — the runner's own enumeration, stronger than grepping for ^@test
bats --count plugins/spawn/tests/unit/*.bats                       # 473

# passing — TAP `ok` lines that are NOT skips
bats --tap plugins/spawn/tests/unit/*.bats > /tmp/spawn.tap
head -1 /tmp/spawn.tap                                             # 1..473  (declared)
grep -c '^ok' /tmp/spawn.tap                                       # ok INCLUDING skips
grep '^ok' /tmp/spawn.tap | grep -vc '# skip'                      # actually passing
grep '^ok' /tmp/spawn.tap | grep  '# skip'                         # name every skip
grep -c '^not ok' /tmp/spawn.tap                                   # failing
```

bats aggregates a multi-file glob into one plan line — verified on two files
(`bats --tap .../regressions.bats .../jobs.bats` prints `1..24`).

The `# skip` exclusion is the whole point. A plain `grep -c '^ok'` counts a skipped test as
passing, which is the exact hole this check exists to close. In this suite three tests can
skip:

- `plugins/spawn/tests/unit/ceilings.bats:522` and `:555` — the two `LIVE:` arms, gated by
  `live_or_skip` (`ceilings.bats:182`) on `SPAWN_CEILING_LIVE=1` plus a real `claude`
  binary.
- `plugins/spawn/tests/unit/surfaces.bats:261` — "claude plugin validate reports Validation
  passed", which skips when the `claude` CLI is not on PATH.

Those three are deliberate and commented in place. They are also why "473 declared, 473 ok"
is not the same statement as "473 passing" on a box without the claude CLI.

This document does not assert today's passing number — the full suite was not run while
writing it. The commands above are the source; run them on the branch.

## Why This Matters

A subtraction between two totals is a single equation with a great many unknowns. It can
only detect a change that moves the count. Everything else keeps one number intact while
the other moves, and reads as green:

- **A test silently skipped.** `skip` inside the body still declares the test, still emits
  `ok N ... # skip`, still reports as not-failed. Declared holds, passing drops, the
  subtraction sees nothing. A skip introduced by a changed guard — an env var no longer
  set, a binary no longer on PATH in the new environment — moves nothing the totals can
  see.
- **A test renamed into a no-op.** The `@test` line survives, the assertions inside are
  gutted or rewritten. Both numbers hold. This is the near-miss in PR #43: `setup.bats`
  kept all 21 declarations while an assertion was replaced.
- **A test guarded behind a now-always-false condition.** The body runs, the `if` never
  enters, the test passes vacuously. Declared and passing both hold, and coverage is gone.
- **A file the runner stopped globbing.** `run_suite` iterates `"$SCRIPT_DIR/$dir"/*.bats`
  and sets `found=1` if *any* file matched. Rename a `.bats` to `.bats.bak`, move it into a
  subdirectory, or drop the extension, and it silently leaves the suite — `found` is still
  1, the runner still prints PASSED for everything else, and both the declared and passing
  totals fall together in lockstep. The subtraction reconciles perfectly against a file you
  did not intend to remove.

And the failure mode that makes this worth writing down: **a coincidentally-clean
subtraction is a false all-clear.** PR #43 is the live example. Three test files changed,
one deletion, and the totals reconciled to the digit. The exact reconciliation was true and
told you nothing about the two files it did not cover. Having the arithmetic close makes it
*less* likely anyone looks further, which is the opposite of what a check should do.

`declared == passing` fails on the first three of those four. It does not catch the fourth
on its own — for that you need the per-file counts from step 1, which is why both steps
run.

## When to Apply

- **Any refactor that moves or splits test files.** Splitting one `.bats` into four, moving
  a suite under a new directory, extracting shared setup — every one of these can drop a
  file out of the runner's glob while the totals still look sane.
- **Any branch where the count moved at all**, in either direction. A count that went *up*
  by the right amount hides a deletion just as well as one that went down.
- **Any review that reports a count as evidence.** "473 tests, same as before minus the 16
  we deleted" is an arithmetic statement, not a verification statement. If a review offers
  a count as its evidence, the count is the claim being made — ask for declared-vs-passing
  on the branch.
- Before merging any change to `plugins/spawn/tests/run-tests.sh` itself, since that file
  decides which tests exist at all.

## Examples

**The arithmetic that reconciled, and what it missed.**

```
at ee393b2^   473 + 16 (setup-gw.bats) = 489 declared
today                                    473 declared
delta                                     -16
setup-gw.bats deleted, declared           -16      closes exactly
```

What the same change did that the arithmetic cannot express:

| file | declared before | declared after | lines changed |
|---|---|---|---|
| `plugins/spawn/tests/unit/setup-gw.bats` | 16 | — (deleted) | −507 |
| `plugins/spawn/tests/unit/setup.bats` | 21 | 21 | 32 |
| `plugins/spawn/tests/unit/surfaces.bats` | 18 | 18 | 1 |

Two of the three rows are invisible to the subtraction. The `surfaces.bats` line removed an
assertion for a flag that no longer parses (`--consent-overwrite-gw`); the `setup.bats`
lines rewrote F1's `changed`-accumulator assertion. Both are correct here. Neither was
proven correct *by the count reconciling*.

**The shape of the stronger check.** Not "the totals differ by the number I expected", but:

```
declared (bats --count, or the TAP `1..N` plan line)   N
passing  (TAP `ok` lines, minus `# skip`)              N
failing  (TAP `not ok` lines)                          0
skipped  (TAP `ok ... # skip`)                         enumerated by name, each one expected
```

Every skip gets named and justified out loud. In this suite that list is exactly three, all
environment-gated and commented in place. A fourth appearing is a finding, whether or not
any total moved.

## Related

- [A rebase composes two sets of gates, not just two sets of code](rebasing-onto-a-base-that-added-enforced-gates.md)
  — its Examples section teaches the count reconciliation (`theirs + yours must equal the
  result`) that is step 1 above, and it is where the idiom earns its keep: a bats file that
  will not parse collapses to a single failing test, which only a count exposes. This doc
  bounds that idiom — reconciliation explains a total, and the declared-vs-passing check is
  what holds when the total reconciles for the wrong reason.
- [A permission allow-list is only as narrow as its widest bare tool](../documentation-gaps/permission-allowlist-is-only-as-narrow-as-its-widest-bare-tool.md)
  — a membership test satisfied by a list containing the right entries plus anything else,
  which is the same gap between a check and the invariant it is trusted to hold.

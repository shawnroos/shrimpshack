---
title: "A tally keyed on exit status reports work that never happened"
date: 2026-08-16
module: plugins/reflect
problem_type: logic_error
component: verification
severity: high
category: logic-errors
applies_when:
  - "a counter, summary line, or test assertion is incremented because a command exited 0"
  - "a script reports how much work it did, and the number is derived from control flow rather than from the tool's own output"
  - "you are about to add a fallible stage in front of an existing best-effort stage"
symptoms:
  - "reflect Pass 8 printed `embedded=5 failed=0` while zero documents were indexed and every memory saved that session was unfindable next session"
  - "a guard's test asserted `rc == 0` against a hook that returns 0 on every path by design, so it passed whether or not the effect fired (2026-08-11, same plugin, same week)"
  - "after the fix, a failure of the NEW first stage printed a byte-identical clean tally, because nothing indexed means every later check honestly reports 'no work'"
  - "an end-to-end guard searched BM25 (`qmd search`) while the real consumer searched vectors (`qmd vsearch`), so a totally broken embed shipped green"
tags:
  - exit-code-as-proxy
  - false-clean
  - observed-effect
  - qmd
  - reflect-plugin
  - tally-honesty
---

## Context

`plugins/reflect` Pass 8 reconciles the Claude-owned QMD collections and re-embeds them.
It counted `embedded` by incrementing once per collection whose `qmd embed -c <name>`
exited 0. Every run reported a clean `embedded=5 failed=0`.

Nothing was being embedded. `qmd embed` only re-vectorises documents **already in the
index**, and the pass never ran `qmd update`, so a memory saved during a session was never
indexed, never embedded, and unfindable in the next session's seeded recall. The tally was
structurally incapable of saying so: exit zero proves the command ran, never that the
effect happened.

This is the **second** instance of the same class in this plugin inside one week. On
2026-08-11 a projection-gate test asserted `rc == 0` against a hook that returns 0 on every
path by design — see
`docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`.

## The fix shape

**Count observed effects, or say `unknown`.** Match the specific output the tool prints
when it did nothing:

```bash
QMD_NO_WORK_LINE='✓ All content hashes already have embeddings.'
if out="$(qmd embed -c "$1" 2>&1)"; then
  case "$out" in
    *"$QMD_NO_WORK_LINE"*) : ;;      # observed: zero
    *) embedded_unknown=1 ;;          # ran, count not observable
  esac
```

Two rules fell out of it:

- **Never publish a proxy count as if it were the real unit.** qmd reports content hashes,
  not documents, and one document carries several — so there is no honest number above
  zero to compute. An honest `unknown` beats a confident number nobody measured.
- **`unknown` is not a failure.** It has to be rendered as a distinct value, not folded
  into either the success number or the failure count.

## Three traps, all of which fired for real

1. **The fix reintroduces the defect one stage earlier.** Adding `qmd update` in front
   created a new fallible stage — and when *it* failed, every scoped embed below correctly
   found no new work and printed the no-work line, so the run reported `embedded=0` again.
   `0` now meant "we never looked". Ask of every new fallible stage: *what does the tally
   say when this one fails?* The answer here was an explicit `embedded_unknown=1` on the
   update's failure branch.
2. **The test asserted a different path than production uses.** The end-to-end guard used
   `qmd search` (BM25, satisfied by indexing alone); the real seeded-recall consumer uses
   `qmd vsearch` (vectors). Assert through the path the consumer actually calls.
3. **A stub the same change authored proves nothing about reality.** Back stub-based tests
   with at least one assertion against the real binary — and check that one isn't vacuous
   too (it initially matched a filename rather than a body token).

## Proving an assertion is load-bearing

A deliberate-fail flag only proves the harness can exit 1. The evidence chain that counted
here was: 7 red before the fix → 179/0 after → **delete the production `qmd update` line
with the tests untouched → 5 red** → restore → green. Review still found traps 2 and 3
*after* a clean mutation pass, because a mutation only tests the mutation you thought to
make.

## Shell hazards met on the way

- `local out="$(cmd)"` returns `local`'s status, silently swallowing the failure, so
  neither the warning nor the unknown branch ever fires. `out="$(cmd)"` as a bare statement
  aborts the whole script under `set -e`. Only `if out="$(cmd)"; then` is correct.
- Keep the numeric tally and the `unknown` flag as **two variables**. One mixed-type
  variable holding `unknown` plus any later `$((var + n))` exits 1 under `set -u` with
  `unknown: unbound variable`, killing the run before the summary prints — the exact
  starvation the best-effort design exists to prevent.

## See also

- `docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`
- `docs/plans/2026-08-14-001-fix-reflect-embed-index-new-memories-plan.md`
- `docs/residual-review-findings/bugfix-reflect-embed-indexes-new-memories.md`

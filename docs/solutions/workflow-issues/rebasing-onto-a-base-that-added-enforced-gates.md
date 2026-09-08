---
title: "A rebase composes two sets of gates, not just two sets of code"
date: 2026-08-11
module: plugins
problem_type: workflow_issue
component: tooling
severity: medium
category: workflow-issues
tags:
  - git
  - rebase
  - testing
  - lint
  - code-review
applies_when:
  - "rebasing a long-lived branch onto a base that landed a refactor or new tests"
  - "a suite goes red after a rebase and neither parent branch was red"
  - "a repo enforces architectural decisions (file size, duplication) as tests"
---

## Context

Landing PR #33 (the spawn background agent) meant rebasing onto PR #37, which had
just split `setup.sh` and strengthened the plugin's own quality gates. Both branches
were green: #37 passed its suite, and the background-agent branch passed 489 tests on
the pre-#37 base.

The rebased result failed three tests.

The instinct is to reach for one of two explanations — "I broke something in the
conflict resolution" or "main was already red and I inherited it". Both were wrong,
and chasing either would have wasted the session.

## Guidance

**After a rebase goes red, check the base alone before diagnosing anything.** It costs
one command and eliminates half the hypothesis space:

```bash
git worktree add -f /tmp/basechk origin/main --detach
cd /tmp/basechk && <run the failing tests>
```

Pristine-green proves the failure is yours or *interactional*. Pristine-red means you
inherited it, and fixing it under a rebase is the wrong place — audit it separately.

**Then read the failure as a contract meeting, not a bug.** All three failures here
were interactions that existed in neither parent:

| What #37 added | What the branch added | Result |
|---|---|---|
| A duplicate-function lint with **no length floor** | Six new libs, each with its own `say`/`die`/`now_utc`/`emit_error` | 8 duplicate groups |
| A hard `code_lines < 1000` assertion on `spawnctl.sh` | +209 lines to that file | 1033 — over the bar |
| A doc-vs-file line-count check | The same +209 lines | Stale doc |

A gate is a rule written at a point in time. Code written *before* that rule exists has
never been measured against it. The rebase is the first moment the two meet, so
"both branches were green" carries no information about their union.

**Satisfy the new rule honestly rather than widening it.** The size gate was tempting to
relax — it is one integer in a test file. But the repo's own audit doc had pre-committed
to the answer: the decision must be *"re-taken, not re-quoted, the next time this file
grows."* The gate firing was the intended outcome, not an obstacle. The honest re-take
moved the `status` jobs block into `plugins/spawn/lib/jobs-view.sh` (it read the job record layer and
rendered it — never `spawnctl`'s own concern), which put the file at 927 lines and
required no change to the bar.

## Why This Matters

A gate that gets widened the first time it fires was never a gate. The failure modes
are asymmetric: satisfying the rule costs an extraction and leaves the invariant intact;
relaxing it costs nothing today and silently retires the check for everyone after you.

The same logic applies to the duplicate lint. Its own comment states the reasoning —
a 3-line floor had previously hidden a real 2-line duplicate, so the floor was removed
entirely, and the file records that any genuine coincidence should be carved out *by
name with a stated reason* rather than by reopening the class.

## When to Apply

- Any rebase onto a base that landed a refactor, a new lint, or new structural tests
- Any red suite where you are about to attribute blame without having run the base alone
- Any time you are tempted to adjust a threshold in a test file to make your branch pass

## Examples

**Deciding whether a failure is yours** — reconcile counts rather than eyeballing a
conflict resolution. After keeping both sides of an append-collision in a bats file:

```bash
# theirs + yours must equal the result
git show origin/main:path/to/file.bats | grep -c '^@test'   # 57
git show <your-commit>:path/to/file.bats | grep -c '^@test' # (your 5 additions)
grep -c '^@test' path/to/file.bats                          # must be 62
```

This caught a genuine defect twice in one session: git matches a shared trailing `}`
as common context across an append-collision and leaves it out of one side's conflict
region, so "keep both sides" silently produces an unbalanced file. A bats file that
will not parse collapses to a single `not ok 1 bats-gather-tests`, hiding every real
test in it — the count reconciliation is what exposes it.

**Recording a re-taken decision** — when a gate forces a design decision, update the
doc that argues for it rather than only the number it asserts. The audit doc here now
records that the decision was re-taken and what the re-take chose, so the next reader
sees a live decision instead of a number that drifted.

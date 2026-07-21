---
name: multi-slice-review
description: Review a change too large for one reviewer — many files, several subsystems, or work built incrementally by different authors/agents. Slice the diff by invariant, staff the seams between slices, assign lenses by risk, prove load-bearing assertions by mutation, and loop to an empty round. A deterministic pre-pass sizes the fan-out; a native Workflow runs each round; Claude's /loop drives the across-rounds iteration. Companion to /ce-code-review and /code-review for large, seam-focused reviews — it reviews, it does not auto-fix. Trigger for a big diff, a multi-subsystem change, or incrementally-built work where boundary defects are the risk.
allowed-tools: Bash, Read
---

# Multi-Slice Review with Seam Coverage

Use when reviewing a change too large for one reviewer to hold: many files, several subsystems,
or work built incrementally by different authors/agents. Reviewing large work as a whole misses
boundary defects because each side looks correct in isolation; reviewing it as isolated units misses
them for the same reason. **Slices** make each invariant checkable; **seams** make each contract
checkable; **mutation** makes the checks themselves trustworthy.

This skill is a *companion* to `/ce-code-review` and `/code-review`, not a replacement. It reviews;
fixing is the caller's job between rounds.

---

## How it runs (two entry points)

### Front door — `/multi-slice-review <base> [--review-plan]`

1. **Signals (deterministic).** Run the pre-pass and rubric:
   ```
   scripts/prepass.sh <base>                    # → F, D, L, RS  (fixed every run)
   scripts/prepass.sh <base> | scripts/rubric.sh   # → TIER, SLICE_TARGET, RISK_LENSES, WAVE_CAP, MAX_REVIEWERS
   ```
   Signals are reproducible; the slice count you actually draw is judgment (below), so it is not.
2. **Slice by invariant (§1)** within the rubric's `SLICE_TARGET` — you may exceed it (log the
   override, up to `MAX_REVIEWERS`) when you find more coherent invariants than the target allows.
3. **Enumerate the seams (§2)** — for every pair of slices sharing a contract, write the contract in
   one sentence and the single question the seam reviewer must answer.
4. **Assign lenses (§3)** — `correctness` + `adversarial` everywhere; add the `RISK_LENSES` the rubric
   surfaced (security / reliability / api-contract) to the slices they apply to; skip others *with a
   stated reason*.
5. **Print the plan + the signals that drove it.** Then **proceed unless the user stops you or passed
   `--review-plan`** (which turns the plan into a hard approve/edit gate before any reviewer spawns).
   Slicing is the crux — if the seam and mutation reviewers don't produce the top findings, the slicing
   was drawn where the code already agrees.
6. **Early value-check gate (U7)** — the first time on a repo, run `docs/value-check.md`'s protocol
   before trusting the tool: does seam-review beat a whole-diff review on N=3 sound-sliced diffs,
   blind-graded on a neutral rubric? Record PASS/FAIL. Don't ship reliance on the method if it can't
   clear the bar.
7. **Start the loop:** `/loop /multi-slice-review-round <base>` (self-paced). Each round reviews; you
   apply fixes by slice (seams last, serially); the next round re-reviews, primed with what changed.

### Per round — `/multi-slice-review-round <base>` (invoked by `/loop`)

Read `docs/round-state.json` → run **one** `Workflow({scriptPath: workflows/review.js, args})` round
→ feed its findings through `workflows/predicates.js` (`dedupeVsSeen` → `isEmptyRound` → `escalates`)
→ write the state → signal STOP (empty or escalate) or let `/loop` continue. The predicates decide;
`/loop` only schedules re-entry. Full steps in `commands/multi-slice-review-round.md`.

**Why a `/loop`, not an in-Workflow loop:** the fix between rounds is an external human action across
turns. A single Workflow run can't pause for it, so the loop is cross-turn (`/loop`); each round is
one Workflow run.

---

## The method (the authoritative content)

### 1. Slice by invariant, not by commit or file count
Group files into slices where each has **one invariant a reviewer can state and check** — storage,
network/IO, domain logic, runtime/lifecycle, external-boundary. Avoid slicing by delivery increment:
increments are ordered by dependency, not coherence, and a reviewer holding one sees a correct-looking
fragment. Aim for 4–7 slices. If a slice needs two sentences to state its invariant, split it.

### 2. Enumerate seams explicitly, and staff them
**The step most reviews skip, and where the defects are.** For every pair of slices sharing a
contract, write the contract in one sentence. Typical seams: a shared resolver used by two callers;
a field one side requires and the other treats as optional; an ordering guarantee spanning two
modules; a value produced by one layer and interpreted by another; a rule duplicated rather than
shared. Give each seam its own reviewer, handed **both sides and exactly one question**, told not to
review either side's internals — otherwise it duplicates slice findings and the synthesis drowns.
A guard on the reader and absent on the writer looks correct from inside either file; only a seam
reviewer sees the asymmetry.

### 3. Assign lenses per slice by actual risk
2–3 lenses per slice. Correctness and adversarial everywhere; add **security** where there is
destructive action, untrusted input, or credentials; **api-contract** where a published signature or
return convention changed; **reliability** where there are retries, locks, signals, or background
work. Skip a lens with a stated reason rather than mechanically including it.

### 4. Brief every reviewer with four things
1. **Its slice, and the names of the other slices** — so it knows what is deliberately out of scope.
2. **Already-fixed findings, listed**, with: *hunt what those fixes introduced.* Fix-induced
   regressions consistently outnumber fresh discoveries after round one.
3. **Environment traps as fact, not caution.** Every way verification lies in this repo: aliased or
   shadowed tools, missing binaries that exit 0, interactive-by-default commands that silently no-op.
   Prove by execution, not by string-matching.
4. **Output contract:** compact structured findings, capped (~8), detail to an artifact file. With
   20+ reviewers, full returns exhaust the orchestrator before synthesis.

### 5. Require mutation proof for anything load-bearing
A passing assertion has two causes: the code is right, or the assertion has no teeth. Only mutation
distinguishes them. Break the code an assertion guards → it must fail → restore → it must pass. Report
both outputs. **If a mutation survives, the assertion is weak — strengthen it and say so.** Expect
survivors. A deliberate-fail flag that flips one expected *value* proves only that the harness can exit
non-zero; it is not evidence any assertion is load-bearing. (This tool runs mutation on an **isolated
worktree** — never the reviewed working tree.)

### 6. Verify claimed findings yourself before acting
Reproduce every P0/P1 independently. A **failed** reproduction is not a refutation — check your setup
first (a confirmed arbitrary-file-deletion bug once took four attempts: it needed an initialised store,
a held lock, a matching file extension, and a lazily-created directory to already exist; the first
attempt looked like a clean refutation). A **confirmed** finding should be reproduced with a sentinel,
not reasoned about.

### 7. Loop until an empty round, with an escalation rule
Exit condition is an **empty** round across all lenses — not a shrinking one. Fix **by slice**
(disjoint files → parallel-safe). Fix **seams last and serially** — they touch two slices by
definition. Round N+1 reviews **the fixes**, primed with what was applied. **If one machinery produces
new P1s in three consecutive rounds, stop and propose a structural change, not a fourth guard.** Count
by finding *class*, not identical finding — a literal same-finding check never trips, because each
round's defect is genuinely new. Reviewers often name the structural fix themselves in a low-severity
"was this alternative considered?" — read the P2s and P3s for it. (This tool encodes the empty-round
exit and the 3-rounds-same-class escalation as tested predicates in `workflows/predicates.js`.)

### 8. Re-validate the review apparatus itself
Tests and baselines rot, sometimes through legitimate actions. Ask each round: does this test still
compare what it claims to? A parity test resolving its baseline from `HEAD` is a genuine proof until
the work is committed, at which point it compares the new code to itself — and keeps passing. Pin
baselines to an immutable ref or a vendored fixture, and add a self-check that fails loudly if the
baseline already contains the thing under test. Watch for probabilistic assertions: run any
concurrency test ~8 times against a deliberately broken implementation and measure the detection rate.
A 1-in-8 detector reads as a guarantee and behaves as chance.

**What to expect:** the seam reviewers and the mutation runs produce the highest-severity findings. If
they don't, the slicing is probably wrong — the boundaries were drawn where the code already agrees.

---

## Files

- `scripts/prepass.sh` — deterministic F/D/L/RS signals from `git diff <base>`.
- `scripts/rubric.sh` — signals → tier, soft slice target, risk lenses, wave cap, MAX_REVIEWERS.
- `workflows/review.js` — one Workflow round (slices→lenses, seams, mutation, synthesis).
- `workflows/predicates.js` — the crisp per-round decisions (empty-round, escalation, dedup), tested.
- `docs/round-state.json` — loop state across `/loop` iterations.
- `docs/workflow-contract.md` — the recorded U1 substrate verdict.
- `docs/value-check.md` — the recorded early value-check gate protocol + result.

Tests: `bash tests/run-tests.sh all` (self-check + pre-pass + rubric + predicates, mutation-proven).

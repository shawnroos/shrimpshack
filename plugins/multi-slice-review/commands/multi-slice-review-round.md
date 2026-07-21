---
description: Run ONE multi-slice review round. Invoked by /loop each iteration — not usually run by hand. Reads and writes docs/round-state.json.
argument-hint: "<base-ref>"
---

Invoke the **multi-slice-review** skill's per-round path for a single round:

1. Read `docs/round-state.json` (seen set, round number, history-by-class, prior applied fixes). If absent, this is round 1.
2. Run one review round: `Workflow({ scriptPath: workflows/review.js, args })` (or the KTD8 subagent-dispatch fallback per the recorded workflow-contract verdict), primed with `priorFixes` from the state.
3. Feed the round's findings through `workflows/predicates.js`: `dedupeVsSeen` (drop already-seen) → record the new-P1 classes → `isEmptyRound` and `escalates`.
4. Write the updated `round-state.json`.
5. **Signal the loop:**
   - Empty round → set `exit.reason = "empty-round"` and STOP the loop (the review converged).
   - 3-rounds-same-class → set `exit.reason = "escalate:<classKey>"`, emit the structural-change proposal, and STOP.
   - Otherwise → present this round's findings by slice/seam, note that the caller should apply fixes, and let `/loop` continue (self-paced, so it waits for the between-round fixes).

Do not put loop-exit judgment in prose — the predicates decide; `/loop` only schedules the next round.

$ARGUMENTS

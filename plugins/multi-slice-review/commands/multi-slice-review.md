---
description: Review a change too large for one reviewer — slice by invariant, staff the seams, prove assertions by mutation, loop to an empty round. Companion to /ce-code-review for large, seam-focused reviews.
argument-hint: "<base-ref> [--review-plan]"
---

Invoke the **multi-slice-review** skill and follow it end to end as the front door:

1. Run the deterministic pre-pass and rubric on `git diff <base-ref>` to get the signals and the sizing.
2. Draw slices by invariant, enumerate the seams, and assign lenses per the rubric budget.
3. Print the derived plan **and** the signals that drove it, then proceed unless the user stops you or passed `--review-plan` (which forces an approve/edit gate before any reviewer spawns).
4. Run the early comparative value-check gate the first time on a repo (U7) if it has not passed yet.
5. Start the across-rounds loop with Claude's native `/loop /multi-slice-review-round <base-ref>` — each round reviews, you apply fixes, the next round re-reviews, until an empty round.

The base ref is required. `--review-plan` makes the slice/seam/lens plan a hard confirmation instead of the default show-and-proceed.

$ARGUMENTS

# Phase B Spike — Results & Decision (U3)

Run 2026-06-28 against the live `claude-memory` QMD collection (157 bodies),
28 labeled paraphrased prompts (`recall-fixture.jsonl`). Harness: `recall-eval.py`.
recall@3 = expected memory appears in the top-3 (the K seeded-recall injects).

## Recall mechanism (Q1)

| mechanism      | recall@1 | recall@3 | lat_mean | lat_p50 | lat_max |
|----------------|---------:|---------:|---------:|--------:|--------:|
| bm25_full (today) | 0.25 | 0.25 | 0.47s | 0.37s | 1.24s |
| vsearch (vector)  | 0.57 | **0.75** | 6.71s | 3.94s | 21.23s |
| keyword_bm25      | 0.32 | 0.32 | 0.17s | 0.16s | 0.21s |

**Findings.**
- Today's full-prompt BM25 recalls 0.25 — it's AND-over-content-terms, so a real
  prompt's extra words exclude the terse body. Confirmed.
- Keyword-extraction → BM25 helps a little (0.32) and is the fastest path (0.17s),
  but still recalls far too poorly to fade memories behind.
- Vector search is the only recall-adequate mechanism (0.75). Its cost is latency:
  mean 6.7s, p50 3.9s, max 21.2s (cold embedding-model load). Unusable as a hard
  synchronous call, but the seeded-recall hook is already fail-open under a wall
  budget.

**Decision.** Use `qmd vsearch` in seeded-recall with a bumped budget (7s, under
the 8s hook timeout) and the existing fail-open contract: inject when it returns in
budget, degrade silently otherwise. vsearch is the recall-quality winner with a
minimal, deterministic-contract change.

**Important caveat — per-process cold load.** qmd loads the embedding model *per
process*, and the hook runs as a fresh process once per session, so its vsearch
almost always pays the cold-load cost (5–21s). Against a 7–8s budget that means
production recall is **best-effort**: it fires when the model is already warm (a
qmd-heavy workflow, consecutive sessions) and fails open otherwise. This is
coherent with the accessibility design rather than a defect — a cold memory that
doesn't auto-surface on a cold session is exactly "less accessible, needs more
intention"; it stays reachable by explicit search and on warm sessions. The
PRIMARY deliverable (budget self-heal → no nag) does not depend on recall latency
at all.

The reliability upgrade is a warm `qmd mcp --http --daemon` (keeps the model
loaded → consistent sub-second vector queries across processes). It is the right
follow-up to make cold-tier auto-recall dependable, and is deliberately **not** a
v1 dependency so the nag-fix doesn't hinge on a managed process.

## Accessibility granularity (Q2)

Continuous activation (a decaying score, ranked, truncated at budget) vs discrete
bands. The continuous renderer (`memory-index-render.py`) was built and validated:
on the live store it produces a clean 99-hot / 58-cold split at 17.3 KB, idempotent,
with re-access re-promotion (AE2) and pin-always-hot (AE6). It is simpler than
maintaining banded state and gives smoother behavior.

**Decision.** Continuous activation. No separate discrete-band implementation.

## Decay parameters (Q3)

Defaults (`memory_activation.DEFAULT_PARAMS`): recency half-life 45d, mtime
half-life 60d, weights recency 1.0 / mtime 0.3 / freq 0.4, neutral seed 45d. These
produce a sensible hot set (99 memories) within the 17 KB budget; nothing in the
recall data argues for retuning. All are env-overridable (`MEMORY_ACT_*`) so the
curve can be tuned later without code changes.

## Residual recall misses

Even vsearch missed 7/28 — short, abstract memories with little lexical or semantic
surface (`worktrees-automatic`, `do-it-all-means-sound-not-every`,
`concurrent-agents-branch-switch-hazard`). These are inherently hard to cue; the
rising-floor design (U6) keeps them reachable on a strong, specific cue and they
remain findable by explicit search. Not a blocker for v1.

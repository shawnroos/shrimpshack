---
date: 2026-05-11
source_agent: claude (autonomous /nerd run — Batch 28)
session_id: 54fb78d6-08a7-4fe8-ad6e-2b4510c71488
signal_type: prereq-blocked
tags: [empty-production-db, data-bottleneck, eval-db-bootstrap, recurring-three-batch-blocker, fell-back-to-static-snapshot]
related_commands: [/nerd:nerd]
idea_tag: harness-aware-experimentable-predicate
outcome: partial
---

## What happened

Two of eight experiments in this batch were blocked by an empty production database. From `docs/research/batch28-findings.md`:

"DOUBLE-RERANK and SYNC-DISC-TIMEOUT both hit the same wall: the production database is empty (0 bytes at all three expected locations). DOUBLE-RERANK needs entity-bearing search queries; it found 0 of the required 15. SYNC-DISC-TIMEOUT needed updated session duration data; it fell back to the V015 static snapshot from 2026-03-15 with 0 new jobs."

E-DOUBLE-RERANK verdict: "FAILED — 0 entity-bearing queries found (minimum: 15)." All theory verdicts INCONCLUSIVE — no data.

The agent identified this as structural, not an edge case:

"This is the third consecutive batch where empty production data has constrained or blocked experiments. The eval infrastructure needs a bootstrap mechanism: a minimal realistic arras.db seeded with entity data, search feedback rows, and sync session history."

"The eval infrastructure assumes a live workspace with accumulated usage. Without it, any experiment requiring entity resolution, search feedback, or sync session history falls back to synthetic data or static snapshots. Three-batch pattern: this is not an edge case, it is a structural gap."

The agent filed E-EVAL-DB-BOOTSTRAP as a High-priority follow-up: "Seed a realistic arras.db with entity-bearing search queries, sync session history, and search feedback rows. Blocks: E-DOUBLE-RERANK, E-SYNC-DISC-TIMEOUT (live data), E-ENTITY-BOOSTS, E-FTS5-MULTIPLIER. Immediate — 3 batches blocked."

## What would have helped

From the agent's Infrastructure Findings:

"The fix is a seeded eval database committed to the repo and loaded by harnesses as fallback."

A lab-readiness / experimentable predicate that checks data prerequisites (not just harness presence) BEFORE selecting a data-dependent experiment for a batch, so the pipeline doesn't burn an executor slot on an experiment that will return FAILED (data_insufficiency).

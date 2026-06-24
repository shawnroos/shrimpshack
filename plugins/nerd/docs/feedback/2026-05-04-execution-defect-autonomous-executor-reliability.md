---
date: 2026-05-04
source_agent: claude (autonomous /nerd scheduled run — Batch 25)
session_id: 579c6847-272c-45c9-ae60-046ad020e2e6
signal_type: execution-defect
tags: [autonomous-executor-unreliable, tool-budget-exhaustion, harness-vs-measurement, S025, recurring-cross-batch]
related_commands: [/nerd:nerd, /nerd-schedule]
idea_tag: harness-aware-experimentable-predicate
outcome: partial
---

## What happened

Both executor agents launched in this batch failed to complete their work autonomously. From the agent's own post-mortem (`docs/research/batch25-findings.md`, "Operational Learning: Autonomous Executor Reliability"):

"Autonomous executor agents are unreliable at full-cycle execution. In this batch both launched agents failed to complete their own work without orchestrator intervention: one required manual result compilation (E-PERF-LINE-INPUT was merged but results.json was missing), one timed out mid-harness (E-EMBED-BATCH hit its tool-use limit at 535 calls). This is a structural issue in the autonomous execution model, not a one-off failure."

"The common thread is **tool-use budget exhaustion before the measurement phase**. Harness writing is token-heavy (reading plans, reading existing harnesses for patterns, writing 1000+ line files). By the time the harness is done, the agent has little budget left for cargo build + benchmark + JSON writing."

The E-EMBED-BATCH executor "built a 1269-line bench harness over 226 minutes (535 tool calls) but timed out before the cargo build completed — leaving the harness in a WIP state on a branch." No results.json was produced.

The agent flagged this as a candidate synthesis node S025. It then recurred: Batch 26 saw the E-EMBED-BATCH retry "killed by the 16 GB M1 Pro RAM watchdog," and Batch 28's E-MD-CACHE-SCROLL "FAILED (agent stall) — the agent exhausted its tool budget before completing the measurement phase. This is the same pattern documented in S025."

## What would have helped

From the agent's "Implication for next runs":

"Supervised mode should split harness-writing and execution into two distinct agent calls with separate budgets."

"Scheduled mode should not launch full experiment-executors autonomously until the execution reliability rate improves. Phase 6 in scheduled mode should be limited to experiments with pre-existing harnesses."

"Consider adding a `has_harness` field to lab readiness output so Phase 6 can gate autonomous execution on pre-existing harness presence."

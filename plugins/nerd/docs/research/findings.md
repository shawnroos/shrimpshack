---
title: "Nerd Meta-Research: Tuning Nerd's Own Parameters"
date: 2026-03-15
status: complete
parameters_scanned: 20
changes_implemented: 7
deferred: 13
---

# Nerd Meta-Research Findings

The nerd was run on itself. 20 tunable parameters were identified across the plugin's markdown instruction files — hardcoded thresholds, magic numbers, and untested heuristics that control how the nerd pipeline operates.

## Changes Implemented (High Confidence)

### E003: Loop Reflection Interval — 5 -> 3 iterations
**File:** commands/nerd-loop.md
**Rationale:** The old E003/E001 ratio of 1.0 gave exactly one reflection per phase, which is fragile. Reducing to 3 and adding triggers at phase transitions gives 5-6 reflections per run instead of 3, at modest token cost. Supported by meta-learning literature (MAML reflects at task boundaries, not fixed schedules).

### E004: Default Max Parallel Experiments — hardcoded 4 -> hardware-derived
**File:** commands/nerd.md, commands/nerd-this.md
**Formula:** `floor((memory_gb - 4) / 2)`, clamped to 1-6
**Rationale:** Static default ignored actual machine capacity. A 64GB machine was capped at 4; an 8GB machine might choke at 4. Now scales: 8GB→2, 16GB→6, 32GB→6 (clamped), 64GB→6 (clamped).

### E006: Retry Sleep Delay — flat 30s -> exponential backoff with jitter
**File:** commands/nerd-schedule.md
**Formula:** `10s * 2^(attempt-1) + random(0, half_base)`
**Rationale:** Flat 30s was a placeholder. Exponential backoff with jitter is the industry standard for transient failure recovery. First retry is fast (~10s) for process crashes; second is longer (~45s) for rate limits.

### E007: Global Concurrency Cap — hardcoded 4 -> hardware-derived
**File:** commands/nerd-schedule.md
**Formula:** `floor((memory_gb - 2) / 2)`, clamped to 2-8. Batch uses smaller reserve (2GB) than interactive (4GB).
**Rationale:** Same as E004 but for scheduled batch mode. Also made per-project cap dynamic — equals global cap when only one project is queued, eliminating the 50% capacity waste solo developers experienced.

### E013: KEEP/CHANGE Threshold — 1% -> 3%
**File:** skills/research-reporting/SKILL.md
**Rationale:** 1% is below the noise floor for LLM-evaluated metrics and small-sample experiments. Raising to 3% prevents false positives. Added per-experiment override for tighter measurements.

### E019: Pre-Calibration Performance Estimates — removed
**File:** commands/nerd-setup.md
**Rationale:** The plugin's own documentation showed a >50% discrepancy (3.1 experiments/hr measured vs 6-8 estimated for M1 Pro). Pre-calibration estimates were replaced with "run calibration to find out." Calibration is now the single source of truth.

### E009: Agent Overhead — static 60s -> self-correcting
**File:** commands/nerd-schedule.md
**Rationale:** The 60s flat adder was a guess. Now falls back to 60s initially but self-corrects: the report-compiler computes median actual overhead from DAG timestamps after each batch and writes it back.

## Deferred (Need More Data)

| ID | Parameter | Current | Why Deferred |
|----|-----------|---------|-------------|
| E001 | Pivot threshold | 5 | Defensible equilibrium; needs iteration-level logging from real runs |
| E002 | Phase count | 3 | Maps to natural exploit/explore hierarchy; needs escalation phase data |
| E005 | Retry count | 3 | Reasonable; would change if backoff strategy proves insufficient |
| E008 | Per-project cap | 2 | Now dynamic; no further change needed unless fairness issues emerge |
| E010 | Scope warning | 50 files | Should be relative; needs codebase size distribution data |
| E011 | Synthesis min verdicts | 3 | Need more DAG data to assess false pattern rates |
| E012 | Score thresholds | 7/5 | Scoring weights need empirical validation from loop outcomes |
| E014 | Fixture max records | 1000 | Should be density-adaptive; needs prevalence data |
| E015 | Headroom tiers | 10%/3% | Interacts with E013; wait for noise floor data |
| E016 | Min theories | 3 | Keep; add diversity requirements rather than changing count |
| E017 | Max themes | 6 | Replace with sqrt-scaled; needs UX testing |
| E018 | Batch size table | lookup | Replace with continuous formula; needs OOM testing per chip |
| E020 | Theory matching | 1-AND-1 | Tiered by DAG size; needs DAG growth data |

## Instrumentation Recommendations

The most important next step is **per-iteration logging** in loop runs. Without data on which iteration within each phase produced improvements, the loop control parameters (E001, E002, E003) remain theoretical. Log:
- Iteration number within phase
- Phase (normal/pivot/escalate)
- Whether the change was kept or discarded
- Metric delta
- Time elapsed

This data will resolve E001 and E002 empirically after 5+ loop runs.

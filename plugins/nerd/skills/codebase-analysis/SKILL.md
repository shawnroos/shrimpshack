---
name: codebase-analysis
description: "Reference for identifying tunable parameters in codebases. Use when scanning for research targets — hardcoded thresholds, magic numbers, heuristic weights, prompt templates, pipeline budgets."
---

# Codebase Analysis for Nerd

## Parameter Categories (by impact)

**High:** Search/ranking weights, resolution thresholds, AI prompt efficiency, token budgets
**Medium:** Temporal decay rates, cache TTLs, batch/concurrency limits, scoring formulas
**Lower:** Animation timing, layout defaults, retry/backoff parameters

## Scan Patterns

```bash
# Constants and config values
grep -rn "const\|DEFAULT_\|THRESHOLD\|LIMIT\|MAX_\|MIN_\|TIMEOUT\|BATCH\|WEIGHT\|BOOST\|DECAY"

# Float comparisons (thresholds)
grep -rn ">= 0\.\|<= 0\.\|> [0-9]\.\|< [0-9]\."

# Prompt templates
grep -rn "system_prompt\|systemPrompt\|PROMPT\|template\|instructions"

# Tuning TODOs
grep -rn "TODO.*tun\|FIXME.*threshold\|TODO.*calibrat\|TODO.*magic"
```

## Skip: math constants, UI colors/padding, protocol values (HTTP codes), test fixtures, values with citations.

## Prioritize by: frequency (per-request > per-session), measurability (clear metric exists), sweep feasibility (no side effects), data availability (feedback/ground truth exists).

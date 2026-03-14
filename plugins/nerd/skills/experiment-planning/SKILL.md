---
name: experiment-planning
description: "Reference for designing nerd experiments — competing theories, sweep harnesses, ground truth strategies, metric selection, and feasibility checks. Use when creating or reviewing experiment plans."
---

# Experiment Planning for Nerd

## Every Plan Needs
1. **Competing theories** (3+) — not just "is X optimal?" but "what's really going on?"
2. **Testable predictions** — what we'd observe if each theory is correct
3. **Ablation baseline** — what happens if we remove the feature entirely?
4. **Metric** — specific, computable (F1, nDCG, latency, token count)
5. **Sweep spec** — ranges, steps, --max-combos cap
6. **Ground truth** — how "correct" is defined, with circularity caveats
7. **Theory-linked acceptance criteria** — each theory can be confirmed or rejected

## Theory Types
- **Parameter is wrong**: a different value would improve the metric
- **Model is wrong**: a different model (not just parameters) would fit better
- **Feature is unnecessary**: removing it entirely causes no degradation
- **Metric is wrong**: we're optimizing the wrong thing
- **Data is the bottleneck**: the parameter doesn't matter because the input data is the real problem
- **Architecture is the bottleneck**: no parameter value can fix this

## Ground Truth Strategies
- **Auto-resolved data**: measures sensitivity, not absolute quality (circular)
- **User feedback**: clicks/engagement (sparse, position-biased)
- **Hand-labeled**: gold standard (expensive, small samples)
- **Synthetic**: tests metric computation, not real-world quality

## Feasibility Check
```
combos = product(range_sizes)
time = combos * data_size * cost_per_eval
if time > 1 hour: reduce ranges or use random search
```

## Anti-Patterns
- Single-hypothesis experiments (only testing "is the parameter optimal?")
- Sweeping dead code parameters (verify the hot path first)
- Optimizing metrics that don't correlate with user satisfaction
- No ablation (never tested if the feature matters at all)
- Insufficient data (<30 points per config = noise)
- No baseline (always include current values as comparison)

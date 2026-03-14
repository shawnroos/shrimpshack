---
name: experiment-planning
description: "Reference for designing nerd experiments — sweep harnesses, ground truth strategies, metric selection, and feasibility checks. Use when creating or reviewing experiment plans."
---

# Experiment Planning for Nerd

## Every Plan Needs
1. **Hypothesis** — why the parameter might be suboptimal
2. **Metric** — specific, computable (F1, nDCG, latency, token count)
3. **Sweep spec** — ranges, steps, --max-combos cap
4. **Ground truth** — how "correct" is defined, with circularity caveats
5. **Phases** — ordered implementation steps
6. **Acceptance criteria** — measurable checkboxes

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
- Sweeping dead code parameters (verify the hot path first)
- Optimizing metrics that don't correlate with user satisfaction
- Insufficient data (<30 points per config = noise)
- No baseline (always include current values as comparison)

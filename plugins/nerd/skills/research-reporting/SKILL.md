---
name: research-reporting
description: "Reference for compiling nerd findings into structured reports. Use when writing experiment reports, creating executive summaries, or documenting parameter tuning results."
---

# Research Reporting for Nerd

## Report Frontmatter
```yaml
---
title: "Experiment Title"
experiment_id: "E001"
status: complete|failed|inconclusive
date: 2026-03-14
parameter: "parameter_name"
file: "src/path/file.rs:42"
recommendation: keep|change|investigate
---
```

## Recommendation Logic
- **KEEP**: best config == current, OR improvement < 1%
- **CHANGE**: best config != current AND improvement >= 1% (include exact code diff)
- **INVESTIGATE**: insufficient data or inconclusive metric

## Writing Style
- Lead with recommendation, not methodology
- Concrete numbers: "k=40 improves nDCG by 3.2%" not "lowering k helps"
- Exact code change for CHANGE recommendations
- Honest about limitations (circular ground truth, sparse data)

## File Structure
```
docs/research/
├── findings.md          # Executive summary
├── plans/{id}-plan.md   # Experiment plans
├── results/{id}-results.json  # Raw data
└── {id}-report.md       # Per-experiment reports
```

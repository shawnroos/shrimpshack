# E-PORTRAIT-IDENTITY — example judge-rubric experiment plan

> A worked template for a **rubric-judged** experiment — the kind `/nerd` and
> `/nerd-this` now admit alongside numeric-metric experiments. Copy this shape
> when an experiment's "better?" question is a judgment call (rendered images,
> prompts, model outputs) rather than a number. The rubric it references is
> `docs/research/examples/portrait-v3.yaml` (in a real project: `.nerd/rubrics/portrait-v3.yaml`).

```yaml
---
id: E-PORTRAIT-IDENTITY
instrument: judge_rubric          # <- routes this experiment through the judge-instrument gate, not the numeric path
rubric: portrait-v3               # library id -> .nerd/rubrics/portrait-v3.yaml (or an inline ./path)
judge: claude-opus-4-7            # optional; falls back to the rubric's default_judge
# Per-experiment anchor override (R8): if present, lab-tech uses these instead of the
# rubric's default_anchors for the fixture-pair and triangle checks. The library file is untouched.
anchors:
  good: docs/research/examples/fixtures/portrait/good.png
  bad: docs/research/examples/fixtures/portrait/bad.png
---
```

## Hypothesis
The reworked portrait pipeline preserves subject identity at least as well as the
baseline, without introducing face drift.

## Cells (sweep grid)
A small grid the judge scores cell-by-cell — e.g. 3 prompts × 2 seeds = 6 cells.
A single-commit `/nerd-this rubric:portrait-v3 commit:<sha>` brief is just a 1-cell grid.

| Dimension | Values |
|-----------|--------|
| prompt    | promptA, promptB, promptC |
| seed      | seed1, seed2 |

## What the instrument gate checks (lab-tech Check 3, before any cell runs)
1. **Hash-lock** — `portrait-v3.yaml` is hash-locked; an edit after first use forces a fork.
2. **Fixture-pair sensitivity** — the judge must separate `anchors.good` from `anchors.bad`
   by ≥ `min_anchor_separation` (1.0) on `subject_identity`.
3. **Triangle discriminability** — a blind 3-item test (N≥15, ≥80% correct and binomial
   p<0.05 against the 1/3 null), cached per (rubric_hash, judge) for `triangle_cache_days`.

If any check fails, the experiment is instrument-blocked — exactly like a numeric
experiment whose metric isn't sensitive.

## Pass condition
Per the rubric: `subject_identity` mean ≥ 4.0 AND `composition` mean ≥ 3.5 AND no cell
has `face_drift == true`. The executor rolls per-cell verdicts up into a single
PASS/FAIL, which report-compiler records as SUPPORTED/REFUTED on the DAG verdict node
with full provenance (rubric_id, rubric_hash, judge_id, triangle_verdict_id, criterion_scores).

See `docs/research/fixtures/dag-rubric-example.json` for the resulting DAG nodes.

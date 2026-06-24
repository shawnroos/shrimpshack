---
date: 2026-05-22
topic: non-numeric-judge-experiments
focus: how nerd should admit agent-judged / rubric-judged experiments without diluting U5 instrument-trust
mode: repo-grounded
---

# Ideation: Non-numeric judge experiments in nerd

## Grounding Context

### Codebase context
nerd is a prompt-driven Claude Code plugin (markdown agents/commands/skills + JSON schema, no executable source). The current branch `feat/nerd-feedback-improvements` just repositioned nerd as "execute any falsifiable experiment with a **trusted numeric metric**" (commits `e4e4439`, `b8b29c7`) — the numeric-metric bound was deliberately added as a bait-and-switch guard so U5's sensitivity gate (commit `a1449b2`) wouldn't BLOCKER experiments whose metric the harness can't auto-verify.

### Past learnings (from this repo's research corpus)
- `docs/research/plans/E017-E020-plan.md` (and `E001-E003`, `E004-E009`) already used **Criterion + Theory Tested + Pass Condition** tables — non-numeric rubric judgment, just unnamed.
- Arras `E-PROMPT-OPT-report.md` and `batch18-findings.md` use AC-A1/AC-B1/AC-C2 acceptance-criteria format for qualitatively-judged dimensions.
- The 207-node Arras DAG has **zero rubric/judge nodes in titles** — the structure is in plans/reports but invisible to cross-experiment memory.

### Scope nuance the original framing missed
The "LLM-as-judge too noisy" stance in `commands/nerd-loop.md:38,42,64` and `agents/parameter-scanner.md:138` is **scoped to iterative hill-climbing** (nerd-loop), not nerd overall. nerd-loop:42 verbatim: *"They work for one-shot analysis (as in `/nerd`) but not for iterative hill-climbing."* One-shot rubric eval in `/nerd` is **already endorsed implicitly**.

### Existence proofs in docs/feedback/
- `2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md`: 3×3×5 = 45-cell prompt sweep, LLM-judge on rendered images against pre-registered rubric ("subject-identity preservation 1–5, composition preservation 1–5, vibe-application 1–5, face drift binary; pass criteria <5% face drift; mean subject-identity ≥ 4.0"). Verdict: "Format C: subject 4.93, composition 5.00, vibe 5.00, ZERO leakage, ZERO face drift... Format A fails all gates." Worked. Nerd was never on the menu.
- `2026-05-15-slate-surface-gap-human-judge-sweep.md`: 4-variant audio sweep, QA engineers listening. Same shape, human judge.

### External grounding (web research, summarized)
- LLM-judge single-shot reliability is brittle (0.167–1.00 IRR across 100 seeds, arxiv 2412.12509).
- 8 named failure modes (JudgeBiasBench): position, verbosity, self-preference, family, recency, domain mismatch, single-shot evaluation, rubric-free absolute scoring. Frontier models fail >50% of bias tests.
- Calibration mechanisms with empirical backing: N≥3 sampling, score-before-rationale (G-Eval), few-shot anchor examples, logprob-weighted scoring, human spot-check gate <20-25% divergence.
- Pairwise + Bradley-Terry beats absolute Likert for ranking (MT-Bench, Chatbot Arena, Vibe-Eval) but has "Comparative Trap" failures (amplifies surface biases) and O(n²) cost.
- Cross-domain analogs: MUSHRA hidden reference (audio, ITU-R BS.1534), triangle test (wine, ISO 4120), psychophysics d-prime, PRISMA pre-registration, USP S1/S2/S3 tiered acceptance.

## Ranked Ideas

### 1. Judge-as-instrument: apply U5's sensitivity protocol to the judge

**Description:** Treat the "instrument" U5 already protects as referent-agnostic. `lab-tech.md` Check 3 already requests a known-good/known-bad fixture pair for semantic metrics — that text is verbatim correct for judges too. Add `instrument: numeric_metric | judge_rubric` to plans. For judges, fixture pair = (reference-good output, reference-bad output) tagged with expected verdicts. Sensitivity check = run judge N≥3 on both, require verdicts to split correctly. Same gate, generalized referent.

**Warrant:** `direct:` — `agents/lab-tech.md` Check 3 emits the exact SETUP-NEEDED message that already presupposes this generalization; commit `a1449b2` split mechanical vs semantic; this just extends "semantic" to admit judges. nerd's own `E-PROMPT-OPT-report.md` used this shape verbatim.

**Rationale:** No new trust machinery. Same gate, generalized. The smallest possible move that admits the workload. Closes the bait-and-switch the numeric-metric bound accidentally opened.

**Downsides:** Fixture pair catches content-axis flatness but doesn't catch position bias, family bias, or verbosity bias. Sufficient ground floor, not sufficient ceiling — needs Ideas 2 and 4 above it for bias-sensitive work.

**Confidence:** 90%
**Complexity:** Low
**Status:** Unexplored

---

### 2. Triangle-test admissibility gate (ISO 4120 forced-choice discriminability)

**Description:** Before any rubric scoring, the judge must pass an N-trial triangle test on a deliberately wide-quality pair: present {A,A,B} and {A,B,B} blind; judge picks odd one out. Pass if ≥80% correct (binomial p<0.05 at N≥10). Failure → BLOCKER. The rubric-mode analog of "metric must move under known perturbation" — the judge must demonstrate it can separate obvious-good from obvious-bad before its rubric scores are trusted.

**Warrant:** `external:` ISO 4120 (sensory science, validated for decades in wine/audio/fragrance); psychophysics d-prime literature for forced-choice discriminability.

**Rationale:** Catches the d-prime-collapse failure mode (judge scores everything 4.7–5.0 — high apparent accuracy, zero discrimination) before the sweep wastes tokens. Cheap (~10–20 judge calls). Layers cleanly on Idea 1.

**Downsides:** A judge can pass triangle by attending to a confound (longer text = "different" = picked) while failing on the real rubric dimension. Triangle proves separation of *something*, not of the right thing. Needs Idea 1 (content-correctness fixture) on top.

**Confidence:** 85%
**Complexity:** Low
**Status:** Unexplored

---

### 3. Rubric as first-class DAG node (and a citable rubric library)

**Description:** Add a `rubric_node` type to `schemas/dag-schema.json` carrying `criteria[]` (name, scale, anchors, pass_condition, theory_tag). Experiments cite a rubric by ID rather than redefining inline. Co-locate per-project rubrics in `.nerd/rubrics/` (versioned, frontmattered). nerd's own past work (E017-E020, E-PROMPT-OPT AC-A1/B1) already emitted these structures into markdown — they just don't compound.

**Warrant:** `direct:` from research-corpus grep — `docs/research/plans/E017-E020-plan.md` has `| Criterion | Theory Tested | Pass Condition |` tables that are exactly this shape; Arras `E-PROMPT-OPT-report.md` carries the AC-A1/B1/C2 pattern. The 207-node Arras DAG has zero rubric structure in node titles, so cross-experiment memory loses it today.

**Rationale:** The compounding move. Without it, every rubric experiment is greenfield. With it, the team accumulates calibrated rubric components — "the 1-5 subject-identity scale with face-drift binary worked across E-PROMPT-OPT and ai-pipeline-test; reuse those anchors."

**Downsides:** Schema bloat invites optionality abuse — agents will emit `rubric: {}` decoratively without anchor-validation actually running. Needs a hard "if `rubric_id` is set, judge must pass Ideas 1 + 2 gates" enforcement, not just a schema slot.

**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

---

### 4. Inter-rater agreement (Krippendorff α) as the trusted numeric metric

**Description:** Run N≥3 judges (different model families to defend against family bias). The "trusted numeric metric" U5 demands becomes **inter-rater concordance** (Krippendorff α or Cohen κ) across the runs. The rubric scores are quarantined unless concordance lands in a pre-registered band (e.g., 0.4 ≤ α ≤ 0.9 — too low = rubric ambiguous; too high = ceiling-effect / d-prime collapse). U5's spine works unchanged: concordance is auto-numeric and sensitivity-checkable.

**Warrant:** `external:` arxiv 2412.12509 (0.167–1.00 IRR variance across 100 seeds); MT-Bench/Chatbot Arena/Vibe-Eval all rely on multi-judge agreement. `reasoned:` — elevating concordance to *the metric* makes every rubric experiment legal under the existing numeric-metric spine without changing the spine.

**Rationale:** Cheapest path through the constraint — no schema change strictly required, just a convention. Eliminates a class of false-confidence verdicts at the source. Pairs naturally with Ideas 1 and 3.

**Downsides:** 3× judge cost. High α can coexist with shared bias (all judges biased the same way → high α but wrong) — concordance is necessary but not sufficient; still needs Idea 1's fixture-pair check.

**Confidence:** 80%
**Complexity:** Medium
**Status:** Unexplored

---

### 5. Pre-registration: rubric content-hashed before any judging starts

**Description:** Every rubric experiment must commit `rubric.yaml` (Idea 3) BEFORE any cell is scored. Hash the file, record `rubric_hash` + `signed_at` on the DAG node. Any post-judging edit creates a new experiment, not an amendment. Reports surface `pre_registered: true/false` prominently. The rubric-experiment analog of "verify the instrument before trusting it" — prevents the most damning critique of LLM-judge work, that the rubric was reverse-engineered from results.

**Warrant:** `external:` PRISMA 2020, Cochrane Handbook §3.1.5, ClinicalTrials.gov pre-registration; Kaplan & Irvin 2015 (pre-registered trials report null results at much higher rates). `direct:` — nerd's `E017-E020` already pre-declares theories and acceptance criteria; formalizing this closes an existing gap.

**Rationale:** Prevents the most insidious rubric failure: tuning the rubric until you like the answer. Cheap to enforce (hashing). Layers cleanly on Idea 3.

**Downsides:** Doesn't prevent *pre*-experiment rubric shopping (try 5 rubrics on a pilot, register the favorable one). Mitigation: pilot data itself must be timestamped on the DAG. Adds friction for exploratory work — for cheap `/nerd-this` one-shots the overhead may exceed value.

**Confidence:** 75%
**Complexity:** Low
**Status:** Unexplored

---

### 6. Downstream behavior probe: convert judge experiments to numeric when possible

**Description:** Before defaulting to a rubric, check whether the artifact has a *downstream observable* — a measurable consequence in the next agent/system. A prompt produces code (run it, count test failures). An image goes into a layout (does the layout-agent place it correctly?). A spec is followed by an agent (compliance rate). When a downstream exists, route the experiment through it instead of through a judge — the verdict becomes numeric again, U5 applies unchanged.

**Warrant:** `direct:` from the harvest's existence proof — the Format C verdict's most decisive criteria were *"ZERO leakage, ZERO face drift"*: binary downstream counts, not rubric judgments. `reasoned:` — non-numeric metrics often exist only because we stopped looking downstream.

**Rationale:** Preserves U5 *untouched* for the broadest slice. Doesn't replace Ideas 1–5; sits *before* them in routing as the "can we avoid the judge entirely?" question.

**Downsides:** Many experiments don't have a clean downstream — the artifact IS the product (poems, music, brand). Those still need Ideas 1–5. Also: downstream probing can add latency.

**Confidence:** 70%
**Complexity:** Low–Medium
**Status:** Unexplored

---

## The clean stack

**Ideas 1 + 2 + 3 + 5** form a coherent minimum spine for admitting agent-judged experiments:
- **1** is the U5 generalization (fixture pair → judge sensitivity)
- **2** is the cheap discriminability prerequisite (triangle test)
- **3** is the structural memory (rubric as a DAG citizen + library)
- **5** is the falsifiability discipline (pre-register the rubric)

**Idea 4** raises the ceiling for high-stakes work (multi-judge ensemble + α gate). **Idea 6** widens the entry by routing numeric-in-disguise experiments away from the judge entirely.

**Scope guardrail:** none of these lift the `nerd-loop` LLM-as-judge ban. The literature is clear that single-shot LLM judges have too much variance for hill-climbing iteration. These are *one-shot batch* admissions only — the repositioning stays scope-correct.

## Rejection Summary

| # | Idea | Reason rejected |
|---|------|-----------------|
| 1 | Forbid LLM-judge in nerd-loop (formal hard precondition) | Already exists in prose; refactor not a capability change. Below the meeting-test floor. |
| 2 | Auto-derive rubric from hypothesis | Promising but speculative — overlaps with Idea 3; brainstorm later if Idea 3 ships. |
| 3 | Verdict caching (judge once, reuse) | Compounding payoff, but covered indirectly by Idea 3 (rubric+verdict library) — a follow-up enhancement, not a top-6 lever. |
| 4 | Binary constraint satisfaction (drop Likert entirely) | Strong but overlaps with Format C precedent's downstream metrics (Idea 6) and Idea 1's fixture-pair shape. Worth a brainstorm if Idea 1 ships. |
| 5 | Pairwise + Bradley-Terry | Real prior art (MT-Bench, Chatbot Arena) but O(n²) scaling kills it at 45-cell sweep size; "Comparative Trap" amplifies surface biases. Better as opt-in for small-N close-call rankings — defer. |
| 6 | Pairwise→pointwise anchoring hybrid | Clever but speculative; needs Idea 4's ensemble groundwork first. |
| 7 | Figure-skating trimmed mean + rogue-judge audit | Variant of Idea 4; Krippendorff α is the cleaner gate. |
| 8 | ACE-V blind verification | Variant of Idea 4; ensemble divergence captures the property without forcing strict invocation isolation. |
| 9 | USP S1/S2/S3 tiered acceptance | Useful escalation protocol but premature — get base gates working first. |
| 10 | Pharma A-A test-retest consistency | Subset of Idea 1's "judge runs N≥3 on identical input." |
| 11 | WADA B-sample (decision-critical cells doubled) | Cost-aware variant of Idea 4; the cost optimization can wait. |
| 12 | Diving DD × execution multiplier | Pre-rating difficulty needs an out-of-band oracle; introduces a tunable that re-opens post-hoc bias. Defer. |
| 13 | SCAA cupping pre-flight calibration | Cross-domain inspiration for Idea 1 but the LLM analog assumes shared sensory ground truth that doesn't exist across model families. |
| 14 | Judge-as-versioned-artifact registry | Strongest cross-experiment compounding move but presupposes Ideas 1+3+4 are in place. Promote later. |
| 15 | Rubric library with `used_in` back-refs | Folded into Idea 3. |
| 16 | Gold-fixture library (shared `.nerd/fixtures/`) | Folded into Idea 1's evolution. |
| 17 | Score-before-rationale + N≥3 default | Folded into Idea 4. |
| 18 | Judge-promotion ladder (tier-by-accrual) | Strong compounding move but premature without Ideas 3 + 5. Promote after first batch ships. |

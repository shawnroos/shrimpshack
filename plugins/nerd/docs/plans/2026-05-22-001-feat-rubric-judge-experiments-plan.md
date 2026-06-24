---
title: "feat: admit rubric-judged experiments to /nerd via judge-as-instrument gate"
type: feat
status: completed
date: 2026-05-22
deepened: 2026-06-23
origin: docs/brainstorms/2026-05-22-non-numeric-judge-experiments-requirements.md
---

# feat: admit rubric-judged experiments to /nerd via judge-as-instrument gate

## Overview

The prior plan (`docs/plans/2026-05-21-001-feat-nerd-feedback-driven-improvements-plan.md`, shipped on `feat/nerd-feedback-improvements`) repositioned nerd as "any falsifiable experiment with a *trusted numeric metric*." The numeric-metric bound was deliberately added as a bait-and-switch guard so the U5 sensitivity gate (commit `a1449b2`) wouldn't BLOCKER experiments whose metric the harness can't auto-verify.

This plan admits **rubric-judged experiments** (LLM-judge against a pre-registered rubric) to `/nerd` and `/nerd-this` one-shot batches through a *parallel* trust gate that is at least as strict as the numeric U5 — without diluting U5 itself and without lifting the `nerd-loop` LLM-as-judge ban. The Format C precedent in `docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md` (3×3×5 = 45-cell sweep with a pre-registered rubric that produced a definitive verdict) is the existence proof; nerd's own `docs/research/plans/E017-E020-plan.md` already uses the same `Criterion / Theory Tested / Pass Condition` shape unnamed.

The implementation is six units: lab-tech gains a judge-instrument pre-flight (hash-lock + fixture-pair sensitivity + cached triangle-test); the DAG schema gets a `rubric_node` type; report-compiler emits rubric provenance on verdict nodes; nerd.md Phase 2c routes `instrument: judge_rubric` as a fourth classification; nerd-this brief mode admits a `rubric:` parameter; experiment-executor learns to invoke a judge against a rubric instead of running a numeric metric command. No file renames, no `subagent_type=` changes — prose + schema editing only.

> **Reconciliation note (2026-06-23):** A deepening pass verified every cited anchor against current (post-PR-#3) file state. All line numbers match (the plan was authored after PR #3 landed). One structural correction was integrated: the cross-session read path for `rubric_hash` and cached triangle verdicts is routed through the **orchestrator's** DAG→filtered-markdown injection (the mechanism the architecture doc actually describes), not through a "per-experiment markdown summary emitted by report-compiler" — that surface does not exist today. report-compiler does not read lab-readiness reports today; U4 adds that read as new plumbing. Correspondingly, U3 owns the orchestrator-side filtered-markdown injection (Phase 4.5) and the `phase=build` skip for rubric experiments, reusing the existing `has_harness: true` skip-build precedent at `commands/nerd.md:411`.

---

## Problem Frame

Carried from origin: a meaningful share of real workload is rubric-judged sweeps (rendered images, prompts, model outputs) that the recent reposition's numeric-metric bound currently excludes. Agents who hit this either hand-build a parallel skill (the `/ai-pipeline-test` precedent in the ai-service-hub worktree) or run experiments outside nerd entirely (the Slate audio QA-listening case in `docs/feedback/2026-05-15-slate-surface-gap-human-judge-sweep.md`). nerd ceded territory it was structurally able to claim. This plan claims it for LLM-judge substrates with the same instrument-trust rigor numeric experiments earn through U5.

(see origin: `docs/brainstorms/2026-05-22-non-numeric-judge-experiments-requirements.md` — Problem Frame.)

---

## Requirements Trace

- R1. Fixture-pair sensitivity check (lab-tech)
- R2. Triangle-test admissibility gate, cached per `(rubric_hash, judge_id)` for 30 days
- R3. `rubric_node` type in DAG schema
- R4. Verdict nodes carry rubric provenance (`rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id`, per-criterion scores)
- R5. Strict pre-registration: rubric content-hashed before first judge call; post-judge edits require fork
- R6. Phase 2c routes `instrument: judge_rubric` as a fourth classification
- R7. Rubric library at `.nerd/rubrics/<rubric-id>.yaml` with frontmatter and defaults
- R8. Per-experiment anchor override of library rubric
- R9. `/nerd-this` brief mode admits `rubric:` parameter (both library-id and inline-file paths)
- R10. `nerd-loop` LLM-as-judge ban unchanged (verification, not implementation)

(Note: the structural prerequisites for R4 — verdict nodes carrying per-criterion scores — span three units: U2 admits the schema fields, U6 produces them at execution time, U4 emits them on report. Each unit's Requirements line names which slice it owns.)

**Origin actors:** A1 (experiment author), A2 (lab-tech agent), A3 (nerd orchestrator), A4 (experiment-executor), A5 (report-compiler)
**Origin flows:** F1 (rubric experiment pre-flight — load-bearing), F2 (rubric experiment execution and verdict), F3 (rubric reuse from the library)
**Origin acceptance examples:** AE1 (anchors missing), AE2 (judge instrument insensitive), AE3 (triangle cache hit), AE4 (triangle cache miss → run + persist), AE5 (rubric hash mismatch refuses to resume), AE6 (verdict node carries full provenance)

---

## Scope Boundaries

- **Out: ensemble + Krippendorff α** (Idea 4 from the ideation doc — multi-judge agreement gate). Future increment after v1 ships and we know whether single-judge + fixture-pair + triangle is sufficient floor.
- **Out: downstream behavior probe** (Idea 6 — route numeric-in-disguise experiments past the judge entirely). Sits *before* this spine in the experiment-design pipeline; separate brainstorm.
- **Out: `nerd-loop` integration.** The LLM-as-judge ban at `commands/nerd-loop.md:38,42,64` is correct and stays. This plan admits rubric experiments to `/nerd` and `/nerd-this` one-shot batches only.
- **Out: human-judge mode.** The Slate audio QA-listening case (`docs/feedback/2026-05-15-slate-surface-gap-human-judge-sweep.md`) is real workload but has materially different ergonomics (asynchronous, file-based review surface). Carved out for a v2 brainstorm. The `instrument: judge_rubric` field is substrate-agnostic by design (it admits a future `kind: human` variant) but v1 implementation is `kind: llm` only.
- **Out: automatic rubric synthesis.** Rubric authoring is human-in-the-loop in v1. lab-tech does not generate candidate rubrics from the hypothesis.
- **Out: rubric versioning beyond hash.** A rubric's `version:` field is informational metadata in v1. No migration, no compatibility check, no auto-bumping. Substantive change → fork to new `rubric_id`.
- **Out: in-band rubric amendments.** Strict mode only: hash-lock at first judge call, fork-for-edit. A future `--allow-amendment 'reason: ...'` flag is v2 if strict mode proves too painful.
- **Out: pairwise + Bradley-Terry as a judge protocol.** The Likert+rubric path is what v1 ships. Pairwise is a separate increment for close-call rankings.

---

## Context & Research

### Relevant Code and Patterns

- **`agents/lab-tech.md` Check 3** (recently extended in commit `a1449b2`, sensitivity-smoke subsection at ~lines 141-158): emits `has_harness` per experiment; classifies metrics as *mechanical* (auto-perturb sensitivity check) vs *semantic* (request known-good/known-bad fixture pair via `[SETUP NEEDED]`); uses `[OK]/[FIXED]/[BLOCKER]/[SETUP NEEDED]` vocabulary. The judge-instrument gate is a *parallel application* of the same gate, same vocabulary, same per-experiment readiness block shape.
- **`agents/lab-tech.md` `## Output` section** (starts ~line 348, runs to ~line 420): frontmatter fields `checked_at`, `experiments_checked`, `status`, `has_harness` per-experiment. The plan adds rubric-specific fields per experiment: `rubric_hash`, `triangle_verdict_id`, `instrument_kind`.
- **`schemas/dag-schema.json` `research_type` enum** (extended in `b8b29c7` and `71f257c`): currently `["parameter","performance","experiment","hypothesis"]`. Rubric experiments use `"experiment"` — no new enum value is needed; the rubric structure lives on a new `rubric_node` type, not on `research_type`.
- **`schemas/dag-schema.json` existing node types**: `theory_node`, `verdict_node`, `synthesis_node`, `build_profile_node`, `cache_verdict_node`, `tool_availability_node`. The new `rubric_node` follows the same shape (id pattern, type discriminator, created_at, status). The new `triangle_verdict_node` is a sibling of `cache_verdict_node` (same role: a calibration verdict cached per-pair that gates downstream work).
- **`agents/report-compiler.md` theory-node template** (lines ~176-188, extended in `b8b29c7`): currently emits `id, type, title, source_experiment, source_files, codebase_hash, created_at, status, research_type, tags`. Rubric experiments need `rubric_id, rubric_hash, judge_id, triangle_verdict_id` plus per-criterion scores on the *verdict* node — same emit path, more fields conditional on `instrument_kind: judge_rubric`.
- **`commands/nerd.md` Phase 2c** (extended in commit `a1449b2`): classification currently splits findings into *experimentable (provisional)*, *analytical*, and *instrument-blocked* (the latter assigned by lab-tech, not at scan time). R6 adds a fourth: *rubric-judged* — also assigned at the plan level, not at scan time, since rubric mode is declared explicitly by the experiment author.
- **`commands/nerd-this.md` Brief Mode Detection** (added in commit `71f257c`, lines ~16-40): parses `commit:<ref>` and `hypothesis:<statement>` prefixes from `$ARGUMENTS` using the same precedent as `commands/nerd-intern.md:12`. R9 adds `rubric:<id-or-path>` — same parsing pattern, value-suffix detection: bare name → library lookup at `.nerd/rubrics/<name>.yaml`; path starting with `./` or containing `/` → inline file path.
- **Existing rubric prior art (informs Idea 3's structure):**
  - `docs/research/plans/E017-E020-plan.md`: `| Criterion | Theory Tested | Pass Condition |` tables (lines 72, 176, 272, 380). The `theory_tag` field on `rubric_node.criteria[]` mirrors the "Theory Tested" column directly.
  - Arras `docs/research/E-PROMPT-OPT-report.md` and `batch18-findings.md`: `AC-A1/AC-B1/AC-C2` format with pass/fail conditions per acceptance criterion. The `pass_condition` field on `rubric_node.criteria[]` is the structural carrier.
- **Config file precedent**: `.claude/nerd.local.md` uses YAML frontmatter + structured body (`backlog:` array, `intern:` block). `.nerd/rubrics/<id>.yaml` is a **pure-YAML file (not markdown with `---` frontmatter)** — the entire file is one YAML document with a metadata block at top (id, version, created_at, used_in, default_judge, triangle_cache_days) and structured sections below (criteria, min_anchor_separation, default_anchors). Pure-YAML is right because rubrics are read by lab-tech for structured fields, not by humans for prose. Terminology note for the implementer: where this plan and downstream prose say "frontmatter" in the context of a rubric file, read it as "top-of-file metadata keys" — a YAML convention, not the markdown `---` separator.

### Institutional Learnings

- **`docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`** — DAG invariants to preserve: (a) orchestrator-mediated reads (filtered markdown, not raw JSON), (b) single-writer-per-file (only `report-compiler` and `loop-scout` write today; the new `rubric_node` and `triangle_verdict_node` are written by `report-compiler` as part of pre-flight, not by `lab-tech` directly), (c) crash-safe atomic writes, (d) INCONCLUSIVE creates no `supports`/`refutes` edge. **Integration concern flagged for U1**: lab-tech's hash-mismatch check needs to read the *prior run's* `rubric_hash` from the DAG node — the architecture doc says agents get filtered markdown from the DAG, so the hash needs to surface in that filtered view, not require lab-tech to parse JSON directly. Resolution (2026-06-23 reconciliation): report-compiler **writes** `rubric_hash`/`rubric_node` to the DAG (U4); the **orchestrator** renders the filtered-markdown view and injects it into lab-tech's Phase 4.5 pre-flight context (U3) — there is no pre-existing "report-compiler per-experiment markdown summary" to extend, and report-compiler does not read lab-readiness reports today (the orchestrator does, at Phase 6c).
- **`docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`** — "different intent → own entry point" precedent. **Already addressed in the brainstorm**: rubric mode is a *native* `/nerd-this` brief parameter (R9), not a separate command, because the brainstorm's Key Decisions establish that a single-commit rubric test is a *central case* of nerd's repositioned identity, not a different intent. The precedent doesn't apply against R9.
- **Prior plan's review** (`feat: nerd feedback-driven improvements`) — surfaced that test scenarios in a prompt-only plugin are verification procedures, not unit tests. Same convention applies here: every unit's test scenarios are "does the reworded prose read coherently to a reader? does the BLOCKER fire on a deliberately-broken fixture? does a schema validation accept/reject the right shapes?"

### External References

No external research dispatched — the calibration literature (LLM-judge reliability, triangle tests, MUSHRA, PRISMA pre-registration) was already consolidated in the ideation doc's grounding (`docs/ideation/2026-05-22-non-numeric-judge-experiments-ideation.md`, §"External grounding"). All structural decisions were made against that grounding and the brainstorm's Key Decisions. The plan does not introduce new external dependencies.

---

## Key Technical Decisions

- **One unit for all `lab-tech` Check 3 additions (U1)**, not separate units per R1/R2/R5. The hash-lock, fixture-pair, and triangle gates all land in the same Check, share BLOCKER vocabulary, and fire in a fixed sequence (hash → fixture → triangle). Splitting them creates artificial commit boundaries and fights atomic-commit principles.
- **`rubric_node` and `triangle_verdict_node` are sibling nodes to existing DAG types**, not extensions to `theory_node`. Rationale: a rubric is reusable across experiments (cited by `rubric_id`), and a triangle verdict caches per-`(rubric_hash, judge_id)` and survives independently of any single experiment. Embedding them on `theory_node` would force rubric-experiments to duplicate the rubric structure per theory.
- **`rubric_node` lives ONLY in the DAG; the YAML library file is the source of truth.** When an experiment cites `rubric_id: portrait-v3`, lab-tech reads `.nerd/rubrics/portrait-v3.yaml`, computes its content hash, and persists a `rubric_node` reference with `id`, `version`, `content_hash`, `source_path` — but not the full criteria. The DAG references the library file; the library file is the authoritative content. This avoids DAG bloat and keeps rubrics editable as files (subject to R5's strict hash-lock semantics after first use).
  - **Explicit deviation from R3:** the brainstorm's R3 literally says `rubric_node` carries `criteria[]` inline. This plan refines "carries" to mean "carries a content-hash reference to the criteria, whose authoritative source is the YAML library file." Rationale: rubrics are reusable across experiments (a single `portrait-v3` may be cited by 30 experiments), and `criteria[]` is structured but stable — embedding it on every `rubric_node` instance creates DAG bloat and a second source of truth that can diverge from the YAML file. The content-hash makes the reference cryptographically tight: any criteria change forces a new `content_hash`, which by R5 forces a fork to a new `rubric_id`. The criteria's *content* is therefore preserved in `.nerd/rubrics/<id>.yaml` (the source of truth) and *referenced* in the DAG (by hash); the brainstorm's intent — verdict nodes are queryable for the exact criteria used — holds.
- **`instrument: judge_rubric` is an explicit top-level plan field** (carried from brainstorm Key Decisions). Phase 2c branches on this field; lab-tech routes to the judge-instrument gate when set; report-compiler conditionally emits the rubric provenance fields. Composes cleanly with a future `kind: human` variant.
- **`rubric:` brief parameter accepts both library-id and inline-file-path** (resolves origin Deferred Question 4). Detection: value contains `/` or starts with `./` → inline file path; otherwise → library lookup at `.nerd/rubrics/<value>.yaml`. Mirrors how command-line tools commonly disambiguate library names from paths (npm, gem, etc).
- **Triangle cache freshness window: 30 days, configurable per rubric** (resolves Deferred Question 3). Rubric YAML carries optional `triangle_cache_days: <int>`, default 30 if absent. The 30-day default is a starting heuristic — frontier model versions are usually stable inside a 30-day window, but the field exists so it can be tightened per rubric if a particular `(rubric, judge)` combo proves drifty in practice.
- **Triangle prompt template structure, not exact wording** (resolves Deferred Question 2). The plan specifies the *shape* (blind three-item presentation; the judge sees stimuli labeled A/B/C in random order; the prompt asks "Which of A, B, C is most different on `<headline_criterion>`?"; the judge returns a single letter). The exact prompt copy is a `Deferred to Implementation` item — the right wording emerges from writing it against real anchor fixtures and is implementation-time discovery, not planning-time.
- **No CLI helper for "fork to new experiment ID"** (resolves Deferred Question 5). The hash-mismatch BLOCKER message includes a one-line fix instruction (*"Copy `.nerd/rubrics/<id>.yaml` to a new id, edit, and re-run with `rubric:<new-id>`"*). A `nerd-fork-rubric` helper is v2 if the manual flow proves frictional.
- **Report-compiler emits rubric-experiment fields conditionally on `instrument_kind`** (resolves Deferred Question 6). Existing emit path is extended, not duplicated. When `instrument_kind: judge_rubric`, the verdict node gains `rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id`, and `criterion_scores: {<criterion_name>: <value>}`. Numeric experiments are untouched.
- **R10 ("nerd-loop unchanged") is not a unit.** It's a verification step in the System-Wide Impact section: a grep across the changed files confirms no edits to `commands/nerd-loop.md`'s LLM-as-judge ban prose. No implementation work.

---

## Open Questions

### Resolved During Planning

- *Yaml shape for `.nerd/rubrics/<id>.yaml`?* → Pure-YAML file (no markdown `---` separator). Top-of-file metadata keys: `id`, `version`, `created_at`, `created_by`, `used_in`, `default_judge`, `triangle_cache_days`. Lower body keys: `criteria:`, `min_anchor_separation:`, `default_anchors:`. Inspired by `.claude/nerd.local.md`'s metadata-then-structured-body precedent, but pure YAML rather than markdown-with-frontmatter. See U2 Approach and U5 Approach.
- *Inline-rubric vs library-only for the `rubric:` brief parameter?* → Both. Detection by path-vs-bare-name. See U5 Approach.
- *30-day cache freshness window valid?* → Default 30, configurable per rubric via `triangle_cache_days:`. See Key Decisions.
- *"Fork to new experiment ID" affordance?* → Hash-mismatch BLOCKER includes a one-line manual-fork instruction. No CLI helper in v1. See U1 Approach.
- *How does report-compiler currently route theory vs verdict nodes?* → Same emit path, new fields conditional on `instrument_kind`. See U4 Approach.
- *Canonical triangle-test prompt template?* → Structure specified (blind 3-item, headline-criterion question, single-letter answer); exact wording deferred to implementation. See U1 Approach.

### Deferred to Implementation

- **Exact triangle prompt copy.** The right wording emerges from writing it against real anchor fixtures; planning specifies the structural contract only.
- **Whether `created_by` in rubric frontmatter is captured automatically.** Trivial implementation detail; either `$USER` at write time or left to the author. Resolve when writing the first rubric.
- **Whether judge-side temperature/seed should be fixed in the rubric YAML.** Determinism affects the sensitivity check's reliability. Best resolved by trying the gate with a few real judges and seeing the variance — implementation discovery.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

The judge-instrument gate is a fourth Phase 2c classification that routes through a parallel lab-tech check before joining the existing executor/report path:

```
Author writes plan ──────► commands/nerd.md or commands/nerd-this.md
   instrument: judge_rubric
   rubric: <id>|<path>           │
                                 ▼
                       Phase 2c classification
                                 │
       ┌─────────────────────────┼─────────────────────────────────┐
       │                         │                                 │
       ▼                         ▼                                 ▼
  experimentable           analytical                       rubric-judged   ◄── new
  (numeric U5)             (no execution)                  (judge-instrument gate)
       │                                                          │
       │                                                          ▼
       │                                              agents/lab-tech.md Check 3
       │                                              ┌───────────────────────┐
       │                                              │ 1. Hash-lock check    │
       │                                              │    (R5: prior hash    │
       │                                              │     from DAG vs file) │
       │                                              │ 2. Fixture-pair       │
       │                                              │    sensitivity (R1)   │
       │                                              │ 3. Triangle gate      │
       │                                              │    (R2: cache or run) │
       │                                              └───────────┬───────────┘
       │                                                          │
       │                                            BLOCKER ◄─┬───┴───┐ ► [OK]
       │                                                     │       │
       │                                                  failure   pass
       │                                                          │
       │              ┌───────────────────────────────────────────┘
       ▼              ▼
   agents/experiment-executor.md  (numeric branch unchanged;
                                   rubric branch added by U6:
                                   invoke judge per cell with rubric
                                   prompt, evaluate pass_condition)
                                              │
                                              ▼
                                   agents/report-compiler.md
                                   emits theory + verdict nodes
                                   (numeric experiments untouched;
                                    rubric experiments gain rubric_id,
                                    rubric_hash, judge_id,
                                    triangle_verdict_id, criterion_scores)
                                              │
                                              ▼
                                   schemas/dag-schema.json
                                   ┌──────────────────────────┐
                                   │ theory_node    (existing) │
                                   │ verdict_node   (existing, │
                                   │   + new fields)           │
                                   │ rubric_node    ◄── new   │
                                   │ triangle_verdict_node     │
                                   │   ◄── new (sibling of    │
                                   │   cache_verdict)         │
                                   │ (other types unchanged)  │
                                   └──────────────────────────┘
```

The shape mirrors the numeric U5 path exactly — same Phase 2c branching, same lab-tech `[OK]/[BLOCKER]` vocabulary, same executor and report-compiler files (with conditional branches added). The structural additions are: the two new DAG node types (U2), the conditional emit fields on verdict nodes (U4), and the parallel judge-rubric execution branch in the executor (U6). Numeric experiments traverse the unchanged path.

---

## Implementation Units

- U1. **lab-tech judge-instrument pre-flight (hash-lock + fixture-pair + cached triangle)**

**Goal:** Add a judge-instrument gate to `agents/lab-tech.md` Check 3 that runs three sequential sub-checks for any experiment with `instrument: judge_rubric`: (1) verify the rubric is hash-locked and matches the DAG's prior hash if any (R5); (2) run the declared judge N≥3 times on the `anchors: {good, bad}` pair and verify verdicts split by ≥`min_anchor_separation` on the headline criterion (R1); (3) consult the DAG for a cached `triangle_verdict_node` for `(rubric_hash, judge_id)` within the configured freshness window — if present and PASS, skip; if missing/expired/FAIL, run the triangle test and persist verdict (R2). All failures use the existing `[OK]/[BLOCKER]/[SETUP NEEDED]` vocabulary.

**Requirements:** R1, R2, R5

**Dependencies:** U2 (schema must define `rubric_node` and `triangle_verdict_node` before lab-tech can reference them in its readiness output). Soft-deps U3 (the cross-session reads in this unit — prior `rubric_hash` and cached triangle verdicts — arrive via the orchestrator's filtered-markdown injection, which U3 adds at `commands/nerd.md` Phase 4.5) and U4 (report-compiler writes the durable `rubric_node`/`triangle_verdict_node` the orchestrator reads back into that markdown). First-time runs don't need either; the cross-session round-trip does.

**Files:**
- Modify: `agents/lab-tech.md` (Check 3 section sensitivity-smoke subsection at ~lines 141-158, add a parallel judge-instrument subsection right after; `## Output` section starting at ~line 348 — add per-experiment `instrument_kind`, `rubric_hash`, `triangle_verdict_id` fields to the per-experiment block format around ~line 380)

**Approach:**
- The three sub-checks fire in fixed order; the first failure short-circuits with a specific BLOCKER message. Sequence: hash-lock → fixture-pair → triangle. Rationale: hash-lock is cheapest (file read + compare); fixture-pair is medium (N=6 judge calls); triangle is most expensive (N≥10 judge calls). Cheapest-first short-circuit minimizes waste on broken rubrics.
- **Hash-lock check (R5):** if the experiment was previously run, lab-tech receives the prior `rubric_hash` via the orchestrator-injected filtered-markdown block (the same mechanism as the triangle-cache read below, sourced from the DAG's `rubric_node`/verdict provenance and produced by U3 at `commands/nerd.md` Phase 4.5 — **not** by parsing raw DAG JSON, per the architecture doc). Compare the recorded hash against the current `.nerd/rubrics/<id>.yaml` content hash. Mismatch → `[BLOCKER] rubric_hash_mismatch: rubric "<id>" was hash-locked at signed_at <ts> with hash <old>; current hash is <new>. Copy .nerd/rubrics/<id>.yaml to a new id, edit, and re-run with rubric:<new-id> — there is no in-band amendment.` First-time runs: compute and persist hash, emit `signed_at`.
- **Fixture-pair sensitivity check (R1):** load `anchors: {good, bad}` from the experiment plan (preferred) or rubric defaults (fallback per R8). Missing both → `[BLOCKER] anchors_missing: rubric "<id>" must declare anchors.good and anchors.bad with min_anchor_separation. See agents/lab-tech.md Check 3.` Run the judge N≥3 on each anchor; compute mean score on the rubric's headline criterion. If `mean(good) - mean(bad) < min_anchor_separation` → `[BLOCKER] judge_instrument_insensitive: <judge_id> separated anchors by <delta> on <headline_criterion>, expected ≥<threshold>. The judge cannot discriminate this rubric's good/bad cases — refine the rubric anchors or use a more capable judge.`
- **Triangle gate (R2):** before running, consult the DAG for a `triangle_verdict_node` matching `(rubric_hash, judge_id)`. **Read path** (honoring the architecture-decisions filtered-markdown rule): the orchestrator pre-loads a filtered-markdown view of triangle verdicts into lab-tech's invocation context — a small block such as `Triangle verdicts on file: (rubric_hash=abc1234..., judge=claude-opus-4-7) PASS 13/15 verified 2026-05-12; (rubric_hash=def5678..., judge=claude-opus-4-7) FAIL 6/15 verified 2026-04-30`. U3's Approach extends the orchestrator (`commands/nerd.md` Phase 4.5) to generate this filtered triangle-verdict block from the DAG and inject it into lab-tech's pre-flight context — the orchestrator-owned DAG→filtered-markdown mechanism the architecture doc describes. report-compiler's role (U4) is only to *write* the underlying `triangle_verdict_node` to the DAG; the orchestrator reads it back into markdown. Cache hit AND status=PASS AND `verified_at` within `triangle_cache_days` → emit `[OK] triangle cached (verified <date>, <correct>/<total> trials)` and skip. Cache hit AND status=FAIL → `[BLOCKER] judge_fails_triangle_discriminability` (cached). Cache miss or expired → run the triangle: generate N≥10 trials, half {good,good,bad} half {good,bad,bad}, shuffle order, prompt judge per the structural template (see Key Decisions), check ≥80% correct identification (binomial p<0.05).
- **Triangle verdict persistence path:** lab-tech does NOT write the DAG directly (single-writer invariant: only report-compiler and loop-scout write). When a fresh triangle test runs, lab-tech emits the verdict into its readiness report (`docs/research/lab-readiness-*.md`) as a structured block (`triangle_verdict: { rubric_hash: <sha>, judge_id: <id>, correct_count: <n>, total_trials: <n>, status: <PASS|FAIL>, verified_at: <ISO> }`); report-compiler reads the readiness report at batch-end and writes the `triangle_verdict_node` to the DAG. **This is a new read path for report-compiler** — today report-compiler reads raw results, experiment plans, and backlog entries (not lab-readiness reports); the orchestrator is what reads `has_harness` from lab-readiness at `commands/nerd.md` Phase 6c. U4 adds report-compiler's readiness read. This keeps lab-tech as a markdown producer and report-compiler as the sole DAG writer.
- **Integration concern (flagged from learnings, corrected in the 2026-06-23 reconciliation):** the DAG read path in step 1 (hash-lock) must use the filtered-markdown convention from `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`, not raw JSON. There is **no existing "per-experiment markdown summary emitted by report-compiler" to extend** — that surface does not exist today. Two responsibilities, two units: **U4** = report-compiler writes `rubric_hash`/`triangle_verdict_id` into the DAG (durable); **U3** = the orchestrator (`commands/nerd.md` Phase 4.5) generates the filtered-markdown block from the DAG and injects it into lab-tech's pre-flight context. lab-tech (this unit) reads only that injected block.
- The U5 (numeric) sensitivity check and the new judge-instrument gate are *parallel* — never both run on the same experiment. Phase 2c routing (U3) selects exactly one.

**Patterns to follow:**
- `agents/lab-tech.md` Check 3 existing structure: mechanical-vs-semantic metric classification, the `[OK]/[BLOCKER]/[SETUP NEEDED]` verbs, the `## Output` per-experiment block format (`### E001: {title} — READY`, status lines with `[OK]` or `[BLOCKER]` prefixes, frontmatter fields).
- `agents/lab-tech.md` Check 8b "Determinism Validation" (starts ~line 452): run-metric-N-times pattern. The fixture-pair sensitivity check borrows this structural pattern (mirror its mechanics, invert its assertion — same code different inputs vs different inputs different outputs).
- The cached-verdict pattern in `cache_verdict_node` (schema) — `triangle_verdict_node` is its structural twin for judge calibration.

**Test scenarios:**
- Happy path: experiment plan declares `instrument: judge_rubric`, rubric file exists, anchors declared inline, judge separates them by 1.2 on headline criterion (threshold 1.0). lab-tech emits `[OK]` and runs triangle (no cache hit on first use). Triangle passes 13/15. Verdict persisted; experiment proceeds to executor.
- Edge case (cache hit): same experiment re-run 7 days later. Hash matches prior; triangle cache hit → skip; only fixture-pair runs. `[OK] triangle cached (verified <date>, 13/15 trials)`. Covers AE3.
- Edge case (cache expired): same experiment re-run 35 days later (default 30-day window). Cache miss-by-staleness → re-run triangle. New `triangle_verdict_node` persisted with fresh `verified_at`.
- Error path (anchors missing): plan omits `anchors:`, rubric defaults also absent. Pre-flight emits `[BLOCKER] anchors_missing: ...` and the experiment does NOT proceed to executor. Covers AE1.
- Error path (judge insensitive): judge scores `good_anchor: 4.6, bad_anchor: 4.5` (separation 0.1, below 1.0 threshold). `[BLOCKER] judge_instrument_insensitive: ...` with observed values. Covers AE2.
- Error path (triangle fail): judge identifies odd item 6/15 trials (40%, p>0.05 — chance). `[BLOCKER] judge_fails_triangle_discriminability`. Persist FAIL verdict (so subsequent runs short-circuit on cache hit until rubric or judge changes).
- Error path (hash mismatch): rubric file edited after a prior run. lab-tech reads prior `rubric_hash` from the orchestrator's Phase 4.5 filtered-markdown injection (U3), compares against current file hash, fails. `[BLOCKER] rubric_hash_mismatch: ...` with both hashes and the fork instruction. Covers AE5.
- Integration (cross-file): lab-tech writes per-experiment readiness; report-compiler reads it for execution; the `rubric_hash` and `triangle_verdict_id` flow from lab-tech → readiness report → executor invocation (U3) → report-compiler verdict node (U4). Verify the data round-trips correctly.

**Verification:**
- A plan with `instrument: judge_rubric` and a valid library rubric + anchors completes pre-flight with `[OK]` and accurate per-experiment fields in the readiness report.
- The four BLOCKER variants (anchors_missing, judge_instrument_insensitive, judge_fails_triangle_discriminability, rubric_hash_mismatch) each fire on a deliberately-broken fixture, with the specified message text and fix instruction.
- The triangle gate's cache lookup correctly short-circuits a same-`(rubric_hash, judge_id)` re-run within the freshness window.

---

- U2. **DAG schema: `rubric_node` and `triangle_verdict_node` types**

**Goal:** Add two new node types to `schemas/dag-schema.json` and the verdict-node fields needed for rubric provenance (R3, R4 structural part). `rubric_node` references a library file by `source_path` + `content_hash`; `triangle_verdict_node` caches calibration verdicts per `(rubric_hash, judge_id)`.

**Requirements:** R3, R4 (structural — emit logic is U4)

**Dependencies:** None (independent schema work; gates U1, U3, U4, U5 which reference these types)

**Files:**
- Modify: `schemas/dag-schema.json`

**Approach:**
- `rubric_node` carries: `id` (string pattern `R\d{3,}`, mirrors theory/verdict ID conventions), `type: "rubric"`, `rubric_library_id` (e.g., `"portrait-v3"` — the YAML file basename without extension), `version` (integer), `content_hash` (sha256 hex of canonicalized YAML), `source_path` (repo-relative path to the YAML file), `created_at` (ISO 8601), `created_by` (optional), `status: active|deprecated`. Does NOT embed criteria — the library file is source of truth.
- `triangle_verdict_node` carries: `id` (pattern `TRI\d{3,}`), `type: "triangle_verdict"`, `rubric_hash` (sha256 of the rubric YAML at the time of the verdict — pins the verdict to a specific rubric content), `judge_id` (e.g., `"claude-opus-4-7"`), `correct_count` (int), `total_trials` (int), `verified_at` (ISO 8601), `status: PASS|FAIL`, optional `notes`.
  - **ID-prefix divergence from `cache_verdict_node` rationale:** `cache_verdict_node` uses the Infra prefix `I\d{3,}` because it's a build-cache infrastructure record. Triangle verdicts are *judge-instrument calibration* records — neither theory, verdict, nor infrastructure. Using `TRI` (3-letter, distinct from existing T/V/I/S/R single-letter prefixes) avoids namespace collisions and makes the node type self-evident in DAG dumps. `rubric_node` uses `R\d{3,}` for the same reason — it's a new namespace, not an extension of an existing one.
- `verdict_node` (existing) gains optional fields conditional on the producing experiment's `instrument_kind`: `rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id`, `criterion_scores: { <criterion_name>: <number> }`. All optional so numeric verdicts still validate.
- Preserve DAG invariants (single-writer-per-file, additive optional fields, INCONCLUSIVE-no-edge — none of which this unit changes).

**Patterns to follow:**
- Existing `cache_verdict_node` definition in `schemas/dag-schema.json` — structural twin of `triangle_verdict_node`. Same id-pattern style, same optional `notes`, same `status` enum shape.
- Existing `theory_node` and `verdict_node` field-additive pattern (research_type added in `b8b29c7` as optional, no migration needed) — `rubric_id` etc. on `verdict_node` follows the same approach.

**Test scenarios:**
- Happy path: a `rubric_node` with all required fields and valid `content_hash` (64 hex chars) validates against the schema.
- Happy path: a `triangle_verdict_node` with `status: PASS, correct_count: 13, total_trials: 15` validates.
- Happy path: a `verdict_node` with the new optional rubric fields populated validates.
- Edge case: a `verdict_node` WITHOUT the new optional fields still validates (numeric experiments unchanged).
- Error path: a `rubric_node` with a malformed `content_hash` (not 64 hex) fails validation.
- Error path: a `triangle_verdict_node` with `correct_count > total_trials` is rejected. (Confirmed in reconciliation: the schema is JSON Schema draft 2020-12 but uses **no** cross-field constraints anywhere today, and the node union is a plain `oneOf` over `#/definitions`. Express `correct_count <= total_trials` as a runtime assertion report-compiler checks before writing the node — not in the schema — to stay consistent with the current schema style.)

**Verification:**
- `schemas/dag-schema.json` parses as valid JSON.
- All existing DAG nodes in `~/.claude/plugins/nerd/dag/projects/projects-arras.json` still validate against the updated schema (no false positives from added optional fields).
- New node types can be instantiated against the schema.

---

- U3. **Phase 2c routing: `instrument: judge_rubric` as fourth classification**

**Goal:** Extend `commands/nerd.md` on three orchestrator-owned surfaces: (a) Phase 2c recognizes `instrument: judge_rubric` and routes the experiment through U1's judge-instrument gate instead of the existing numeric U5 path (R6); (b) Phase 4.5 (the pre-flight context handoff to lab-tech) generates a filtered-markdown block of on-file rubric hashes + cached triangle verdicts from the DAG and injects it into lab-tech's invocation — this is the read surface U1's hash-lock and triangle-cache checks consume, and per the architecture doc filtered-markdown generation is the orchestrator's job (not report-compiler's); (c) Phase 6c carries the rubric (id-or-path) and judge_id forward as executor invocation parameters AND skips `phase=build` for rubric experiments, launching `phase=run` directly — reusing the existing skip-build precedent for `has_harness: true` experiments at `commands/nerd.md:411`. The executor's *internal* judge-rubric branch is owned by U6, not this unit.

**Requirements:** R6 (plus the orchestrator half of R1/R2/R5's cross-session read path)

**Dependencies:** U1 (the gate must exist for the routing to be meaningful); U2 (the filtered-markdown block in (b) is built from `rubric_node`/`triangle_verdict_node`, which U2 defines); soft-deps U4 (report-compiler writes the DAG nodes this Phase 4.5 injection reads back)

**Files:**
- Modify: `commands/nerd.md` (Phase 2c classification, ~lines 247-287; Phase 4.5 pre-flight context handoff — add the rubric/triangle filtered-markdown injection; Phase 6c "Launch Experiment Agents" prose at ~lines 366-411 to carry rubric/judge into the executor invocation parameters and to skip `phase=build` for rubric experiments, mirroring the `has_harness: true` skip at `commands/nerd.md:411`)

**Approach:**
- Phase 2c gains a fourth classification: **rubric-judged**. Trigger: experiment plan declares `instrument: judge_rubric` (explicit top-level field per brainstorm Key Decisions). Distinction from `instrument-blocked`: rubric-judged is the *expected positive* route for an experiment that wants a judge, whereas instrument-blocked is a *failure outcome* from lab-tech. They're not alternatives — a rubric-judged experiment that fails the gate becomes instrument-blocked.
- Routing prose: rubric-judged experiments proceed to Phase 3 (experiment design) and Phase 4.5 (lab-tech readiness), but lab-tech runs U1's gate instead of U5's numeric sensitivity check. The Phase 6c executor invocation carries the rubric (by id or inline path) and judge_id forward, so the executor knows what to score against.
- The classification text in Phase 2c needs to NAME rubric-judged alongside experimentable/analytical/instrument-blocked so plan-reviewer and report-compiler downstream see it as a first-class kind.
- The numeric `experimentable` path is *untouched* — this unit adds a parallel branch, it doesn't refactor the existing classification.
- **Phase 4.5 filtered-markdown injection (surface (b)):** before lab-tech runs the pre-flight, the orchestrator queries the DAG for `rubric_node`s (by `rubric_library_id` → `content_hash`) and `triangle_verdict_node`s (by `rubric_hash`, `judge_id`, `verified_at`, `status`) relevant to the batch, renders them into a small markdown block (e.g. `Rubric on file: portrait-v3 hash=abc1234...` and `Triangle verdicts on file: (rubric_hash=abc1234..., judge=claude-opus-4-7) PASS 13/15 verified 2026-05-12`), and includes that block in lab-tech's invocation context. This is the producer side of U1's cross-session reads. The architecture doc (`docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`) already establishes that the orchestrator — not an agent — computes filtered-markdown views of the DAG; this extends that existing capability with rubric/triangle rows. lab-tech never touches raw DAG JSON.
- **Phase 6c phase=build skip (surface (c)):** rubric experiments have no harness to build, so the orchestrator skips `phase=build` and launches the executor with `phase=run` directly — structurally identical to the existing `has_harness: true` path at `commands/nerd.md:411` ("skip `phase=build` and launch `phase=run` directly"). The rubric and judge_id ride along in the `phase=run` invocation prompt; the executor (U6) re-reads the plan, sees `instrument: judge_rubric`, and runs the judge branch without expecting a committed harness in the worktree.

**Patterns to follow:**
- The recent commit `a1449b2` already established the precedent of adding a fourth classification (`instrument-blocked`) to Phase 2c. R6 follows the same shape: another classification bullet, another routing destination, no rewrite of the existing branches.
- **`commands/nerd.md:411` `has_harness: true` skip-build precedent** — the existing prose already conditionally skips `phase=build` and launches `phase=run` directly for experiments whose harness already exists. Rubric experiments reuse this exact shape (no harness ever needs building); mirror its wording rather than inventing a new branch.
- Phase 6c's existing executor invocation pattern (two-phase build/run from commit `0f74c16`) — for rubric experiments only the `phase=run` invocation fires, with rubric and judge_id as additional parameters in the prompt template; numeric experiments keep both phases unchanged.
- The orchestrator's existing DAG→filtered-markdown handoff (architecture doc) — the rubric/triangle block in surface (b) is a new set of rows in that existing handoff, not a new mechanism.

**Test scenarios:**
- Happy path (cold read): a fresh reader of `commands/nerd.md` Phase 2c can describe four classifications and where each one routes. The new bullet does not require reading other files to understand.
- Happy path (data flow): a plan with `instrument: judge_rubric, rubric: portrait-v3, judge: claude-opus-4-7` reaches lab-tech with all three values intact and is routed to U1's gate.
- Edge case: a plan with `instrument: judge_rubric` but no `rubric:` field is BLOCKER at Phase 2c with an actionable message (`"instrument: judge_rubric requires a rubric: field naming a library id or path"`) — caught before lab-tech runs.
- Integration: an experiment that passes the rubric gate produces a results JSON the executor and report-compiler can consume in the existing path; an experiment that fails the gate is dropped from the batch with the instrument-blocked routing prose.
- Regression (numeric path unchanged): a plan with `instrument: numeric_metric` (or absent — backward-compat for existing experiments) routes through the existing U5 path with no behavior change.
- Happy path (Phase 4.5 injection): a batch containing a rubric experiment whose rubric + a fresh-enough triangle verdict are already in the DAG produces a pre-flight context block naming the rubric hash and the cached triangle verdict; lab-tech (U1) reads that block and short-circuits the triangle test on cache hit. Verify the rendered block format matches exactly what U1's read expects (producer/consumer agreement).
- Happy path (phase=build skip): a rubric experiment is launched with a single `phase=run` invocation (no `phase=build`), exactly as a `has_harness: true` numeric experiment is today; the executor receives rubric + judge_id and does not look for a committed harness.

**Verification:**
- Phase 2c text names all four classifications and the conditions that produce each.
- Phase 4.5 prose generates and injects the rubric/triangle filtered-markdown block, and its format matches what U1 reads (documented on both sides).
- The executor invocation prose in Phase 6c references rubric and judge for rubric-judged experiments and skips `phase=build` for them, mirroring `commands/nerd.md:411`.
- Reading Phase 2c → Phase 4.5 → Phase 6c as a single flow makes the rubric-experiment path coherent without surprises.

---

- U4. **report-compiler emits rubric provenance on verdict nodes**

**Goal:** Extend `agents/report-compiler.md` to (a) emit the rubric-experiment provenance fields on verdict/theory nodes (R4) — `rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id`, `criterion_scores`; (b) write the new `rubric_node` and `triangle_verdict_node` to the DAG; (c) gain a **new read of lab-tech's readiness report** (`docs/research/lab-readiness-*.md`) to pick up fresh `triangle_verdict:` blocks at batch-end. report-compiler does **not** read readiness reports today (it reads raw results, plans, and backlog), so (c) is new plumbing. The filtered-markdown surface lab-tech reads on resume is generated by the **orchestrator (U3)** from the DAG nodes this unit writes — not by report-compiler.

**Requirements:** R4 (emit logic; structural fields owned by U2)

**Dependencies:** U2 (schema must define the optional fields and the two new node types before report-compiler emits/writes them); soft-deps U1 (the triangle-verdict data report-compiler reads comes from lab-tech's readiness report)

**Files:**
- Modify: `agents/report-compiler.md` (theory-node template ~lines 176-189 and verdict-node template ~lines 204-218 — add conditional rubric fields; the DAG-write section (Step 8) — add `rubric_node` and `triangle_verdict_node` write paths; the `## Input` section — add the lab-readiness read so fresh `triangle_verdict:` blocks are picked up at batch-end)

**Approach:**
- The theory-node template (extended in commit `b8b29c7` for `research_type`) gains conditional emit logic: when the source experiment has `instrument_kind: judge_rubric`, add `rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id` fields. Verdict nodes (separately emitted) additionally carry `criterion_scores`.
- The numeric path is untouched: experiments with `instrument_kind: numeric_metric` (or absent) emit the current set of fields exactly as today.
- The provenance also lands on report-compiler's human per-experiment report (`docs/research/{id}-report.md`) as a `Rubric:` line for readability — but that human report is **not** the surface U1 reads. U1's cross-session reads come from the orchestrator's Phase 4.5 filtered-markdown injection (U3), built from the DAG nodes this unit writes. report-compiler's job here is to make the DAG durable; the orchestrator turns the DAG back into the markdown lab-tech consumes.
- **New `rubric_node` and `triangle_verdict_node` writes**: report-compiler also gains two new write paths:
  - When lab-tech's readiness report contains a `triangle_verdict:` block (fresh test result), report-compiler writes a corresponding `triangle_verdict_node` to the DAG. Read by lab-tech (filtered-markdown) on subsequent pre-flights.
  - When an experiment first cites a `rubric_id` not yet present in the DAG, report-compiler writes a `rubric_node` referencing the library file's `content_hash` + `source_path`.
- **Triangle-verdict cache filtered-markdown surface (owned by U3, not this unit):** the small block listing on-file triangle verdicts that lab-tech reads on pre-flight (`Triangle verdicts: (rubric_hash=abc1234..., judge=claude-opus-4-7) PASS 13/15 verified 2026-05-12; ...`) is generated and injected by the **orchestrator** at `/nerd` Phase 4.5 (U3), per the architecture doc's rule that the orchestrator owns DAG→filtered-markdown. This unit's only contribution to that path is *writing* the `triangle_verdict_node` to the DAG so the orchestrator has something to filter. (The original plan misattributed block production to report-compiler; corrected 2026-06-23.)
- Preserve DAG invariants from `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`: report-compiler is one of the two designated writers (the other is loop-scout); INCONCLUSIVE creates no `supports`/`refutes` edge; crash-safe atomic writes.

**Patterns to follow:**
- Existing theory-node and verdict-node emit templates in `agents/report-compiler.md` — same JSON shape extension, additive only.
- The existing per-experiment markdown summary block style (the section lab-tech and loop-scout consume) — add the `Rubric:` line in the same style as existing metadata lines.

**Test scenarios:**
- Happy path: a rubric experiment completes. report-compiler emits a verdict node with `rubric_id, rubric_hash, judge_id, triangle_verdict_id, criterion_scores: {subject_identity: 4.93, composition: 5.00, vibe: 5.00}` and a theory node with the same rubric provenance. report-compiler's human per-experiment report (`docs/research/{id}-report.md`) contains a readable `Rubric:` line (the cross-session machine-read surface is the orchestrator's Phase 4.5 block, U3, not this human report). Covers AE6.
- Happy path (numeric unchanged): a numeric experiment emits exactly the existing field set on theory and verdict nodes; no rubric fields appear.
- Edge case: a rubric experiment that produced an INCONCLUSIVE verdict still emits the rubric provenance fields but creates no `supports`/`refutes` edge (DAG invariant).
- Integration (round-trip): the full cross-session chain is report-compiler writes `rubric_node`/verdict `rubric_hash` to the DAG (this unit) → orchestrator reads the DAG and renders the filtered-markdown block at Phase 4.5 (U3) → lab-tech parses it and compares against the current `.nerd/rubrics/<id>.yaml` file hash (U1). The producer/consumer format agreement that U1's hash-lock depends on is between **U3 (renders) and U1 (parses)**; this unit's responsibility is only that the DAG carries the fields U3 needs. Verify all three links.
- Integration (triangle-verdict write path): lab-tech writes a `triangle_verdict:` structured block in its readiness report after running a fresh triangle test. report-compiler **(via the new readiness read added in this unit)** picks it up at batch-end and emits a `triangle_verdict_node` to the DAG. Subsequent pre-flights see the cached verdict via the orchestrator's filtered-markdown block (U3).
- Integration (triangle-verdict cache read path): on a same-`(rubric_hash, judge_id)` re-run within 30 days, the orchestrator's pre-flight context handoff includes the cached `triangle_verdict` line; lab-tech matches it; emits `[OK] triangle cached (...)`.

**Verification:**
- A rubric experiment's DAG output contains all R4 fields and the new `rubric_node`/`triangle_verdict_node`, and validates against the U2 schema.
- report-compiler's new readiness read picks up a `triangle_verdict:` block and writes the corresponding node; without such a block, no node is written.
- A numeric experiment's output is byte-identical to what the existing report-compiler would produce today (no regressions) — the new readiness read and rubric writes are inert for numeric experiments.
- The DAG field set report-compiler writes is sufficient for U3's Phase 4.5 block to render the `Rubric:`/`Triangle verdicts:` lines U1 parses; the *block* format itself is documented in `commands/nerd.md` (U3), the human `Rubric:` report line in `agents/report-compiler.md` (this unit).

---

- U5. **`/nerd-this` brief mode: `rubric:` parameter and `.nerd/rubrics/` library convention**

**Goal:** Extend the brief mode added in commit `71f257c` to accept `rubric:<id-or-path>` as a third brief shape alongside `commit:` and `hypothesis:` (R9); establish `.nerd/rubrics/<id>.yaml` as the library convention with documented frontmatter (R7) and per-experiment override semantics (R8).

**Requirements:** R7, R8, R9

**Dependencies:** U1 (the gate must exist for a rubric brief to do anything); U2 (the DAG must accept rubric nodes); soft-deps U3 (Phase 2c routing makes batch-mode rubric experiments work; this unit specifically handles brief mode)

**Files:**
- Modify: `commands/nerd-this.md` (Brief Mode Detection section ~lines 16-40; Brief Mode body that defines what each brief shape does)

**Approach:**
- Brief Mode Detection grows from two prefixes (`commit:`, `hypothesis:`) to three (add `rubric:`). Detection: same prefix-on-`$ARGUMENTS` parsing as the existing precedent. Value disambiguation: `rubric:<bare-name>` → library lookup at `.nerd/rubrics/<bare-name>.yaml`; `rubric:<value-containing-slash>` or `rubric:./<path>` → inline file path. Mirrors npm/gem name-vs-path convention.
- A rubric brief composes with `commit:` (e.g., `/nerd-this commit:abc123 rubric:portrait-v3 judge:claude-opus-4-7 metric:"<metric-cmd>"` for "test this commit's effect on portrait quality"). When `commit:` and `rubric:` co-occur, the experiment is a sweep-of-one on the commit, judged by the rubric — combines the existing sweep-of-one shape (commit `71f257c`) with the new rubric path.
- A `rubric:` brief without `commit:` is a one-shot rubric run on the current working state — useful for "score this prompt across these variants" without a commit anchor.
- Document the YAML library shape in `commands/nerd-this.md` (brief mode body) with a short inline example. The file is **pure YAML** (one document, no markdown `---` separator). Top-of-file metadata keys: `id`, `version`, `created_at`, `created_by` (optional), `used_in: [<E-IDs>]` (back-references, append-only), `default_judge` (optional), `triangle_cache_days` (optional, default 30). Lower body keys: `criteria:` (list of `{name, scale, anchor_examples?, pass_condition, theory_tag?}`), `min_anchor_separation: <float>` (default 1.0 for Likert 1-5), `default_anchors: {good: <path>, bad: <path>}` (used when experiment doesn't override per R8).
- Per-experiment override (R8): if the experiment plan declares its own `anchors:`, lab-tech uses those for that experiment's sensitivity and triangle checks. The library file's defaults are unchanged. This means `.nerd/rubrics/` is a *defaults registry*, not an enforcer.

**Patterns to follow:**
- `commands/nerd-this.md:14-40` (Brief Mode Detection added in `71f257c`) — same prefix detection, same prose structure for the new brief shape.
- `commands/nerd-intern.md:12` — the structured-`$ARGUMENTS` parsing precedent.
- `.claude/nerd.local.md` — YAML frontmatter + structured body convention for nerd's config files.

**Test scenarios:**
- Happy path (library): `/nerd-this rubric:portrait-v3` resolves to `.nerd/rubrics/portrait-v3.yaml`, lab-tech loads it, the experiment proceeds through U1's gate.
- Happy path (inline): `/nerd-this rubric:./scratch/my-rubric.yaml` resolves to the relative path, lab-tech loads it.
- Happy path (composed): `/nerd-this commit:abc123 rubric:portrait-v3 judge:claude-opus-4-7 metric:"<cmd>"` runs a single-commit rubric experiment.
- Edge case (override): an experiment plan declares both `rubric: portrait-v3` AND `anchors: {good: ..., bad: ...}`. lab-tech uses the experiment's anchors, not the library defaults. The library file is not modified.
- Edge case (free-text unchanged): `/nerd-this auth flow` (no `rubric:`, `commit:`, or `hypothesis:` prefix) routes through the existing scope-inference Phase 1, exactly as today.
- Error path (library file missing): `/nerd-this rubric:nonexistent` → BLOCKER with actionable message (`rubric file .nerd/rubrics/nonexistent.yaml not found; create it or check the id`).
- Error path (malformed YAML): library file exists but parsing fails → BLOCKER with line number and parser error.
- Integration: the brief mode produces a plan that flows through U3's Phase 2c routing → U1's gate → executor → U4's report-compiler emit. Full pipeline coverage.

**Verification:**
- The Brief Mode Detection section names three brief shapes and their parsing rules.
- A library lookup, an inline path, and a free-text invocation all resolve correctly.
- The YAML library top-of-file metadata and lower-body schema are documented in the command file with a working example.
- Per-experiment anchor override works as specified — library defaults stay untouched.

---

- U6. **experiment-executor learns judge-rubric execution shape**

**Goal:** Extend `agents/experiment-executor.md` so that an experiment with `instrument: judge_rubric` runs the F2 execution shape from the brainstorm (invoke declared judge per cell with the rubric prompt, collect structured per-criterion verdicts, evaluate pass conditions, capture results JSON) rather than the current numeric-metric path (build/extend the eval module and run a metric command). The two execution paths coexist as parallel branches in the executor's protocol; numeric-metric experiments are unchanged.

**Requirements:** R4 (the executor must produce verdicts that *carry* per-criterion scores so U4's report-compiler can emit them) — also a structural prerequisite for F2 in the brainstorm.

**Dependencies:** U2 (schema must define `criterion_scores` on verdict nodes so the executor's output JSON shape has a target); soft-deps U1 (the executor assumes lab-tech's gate emitted `[OK]` and the rubric is hash-locked); soft-deps U3 (Phase 6c carries rubric/judge into the invocation)

**Files:**
- Modify: `agents/experiment-executor.md` (description ~line 6; Execution Protocol intro and Step 3-Step 5 — add a judge-rubric branch that runs *instead of* the eval-module-extend + numeric metric command path; results JSON shape — add per-criterion structured verdicts when `instrument_kind: judge_rubric`)

**Approach:**
- The executor protocol gains an upfront branch on `instrument_kind`. For `instrument: judge_rubric`, the executor skips the eval-module-extension steps (Step 3 in current prose) and instead:
  1. Loads the (already hash-locked) rubric from its `source_path` — the rubric file is treated as read-only input, never edited.
  2. Loads the experiment plan's cell grid (sweep dimensions × variants).
  3. For each cell, generates the input artifact (or reads the pre-generated fixture if the experiment supplies one), then invokes the declared judge with the rubric prompt — the judge sees the artifact and the rubric criteria, returns a structured verdict matching the rubric's `criteria[]` shape (e.g., `{subject_identity: 4.93, composition: 5.0, vibe: 5.0, face_drift: false}`).
  4. Per cell, evaluates the rubric's `pass_condition` against the verdict (e.g., `mean(subject_identity) ≥ 4.0 AND no_cell(face_drift==true)`).
  5. Captures the full per-cell verdict matrix into the results JSON. Headline scalar = the rubric's headline criterion's mean (or whatever the rubric's pass_condition derives the verdict from); per-cell records carry all criteria.
- The two-phase split (`phase=build` / `phase=run`) collapses to a single phase for judge-rubric experiments — there is no harness to build (no metric command to wire into an eval module). The **orchestrator skips `phase=build` entirely** and launches only `phase=run` (U3 owns this, mirroring the existing `has_harness: true` skip at `commands/nerd.md:411`). The executor's `phase=run` branch for judge-rubric must therefore **not assume a committed harness exists in the worktree** — unlike the numeric `phase=run` path, which re-reads a harness committed by `phase=build`. Defensive belt-and-suspenders: if `phase=build` is somehow invoked on a judge-rubric experiment, the executor returns immediately with "no harness needed for judge-rubric mode" rather than attempting to build one. This keeps the executor correct even if an orchestrator caller forgets the skip.
- The current numeric-metric path is *untouched* — language detection, eval-module extension, metric command execution, two-phase split all unchanged for `instrument: numeric_metric` (or absent).
- Determinism note: the judge is invoked at temperature 0 by default (the rubric's `default_judge` block may pin a temperature/seed; if so, the executor honors it). This pairs with U1's fixture-pair sensitivity check's assumption that the judge is deterministic enough for N≥3 replicates to be meaningful.

**Patterns to follow:**
- The existing two-phase invocation prose in `agents/experiment-executor.md` (lines ~20-27): the branching shape (`phase=build` vs `phase=run`) is the structural twin of the `instrument_kind: numeric_metric` vs `judge_rubric` branch — branch up front, run the path, return. Use the same prose style.
- The results JSON shape today (numeric metric → headline scalar + raw runs); judge-rubric results extend this to (headline scalar + per-cell-per-criterion structured records + pass_condition evaluation).
- The commit message convention at line 98 (`feat(eval/{experiment_id}): add {metric} sweep harness`) — judge-rubric experiments don't add a sweep harness, so the commit message convention becomes `feat(results/{experiment_id}): record judge-rubric sweep` (no eval module change to commit).

**Test scenarios:**
- Happy path: a rubric experiment with `instrument: judge_rubric`, valid `rubric:portrait-v3`, judge `claude-opus-4-7`, and a 3×3 cell grid completes via the judge-rubric branch. Per-cell verdicts are captured; the pass_condition is evaluated against each cell; results JSON contains a `per_cell` array with `{cell_id, criterion_scores, cell_verdict}` records plus a top-level `experiment_verdict: PASS|FAIL` rolled up from the cells.
- Happy path (numeric unchanged): a numeric-metric experiment runs the existing eval-module-extension + metric-command path with no observable change.
- Edge case (single-cell brief mode): `/nerd-this rubric:portrait-v3 commit:<sha> judge:<id>` produces a 1-cell sweep on that commit. The executor runs the cell once, captures the verdict, evaluates pass_condition. Same path as a multi-cell grid, just N=1.
- Edge case (judge tool unavailability): the declared judge model is unreachable at execution time. The executor stops gracefully with an actionable error (`judge claude-opus-4-7 unreachable: <error>; results not recorded`) rather than producing partial results — partial-result handling for judge-rubric experiments is out of v1 (every-cell-or-none).
- Edge case (rubric file hash mismatch at execution time): between lab-tech's pre-flight and the executor's run, the rubric file is edited. The executor re-checks the hash against the locked hash from the readiness report; mismatch → STOP with `rubric_hash_drift_detected: <reason>; aborting run`. This is a defensive belt-and-suspenders check; lab-tech's pre-flight is the primary defense.
- Regression (numeric path byte-identical): the executor's behavior on a numeric-metric experiment is unchanged. The two-phase split, eval-module-extension, metric-command execution, and results JSON shape all match the current prose exactly.

**Verification:**
- A judge-rubric experiment completes the cell-grid → judge invocation → pass_condition evaluation flow and produces a results JSON whose shape U4's report-compiler can consume to emit `criterion_scores` on verdict nodes.
- A numeric-metric experiment is unaffected — reading the executor's prose for a numeric experiment never lands on the judge-rubric branch.
- The two execution paths are visibly parallel in the protocol prose: an upfront branch on `instrument_kind`, two clearly-labeled sub-protocols, no entanglement.

---

## System-Wide Impact

- **Interaction graph:** This plan adds one new routing branch from Phase 2c (U3), one new pre-flight gate in lab-tech (U1), and one new execution branch in experiment-executor (U6). Existing branches (numeric experimentable, analytical, instrument-blocked) are unchanged. Numeric experiments traverse the same path as before — the test scenarios in U3 and U6 explicitly verify regression-freedom.
- **Error propagation:** Each of the four BLOCKER variants (anchors_missing, judge_instrument_insensitive, judge_fails_triangle_discriminability, rubric_hash_mismatch) names the specific failure and includes the fix instruction. All emit through lab-tech's existing readiness report, which the orchestrator already consumes. No new error channels.
- **State lifecycle risks:** The hash-lock semantics (R5) introduce a cross-invocation state dependency — lab-tech must read the prior `rubric_hash` to detect mid-experiment drift. This is the only state-across-invocations concern, and it is **new plumbing**, not an existing surface: report-compiler writes the durable `rubric_hash`/`rubric_node` to the DAG (U4, including a new readiness read), and the **orchestrator** renders it into the filtered-markdown block lab-tech reads at Phase 4.5 (U3) — honoring the DAG-invariants doc's "orchestrator-mediated reads, not raw JSON" rule. Verify producer and consumer (U3 renders, U1 parses) agree on the block format.
- **API surface parity:** Both `commands/nerd.md` (batch mode) and `commands/nerd-this.md` (brief mode) need to recognize `instrument: judge_rubric`. U3 owns the batch-mode routing; U5 owns the brief-mode parameter. Both write the same DAG shape via the same executor/report-compiler path.
- **Integration coverage:** The integration concern (lab-tech reading prior `rubric_hash` and cached triangle verdicts) crosses four units: U2 (schema admits the fields/node types), U4 (report-compiler writes them to the DAG + new readiness read), U3 (orchestrator renders the filtered-markdown block at Phase 4.5 and injects it), U1 (lab-tech parses it). Cross-unit verification lives in U3's and U4's Integration test scenarios — confirm the U3-renders/U1-parses format agreement before declaring U1 done.
- **Unchanged invariants:** `commands/nerd-loop.md`'s LLM-as-judge ban (lines 38, 42, 64) stays untouched (R10 — verified by grep, not implemented). The numeric U5 path (lab-tech Check 3 mechanical/semantic classification from commit `a1449b2`) is untouched — the new judge-instrument gate is a *parallel* check, not a replacement. DAG single-writer-per-file invariant preserved (report-compiler still emits, lab-tech still reads filtered markdown). `merge_strategy` config still unwired (noted in prior plan; not in scope).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| The judge fixture-pair check (R1) catches content-axis flatness but not bias (position, verbosity, family) — JudgeBiasBench: frontier models fail >50% of bias tests | This is the documented ground floor, not the ceiling. The triangle gate (R2) layers discriminability on top. Higher-bias defenses are explicitly out of v1 (ensemble + α deferred per Scope Boundaries); revisit after v1 ships and we see failure modes. |
| Triangle test passes by attending to a confound (longer text = "different" = picked) rather than the rubric's headline criterion | Triangle prompt template structure requires the judge to name the rubric's *headline criterion* in the question. Documented in U1 Approach. Implementation-time validation against real anchors will surface confound issues; fixture-pair sensitivity check is the layered defense (catches when the judge can't separate good from bad on the headline criterion specifically). |
| Hash-lock semantics block legitimate mid-experiment iteration when a researcher genuinely discovers the rubric is wrong | The fork-for-edit affordance is documented in the BLOCKER message itself (Copy file to new id, edit, re-run). v2 may add `--allow-amendment 'reason: ...'` if strict mode proves too painful. Strict by default is the literature's stance (Kaplan & Irvin 2015 — honor-system pre-registration has no effect on null-rate). |
| The 30-day triangle cache window is wrong (too lax or too strict) | Configurable per rubric via `triangle_cache_days:` (default 30). Tuneable without code change. Empirical evidence is genuinely needed; tune per rubric in real use. |
| The orchestrator-injected `Rubric:`/`Triangle verdicts:` block format diverges between U3 (renders/injects at Phase 4.5) and U1 (parses) | U3's and U4's Integration test scenarios explicitly round-trip the block format through DAG write (U4) → orchestrator render (U3) → lab-tech parse (U1). Document the block format in `commands/nerd.md` (U3), not just example-based. (The original plan put this surface on report-compiler; the orchestrator owns DAG→filtered-markdown per the architecture doc — corrected 2026-06-23.) |
| New DAG node types break loop-scout's existing read paths | loop-scout writes synthesis nodes only and does not read `rubric_node` or `triangle_verdict_node`. Additive schema changes don't break loop-scout. Verify by grep against `agents/loop-scout.md`. |
| Brief-mode `rubric:` parameter collides with `hypothesis:` or `commit:` when authors compose them | Brief shapes are designed to compose, not collide. The detection logic (prefix on `$ARGUMENTS`) processes each prefix independently. U5 Approach names the legitimate composition: `commit:abc rubric:portrait-v3 judge:claude-opus metric:"<cmd>"`. Document composition rules in `commands/nerd-this.md`. |
| Plan touches the same files as the just-shipped feedback-improvements plan; a stacked merge could conflict | This plan is a clean extension of the prior plan, not a revision — every modified file is touched in a different region (U1 adds a Check 3 sub-section; U2 adds two new node types; U3 adds a Phase 2c bullet; U4 adds a conditional emit; U5 adds a brief-mode branch; U6 adds an `instrument_kind` branch at the top of the executor protocol). Verify no overlap by grep before merging. |
| nerd-loop ban (R10) is accidentally lifted by an implementer who reads "rubric experiments admitted" and edits the loop file | R10 stays as a verification check in this section, not a unit. Final verification step: `git diff main..HEAD -- commands/nerd-loop.md` should produce zero output for this plan's PR. |

---

## Phased Delivery

The 6 units have a clear dependency order: schema (U2) before consumers (U1, U4, U6); U1 before its routing (U3); U4 before its read (U1's hash-lock); U6 executes what U1 admits; U5 composes the brief-mode entry on top of the gate, routing, and executor.

```
              ┌──────────┐
              │   U2     │  DAG schema (rubric_node, triangle_verdict_node,
              │          │   optional verdict fields)
              └────┬─────┘
                   │
     ┌───────┬─────┴─────┬─────────┐
     │       │           │         │
     ▼       ▼           ▼         ▼
┌───────┐  ┌────┐  ┌────────┐  ┌──────┐
│  U4   │  │ U1 │  │   U3   │  │  U6  │
│ report│  │lab-│  │Phase 2c│  │ exec │
│-comp  │◄─┤tech│  │routing │  │ rub  │
│ emit  │  │gate│  │        │  │ run  │
└───┬───┘  └──┬─┘  └────┬───┘  └──┬───┘
    │         │         │         │
    │ ┌───────┘         │         │
    │ │                 │         │
    │ │ (U4 writes DAG; │         │
    │ │  U3 renders md; │         │
    │ │  U1 parses it)  │         │
    ▼ ▼                 ▼         ▼
   ┌────────────────────────────────┐
   │             U5                 │  brief-mode rubric: parameter
   │  (composes U1+U3+U4+U6 into a  │  (depends on the full pipeline
   │   single user-facing entry)    │   being reachable)
   └────────────────────────────────┘
```

### Phase 1 — Schema first (U2)
Land U2 alone. It's independent and gates everything else. Verify existing DAG files still validate against the updated schema before proceeding.

### Phase 2 — Gate, routing, emit, executor in parallel (U1, U3, U4, U6)
U1, U3, U4, U6 are independent of each other but all depend on U2. Note the cross-session read path now spans three of them (U4 writes the DAG → U3 renders + injects filtered markdown at Phase 4.5 → U1 parses it):
- U1's cross-session reads (prior `rubric_hash`, cached triangle verdicts) arrive via U3's Phase 4.5 injection, fed by U4's DAG writes — but only on resume of an experiment that's already run once. First-time landing in any order works; the cross-unit integration test (U3's and U4's Integration scenarios) verifies the U3-renders/U1-parses format agreement before the hash-lock check can fire on real data.
- U3's Phase 2c routing dispatches to U1's gate, and U3 also owns the Phase 4.5 injection U1 reads and the Phase 6c phase=build skip — U1 and U3 are mutually referential (U3 routes to U1's gate; U1 reads U3's injection), so they're best landed together, but either can be authored first against the other's documented contract.
- U6's executor extension consumes what U3 routes to it (rubric/judge invocation params) and produces what U4 emits (per-criterion verdict shape). U6 can land independently of U3 and U4 if its prose targets the contract those units will provide.

### Phase 3 — Brief-mode entry (U5)
U5 composes everything below it. Lands last because authors invoking `/nerd-this rubric:...` need the full pipeline to be reachable end-to-end (routing → gate → executor → report-compiler emit).

---

## Documentation / Operational Notes

- After all five units land, capture the rubric-as-instrument pattern with `/ce-compound` — this is genuinely new territory not in existing `docs/solutions/`. Topics: judge-as-instrument trust generalization of U5; cached calibration verdicts as a DAG node type; strict pre-registration of rubrics; the prefix-disambiguation rule for brief mode params.
- Per the project's `CLAUDE.md` feedback memory: sync the nerd plugin to the shrimpshack marketplace after merging.
- Update `README.md` to surface rubric experiments in the "What It Actually Does" section — the recent reposition (commit `e4e4439`) mentions "any falsifiable experiment with a numeric metric" but doesn't yet describe rubric experiments as a first-class mode. Light prose addition; can be folded into U5's commit if convenient.
- Consider adding a `docs/research/plans/` example for a rubric experiment so future authors have a template — using the Format C precedent as the worked example. Optional; not required for the plan to be complete.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-22-non-numeric-judge-experiments-requirements.md`
- **Upstream ideation:** `docs/ideation/2026-05-22-non-numeric-judge-experiments-ideation.md`
- **Prior plan (currently on branch):** `docs/plans/2026-05-21-001-feat-nerd-feedback-driven-improvements-plan.md`
- **Existence-proof feedback entries:**
  - `docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md` (Format C 45-cell rubric sweep)
  - `docs/feedback/2026-05-05-aipipeline-positioning-nerd-named-then-passed-over.md`
  - `docs/feedback/2026-05-15-slate-surface-gap-human-judge-sweep.md` (human-judge case, parked v2)
- **Prior-art research patterns:**
  - `docs/research/plans/E017-E020-plan.md` (Criterion/Theory Tested/Pass Condition tables)
  - Arras `docs/research/E-PROMPT-OPT-report.md`, `batch18-findings.md` (AC-A1/B1/C2 format)
- **Institutional learnings:** `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`, `docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`
- **Related commits on `feat/nerd-feedback-improvements`:** `a1449b2` (U5 sensitivity gate), `b8b29c7` (research_type "experiment"), `71f257c` (brief mode), `e4e4439` (numeric-metric reposition), `0f74c16` (executor two-phase split), `da8813c` and `f3a55cb` (worktree cleanup)

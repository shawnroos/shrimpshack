---
date: 2026-05-22
topic: non-numeric-judge-experiments
---

# Non-Numeric Judge Experiments in nerd — Requirements

## Problem Frame

nerd was just repositioned (commits `e4e4439`, `b8b29c7`, `71f257c`) as "execute any falsifiable experiment with a **trusted numeric metric**." The numeric-metric bound was added as a bait-and-switch guard so the U5 sensitivity gate (`a1449b2`) wouldn't BLOCKER experiments whose metric the harness can't auto-verify.

But a meaningful share of real workload is **rubric-judged experiments** where an LLM agent applies a pre-registered rubric to rendered images, prompts, or other artifacts:

- `docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md`: 3×3×5 = 45-cell prompt sweep, LLM-judge against rubric ("subject-identity 1–5, composition 1–5, vibe 1–5, face-drift binary; pass criteria <5% face drift; mean subject-identity ≥ 4.0"). Verdict: *"Format C: subject 4.93, composition 5.00, vibe 5.00, ZERO leakage, ZERO face drift... Format A fails all gates."* Worked. Nerd was never on the menu.
- `docs/feedback/2026-05-05-aipipeline-positioning-nerd-named-then-passed-over.md`: agent *named* nerd-this twice and still routed to a bespoke `/ai-pipeline-test` skill because nerd didn't claim this territory.
- `docs/research/plans/E017-E020-plan.md` and Arras `E-PROMPT-OPT-report.md` already use `Criterion / Theory Tested / Pass Condition` tables — the rubric pattern in nerd's own past output, just unnamed.

The reposition's numeric-metric bound left this workload outside nerd. Either nerd admits rubric experiments through a parallel gate at least as strict as U5's sensitivity check, or agents continue to hand-build separate skills like `/ai-pipeline-test` to do nerd's job.

The scope nuance the repositioning quietly preserved: nerd-loop's *"LLM-as-judge too noisy for iterative hill-climbing"* ban is correct and stays. The workload to admit is **`/nerd` and `/nerd-this` one-shot batches only.**

---

## Actors

- A1. **Experiment author** (human user, or an agent acting on a user's behalf): writes the rubric, supplies the known-good/known-bad fixture pair, declares the judge model, runs `/nerd` or `/nerd-this`.
- A2. **lab-tech agent** (`agents/lab-tech.md`): runs pre-flight gates — the existing numeric-metric sensitivity check, plus the new judge-instrument gate and triangle-test admissibility gate. Emits `[OK]/[FIXED]/[BLOCKER]/[SETUP NEEDED]` verdicts per experiment.
- A3. **nerd orchestrator** (`commands/nerd.md` / `commands/nerd-this.md`): reads lab-tech's readiness output, routes findings to experimentable / analytical / instrument-blocked / `now also` rubric-judged execution paths.
- A4. **experiment-executor agent**: runs the rubric sweep — calls the judge per cell using the pre-registered rubric, collects structured verdicts, writes results JSON.
- A5. **report-compiler agent**: emits theory and verdict nodes to the DAG, citing the `rubric_id` and `rubric_hash` used.

---

## Key Flows

- F1. **Rubric experiment pre-flight (the load-bearing flow)**
  - **Trigger:** experiment plan has `instrument: judge_rubric` and a `rubric:` block (inline) or `rubric_id:` (library reference)
  - **Actors:** A2 (lab-tech), A1 (author, may be re-prompted)
  - **Steps:**
    1. lab-tech verifies the rubric is content-hashed and `signed_at` is set; refuses to start if not (R5).
    2. lab-tech verifies the rubric declares `anchors: {good, bad}` — file paths or inline content; emits `[BLOCKER]` if missing (R1).
    3. lab-tech runs the **judge-instrument sensitivity check**: invokes the declared judge N≥3 times on each anchor; verdicts must split correctly (judge scores `good > bad` on the rubric's headline criterion, by at least the rubric's declared `min_anchor_separation`). Failure → `[BLOCKER] judge_instrument_insensitive` (R1).
    4. lab-tech checks the DAG for a cached **triangle-test verdict** for this `(rubric_hash, judge_id)` combo within the freshness window (default 30 days). If cached and PASS, skip. If cached and FAIL, BLOCKER. If absent, run the triangle test: present {good, good, bad} and {good, bad, bad} blind, judge must identify the odd one ≥80% across N≥10 trials (binomial p<0.05). Persist verdict to DAG (R2).
    5. All gates pass → emit `[OK]` with the rubric, judge_id, triangle verdict, and sensitivity scores cited in the readiness report. Phase 6 in `/nerd` is unblocked for this experiment.
  - **Outcome:** the experiment proceeds only if the judge has been verified to (a) discriminate the rubric's known-good from known-bad and (b) pass forced-choice discriminability on a wide-quality pair. Any failure produces an actionable error directing the author to the specific gate that failed.
  - **Covered by:** R1, R2, R3, R5, R6

- F2. **Rubric experiment execution and verdict**
  - **Trigger:** F1 emitted `[OK]` for this experiment; orchestrator routes to A4
  - **Actors:** A4 (executor), A5 (report-compiler)
  - **Steps:**
    1. Executor reads the (frozen, hash-locked) rubric, generates the cell grid (parameter sweep × variants), invokes the declared judge per cell with the rubric prompt.
    2. Per cell, the judge emits a structured verdict matching the rubric's criteria (e.g., `{subject_identity: 4.93, composition: 5.0, face_drift: false}`). Executor records the headline scalar plus the full per-criterion record.
    3. Pass conditions are evaluated against the verdict (e.g., `mean(subject_identity) ≥ 4.0 AND no_cell(face_drift==true)`). The experiment emits a Pass/Fail per cell and an overall verdict.
    4. report-compiler writes theory nodes (`research_type: "experiment"` from `b8b29c7`) and verdict nodes citing `rubric_id`, `rubric_hash`, `judge_id`, and the `triangle_verdict_id` that admitted this run (R4).
  - **Outcome:** the experiment produces a verdict shape that is queryable in the DAG (R3, R4) and rooted to the specific rubric and judge that produced it.
  - **Covered by:** R3, R4

- F3. **Rubric reuse from the library**
  - **Trigger:** experiment plan declares `rubric_id: <id>` instead of an inline `rubric:` block
  - **Actors:** A1 (author), A2 (lab-tech)
  - **Steps:**
    1. Author writes `/nerd-this commit:<sha> rubric:portrait-identity-v3` or equivalent — citing a rubric living in `.nerd/rubrics/portrait-identity-v3.yaml`.
    2. lab-tech loads the rubric from the library, computes its content hash, treats this as the experiment's pre-registered hash (R5).
    3. Default anchors travel with the rubric file. The author may override per-experiment by declaring `anchors: {...}` in the plan; lab-tech uses the override if present, library defaults otherwise (R7).
    4. F1 proceeds with the loaded rubric. Triangle verdict cache lookup uses the rubric's content hash — so a rubric that has accumulated triangle-PASS verdicts for several `(rubric, judge)` pairs amortizes the cost across experiments (R2, R8).
  - **Outcome:** subsequent experiments using the same rubric pay only the sensitivity-check cost (fixture pair, ~6 judge calls); the triangle test (~10–20 calls) is cached.
  - **Covered by:** R7, R8

---

## Requirements

**Judge-as-instrument (the centerpiece — Idea 1)**

- R1. **Fixture-pair sensitivity check.** Any experiment with `instrument: judge_rubric` must declare `anchors: {good: <path|inline>, bad: <path|inline>}` and a `min_anchor_separation` value (default: 1.0 on a 5-point Likert, configurable per rubric). lab-tech runs the declared judge N≥3 times on each anchor and verifies the verdicts split with a gap ≥ `min_anchor_separation` on the rubric's headline criterion. Missing anchors → `[BLOCKER] anchors_missing`. Failed separation → `[BLOCKER] judge_instrument_insensitive` with the observed scores cited.

**Triangle-test admissibility (Idea 2 — with caching)**

- R2. **Triangle-test admissibility gate.** Before any rubric scoring, the `(rubric_hash, judge_id)` pair must hold a current PASS verdict on a forced-choice triangle test: ≥80% correct identification of the odd item across N≥10 trials presenting {A,A,B} and {A,B,B} from the rubric's wide-quality anchor pair, binomial p<0.05. Verdicts are persisted to the DAG and cached for 30 days (configurable). Cache HIT → skip. Cache miss or expired → run and persist. FAIL verdict → `[BLOCKER] judge_fails_triangle_discriminability`.

**Rubric as first-class artifact (Idea 3)**

- R3. **Rubric DAG node type.** `schemas/dag-schema.json` admits a `rubric_node` type carrying `id`, `version`, `criteria[]` (each with `name`, `scale`, `anchor_examples`, `pass_condition`, optional `theory_tag`), `min_anchor_separation`, and `default_anchors`. theory and verdict nodes produced by rubric-judged experiments must cite the `rubric_id` and `rubric_hash` they were judged against.
- R4. **Verdict nodes carry rubric provenance.** A verdict node produced by a rubric experiment must record `rubric_id`, `rubric_hash`, `judge_id`, `triangle_verdict_id` (the cached admissibility verdict that admitted the run), and the structured per-criterion scores — not just a headline scalar. This makes rubric experiments queryable cross-experiment in the same way numeric ones are.
- R7. **Rubric library lives at `.nerd/rubrics/<rubric-id>.yaml`** (per-project). Files carry frontmatter (id, version, created_at, used_in) and the criteria block from R3. Experiments cite `rubric_id` to reuse; lab-tech loads, hashes, and treats the loaded file as the pre-registered artifact for that experiment.
- R8. **Per-experiment anchor override.** When an experiment cites a `rubric_id` from the library, the experiment plan MAY override `anchors` with experiment-local values. lab-tech uses the override for that experiment's sensitivity and triangle checks; the library defaults are unchanged.

**Pre-registration via content-hash (Idea 5 — strict)**

- R5. **Rubric is hash-locked once judging starts.** When `instrument: judge_rubric`, lab-tech computes the rubric's content hash before the first judge call and records `rubric_hash` and `signed_at` on the experiment's DAG node. Any edit to the rubric (inline or library) after this point requires forking to a new experiment ID; lab-tech refuses to resume an experiment whose rubric hash no longer matches the recorded one. There is no in-band amendment path in v1 — fork or fail. The report surfaces `pre_registered: <hash>` prominently.

**Surface integration**

- R6. **Phase 2c routes rubric experiments correctly.** `commands/nerd.md` Phase 2c (the classification post-`a1449b2`) treats `instrument: judge_rubric` as a fourth classification alongside `experimentable` / `analytical` / `instrument-blocked`. Rubric experiments proceed to F1; only those that survive F1's gates proceed to F2 execution. The existing numeric `experimentable` path is untouched.
- R9. **`/nerd-this` brief mode admits `rubric:` parameter.** The brief mode added in `71f257c` (`commit:` / `hypothesis:`) gains a `rubric:` parameter for one-shot rubric experiments. The detection pattern (prefix on `$ARGUMENTS`) and parsing precedent (`commands/nerd-intern.md:12`) are reused. `/nerd` Phase 2c is the broader-batch entry; both write the same DAG shape.
- R10. **nerd-loop unchanged.** The `nerd-loop` LLM-as-judge ban (`commands/nerd-loop.md:38,42,64`, `agents/parameter-scanner.md:138`) stays exactly as written. This brainstorm scope is `/nerd` and `/nerd-this` one-shot batches only; loop integration is explicitly out (see Scope Boundaries).

---

## Acceptance Examples

- AE1. **Covers R1.** Given a rubric plan with `instrument: judge_rubric` but no `anchors:` block, when lab-tech runs pre-flight, the experiment is marked `[BLOCKER] anchors_missing: rubric "portrait-v3" must declare anchors.good and anchors.bad with min_anchor_separation. See agents/lab-tech.md Check 3.` and the experiment does not proceed to F2.

- AE2. **Covers R1.** Given anchors are declared and the judge scores `good_anchor: 4.6, bad_anchor: 4.5` (separation 0.1, below the rubric's `min_anchor_separation: 1.0`), when lab-tech runs the sensitivity check, the experiment is marked `[BLOCKER] judge_instrument_insensitive: claude-opus-4-7 separated anchors by 0.1 on subject_identity, expected ≥1.0. The judge cannot discriminate this rubric's good/bad cases — refine the rubric anchors or use a more capable judge.`

- AE3. **Covers R2.** Given the DAG has a 7-day-old `triangle_verdict` PASS for `(rubric_hash: abc123..., judge_id: claude-opus-4-7)`, when a new experiment cites the same rubric and judge, the triangle gate is skipped with `[OK] triangle cached (verified 2026-05-15, 30/30 trials)` and only the sensitivity check runs.

- AE4. **Covers R2.** Given no cached triangle verdict for `(rubric_hash, judge_id)`, when lab-tech runs the triangle test and the judge identifies the odd item 12/15 trials (80%, p<0.05), the verdict is persisted to the DAG and the experiment proceeds. Subsequent experiments with the same combo within 30 days skip this gate.

- AE5. **Covers R5.** Given a rubric experiment is mid-run (some cells scored, some pending), when the author edits `.nerd/rubrics/portrait-v3.yaml`, the next lab-tech invocation detects the hash mismatch and refuses to resume: `[BLOCKER] rubric_hash_mismatch: rubric "portrait-v3" was hash-locked at signed_at 2026-05-22T14:00:00Z with hash abc123...; current hash is def456... Fork to a new experiment ID to use the revised rubric.`

- AE6. **Covers R4, R7.** Given an experiment uses `rubric_id: portrait-identity-v3` from `.nerd/rubrics/`, when the experiment completes, the verdict node in the DAG records `rubric_id: portrait-identity-v3`, `rubric_hash: <sha256>`, `judge_id: claude-opus-4-7`, `triangle_verdict_id: T-tri-042`, and the full per-criterion scores. `loop-scout` querying for "what rubric was used for image-quality?" returns this node.

---

## Success Criteria

- **Human outcome:** an agent or user with a rubric experiment to run (e.g., a 45-cell prompt sweep with a pre-registered rubric) recognizes nerd as the tool, runs `/nerd-this rubric:<...>`, and gets a verdict by morning — without hand-building a parallel skill. The next time they look for prior art, the rubric and its calibration history are queryable in the DAG.
- **Downstream-agent handoff:** when `/ce-plan` consumes this requirements doc, it can produce a plan whose units edit the named files (`agents/lab-tech.md`, `schemas/dag-schema.json`, `commands/nerd.md` Phase 2c, `commands/nerd-this.md` brief mode, `agents/report-compiler.md`) without re-deriving the gate vocabulary, the BLOCKER strings, the cache freshness window, the strict hash-lock semantics, or the human-judge boundary.
- **Instrument-trust preserved:** the numeric-metric bound is unchanged for numeric experiments. The new `judge_rubric` gate is *at least as strict* as the U5 sensitivity check it parallels — anchor separation is the direct analog of metric-moves-under-perturbation, and the triangle test adds a forced-choice prerequisite that numeric experiments don't need (because numeric metrics don't have the d-prime-collapse failure mode).

---

## Scope Boundaries

- **Out: ensemble + Krippendorff α (Idea 4 from the ideation doc).** Multi-judge with inter-rater agreement as a gate is a real next increment, not part of this spine. Single-judge with N≥3 samples on the fixture pair is sufficient sensitivity-of-instrument; ensemble adds ceiling, not floor.
- **Out: downstream behavior probe (Idea 6).** "Route numeric-in-disguise experiments to a downstream probe instead of a judge" is a separate routing improvement that sits *before* this spine in the experiment-design pipeline. Out of v1.
- **Out: nerd-loop integration.** The LLM-as-judge ban in `commands/nerd-loop.md:38,42,64` is correct and stays. This brainstorm admits rubric experiments to `/nerd` and `/nerd-this` one-shot batches only. Loop-mode rubric experiments are a separate, harder problem (iterative hill-climbing on a noisy judge — the literature says don't).
- **Out: human-judge mode.** The Slate audio QA-listening case (`docs/feedback/2026-05-15-slate-surface-gap-human-judge-sweep.md`) is real workload but has materially different ergonomics (asynchronous, file-based review surface, different fixture-pair shape). Carved out as a separate v2 brainstorm. The v1 spine uses an `instrument: judge_rubric` field that is substrate-agnostic by design — when human-judge ships, it slots in as a `kind: human` variant — but the v1 implementation is `kind: llm` only.
- **Out: automatic rubric synthesis.** "lab-tech generates a candidate rubric from the hypothesis" is interesting and was raised in ideation, but rubric authoring is a deliberately human-in-the-loop step in v1. Push to v2 once we see real reuse patterns from the library.
- **Out: rubric versioning beyond hash.** A rubric's `version: 3` field is informational metadata only in v1. There is no migration path, no compatibility check between versions, no auto-bumping. If a rubric needs a substantive change, fork to a new `rubric_id`.

---

## Key Decisions

- **LLM-judge only for v1, human-judge parked.** The Slate audio case is real but has different ergonomics; ship the LLM substrate first against the easier-to-mechanize case. The `instrument: judge_rubric` field is substrate-agnostic so the v1 doesn't paint itself into a corner.
- **User supplies fixture pair; lab-tech enforces.** Lowest-complexity v1; matches the existing `[SETUP NEEDED] Cannot auto-verify sensitivity for semantic metric...` posture in `agents/lab-tech.md`. Lab-tech-scaffolds-candidates is a v2 feature.
- **Triangle test required on first use, cached per `(rubric_hash, judge_id)`.** Catches d-prime collapse without imposing the cost on every rubric reuse. Pairs naturally with R3's first-class-rubric DAG type.
- **Strict pre-registration: hash-lock at first judge call, fork for any edit.** Honor-system pre-registration has no effect per the literature (Kaplan & Irvin 2015). v1 ships strict with no escape hatch; a `--allow-amendment 'reason: ...'` flag is a v2 feature if the strict mode proves too painful in practice.
- **`instrument` is an explicit top-level plan field, not inferred from a `rubric:` block.** Composes better with future judge kinds (`kind: human`, multi-judge ensembles) and makes the routing decision in Phase 2c trivial.

---

## Dependencies / Assumptions

- **Depends on:** the U5 sensitivity gate shipped in commit `a1449b2`. The judge-instrument gate is a parallel application of the same protocol; it doesn't replace U5.
- **Depends on:** the `experiment` enum value added to `schemas/dag-schema.json` in commit `b8b29c7`. Theory nodes for rubric experiments are `research_type: "experiment"`. (No new enum value is needed for v1 — `"experiment"` covers it. A future `"rubric_judged"` value is *not* needed because the structural information lives on the rubric and judge nodes, not on `research_type`.)
- **Assumes:** the user can articulate a known-good and known-bad output for their rubric. This is the same assumption U5 makes for semantic metrics today; the Format C precedent confirms it's a workable assumption in practice (they did it for portrait subject-identity).
- **Assumes:** the declared judge model is deterministic enough across N≥3 calls that the sensitivity check is meaningful. Frontier LLMs at temperature 0 generally satisfy this; if a judge fails the determinism check (verdicts on the same anchor vary wildly across N=3), that's itself a `[BLOCKER]` and signals the judge isn't suitable for rubric work.
- **Assumes:** rubric content hashing uses a stable canonicalization (sorted keys, normalized whitespace). Hash algorithm is sha256 (`reasonable cryptographic default; no migration burden assumed`).

---

## Outstanding Questions

### Resolve Before Planning

*(none — all blocking product decisions were resolved during the brainstorm)*

### Deferred to Planning

- [Affects R3, R7][Technical] What is the exact yaml frontmatter shape for `.nerd/rubrics/<rubric-id>.yaml`? The brainstorm names the fields (id, version, criteria, anchors, min_anchor_separation); the precise schema is a planning detail.
- [Affects R2][Technical] What is the canonical triangle-test prompt template the judge sees? Resolving this affects whether the triangle gate's reliability transfers across rubrics — a poorly-templated prompt could make a judge fail triangle for the wrong reason.
- [Affects R2][Needs research] Is the 30-day cache freshness window correct? Frontier models update; a judge that passed triangle for `rubric:portrait-v3` 25 days ago may be a different model under the same name today. Worth checking how OpenAI/Anthropic/Google publish model-version stability before planning.
- [Affects R6][Technical] Does the brief-mode `rubric:` parameter accept an inline rubric YAML or only a `rubric_id` library reference? Inline is more flexible; library-only is simpler. Planning can decide once the rubric file format is settled.
- [Affects R5][Technical] What does the "fork to new experiment ID" affordance look like in practice? Does lab-tech offer a one-shot helper (`/nerd-this --fork-rubric portrait-v3 portrait-v4`), or is it a manual file copy + edit + new run?
- [Affects R4][Needs research] How does report-compiler currently route theory nodes vs verdict nodes for non-rubric experiments? Verifying the existing emit shape will tell us how much of R4 is "add fields to existing schema" vs "new emit path."

---

## Next Steps

→ `/ce-plan` for structured implementation planning. No `Resolve Before Planning` items remain; all deferred questions are technical decisions appropriate to planning.

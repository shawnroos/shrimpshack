# Spinoff: rubric-judged experiments for nerd

## Goal
Admit **rubric-judged experiments** (LLM-judge against a pre-registered rubric) to `/nerd` and `/nerd-this` one-shot batches, through a *parallel* instrument-trust gate at least as strict as the numeric U5 sensitivity gate — without diluting U5 and without lifting the `nerd-loop` LLM-as-judge ban. This lets nerd run qualitative/non-numeric sweeps (rendered images, prompts, model outputs) it currently excludes by its "trusted numeric metric" bound.

## Why now / context
The just-shipped feedback-improvements work (PR #3 on `feat/nerd-feedback-improvements`) repositioned nerd as "any falsifiable experiment with a *trusted numeric metric*." That numeric bound was a deliberate bait-and-switch guard so the U5 sensitivity gate wouldn't BLOCKER experiments it can't auto-verify. The cost: a meaningful share of real workload — rubric-judged sweeps — is now explicitly out of scope. Agents who hit this hand-build parallel skills (the `/ai-pipeline-test` precedent) or run experiments outside nerd entirely. This workstream claims that territory back, with the same instrument-trust rigor numeric experiments earn through U5. This is workstream #2 of three on nerd (the other unstarted one is the "discovery loop").

## Key decisions already made (in the deepened plan)
- **Branch base = current HEAD (`feat/nerd-feedback-improvements`), not main.** The plan extends commits `a1449b2` (lab-tech sensitivity gate), `b8b29c7` (schema enum), `71f257c` (nerd-this brief mode) — all on this branch, NOT yet merged to main (PR #3). Building off main would be missing the surface this work extends.
- **Six units, prose + schema only** — no file renames, no `subagent_type=` changes: lab-tech judge-instrument pre-flight (hash-lock + fixture-pair sensitivity + cached triangle-test); DAG `rubric_node` type; report-compiler rubric provenance on verdict nodes; nerd.md Phase 2c routes `instrument: judge_rubric` as a *fourth* classification; nerd-this brief mode admits a `rubric:` parameter; experiment-executor learns to invoke a judge against a rubric instead of a numeric metric command.
- **The judge gate mirrors U5's shape/vocabulary** (`[OK]/[FIXED]/[BLOCKER]/[SETUP NEEDED]`, same per-experiment readiness block) — a *parallel application* of the same gate, deliberately not merged into U5.
- **Triangle-test admissibility cached per `(rubric_hash, judge_id)` for 30 days** (sibling of the existing `cache_verdict_node`).
- **Strict pre-registration**: rubric content-hashed before first judge call; post-judge edits require a fork to a new `rubric_id`. No in-band amendments in v1.
- **Rubric library** at `.nerd/rubrics/<rubric-id>.yaml`; per-experiment anchor override allowed.
- **v1 is `kind: llm` only** — the `instrument: judge_rubric` field is substrate-agnostic by design (admits a future `kind: human`) but human-judge mode is carved out for v2.
- **Explicitly OUT of v1**: ensemble + Krippendorff α multi-judge agreement; downstream numeric-in-disguise behavior probe; `nerd-loop` integration (the ban stays); human-judge mode; automatic rubric synthesis; rubric versioning beyond hash; pairwise + Bradley-Terry.

## Open questions / not yet decided
- Whether single-judge + fixture-pair + triangle-test is a sufficient trust floor, or whether ensemble/α is needed before v1 ships (currently deferred — revisit after v1).
- Exact `rubric_node` / `triangle_verdict_node` field shapes vs. the existing node templates (plan sketches them against `report-compiler.md` lines ~176-188 and the schema's existing node types — verify against current file state).
- How the judge invocation is wired in experiment-executor's two-phase (`phase=build`/`phase=run`) split that PR #3 just introduced — the plan predates fully reconciling with that split; confirm the judge run lands in `phase=run`.

## Starting point
The planning docs are **untracked** in the main nerd working tree (they were authored on this branch but not committed). Read them at these absolute paths (always available regardless of worktree), and they're also copied into this worktree's `docs/` for you to commit on this branch:
- Plan (deepened, ~69k): `~/projects/nerd/docs/plans/2026-05-22-001-feat-rubric-judge-experiments-plan.md`
- Origin requirements: `~/projects/nerd/docs/brainstorms/2026-05-22-non-numeric-judge-experiments-requirements.md`
- Ideation: `~/projects/nerd/docs/ideation/2026-05-22-non-numeric-judge-experiments-ideation.md`

Key code anchors the plan cites (verify against current state — PR #3 just moved some of these): `agents/lab-tech.md` Check 3 + `## Output`; `schemas/dag-schema.json` node types; `agents/report-compiler.md` theory/verdict templates; `commands/nerd.md` Phase 2c; `commands/nerd-this.md` Brief Mode Detection. Precedents: `docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md` (Format C, 45-cell rubric sweep) and nerd's own `docs/research/plans/E017-E020-plan.md` (unnamed `Criterion / Theory Tested / Pass Condition` shape).

First action: commit the three carried planning docs onto this branch so they're tracked, then proceed.

## Recommended next step
`/ce-plan` deepening pass, then execute — **not** `/ce-brainstorm`. The plan is already written and deepened (dated 2026-05-22, six units with a full requirements trace, actors, flows, acceptance examples, and scope boundaries). The remaining open questions are reconciliation-with-PR#3 details, not open scope. Validate the plan against current file state (PR #3 shifted line numbers), reconcile the judge-run wiring with the new two-phase executor split, then implement.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/1af5668b-150c-4426-bfc4-ee67c68ca953.jsonl`
Resume:     `cd /Users/shawnroos && claude -r 1af5668b-150c-4426-bfc4-ee67c68ca953`

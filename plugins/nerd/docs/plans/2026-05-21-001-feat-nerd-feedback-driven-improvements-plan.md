---
title: "feat: nerd feedback-driven improvements (repositioning, loop reliability, harness trust)"
type: feat
status: active
date: 2026-05-21
origin: docs/feedback/  # evidence dir (18 entries), not a single requirements doc
---

# feat: nerd feedback-driven improvements

## Overview

A feedback harvest across 12 past sessions and 5 projects (committed at `docs/feedback/`, 18 entries) re-tallied by `idea_tag` produced a stack of improvements to the nerd plugin. This plan implements three priorities and scopes a gated fourth. **Ranking is by severity, not evidence-count** (a document-review correction): the reliability defects below silently destroyed real overnight work product across three batches, so they lead — even though the repositioning cluster has more *sessions that noticed* it. The three implemented items are mutually independent and all ship in Phase 1; the ordering reflects headline priority and what ships first if forced to choose.

1. **Autonomous-loop reliability** (Arras cluster, highest-volume real usage; **lead — fixes silently-broken runs**) — fix tool-budget exhaustion (an executor timed out at 535 tool calls with no `results.json`, recurring across Batches 25/26/28), stale-worktree non-cleanup (risking re-runs of completed experiments), and data-prerequisite gating that broke overnight `/nerd` + `/nerd-schedule` runs. *(units U3, U4)*
2. **Harness-aware experimentable predicate** (4 entries) — a finding is only "experimentable" if a *trusted, sensitive* metric exists; verify metric sensitivity before sweeping. *(unit U5 ships Phase 1; U6 instrument-inversion is gated — see below)*
3. **Repositioning** (6 sessions noticed it — most source-diverse, but a discoverability gap, not broken runs) — reframe nerd from "discover tunable parameters" to "execute any falsifiable experiment *with a trusted numeric metric*," so it lands on the menu when an agent has such an experiment to run. *(units U1, U2)*
4. **Sweep-of-one input** (N=3 single-user; **gate decided OPEN — building in Phase 1**) — let nerd run a "test this specific commit/hypothesis" brief as a native mode on `nerd-this`. The 2-session ce-debug-overlap evidence was accepted as sufficient (Shawn, 2026-05-21) rather than waiting for the Phase-2 harvest. *(unit U7)*

**Inflow caveat (review):** items 2 and 3 interact. If U1's repositioning does *not* move agent routing (an accepted risk — see Risks), then item 2's harness-trust gates apply to the *existing* set of users already running nerd, not to net-new inflow. U5 still earns its keep (it stops broken-instrument verdicts for current users), but its reach is bounded by whether U1 actually changes who reaches for nerd. Don't assume reposition's downstream effects flow through to harness-trust.

nerd is an entirely prompt-driven plugin (markdown agents/commands/skills + YAML frontmatter, one JSON schema). There is no executable source. "Implementation" means editing prompt text, frontmatter descriptions, and the DAG JSON schema. "Tests" are necessarily verification procedures (does the reworded surface read coherently? does the gate fire on a known-broken harness?) rather than unit tests — see each unit's verification.

---

## Problem Frame

The dominant signal across the harvest is **positioning**: nerd's agents, commands, skills, README, manifest, and even its DAG schema describe it as a *parameter-discovery* tool. As a result, agents with genuine falsifiable experiments routed elsewhere or hand-built parallels:

- Someone built nerd's **entire** experiment loop — "Parameter Sweep," "Prompt A/B Testing Pattern," "Evaluate Results / Compare against baseline," a cardinality abort criterion — as a separate project-local `/ai-pipeline-test` skill, and ran it across three sessions (`docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md`). nerd was never on the menu.
- In one session the agent **named `nerd-this` twice** ("Needs a `nerd-this`-style sweep") and still routed to the local skill because it was more literally described (`docs/feedback/2026-05-05-aipipeline-positioning-nerd-named-then-passed-over.md`).
- The crop-tool session's signals (positioning, ce-debug overlap, harness-wall) **recur silently** across sibling sessions — the misroute is invisible in the moment.

The second cluster is **operational reliability of the autonomous loop**, surfaced by the highest-volume real usage (Arras overnight batches):

- Executor agents exhaust their tool-use budget *before the measurement phase* — one timed out at 535 tool calls with a 1269-line harness but no `results.json`. Recurs across Batches 25/26/28 (`docs/feedback/2026-05-04-execution-defect-autonomous-executor-reliability.md`).
- The orchestrator left worktrees on disk for already-merged branches despite `auto_cleanup_worktrees: true`, risking re-runs of completed experiments (`docs/feedback/2026-05-08-execution-defect-stale-worktree-noncleanup.md`).
- An empty production database blocked data-dependent experiments for three consecutive batches; the pipeline burned executor slots on experiments that returned `FAILED (data_insufficiency)` (`docs/feedback/2026-05-11-prereq-blocked-empty-arras-db.md`).

The third cluster is **instrument trust**: nerd asserts a metric must be "sensitive to changes" in three places but never verifies it, so when the harness is broken every parameter is inconclusive-by-association (`docs/feedback/2026-05-19-prereq-blocked-by-broken-harness.md`, `2026-05-18-home-prereq-blocked-experiments-need-harness-that-measures-wrong-surface.md`, `2026-05-21-webapp-surface-gap-harness-wall-in-loop.md`, `2026-05-19-surface-gap-nerd-on-instrument-mode.md`).

---

## Requirements Trace

Each requirement cites the feedback file(s) that ground it. R-IDs are **stable identifiers and do not track priority** (same convention as U-IDs) — the priority order is reliability → harness → reposition, but R1 remains R1. Authority for *which* improvements to make is the `idea_tag` tally; authority for *priority order* is severity, not count (see Overview).

- **R1.** nerd's positioning surface (manifest, command/agent/skill descriptions, README) frames it as "execute any falsifiable experiment with a trusted numeric metric" — subsuming parameter sweeps AND hypothesis-tests of single commits — so an agent with such an experiment recognizes nerd as the tool. The claim is deliberately bounded to *numeric-metric* experiments to stay consistent with U5's tightened gate (see Key Technical Decisions; without this bound, U1 advertises a surface U5 then BLOCKERs). *(reposition; the six `idea_tag: reposition-execute-any-falsifiable-experiment` entries: `2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md`, `2026-05-09-surface-gap-nerd-cant-do-wiring-work.md`, `2026-05-15-slate-positioning-denoise-sweep-as-feature.md`, `2026-05-18-home-invocation-friction-nerd-too-heavy-defanged-to-design-only.md`, `2026-05-18-home-positioning-perf-bottleneck-debugged-not-swept.md`, `2026-05-21-webapp-positioning-handrolled-experiment.md`)*
- **R1-note (fix-mechanism caveat, from review).** Of these six, only ~4 are cleanly resolved by *wording alone* (the bespoke-skill and hand-rolled cases). Two — `2026-05-18-home-invocation-friction...` (asks for a lighter entry point that skips the broad scan) and `2026-05-09-surface-gap-nerd-cant-do-wiring-work.md` (asks for a non-numeric/qualitative experiment shape nerd can't run today) — request *capability* U1 does not deliver; their real fix is U7 or unbuilt work. The "dominant by count" framing is therefore "dominant by *count of sessions that noticed a positioning gap*," not "count of misroutes wording will fix." See U1 verification, which measures against the ~4 wording-fixable entries only.
- **R2.** The DAG data model (`schemas/dag-schema.json` `research_type` enum) admits experiment types beyond parameter/performance, so the data model no longer contradicts R1. *(reposition, schema consequence of R1)*
- **R3.** Autonomous executor runs do not exhaust tool budget before producing a measurement: harness-writing and benchmark-execution are separable, and scheduled mode does not launch full executors on experiments lacking a pre-existing harness. *(harness-aware/reliability; `2026-05-04-execution-defect-autonomous-executor-reliability.md`)*
- **R4.** Merged experiment branches never leave stale worktrees on disk; the audit step distinguishes truly-active worktrees from merged ones. *(reliability; `2026-05-08-execution-defect-stale-worktree-noncleanup.md`)*
- **R5.** Data-dependent experiments are gated on a data-prerequisite check before consuming an executor slot, so the pipeline does not burn slots on `FAILED (data_insufficiency)`. *(harness-aware; `2026-05-11-prereq-blocked-empty-arras-db.md`)*
- **R6.** A finding is classified "experimentable" only when a *trusted, sensitive* metric exists: lab-tech verifies the metric responds to a known perturbation before the sweep runs; an insensitive metric is a BLOCKER, not "ready." *(harness-aware; `2026-05-19-prereq-blocked-by-broken-harness.md`, `2026-05-18-home-prereq-blocked-experiments-need-harness-that-measures-wrong-surface.md`)*
- **R7.** When the live competing theory is "Metric is wrong," the experiment can be inverted to treat the measurement instrument as the system-under-test (sweep measurement surface/threshold/cadence against a known perturbation). *(instrument-inversion; `2026-05-19-surface-gap-nerd-on-instrument-mode.md`, `2026-05-21-webapp-surface-gap-harness-wall-in-loop.md`)*
- **R8.** *(gated)* nerd can accept a "test this specific commit/hypothesis" brief and run it as a one-cell sweep producing a numeric verdict — but only built if R1's repositioning proves insufficient at getting nerd onto the menu. *(hypothesis-brief; `2026-05-19-tool-overlap-nerd-vs-ce-debug.md`, `2026-05-21-webapp-tool-overlap-ce-debug-commit-isolation.md`, `2026-05-18-home-positioning-perf-bottleneck-debugged-not-swept.md`)*

---

## Scope Boundaries

- **No agent/command/skill file renames.** `parameter-scanner` and `perf-explorer` carry the discovery frame in their *names*, but renaming files breaks `subagent_type=` references across commands. Reword their descriptions only; names stay.
- **No new behavior in repositioning (R1/R2).** Item 1 is wording + an additive schema enum value. It does not change what nerd *does*, only how it describes itself. The DAG is already experiment-shaped (theory/verdict nodes), so this is genuinely surface-level.
- **Do not fold the determinism check (lab-tech Check 8b) into the new sensitivity check.** They share shape but have opposite goals (8b: same code → same output; new: different code → different output). Two checks, not one.
- **Parked — not planned** (noted for completeness): the human-as-judge-sweep new-pattern (`2026-05-15-slate-surface-gap-human-judge-sweep.md`) — no numeric metric, orthogonal to the instrument-trust spine; and the parallel-routing-nudge (`2026-05-19-sequencing-staged-experiments-uninvoked.md`) — weakest, self-flagged by its source as agent error rather than a tool gap.

### Deferred to Follow-Up Work

- **U6 (instrument-inversion, R7):** the one deferred unit — gated on the instrument-wrong case recurring beyond the single crop-tool family that supplies most of its evidence (N=2, single-tool-concentrated). U5 ships in Phase 1; U6's full recipe is deferred. An optional one-line stub pointer may land in Phase 1.

*(U7 was originally deferred but its gate was decided OPEN — it now ships in Phase 1. See U7.)*

---

## Context & Research

### Relevant Code and Patterns

- **Positioning surface inventory (complete):**
  - Manifest: `.claude-plugin/plugin.json` `description` (line 4, canonical statement) + `keywords` (line 8, includes `parameter-tuning`).
  - Command `description` frontmatter: `commands/nerd.md:3`, `commands/nerd-loop.md:3`, `commands/nerd-this.md:3` (the parameter-bound ones); plus body H1/lead at `commands/nerd.md:8,10`, `commands/nerd-loop.md:8-12`, `commands/nerd-this.md:8-10`. Commands have no `whenToUse` field — `description` is the only positioning frontmatter.
  - Agent `description` + `whenToUse`: strongest to reword are `agents/parameter-scanner.md:6-13`, `agents/context-scanner.md:6-14`, `agents/experiment-executor.md:6-13` ("runs parameter sweeps").
  - Skill `description`: `skills/codebase-analysis/SKILL.md:3` (most parameter-bound).
  - README: `README.md:3,5,7-16,39,73,81-87` (theory table at 81-87 is **missing the "Metric is wrong" row** — fix while rewording).
  - DAG schema: `schemas/dag-schema.json:30` `research_type` enum `["parameter","performance"]`.
- **Executor harness/run split:** `agents/experiment-executor.md` Execution Protocol — harness writing in Steps 3-4 (lines 48-74), benchmark execution in Step 5 (lines 76-80), commit in Step 6. Steps 3-5 are currently one continuous invocation with no checkpoint between "harness built" and "harness run."
- **lab-tech readiness output:** `agents/lab-tech.md` `## Output` (lines 318-383); frontmatter fields `checked_at`, `experiments_checked`, `status` (lines 327-331); per-experiment status blocks (lines 341-358); stdout summary (lines 369-383). Check 3 "Eval Command Readiness" (lines 107-129) probes harness existence. Check 8b "Determinism Validation" (lines 415-427) runs the metric 4× for performance batches — the determinism analog, NOT to be merged with the new sensitivity check. Check 1 "Data Access" (lines 53-79) is where the data-prerequisite check extends.
- **Worktree merge + cleanup:** `commands/nerd.md` Phase 6e (lines 402-416: `git merge --no-edit`, test, on-success `git worktree remove`, on-fail keep), Phase 8 `git worktree prune` (lines 430-431); mirrored in `commands/nerd-this.md` Phase 8.3 (lines 452-466) and Phase 10 (lines 478-481). `commands/nerd-schedule.md` has no worktree logic — it delegates to `/nerd` under `NERD_SCHEDULED=1`.
- **Classification + gate anchors:** `commands/nerd.md` Phase 2c (lines 247-286, `experiment_type`-string based, no harness check); `commands/nerd-loop.md` measurability gate (lines 28-34, criterion 3 "Sensitive" asserted not tested); `skills/experiment-planning/SKILL.md:21` "Metric is wrong" theory (also at `agents/plan-reviewer.md:65`).
- **Input parsing precedent:** `commands/nerd-intern.md:12` is the only command that parses a structured subcommand from `$ARGUMENTS` — the precedent pattern for any structured-brief detection (U7).
- **Config:** `.claude/nerd.local.md` frontmatter — `max_parallel_experiments` (read), `merge_strategy: auto` (**written, never read**), `auto_cleanup_worktrees: true` (**written, never read** — cleanup is hardcoded). Global `~/.claude/plugins/nerd/hardware-profile.yaml` schema documented in `commands/nerd-setup.md:203-237`.

### Institutional Learnings

- **`docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`** — the team already rejected overloading `/nerd` with a flag: *"A flag on `/nerd` was considered but rejected — different intent deserves its own entry point."* And documents the parameter-centric identity explicitly: *"`/nerd` was designed as a broad discovery tool."* **Constrains R1** (cite the stance being reversed) and **R8** (a "test this commit" brief is a *different intent* → favor a separate entry point over a parse-branch in nerd-loop/nerd-this).
- **`docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`** — DAG invariants that R2 (and any DAG read in U4/U5) must preserve: orchestrator-mediated reads (filtered markdown, not raw JSON), single-writer-per-file (only report-compiler + loop-scout write), crash-safe atomic writes, and INCONCLUSIVE-creates-no-edge. The schema is already experiment-shaped, so R2 is additive and needs no migration. Prevention rule relevant to all items: *"for every verb in a prompt, verify the tool exists"* and *"grep all `subagent_type=` invocations"* to avoid prompt-sync drift.
- **`docs/solutions/build-errors/parallel-worktree-compilation.md`** (severity high) — the named overnight-run-ballooning failure is already solved: cache daemons over shared build dirs, inline env-var prefixing (never `export`, Bash loses shell state between calls), gate incremental profiling on existing artifacts, APFS `cp -c -r` clones. **U3/U4 inherit these wholesale.** Coverage gap: no prior learning on tool-budget exhaustion or worktree cleanup specifically — U3/U4 are genuinely new territory; capture with `/ce-compound` after they land.

### External References

- None. The work is internal prompt/schema editing grounded in committed feedback evidence; no external research warranted.

---

## Key Technical Decisions

- **R1 is reword-only + one additive schema value; no renames, no behavior change.** The DAG is already theory/verdict-shaped, so repositioning is surface-level. *(Confirmed by the DAG learnings doc.)*
- **Widen `dag-schema.json` `research_type` enum additively** to `["parameter","performance","experiment"]` (Shawn's call, 2026-05-21; `"hypothesis"` deferred to U7 per review — no Phase-1 producer). Existing nodes keep their type; no migration (field is optional). The single real writer of this field is `report-compiler`'s theory-node template, which must be changed to *emit* `research_type` (it doesn't today). This resolves the prose-vs-data contradiction R1 would otherwise create.
- **Wire up `auto_cleanup_worktrees` (and decide `merge_strategy`).** These config fields are written but read by nothing today. U4 makes `auto_cleanup_worktrees` actually gate the hardcoded `git worktree remove`/`prune`, OR — if the simpler fix is "always remove on merge" — the flag is removed rather than left as dead config. Decision: **wire it up** (honor the documented contract) and additionally add the merged-branch cross-check so cleanup is correct even when the flag is on. `merge_strategy` is out of scope — leave as-is, note as dead config in U4's verification (don't expand scope to wire it).
- **Two separate checks for determinism (Check 8b) vs sensitivity (new).** Same shape, opposite goals; do not generalize-and-merge.
- **Reliability (R3) splits the executor, doesn't rewrite it.** Add a checkpoint/budget-split between harness-writing (Steps 3-4) and execution (Step 5), and a `has_harness` field to lab-tech output that scheduled mode reads to gate autonomous execution. Inherit the worktree-compilation fixes; do not re-solve them.
- **Sweep-of-one (R8) favors a separate entry point over an argument parse-branch** if it ships, per the "different intent → own entry point" precedent. U7 carries this as its design default.

---

## Open Questions

### Resolved During Planning

- *DAG enum: widen vs. accept contradiction?* → Widen additively (Shawn, 2026-05-21).
- *`auto_cleanup_worktrees` / `merge_strategy` dead config — wire or delete?* → Wire `auto_cleanup_worktrees`; leave `merge_strategy` as-is (out of scope, noted).
- *Merge Check 8b into the new sensitivity check?* → No. Two distinct *verdicts* (determinism vs sensitivity). Open question from review: whether they share one harness pass — see U5 (they may share setup while emitting separate verdicts; resolve when editing lab-tech).
- *Is R1 structural or reword-only?* → Reword-only + additive enum; DAG already experiment-shaped.
- *U3 executor split: soft checkpoint or hard two-call boundary?* → Hard two-call boundary (tool budget is per-invocation; a soft checkpoint can't give separate budgets). Resolved per feasibility review.
- *Which enum values does U2 add now?* → `"experiment"` in U2; `"hypothesis"` added by U7 (its real producer, now also Phase 1).
- *Build U7 now or gate on a post-U1 harvest?* → Build now (Shawn, 2026-05-21); 2-session ce-debug-overlap evidence accepted as sufficient.
- *U7 entry-point shape: separate `/nerd-test` command or native mode?* → Native `nerd-this` mode (single-commit test is a central case under the reframed identity; the feedback wants the choice to collapse to one tool).

### Deferred to Implementation

- **R8 build/no-build decision** depends on observing whether R1's repositioning gets nerd onto the menu in subsequent real sessions. The measurement mechanism itself (do new feedback entries with `idea_tag: reposition` or `hypothesis-brief` still show silent misroutes?) is the gate — see Phased Delivery.
- Exact wording of each reworded description (U1) is a copy decision best made against the live files, not pre-written here.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Dependency graph across the implementation units (parallelism analysis the brief requested):

Item numbers below are *priority order* (reliability leads); U-IDs are stable identifiers and do not track priority. Phase-1 units: U1, U2, U3, U4, U5, **U7** (gate decided open). Gated/deferred: **U6** only.

```
        ┌────────────────────────────────────────────────────────────┐
        │  Independent — can run in parallel (all Phase 1)             │
        ├───────────────┬───────────────┬──────────────┬──────────────┤
        │  ITEM 1        │  ITEM 2       │  ITEM 3      │  ITEM 4      │
        │ (reliability)  │ (harness)     │ (reposition) │ (sweep-of-1) │
        │                │               │              │              │
        │  U3 executor   │  U5 sensitiv  │  U1 reword ─▶ │  U7 brief    │
        │     split      │     gate      │  U2 enum     │  mode on     │
        │  U4 worktree   │               │  (U2 dep U1) │  nerd-this   │
        │     cleanup    │               │              │  (soft-dep   │
        │  (U3 ∥ U4)     │               │              │   U1, U5)    │
        └───────────────┴──────┬────────┴──────────────┴──────────────┘
                               │
              ▼ (gated: thin evidence, novel abstraction)
        ┌───────────────┐
        │  U6 instrument │  soft-dep U5
        │   -inversion   │
        │  (gated)       │
        └───────────────┘
```

- **Items 1, 2, 3, 4 are mutually independent** — four parallel Phase-1 tracks (headline priority: reliability → harness → reposition; U7 rides on U1's reframing).
- Within reposition: U2 (enum) depends on U1 (reword) only for narrative coherence (do the prose first so the enum value name matches the new vocabulary).
- Within reliability: U3 (executor split) and U4 (worktree cleanup) are independent.
- Within harness: only U5 (sensitivity gate) ships in Phase 1. **U6 (instrument-inversion) is the one gated unit** — single-tool-concentrated evidence (N=2) and a novel abstraction; soft-deps U5's perturbation concept.
- **U7 (sweep-of-one)** soft-deps U1 (the reframing that makes it a native `nerd-this` mode rather than a separate command) and U5 (its numeric-metric gate); builds in Phase 1.

---

## Implementation Units

- U1. **Reposition nerd's prose surface as "execute any falsifiable experiment"**

**Goal:** Reword every prose statement of nerd's purpose so it frames nerd as the tool for *any falsifiable experiment with a trusted numeric metric* (parameter sweeps AND hypothesis-tests of single commits AND model/prompt comparisons), not just parameter discovery — without changing behavior. The *numeric-metric* bound is load-bearing: it keeps U1's advertised surface consistent with U5's gate, so nerd isn't reached for non-numeric/qualitative experiments it will then BLOCKER (the bait-and-switch risk).

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `.claude-plugin/plugin.json` (`description` line 4, `keywords` line 8)
- Modify: `commands/nerd.md` (`description` line 3, H1/lead lines 8,10)
- Modify: `commands/nerd-loop.md` (`description` line 3, lead lines 8-12)
- Modify: `commands/nerd-this.md` (`description` line 3, lead lines 8-10)
- Modify: `agents/parameter-scanner.md` (`description`/`whenToUse` lines 6-13)
- Modify: `agents/context-scanner.md` (`description`/`whenToUse` lines 6-14)
- Modify: `agents/experiment-executor.md` (`description` lines 6-13, "runs parameter sweeps")
- Modify: `skills/codebase-analysis/SKILL.md` (`description` line 3)
- Modify: `README.md` (lines 3, 5, 7-16, 39, 73; add missing "Metric is wrong" row to theory table at 81-87)

**Approach:**
- Lead with the broad-but-bounded frame: nerd executes *any falsifiable experiment with a trusted numeric metric* against your codebase — parameter sweeps, hypothesis-tests of a single commit, model/prompt/algorithm comparisons — and tells you what to keep, change, remove, or rearchitect. Parameter discovery becomes *one mode*, not the identity. The numeric-metric bound is explicit so agents with qualitative/human-judged experiments are NOT steered to nerd (U5 would BLOCKER them).
- **Identity preservation (product-lens finding):** keep the distinctive "finds the magic numbers you forgot" hook as a concrete *lead example* rather than discarding it for a generic "experiment runner" identity — the README already extends that hook to architecture-level findings. Broaden the claimed surface additively; don't surrender the sharp, ownable hook.
- Cite the stance being reversed: the prior "broad discovery tool / parameter-centric" framing is documented in `docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`. This is a conscious reframe.
- Keep names (`parameter-scanner`, `perf-explorer`) — reword descriptions only.
- **Put the numeric-metric qualifier in the reworded copy itself**, not just in this plan. The manifest `description`, command/agent descriptions, and README must literally say something like "any falsifiable experiment *that produces a measurable number*" — do NOT write bare "any falsifiable experiment" because it reads more cleanly. The bound is the bait-and-switch guard and must survive into the shipped prose (the harm-case test scenario checks exactly this).
- Fix the README theory table to include the "Metric is wrong" row (it exists in the skill/agent but is missing from README — a pre-existing inconsistency surfaced during research). *(Coupled doc-fix, not strictly an R1 consequence — included because the file is already open; don't expand further README scope.)*
- Do NOT touch `subagent_type=` references or any execution logic.

**Patterns to follow:** Existing frontmatter `description`/`whenToUse` style across `agents/*.md`; README section voice.

**Test scenarios:**
- Happy path: read each reworded `description`/`whenToUse` cold — does it make nerd recognizable as the tool for a single-commit hypothesis-test, not just "find magic numbers"? (The `/ai-pipeline-test` author's task — "tune guidance/steps/temperature, validate model behavior" — should now obviously match nerd's stated purpose.)
- Harm case (bait-and-switch guard): an agent with a *non-numeric / human-judged* falsifiable experiment reads the new description and is correctly steered AWAY from nerd (or toward its limits), not toward it — the numeric-metric bound must be visible in the prose, not just implied.
- Consistency: grep the repo for "tunable parameter" / "parameter-tuning" / "discover parameters" after the edit — every surviving instance is intentional (a *mode*, not the *identity*).
- Regression: confirm no `subagent_type=` value, agent `name:` field, or command `name` changed (names are load-bearing references).
- Covers R1: the bespoke-skill author's vocabulary (parameter sweep, A/B variant, baseline compare) is now visibly nerd's vocabulary in the README/descriptions.

**Verification:** A reader skimming `plugin.json`, `/help` command descriptions, and the README top-of-file would describe nerd as "runs experiments to answer falsifiable questions about my code," not "finds tunable parameters." No behavior changed.

---

- U2. **Widen the DAG `research_type` enum to match the new framing**

**Goal:** Make the data model admit experiment types beyond parameter/performance so it no longer contradicts U1.

**Requirements:** R2

**Dependencies:** U1 (for vocabulary coherence — do the prose first so enum value names match)

**Files:**
- Modify: `schemas/dag-schema.json` (`research_type` enum on `theory_node`, line ~30)
- Modify: `agents/report-compiler.md` (theory-node JSON template, ~lines 176-188 — **add** a `research_type` field, which the template does not emit today)

**Approach:**
- Additive enum change: `["parameter","performance"]` → `["parameter","performance","experiment"]`. Existing nodes keep their type; `research_type` is optional (not in `theory_node.required[]`), so no migration — old nodes and nodes omitting the field still validate. The enum stays *closed* (an unknown value still fails validation).
- **`"hypothesis"` is deferred to U7** (scope-guardian finding): a single-commit hypothesis-test node only has a producer once U7 ships, so adding `"hypothesis"` in Phase 1 builds writer guidance for a producer that doesn't exist. Add only `"experiment"` now (it has a real Phase-1 producer: the bespoke-skill-style sweeps that fit neither `parameter` nor `performance`); add `"hypothesis"` as part of U7 if/when it's built.
- **Writer correction (feasibility finding):** the real edit is in `agents/report-compiler.md` — its theory-node template does NOT currently emit `research_type` at all, so this *adds* the field with guidance on choosing `parameter` / `performance` / `experiment`. `agents/loop-scout.md` writes only synthesis nodes (which carry no `research_type`) — it is NOT a writer of this field and is dropped from scope. `agents/perf-specialist.md:334` is the existing upstream source of `research_type: "performance"` — confirm the template propagates from there.
- Preserve DAG invariants from the architecture learnings doc: single-writer-per-file, INCONCLUSIVE creates no `supports`/`refutes` edge.

**Patterns to follow:** Existing enum + node-type definitions in `schemas/dag-schema.json`; the existing theory-node JSON template in `agents/report-compiler.md`; `agents/perf-specialist.md:334` for the existing `research_type: "performance"` emit.

**Test scenarios:**
- Happy path: a node written with `research_type: "experiment"` validates against the updated schema.
- Edge case: an existing node with `research_type: "parameter"` still validates (backward compatibility).
- Edge case: a node omitting `research_type` entirely still validates (field is optional).
- Error path: a node with an unknown `research_type` (e.g., `"random"`) fails validation (enum still closed, just wider).
- Covers R2: schema admits an `experiment`-type node and the report-compiler template now emits `research_type`, removing the contradiction U1 creates in prose.

**Verification:** `schemas/dag-schema.json` validates old values, the new `experiment` value, and field-omitted nodes; `agents/report-compiler.md`'s theory template now emits `research_type`; `loop-scout` is untouched (it writes no theory nodes); no existing DAG file needs rewriting.

---

- U3. **Split executor harness-writing from execution; add `has_harness` to lab-tech output**

**Goal:** Stop autonomous executors from exhausting their tool budget before measuring, and let scheduled mode avoid launching full executors on experiments with no pre-existing harness.

**Requirements:** R3

**Dependencies:** None (independent of U1/U2; parallel with U4)

**Files:**
- Modify: `agents/experiment-executor.md` (Execution Protocol — checkpoint/budget-split between harness-writing Steps 3-4 and execution Step 5)
- Modify: `agents/lab-tech.md` (Check 3 / Output — emit a `has_harness` field per experiment)
- Modify: `commands/nerd.md` (Phase 6 — in scheduled mode, gate full-executor launch on `has_harness`; supervised mode may split harness-writing and execution into two calls with separate budgets)
- Modify: `commands/nerd-schedule.md` (note the scheduled-mode gate so the runner's expectations match)

**Approach:**
- Per the executor's own post-mortem (`2026-05-04`): *"Supervised mode should split harness-writing and execution into two distinct agent calls with separate budgets"* and *"Scheduled mode should not launch full experiment-executors autonomously until reliability improves — limit Phase 6 to experiments with pre-existing harnesses."*
- **The split is a hard two-agent-call boundary, not a soft mid-prompt checkpoint** (resolved per feasibility review): tool-use budget is a *per-invocation* property, and the executor is launched as a single `Agent(subagent_type="nerd:experiment-executor", ...)` call (`commands/nerd.md:385-393`). A checkpoint *inside* one call shares the same budget across harness-writing and execution — so it cannot satisfy R3. Phase 6 makes two sequential calls: (1) write-and-commit-harness, (2) run-harness-and-write-results. **Handoff artifact between calls:** the committed harness in the worktree at a known commit, plus the eval/metric command — the second invocation re-reads this from disk/git, since separate invocations share no memory.
- Add `has_harness: true|false` to lab-tech's per-experiment readiness output (computed in Check 3, which already probes harness existence). Scheduled-mode Phase 6 reads it and skips/queues experiments where `has_harness: false` rather than launching an executor that will likely time out building one.
- Inherit worktree-compilation fixes (cache daemons, inline env prefixing, never `export`) — do not re-solve.
- Keep the change a *split*, not an executor rewrite.

**Execution note:** Characterization-first in spirit — before editing, capture the current Step 3-5 boundary so the split lands at the natural seam (harness committed → separate execution pass).

**Patterns to follow:** lab-tech's existing per-experiment status block + frontmatter field style (`agents/lab-tech.md:327-358`); the `cache_fallback` retry pattern already in the executor.

**Test scenarios:**
- Happy path: lab-tech run over a batch emits `has_harness` per experiment; an experiment with an existing eval module reports `true`, one without reports `false`.
- Integration: in scheduled mode, an experiment with `has_harness: false` is NOT handed to a full executor (it's deferred/flagged), matching the post-mortem's gate.
- Edge case: supervised mode still runs `has_harness: false` experiments, but harness-writing and execution are separable so a budget exhaustion in phase one doesn't lose the measurement.
- Covers R3: the S025 failure mode (535 tool calls, no `results.json`) cannot recur silently in scheduled mode because the experiment would not have been auto-launched.

**Verification:** lab-tech output contains `has_harness`; scheduled-mode Phase 6 prose reads that field and gates on it; the executor protocol shows a clear harness/execution seam.

---

- U4. **Make merged-branch worktree cleanup correct and honor `auto_cleanup_worktrees`**

**Goal:** Never leave stale worktrees for already-merged branches; wire up the config flag that's currently dead.

**Requirements:** R4

**Dependencies:** None (parallel with U3)

**Files:**
- Modify: `commands/nerd.md` (Phase 6e merge path lines 402-416, Phase 8 prune lines 430-431)
- Modify: `commands/nerd-this.md` (Phase 8.3 lines 452-466, Phase 10 lines 478-481 — mirror)

**Approach:**
- Per the agent's N1 action items (`2026-05-08`): *"Either have the merge step always `git worktree remove`, or have the audit step always cross-check `git branch --merged` before claiming worktrees are 'in progress'."* Do **both**: make the merge step's `git worktree remove` reliable (it currently runs only on the success branch — ensure a merged branch's worktree is removed regardless of which path set the merge), and add a `git branch --merged` cross-check at the audit/prune step so a leftover worktree for a merged branch is never treated as "active."
- Wire `auto_cleanup_worktrees`: read the flag and gate the hardcoded removal on it (honoring the documented contract). When `true` (default), cleanup runs as above; when `false`, worktrees are intentionally kept.
- Leave `merge_strategy` as-is (out of scope) — note it as dead config in verification, do not expand scope to wire it.

**Patterns to follow:** Existing Phase 6e/8 worktree commands; keep inline env-var style.

**Test scenarios:**
- Happy path: an experiment merges successfully → its worktree is removed; `git worktree list` shows no `nerd-{id}` for the merged branch.
- Edge case (the exact failure): a branch merged in a prior batch leaves a worktree on disk → the next run's audit cross-checks `git branch --merged` and removes it rather than treating it as active.
- Edge case: `auto_cleanup_worktrees: false` → worktrees are kept intentionally, no removal.
- Error path: merge fails (tests fail post-merge) → worktree is kept (existing behavior preserved for debugging).
- Integration: re-run after a completed batch does NOT re-run already-merged experiments (the downstream consequence the feedback flagged).
- Covers R4: the four-stale-worktree scenario from Batch 27 cannot recur — merged branches are detected and cleaned.

**Verification:** After a successful batch, no worktrees remain for merged branches; the audit step references `git branch --merged`; `auto_cleanup_worktrees` is read by the command (no longer dead); `merge_strategy` noted as still-unwired.

---

- U5. **Add a metric-sensitivity smoke-test to lab-tech; make "experimentable" harness-aware**

**Goal:** Classify a finding "experimentable" only when a *trusted, sensitive* metric exists — verify the metric responds to a known perturbation before sweeping, and gate data-dependent experiments on a data check.

**Requirements:** R6, R5

**Dependencies:** None (independent of U1/U2; parallel with U6)

**Files:**
- Modify: `agents/lab-tech.md` (Check 3 lines 107-129 — add sensitivity smoke-test; Check 1 Data Access lines 53-79 — extend data-prerequisite check; keep Check 8b determinism separate)
- Modify: `commands/nerd.md` (Phase 2c lines 247-286 — classification consults lab-readiness/instrument trust, not just `experiment_type` string)
- Modify: `commands/nerd-loop.md` (measurability gate lines 28-34 — criterion 3 "Sensitive" becomes mechanically verified, not asserted)

**Approach:**
- **Sensitivity smoke-test (R6):** in Check 3, after confirming the metric command runs, inject a known perturbation (a deliberately bad/good change, or a synthetic input) and confirm the metric output *moves*. If it doesn't, emit a BLOCKER ("instrument insensitive — metric does not respond to a known perturbation"), not "ready." This makes nerd-loop's asserted criterion 3 mechanical.
- **Metric-shape classification (feasibility review):** auto-synthesizing a perturbation is reliable only for *mechanical* metrics (size: append bytes; compile time: add a sleep; latency: inject delay). For *semantic* metrics (search relevance, quality scores, KPIs) a meaningful perturbation is project-specific and usually not synthesizable from the metric command alone — and these are exactly the broken-harness shapes U5 most wants to catch. So lab-tech first classifies the metric (mechanical vs semantic); it auto-perturbs the mechanical class, and for the semantic class emits an *actionable* SETUP-NEEDED ("provide a known-good/known-bad fixture pair") rather than a bare "cannot verify." This means U5 catches the mechanical broken-harness cases automatically and gives a concrete next step for the rest — never a false "ready."
- **Two distinct verdicts, possibly one pass:** Check 8b (determinism: same code → same output, low CV) and the new sensitivity check (different code → different output) are kept as two distinct *verdicts* — do not conflate them. They MAY share one harness-setup pass (run baseline twice for determinism, plus a perturbed run for sensitivity, from one fixture setup) to avoid doubling lab-tech cost — relevant because U3 exists precisely because executors exhaust budget. Decide pass-sharing when editing lab-tech; the invariant is two separate verdicts, not necessarily two separate passes.
- **Data-prerequisite gate (R5):** extend Check 1 / Check 3 so a data-dependent experiment is verified to have its required data *before* it's selected for a batch — per `2026-05-11`, the fix is "a seeded eval database loaded by harnesses as fallback" plus a predicate that checks data prerequisites so the pipeline doesn't burn an executor slot on `FAILED (data_insufficiency)`.
- **Phase 2c (R6):** a finding with a valid `experiment_type` string but no trusted/sensitive metric is classified "instrument-blocked," not "experimentable."

**Patterns to follow:** Check 8b's metric-running structure (run N times, compare) — *mirror its mechanics, invert its assertion*. lab-tech's `[OK]/[FIXED]/[BLOCKER]/[SETUP NEEDED]` status prefixes.

**Test scenarios:**
- Happy path: a metric that moves under a known perturbation passes the sensitivity check → finding stays "experimentable."
- Edge case (the core failure): a metric that does NOT move under a known perturbation (the broken-harness case) → BLOCKER "instrument insensitive," finding reclassified, not swept.
- Edge case: a data-dependent experiment with empty/missing data → gated before executor launch, not selected for the batch (R5 — the empty-`arras.db` scenario).
- Error path: sensitivity perturbation can't be synthesized cheaply for a given metric → degrade to a clear "SETUP NEEDED: cannot verify sensitivity" rather than a false "ready."
- Integration: nerd-loop's measurability gate now actually fails to start on an insensitive metric instead of trusting criterion 3.
- Covers R6, R5: an experiment grounded in a broken instrument is caught pre-sweep; a data-starved experiment never burns an executor slot.

**Verification:** lab-tech Check 3 runs a perturbation and reports sensitivity; an insensitive metric produces a BLOCKER; Phase 2c has an "instrument-blocked" outcome; the nerd-loop gate references the mechanical check; Check 8b is untouched and still separate.

---

- U6. **(GATED) Instrument-inversion mode when the "Metric is wrong" theory is live**

**Goal:** When the live competing theory is "Metric is wrong," let the experiment treat the measurement instrument as the system-under-test — sweep measurement surface/threshold/cadence against a known perturbation until the metric responds.

**Requirements:** R7

**Gate (from review — single-tool-concentrated evidence):** U6 rests on just 2 entries, and one crop-tool session (`4435cee2`) produced 4 entries across 4 different tags — the "one session split by signal type" pattern. It is also the most *novel* unit (a new "recursively apply nerd to its own instrument" abstraction). So U6 does NOT ship in Phase 1. It is gated like U7: ship U5 (the sensitivity smoke-test, well-evidenced across multiple sessions) first, and build U6's full instrument-sweep recipe only if the instrument-wrong/harness-wall case recurs across more sessions than the crop-tool family. Until then, U5 already catches the *insensitive-metric* case as a BLOCKER; U6 is the additional "now systematically fix the instrument" capability, which the thin evidence does not yet justify building.

**Phase-1 stub (optional, low-cost):** a one-line pointer in `skills/experiment-planning/SKILL.md` under "Metric is wrong" — "consider inverting: make the instrument the system-under-test (see U6, gated)" — captures the insight without building the abstraction. The full recipe below is the gated work.

**Dependencies:** Soft-depends on U5 (reuses the "known perturbation" concept). Gated — does not ship in Phase 1.

**Files:**
- Modify: `skills/experiment-planning/SKILL.md` (the "Metric is wrong" theory at line 21 — add an instrument-inversion experiment recipe)
- Modify: `agents/plan-reviewer.md` (theory-generation row at line 65 — when "Metric is wrong" wins, emit an instrument-sweep plan instead of a source-code sweep)

**Approach:**
- Per `2026-05-19-surface-gap-nerd-on-instrument-mode.md`: when the metric itself is the suspect, invert — make the harness the system-under-test and sweep its parameters (which surface to read, which threshold, which sampling cadence) against a deterministic "does the metric respond to a known perturbation?" predicate. This is the recursive application of nerd to its own instrument, without a new top-level command.
- The recipe reuses U5's perturbation: instead of perturbing the *code* and reading the metric, hold a known perturbation fixed and sweep the *instrument* until it detects the perturbation.
- `plan-reviewer` chooses this plan shape when the "Metric is wrong" theory is the one to test.

**Patterns to follow:** Existing competing-theory → experiment-plan mapping in `skills/experiment-planning/SKILL.md` and `agents/plan-reviewer.md`; the existing theory recipes.

**Test scenarios:**
- Happy path: a plan where "Metric is wrong" is the live theory produces an instrument-sweep plan (surface/threshold/cadence variants) rather than a source-code parameter sweep.
- Edge case: no known perturbation available → the recipe degrades to flagging "instrument-inversion needs a ground-truth perturbation" rather than producing a meaningless sweep (ties to U5's same gap).
- Integration: the harness-wall scenario (`2026-05-21-webapp-surface-gap-harness-wall-in-loop.md`) — a convergence loop blocked by an instrument that can't measure — would now have an instrument-sweep plan available instead of forcing a code refactor.
- Covers R7: "Metric is wrong" becomes an actionable experiment shape, not just a verdict label.

**Verification:** `skills/experiment-planning/SKILL.md` documents the instrument-inversion recipe under "Metric is wrong"; `plan-reviewer` emits it when that theory is live; the recipe explicitly reuses a known perturbation.

---

- U7. **Sweep-of-one input: test a specific commit/hypothesis** *(gate decided OPEN — building in Phase 1)*

**Goal:** Let nerd accept a "test this specific commit/hypothesis" brief and run it as a one-cell sweep producing a numeric verdict — the ce-debug-overlap capability.

**Gate decision (Shawn, 2026-05-21): OPEN — build now.** The 2-session ce-debug-overlap evidence (`2026-05-19-tool-overlap-nerd-vs-ce-debug.md`, `2026-05-21-webapp-tool-overlap-ce-debug-commit-isolation.md`) is accepted as sufficient rather than waiting ~30 days for the Phase-2 harvest. The `"hypothesis"` enum value (deferred from U2) is added as part of this unit. The Phase-2 measurement gate described below is retained as documentation of the original reasoning but is superseded by this decision.

**Requirements:** R8

**Dependencies:** Soft-deps U1 (the repositioning that makes a single-commit test a *central* case, which is why the entry-point shape resolves to a native mode below) and reuses the executor/report path. Not blocking — can build in parallel with the rest of Phase 1.

**Files:**
- Modify: `commands/nerd-this.md` — add a structured-brief mode (a `commit:`/`hypothesis:` brief detected in `$ARGUMENTS`) that scopes to a commit and runs a sweep-of-one, alongside the existing free-text scope inference
- Modify: `schemas/dag-schema.json` — add the `"hypothesis"` `research_type` enum value (deferred from U2; this is its real producer)
- Modify: `agents/report-compiler.md` — emit `research_type: "hypothesis"` for single-commit hypothesis-test nodes
- Reference precedent: `commands/nerd-intern.md:12` (structured `$ARGUMENTS` parsing)

**Approach:**
- **Entry-point shape — re-derived under the post-repositioning framing (Shawn, 2026-05-21): a native mode on `nerd-this`, NOT a separate `/nerd-test` command.** The "different intent → own entry point" precedent assumed the parameter-discovery identity that item 3 reverses; once nerd is "execute any falsifiable experiment with a trusted numeric metric," a single-commit hypothesis-test is a *central case*, and the ce-debug-overlap feedback explicitly wants "the choice [to] collapse" to one tool. A native mode on `nerd-this` (which already does commit/branch scope inference in Signal 1) is the lowest-friction shape and avoids a new top-level command. Reuse `nerd-intern.md:12`'s structured-`$ARGUMENTS` parsing pattern to detect a `commit:`/`hypothesis:` brief.
- A commit brief sets scope to that commit's changed files (`git diff {sha}^..{sha}`) and runs a baseline-vs-HEAD comparison — a sweep-of-one — producing the same numeric verdict ce-debug gives.
- Subject to U5's gate: a sweep-of-one still requires a trusted numeric metric (consistent with U1's bound). A brief with no numeric metric degrades to the same SETUP-NEEDED path.

**Patterns to follow:** `commands/nerd-intern.md` structured parsing; `commands/nerd-this.md` Signal 1 commit-scope inference; the existing executor/report-compiler path (reuse, don't duplicate).

**Test scenarios:**
- Happy path: `nerd-this commit:<sha> metric:<cmd>` scopes to the commit's changed files, runs a baseline-vs-commit comparison, and emits a numeric KEEP/CHANGE/REFUTE verdict.
- Happy path: a free-text `nerd-this <topic>` invocation still works unchanged (the brief mode is additive, detected by the `commit:`/`hypothesis:` prefix).
- Integration: a ce-debug-style "did this commit cause the regression?" brief produces the same numeric output ce-debug would, and writes a `research_type: "hypothesis"` node to the DAG.
- Edge case: a brief with no numeric metric → SETUP-NEEDED via U5's gate, not a false run.
- Covers R8: the ce-debug-overlap capability exists natively in nerd; the choice collapses.

**Verification:** `nerd-this` accepts a `commit:`/`hypothesis:` brief and runs a sweep-of-one; free-text invocation is unchanged; a hypothesis node validates against the widened schema; the brief path reuses (not duplicates) the executor/report path.

---

## System-Wide Impact

- **Interaction graph:** U1 touches the most files but changes no execution path. U3 changes the lab-tech → orchestrator → executor handoff (new `has_harness` field). U5 changes the lab-tech → Phase 2c classification handoff (new "instrument-blocked" outcome). U6 changes the plan-reviewer → experiment-planning handoff (new plan shape).
- **Error propagation:** U5 introduces a new BLOCKER class (instrument insensitive) and a new gated state (data-insufficiency caught pre-launch) — both should surface in lab-readiness reports and stdout summaries, not silently drop experiments.
- **State lifecycle risks:** U4 is the highest-risk for state — incorrect cleanup could remove an *un*merged worktree (data loss) or leave merged ones (the bug). The `git branch --merged` cross-check is the guard; test the merge-failed path explicitly (worktree must be kept).
- **API surface parity:** U4's worktree logic exists in BOTH `commands/nerd.md` and `commands/nerd-this.md` (mirrored) — both must get the same fix. U1's positioning must be consistent across manifest + commands + agents + skills + README (don't reword one and leave another).
- **Integration coverage:** U3's scheduled-mode gate and U5's data gate are integration behaviors (orchestrator reads a lab-tech field and changes what it launches) — verify the field is both *emitted* by lab-tech and *consumed* by the command, per the DAG doc's "every verb has a tool / grep all invocations" prevention rule.
- **Unchanged invariants:** DAG write rules (single-writer, crash-safe, INCONCLUSIVE-no-edge) are preserved by U2. No agent/command/skill `name` or `subagent_type=` reference changes (U1 scope boundary). `merge_strategy` config stays unwired (explicit non-goal).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| U1 reword drifts into behavior change or renames | Scope boundary: descriptions/prose only; grep `subagent_type=` and `name:` unchanged in verification |
| U1 done inconsistently (manifest reworded, an agent left parameter-framed) | Complete file inventory in Context; consistency grep for "tunable parameter" in U1 test scenarios |
| U4 removes an unmerged worktree (data loss) | `git branch --merged` cross-check; explicit merge-failed test keeps the worktree |
| U4 mirror divergence (nerd.md fixed, nerd-this.md not) | Both files in U4 Files list; parity called out in System-Wide Impact |
| U5 sensitivity perturbation not synthesizable for semantic metrics (relevance/quality/KPI) — exactly the broken-harness shape it most wants to catch | Classify metric mechanical vs semantic; auto-perturb the mechanical class, emit actionable "provide a known-good/known-bad fixture pair" SETUP-NEEDED for the semantic class — never a false "ready" |
| U5/U6 redundant with Check 8b via generalize-and-merge temptation | Two distinct *verdicts* (determinism vs sensitivity), opposite goals; MAY share one harness pass to control cost — but never one merged verdict |
| **U1's core mechanism (rewording changes routing) is unproven** — one entry shows nerd in the skill catalog and ignored anyway; rewording a description nobody reads won't fix routing-context misses | Treat U1 as a low-cost bet, not a validated fix (it's the cheapest item, now ranked #3 not #1); U1 verification measures only the ~4 wording-fixable entries; the Phase-2 gate is the success measurement, made decidable |
| **U6 evidence is single-tool-concentrated (N=2, crop-tool family) and the unit is a novel abstraction** | U6 gated out of Phase 1; build only if the instrument-wrong case recurs beyond `4435cee2`; U5's BLOCKER already covers the insensitive-metric case |
| U7 built before wording proves insufficient (wasted work) | Gate decided OPEN on 2-session ce-debug-overlap evidence (Shawn, 2026-05-21); U7 built as a *native nerd-this mode* (low marginal cost, reuses executor/report path), not a speculative new command — limits wasted-work exposure |
| U7 native-mode bloats `nerd-this`'s argument surface / collides with its scope-inference | Brief mode is additive and prefix-detected (`commit:`/`hypothesis:`); free-text invocation unchanged (U7 test scenario verifies this); reuses Signal 1 commit-scope inference |
| Prompt-sync drift (a reworded concept referenced inconsistently across commands) | DAG-doc prevention rule: grep all `subagent_type=` and shared-constant references |

---

## Phased Delivery

### Phase 1 — Ship the implemented units (parallel)
Four independent tracks, led by reliability (U3, U4) since it fixes silently-broken overnight runs. The other tracks: harness-trust (**U5 only** — U6 is gated), repositioning (U1, U2), and sweep-of-one (U7, gate decided open). Soft dependencies (U2 after U1; U7 after U1+U5) are narrative, not blocking. All Phase-1 units are grounded in multi-session evidence. Optional: the U6 one-line stub pointer (see U6) can land here at near-zero cost.

### Phase 2 — (superseded) U7 gate decided early
The original plan gated U7 behind a post-U1 harvest with this decidable rule, retained for the record: *forcing function* — run one feedback harvest over the ~30 days after U1 lands; *decision rule* — if ≥1 falsifiable single-commit/numeric misroute appears, build U7, else close R8 as "resolved by repositioning." **This gate was decided OPEN early** (Shawn, 2026-05-21) on the strength of the existing 2-session ce-debug-overlap evidence, so U7 ships in Phase 1 and this measurement phase is no longer a blocker. The harvest is still worth running to validate U1's effect generally, but it no longer gates U7.

### Phase 3 — Build the one remaining gated unit if its gate opens
- **U6 (instrument-inversion):** build the full instrument-sweep recipe only if the instrument-wrong / harness-wall case recurs across sessions beyond the crop-tool family (`4435cee2`). Until then U5's BLOCKER already catches the insensitive-metric case; U6 adds the systematic-fix capability that the thin evidence doesn't yet justify.

---

## Documentation / Operational Notes

- After U3/U4 land, capture the tool-budget-exhaustion and worktree-cleanup learnings with `/ce-compound` — the research surfaced these are genuinely new territory not covered by existing `docs/solutions/`.
- The measurability-gate / metric-sensitivity learning (U5) also postdates existing solution docs — worth a `/ce-compound` capture.
- Per the project's CLAUDE.md feedback memory: sync the nerd plugin to the shrimpshack marketplace after merging these changes.

---

## Sources & References

- **Evidence dir (origin):** `docs/feedback/` — 18 entries, re-tallied by `idea_tag`; committed at `41932dc`.
- Key feedback entries: `docs/feedback/2026-05-06-aipipeline-tool-overlap-bespoke-experiment-skill.md`, `2026-05-05-aipipeline-positioning-nerd-named-then-passed-over.md`, `2026-05-04-execution-defect-autonomous-executor-reliability.md`, `2026-05-08-execution-defect-stale-worktree-noncleanup.md`, `2026-05-11-prereq-blocked-empty-arras-db.md`, `2026-05-19-prereq-blocked-by-broken-harness.md`, `2026-05-19-surface-gap-nerd-on-instrument-mode.md`.
- Institutional learnings: `docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`, `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`, `docs/solutions/build-errors/parallel-worktree-compilation.md`.
- Positioning inventory + reliability anchors: verified repo-research pass (file paths and line numbers throughout Context & Research).

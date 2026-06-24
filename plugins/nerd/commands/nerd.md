---
name: nerd
description: "Let the nerd loose on your codebase. Designs and runs rigorous experiments — any falsifiable question with a trusted instrument, whether a measurable numeric metric (parameter sweeps, single-commit hypothesis tests) or an LLM judge scoring against a pre-registered rubric — in worktrees while you sleep, and delivers findings. Use with no args to nerd out on everything, or pass a topic to focus (e.g., /nerd search relevance)."
argument-hint: "[topic]"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---

# nerd — Obsessive Codebase Research Pipeline

Turn the nerd loose. It runs any falsifiable experiment that produces a measurable number against your codebase — proving whether a change helps, hurts, or does nothing. Finding every hardcoded threshold, magic number, and untested heuristic and proving whether they're optimal is one thing it does well; testing whether a specific commit caused a regression, or whether one model/prompt beats another, is the same machinery pointed at a different question.

## Input

<user_topic>$ARGUMENTS</user_topic>

## Pre-flight

**Check schedule mode:** If `NERD_SCHEDULED=1` is set, operate fully autonomously — skip all AskUserQuestion calls, execute all backlog experiments, make decisions without user input.

**Check global setup:**
```bash
cat ~/.claude/plugins/nerd/hardware-profile.yaml 2>/dev/null
```
If no hardware profile: "Run /nerd-setup first to calibrate your hardware." Stop.

**Auto-init project (if not already initialized):**
Check if this project has been set up for nerd. If not, do it silently:

```bash
if [ ! -f .claude/nerd.local.md ]; then
    # First run in this project — auto-initialize
    mkdir -p docs/research/plans docs/research/results .claude

    # Detect project language and test command
    if [ -f Cargo.toml ]; then lang="rust"; test_cmd="cargo test"; build_cmd="cargo build";
    elif [ -f package.json ]; then lang="typescript"; test_cmd="bun test"; build_cmd="bun run typecheck";
    elif [ -f pyproject.toml ]; then lang="python"; test_cmd="pytest"; build_cmd="python -m py_compile";
    elif [ -f go.mod ]; then lang="go"; test_cmd="go test ./..."; build_cmd="go build ./...";
    else lang="unknown"; test_cmd="echo 'no tests configured'"; build_cmd="echo 'no build configured'"; fi
fi
```

Create `.claude/nerd.local.md` with defaults:

Derive `max_parallel_experiments` from the hardware profile:
```bash
memory_gb=$(grep "memory_gb" ~/.claude/plugins/nerd/hardware-profile.yaml 2>/dev/null | awk '{print $2}')
# Reserve 4GB for interactive use, 2 per experiment, clamp to 1-6
max_parallel=$(( (${memory_gb:-16} - 4) / 2 ))
[ "$max_parallel" -lt 1 ] && max_parallel=1
[ "$max_parallel" -gt 6 ] && max_parallel=6
```

```yaml
---
max_parallel_experiments: {max_parallel}
merge_strategy: auto
auto_cleanup_worktrees: true
language: {lang}
test_command: "{test_cmd}"
build_command: "{build_cmd}"
backlog: []
---
```

Add `.claude/nerd.local.md` to the project's `.gitignore` if not already present:

```bash
grep -q "nerd.local.md" .gitignore 2>/dev/null || echo ".claude/nerd.local.md" >> .gitignore
```

This means `/nerd-setup` is only needed once per machine (hardware calibration). Every new project auto-inits on first `/nerd` run.

**Auto-init Research DAG (per-project):**

```bash
PROJECT_SLUG=$(echo "$(basename "$(dirname "$PWD")")-$(basename "$PWD")" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
DAG_DIR="$HOME/.claude/plugins/nerd/dag"
DAG_PATH="$DAG_DIR/projects/$PROJECT_SLUG.json"

# Create project DAG if missing
if [ ! -f "$DAG_PATH" ]; then
    mkdir -p "$DAG_DIR/projects"
    echo '{"nodes":[],"edges":[],"project":"'"$PROJECT_SLUG"'","project_path":"'"$PWD"'","version":1}' > "$DAG_PATH"
fi

# Create global index if missing (in case nerd-setup wasn't run)
if [ ! -f "$DAG_DIR/index.json" ]; then
    echo '{"nodes":[],"edges":[],"version":1}' > "$DAG_DIR/index.json"
fi

# Verify project_path matches current directory (detect slug collisions)
stored_path=$(python3 -c "import json; print(json.load(open('$DAG_PATH')).get('project_path',''))" 2>/dev/null)
if [ -n "$stored_path" ] && [ "$stored_path" != "$PWD" ]; then
    echo "ERROR: DAG slug collision — $DAG_PATH belongs to $stored_path, not $PWD. Cannot use the same DAG for different projects. Rename one project directory or manually move the DAG file."
    # Do not proceed with DAG operations — set dag_path to empty so agents skip DAG features
    DAG_PATH=""
fi
```

**Compute DAG staleness and generate summaries:**

Read the project DAG. For each active node with `source_files`, hash the current file contents and compare against `codebase_hash`. If the hash differs or any source file is deleted, mark the node `status: "stale"`. Write the updated DAG back using the crash-safe protocol (backup → tmp → validate → rename).

Then generate two markdown summaries for downstream agents:

**Scanner summary** (for Phase 2 parameter-scanner):
```markdown
## Prior Research (from DAG)

### Skip These Parameters (already resolved):
- {file}:{line} `{param}` — {result} in {experiment}: "{evidence}". Recommendation: {rec}.

### Re-test These (stale — source files changed):
- {file}:{line} `{param}` — tested in {experiment} but source file changed. Previous: {result}.

### Open Hypotheses (untested theories from prior runs):
- {theory_id}: "{title}" — spawned from {verdict_id}, no experiment yet.
```

**Per-experiment plan-reviewer summaries** (for Phase 3, one per experiment):
```markdown
## Prior Theories on {parameter} ({file}:{line})

- {theory_id} ({result}): "{title}" — {evidence}
- Edge: {verdict_id} spawned {theory_id} — "{reason}"
```

Filter plan-reviewer summaries by source file overlap with the experiment's target files. Include edge context (spawned relationships).

**Performance scanner summary** (for Phase 2b specialist agents):
```markdown
## Prior Research — Performance (from DAG)

### Skip These Areas (already analyzed, active verdicts):
- {file}:{function} — {result} in {experiment}: "{evidence}". Category: {category}.

### Re-analyze These (stale — source files changed):
- {file}:{function} — analyzed in {experiment} but source changed. Previous: {result}.

### Open Hypotheses (untested performance theories from prior runs):
- {theory_id}: "{title}" — spawned from {verdict_id}, category: {category}.
```

Filter to nodes with `research_type: "performance"` (or tags containing "performance"). For parameter nodes, use the scanner summary. This separation ensures each agent type receives relevant DAG context.

Store: `$PROJECT_SLUG`, `$DAG_PATH`, `$DAG_DIR/index.json`, scanner summary, perf summary, per-experiment summaries.

**Intern Pre-flight (global default, local override):**

```bash
# Check intern config — project-local first, then global
if grep -q "intern:" .claude/nerd.local.md 2>/dev/null; then
  # Project has intern config — check if explicitly disabled
  INTERN_DISABLED=$(grep -A5 "intern:" .claude/nerd.local.md 2>/dev/null | grep "enabled: false" | wc -l | tr -d ' ')
  [ "$INTERN_DISABLED" = "1" ] && INTERN_SOURCE="none" || INTERN_SOURCE="project"
elif [ -f ~/.claude/plugins/nerd/intern/config.yaml ]; then
  INTERN_SOURCE="global"
else
  INTERN_SOURCE="none"
fi
```

If `INTERN_SOURCE != "none"`: Execute the Pre-Run Health Check defined in `Skill(skill="nerd:intern-delegation")`, Phase 0. Read config from the resolved source (project `.claude/nerd.local.md` or global `~/.claude/plugins/nerd/intern/config.yaml`). Read state from the resolved source (project `.nerd/intern/state.json` or global `~/.claude/plugins/nerd/intern/state.json`). If state.json fails JSON parsing, treat as unconfigured for this run and log warning.

**Always-shadow:** When the intern is available, it shadows ALL tasks on every run — even tasks in `disabled` mode. See `Skill(skill="nerd:intern-delegation")` for the always-shadow protocol. This is free (local model, no API cost) and builds training data for future improvement.

Store: `INTERN_AVAILABLE`, `INTERN_SOURCE`, config values, and task modes.

**Detect project:**
```bash
cat CLAUDE.md .claude/CLAUDE.md 2>/dev/null | head -50
git branch --show-current
```

Store: language, test command, current branch from the local config.

**Guard: experiments must not run off main.**

```bash
CURRENT_BRANCH=$(git branch --show-current)
# Resolve the default branch without assuming 'master' when origin is absent.
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$DEFAULT_BRANCH" ]; then
  for cand in main master; do
    if git rev-parse --verify "origin/$cand" >/dev/null 2>&1 || git rev-parse --verify "$cand" >/dev/null 2>&1; then
      DEFAULT_BRANCH="$cand"; break
    fi
  done
fi
```

**Detached HEAD / empty branch is a hard stop.** If `$CURRENT_BRANCH` is empty, the repo is in a detached-HEAD state. Do NOT proceed — every downstream step (worktree creation from `$CURRENT_BRANCH`, the Phase 6e merge-back, the Phase 8 `git branch --merged "$CURRENT_BRANCH"` reconcile) misbehaves or errors fatally on an empty branch name. In interactive mode, stop and ask the user to check out a branch first; in scheduled mode, auto-create and switch to `nerd/scheduled-{date}` (handled below), then re-capture.

If `$CURRENT_BRANCH` is empty/detached, OR equals `$DEFAULT_BRANCH`, OR `$DEFAULT_BRANCH` could not be resolved (treat an unresolvable default as "the current branch may be protected — ask"):
- In interactive mode: Use AskUserQuestion: "You're on {current_branch_or_'a detached HEAD'}. Experiments create worktrees and merge results back into your current branch — running off main (or a detached HEAD) risks polluting it with experiment branches and partial results. Create a branch first? (suggest: `git checkout -b nerd/research-{date}`)"
- In scheduled mode: Auto-create `nerd/scheduled-{date}` and switch to it.

**After any switch, re-capture `CURRENT_BRANCH`.** Whether the user accepted the interactive branch-create or scheduled mode auto-switched, the working branch has changed — so re-run `CURRENT_BRANCH=$(git branch --show-current)` and store the *post-switch* value. Every later step that says "the source branch" / `$CURRENT_BRANCH` (Phase 6c worktree creation, Phase 6e merge-back, Phase 8 reconcile) MUST use this re-captured value, never the pre-switch one — otherwise experiments branch from and merge into the very branch the guard just moved you off.

Store: the re-captured `$CURRENT_BRANCH`, `$DEFAULT_BRANCH`.

## Phase 1: Check the Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

**Resurface deferred experiments (closes the breadcrumb loop).** Scheduled runs append experiments they couldn't run (e.g. `has_harness: false`) to `docs/research/deferred-experiments.md`. Read it and fold any still-relevant entries into this run's candidate set so a deferral is a *postponement*, not a silent drop — this is the consumer for the breadcrumb Phase 6c writes:

```bash
cat docs/research/deferred-experiments.md 2>/dev/null
```

For each deferred entry whose blocking reason may now be resolvable (e.g. an interactive run can build the harness a scheduled run skipped), add it to the backlog as a candidate; drop entries that are stale or already completed in the DAG.

If backlog has `proposed` entries and no topic: skip to Phase 3 — the nerd has already been collecting findings.
If backlog empty or topic specified: continue to Phase 2.

## Phase 2: Codebase Scan

**Intern delegation (parameter-detection):** If `INTERN_AVAILABLE == 1`, delegate per `Skill(skill="nerd:intern-delegation")` — check task mode, call intern if live/shadow, validate, gate on confidence, log to delegation log. If run failure counter > 3, skip remaining intern calls.

### Phase 2a: Parameter Scan + Performance Explorer (parallel)

Launch both scans in parallel — they are independent:

```
Agent(subagent_type="nerd:parameter-scanner", prompt="Scan {cwd} for tunable parameters. Topic: {user_topic or 'all'}. {scanner_dag_summary}. Return structured JSON list.", run_in_background=true)

Agent(subagent_type="nerd:perf-explorer", prompt="Map {cwd} for performance research. Topic: {user_topic or 'all'}. {scanner_dag_summary}. Identify hot paths, I/O boundaries, complex functions, allocation hotspots, and network boundaries. Return structured JSON area map.", run_in_background=true)
```

Wait for both to complete. Store: parameter findings list, performance area map.

### Phase 2b: Performance Specialist Dispatch (after explorer, parallel)

Based on the perf-explorer's area map, use **judgment** to decide which specialist agents to launch. This is NOT hardcoded dispatch — read the full area map and its `characteristics` to decide which specialists would find meaningful issues.

**Guidance for specialist selection:**

| Characteristic in Area Map | Category Parameter |
|---|---|
| `iteration_heavy`, `complex_logic` | `nerd:perf-specialist` with `category=algorithmic` |
| `io_boundary` | `nerd:perf-specialist` with `category=io` |
| `allocation_hot` | `nerd:perf-specialist` with `category=memory` |
| `repeated_computation` | `nerd:perf-specialist` with `category=caching` |
| `network_boundary` | `nerd:perf-specialist` with `category=network` |

If the explorer found no areas with a particular characteristic, don't launch that specialist. If the explorer found nothing at all, skip Phase 2b entirely.

Compute start IDs for performance findings: take the highest ID from the parameter-scanner results (e.g., if parameter-scanner used E001-E012, start performance IDs at E013). **Pre-allocate non-overlapping ID ranges** per specialist based on the number of areas sent to each (e.g., algo gets E013-E019, io gets E020-E026). This prevents ID collisions when specialists run in parallel.

Launch selected specialists in parallel, each with its own ID range:

```
Agent(subagent_type="nerd:perf-specialist", prompt="Category: algorithmic. Analyze algorithmic complexity in these areas from the performance explorer: {relevant_areas_json}. Project: {cwd}. {perf_dag_summary}. Start IDs from: {algo_start_id}. Max IDs: {algo_range_size}. Return findings as JSON array.", run_in_background=true)

Agent(subagent_type="nerd:perf-specialist", prompt="Category: io. Analyze I/O patterns in these areas from the performance explorer: {relevant_areas_json}. Project: {cwd}. {perf_dag_summary}. Start IDs from: {io_start_id}. Max IDs: {io_range_size}. Return findings as JSON array.", run_in_background=true)

# ... launch one perf-specialist per matched category (algorithmic, caching, io, memory, network)
```

Wait for all specialists to complete. IDs should not collide since each specialist was given a pre-allocated range. If any specialist used fewer IDs than allocated, the gaps are harmless.

### Phase 2c: Combine and Present Findings

Combine parameter findings and performance findings into a unified candidate list.

**Classify all findings by measurability:**

Split into groups:
- **Experimentable (provisional)**: Findings where a shell command can measure the effect (parameter sweeps, benchmarks, I/O counts). Has a valid `experiment_type` like `parameter_sweep`, `comparison`, `ablation`, `algo_benchmark`, `io_benchmark`, `memory_benchmark`, `cache_benchmark`, `network_benchmark`. **"Experimentable" here is provisional — it means a sweepable value exists, not that the metric is trusted.** Lab-tech (Phase 5) verifies the metric is actually *sensitive* to change; a finding whose metric does not respond to a known perturbation, or whose data prerequisites are unmet, is demoted to **instrument-blocked** and does NOT proceed to execution until the instrument is fixed.
- **Analytical**: Findings where the only evaluation is human judgment or code review (has `experiment_type: "analytical"` or `measurability: "analytical"`).
- **Instrument-blocked** (assigned by lab-tech, not at scan time): a finding that looked experimentable but has no trusted/sensitive metric or unmet data prerequisites. Surfaced as a blocker for the user to fix, not run.
- **Rubric-judged** (declared by the experiment author, not at scan time): an experiment whose plan declares `instrument: judge_rubric` — evaluated by an LLM judge against a pre-registered rubric instead of a numeric metric. This is the *expected positive* route for a qualitative sweep (rendered images, prompts, model outputs), distinct from instrument-blocked (a *failure* outcome): a rubric-judged experiment proceeds to lab-tech's **judge-instrument gate** (Check 3) in Phase 5, and only becomes instrument-blocked if it *fails* that gate (anchors missing, judge insensitive, judge fails the triangle test, or rubric hash mismatch). A plan that declares `instrument: judge_rubric` but no `rubric:` field is a BLOCKER here, before lab-tech runs: `instrument: judge_rubric requires a rubric: field naming a library id or path.` Because rubric mode is author-declared (the parameter/performance scanners do not emit rubric findings), rubric experiments arrive as hand-authored plans or via `/nerd-this` brief mode — they do not use the Phase 3 parameter/performance plan-reviewer templates, so no rubric variant of those templates is needed.

**Deduplication for performance findings:** Use `dedup_key` (format: `file:function:metric_type`). If the backlog already has an entry with the same dedup_key, skip it.

Present findings grouped by measurability, then by type and category:

```
The nerd found {N} parameter opportunities and {M} performance opportunities.

Experimentable ({E} total): Can be measured with automated metrics
  Parameters:
    E001 [high] Jaro-Winkler threshold (src/entities/resolution.rs:92) — parameter_sweep
    E002 [medium] Cache TTL (src/cache/config.ts:15) — parameter_sweep
  Performance:
    Algorithmic:
      E010 [high] Quadratic search in rankResults (src/search/ranking.ts:45)
    I/O:
      E011 [high] N+1 query in handleQuery (src/search/handler.ts:87)
    Caching:
      E012 [medium] Repeated regex compilation (src/parser/log.ts:23)

Analytical ({A} total): Can be reasoned about but not swept
    E013 [low] Potential connection leak (src/db/pool.ts:12)
    E014 [low] Prompt template clarity (src/prompts/system.ts:5)

Which ones should the nerd investigate?
```

Use AskUserQuestion to let the user select. Add selections to backlog.

Experimentable findings proceed to Phase 3 (experiment design → worktree execution) — but only those that survive lab-tech's sensitivity + data-prerequisite checks in Phase 5. Findings demoted to **instrument-blocked** there are pulled from the batch and surfaced to the user with the instrument fix needed.
Analytical findings proceed to Phase 3 but use the plan-reviewer for **analytical review** — generating competing theories and reasoned recommendations without building sweep harnesses.
Rubric-judged findings proceed to Phase 3 and Phase 5 like experimentable findings, but lab-tech runs the **judge-instrument gate** (Check 3) instead of the numeric sensitivity check, and Phase 6c runs them through the executor's judge-rubric branch (no harness to build — see the rubric note in Phase 6c). A rubric-judged experiment that fails the gate is demoted to instrument-blocked, exactly like a numeric experiment with an insensitive metric.

## Phase 3: Experiment Design

For each `proposed` entry, launch plan-reviewer agents **in parallel**. Adapt the prompt based on finding type:

**Parameter entries:**
```
Agent(subagent_type="nerd:plan-reviewer", prompt="Create experiment plan for {entry.title}. Parameter: {entry.parameter} at {entry.file}:{entry.line}. {per_experiment_dag_summary}. Write to docs/research/plans/{entry.id}-plan.md.", run_in_background=true)
```

**Performance entries** (entries with `research_type: performance`):
```
Agent(subagent_type="nerd:plan-reviewer", prompt="Create experiment plan for {entry.title}. Performance finding at {entry.file}:{entry.function} (line {entry.line}). Current behavior: {entry.current_behavior}. Proposed improvement: {entry.proposed_improvement}. Metric: {entry.metric} ({entry.metric_direction}). Metric command: {entry.metric_command}. Category: {entry.category}. {per_experiment_dag_summary}. Write to docs/research/plans/{entry.id}-plan.md.", run_in_background=true)
```

Update status: `proposed` → `planned`. Wait for all plan agents.

## Phase 4: Review Gate

Present plans. Use AskUserQuestion: "Plans ready. Execute all, review first, or select subset?"

## Phase 5: Lab Readiness Check

Before spinning up expensive experiment agents, validate that the lab is ready.

**Rubric-instrument pre-flight context (judge_rubric batches only).** If any experiment in the batch declares `instrument: judge_rubric`, the orchestrator first queries the project DAG for `rubric` and `triangle_verdict` nodes matching the batch's rubrics and judges, and renders them into a filtered-markdown block injected into lab-tech's prompt. lab-tech must not parse raw DAG JSON — these are orchestrator-mediated reads per `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`. The block carries **full** sha256 hashes (not prefixes) so lab-tech's hash-lock check can match byte-for-byte:

```
Rubric on file: portrait-v3 hash=<full-sha256> source=.nerd/rubrics/portrait-v3.yaml
Triangle verdicts on file: (rubric_hash=<full-sha256>, judge=claude-opus-4-7) PASS 13/15 verified 2026-05-12; (rubric_hash=<full-sha256>, judge=claude-opus-4-7) FAIL 6/15 verified 2026-04-30
```

lab-tech's judge-instrument gate (Check 3) reads this block for its hash-lock and triangle-cache sub-checks. Omit the block (and the `{rubric_triangle_block}` prompt line) for batches with no rubric experiments — it is inert there.

```
Agent(subagent_type="nerd:lab-tech", prompt="
Validate readiness for experiments: {comma-separated plan paths}.
Project root: {cwd}. Language: {lang}. Test command: {test_cmd}. Build command: {build_cmd}.
Project DAG path: {dag_path}. Max parallel experiments: {max_parallel_experiments}.
Run all checks: data access, config wiring, eval commands, tool availability, worktree readiness, cross-experiment conflicts, and build infrastructure (Check 7).
For any experiment declaring instrument: judge_rubric, run the judge-instrument gate (Check 3) instead of the numeric sensitivity check. On-file rubric hashes and cached triangle verdicts (orchestrator-injected; do not read the DAG directly): {rubric_triangle_block}
Check 7: Profile the build, detect sccache, select cache strategy, set up caching, write build_cache config to .claude/nerd.local.md. Read infra nodes from the DAG for prior cache verdicts.
If any experiments have research_type: performance, also run Check 8 (Performance Profiling Readiness): 8a tool availability for profiling tools, 8b determinism validation of metric commands, 8c build mode check for debug symbols, 8d build cache awareness for profiling flags.
Scaffold any missing infrastructure (export scripts, test fixtures). Do NOT create the eval module — Phase 6b handles that.
Write report to docs/research/lab-readiness-batch-{timestamp}.md.
", run_in_background=false)
```

**Based on the lab-tech report:**
- **All READY**: Continue to Phase 6.
- **Some SCAFFOLDED**: Lab-tech already fixed these. Continue to Phase 6.
- **Any BLOCKED**: Present blockers to user. Use AskUserQuestion: "Lab-tech found blockers: {blocker_summary}. Skip blocked experiments, or proceed anyway (results may be invalid)?"
  - If skip: remove blocked experiments from this batch, continue with the rest.
  - If proceed: mark experiments as "may produce invalid results" and continue.
  - Note: blockers like dead config fields require code changes that are outside the lab-tech's scope. The user should fix these manually before re-running `/nerd`.

In scheduled mode (`NERD_SCHEDULED=1`): skip blocked experiments automatically, proceed with ready ones.

## Phase 6: Run Experiments in Worktrees

### Phase 6a: Build Infrastructure Setup

Read the build cache config written by lab-tech Check 7:

```bash
grep -E "^build_cache" .claude/nerd.local.md 2>/dev/null
```

**If `build_cache_strategy` and `build_cache_env` are set:**
- Start any required cache daemon (e.g., `sccache --start-server` for Rust)
- Store the env var prefix from `build_cache_env` for Phase 6c

**If strategy is `artifact_copy`:**
- Verify the build output directory exists in the main worktree (lab-tech's cache warming should have populated it)
- Note: the copy happens during worktree creation in Phase 6c

**If strategy is `none` or not set:**
- Proceed without build caching. Experiments will build independently.

### Phase 6b: Create Shared Eval Scaffold

Before launching experiments, set up consolidated infrastructure on current branch:
```bash
mkdir -p docs/research/plans docs/research/results
```

If no eval module exists (check first — lab-tech in Phase 5 does NOT create it), create a scaffold appropriate to the project language. Add a single eval CLI subcommand or script entry point. Each experiment extends this — never creates its own.

### Phase 6c: Launch Experiment Agents

For each `planned` experiment, create the worktree by following **`skills/worktree-lifecycle` §Create** (canonical procedure — run its bash verbatim; it handles the empty/detached-HEAD guard and the branch-collision suffix). It sets `$WT_BRANCH` to the actually-created branch name; use that (not the literal `nerd/{entry.id}`) in this experiment's later merge and cleanup steps.

If `artifact_copy` strategy, clone build artifacts using copy-on-write. The build output directory varies by language (e.g., `target/` for Rust, `node_modules/.cache` for JS, `__pycache__` for Python):
```bash
# macOS (APFS):
cp -c -r "$PROJECT_ROOT/{build_output_dir}/" "$PROJECT_ROOT/worktrees/nerd-{entry.id}/{build_output_dir}/" 2>/dev/null
# Linux (btrfs):
# cp --reflink=auto -r "$PROJECT_ROOT/{build_output_dir}/" "$PROJECT_ROOT/worktrees/nerd-{entry.id}/{build_output_dir}/" 2>/dev/null
```

**Scheduled-mode harness gate (`NERD_SCHEDULED=1`):** read `has_harness` for each experiment from the lab-readiness report. For experiments where `has_harness: false`, do NOT launch a full autonomous executor — building the harness is the token-heavy phase that exhausts the executor's tool budget before it can measure (the recurring S025 failure). Instead, **append the deferred experiment to `docs/research/deferred-experiments.md`** (id, reason `has_harness:false`, and the lab-readiness setup note) so it is a visible breadcrumb for the next supervised run, not silently dropped from the batch — then continue with the `has_harness: true` ones. In interactive mode, all experiments run (the user can intervene if an executor stalls).

**Don't trust `has_harness` blindly — it's a model-judged field.** Before treating an experiment as `has_harness: true` in scheduled mode, independently confirm the harness actually runs: execute the eval/metric command from the lab-readiness report once in the worktree and check it exits 0 and emits output. If the dry-run fails, the field was a false positive — demote the experiment to deferred (as above) rather than launching a `phase=run` that finds no harness, or a single-shot executor that exhausts its budget rebuilding one.

**Two-phase executor split (separate tool budgets).** Harness-writing and the measurement run are **two distinct executor invocations** so that exhausting the build budget never starves the measurement. They share state ONLY through the committed worktree, which means **`phase=run` must not start until `phase=build` has finished and committed** — otherwise `run` opens a worktree with no harness in it. Run the two phases **strictly sequentially within one experiment**; parallelism is *across experiments*, never between the two phases of the same experiment.

```
# Phase build — write and COMMIT the harness, then stop. Launch in the FOREGROUND (or await it)
# so the run phase sees the committed harness. Do NOT background this and immediately launch run.
build_result = Agent(subagent_type="nerd:experiment-executor", prompt="
phase=build
Execute plan at docs/research/plans/{entry.id}-plan.md.
Worktree: {path}. Language: {lang}. Tests: {test_cmd}.
Extend the existing eval module with your experiment code and COMMIT it. Do NOT run the sweep.
Report the commit SHA and the exact eval/metric command the run phase should execute.
Before building, read .claude/nerd.local.md for build_cache_strategy and build_cache_env.
If build_cache_env is set, prefix all build commands with it inline (e.g., for Rust: RUSTC_WRAPPER=sccache cargo build).
If a build fails with cache, retry without it and note cache_fallback: true.
", run_in_background=false)

```

**Gate between the phases (run this — do not skip).** After `phase=build` returns, confirm the harness was actually committed before launching `phase=run`. This is an enforced step, not a hope: a `phase=run` against an uncommitted/empty harness produces a garbage verdict.

```bash
# Capture the worktree HEAD before/after isn't needed — just confirm a harness commit exists now.
BUILD_HEAD=$(git -C "{path}" rev-parse HEAD 2>/dev/null)
if [ -z "$BUILD_HEAD" ] || ! git -C "{path}" log -1 --oneline | grep -qiE 'eval|harness|{entry.id}'; then
  echo "SKIP phase=run for {entry.id}: build phase left no harness commit — mark experiment failed." >&2
  # do NOT launch phase=run; record failed and move on.
else
  : # harness committed → launch phase=run below
fi
```

Only if the gate passed:

```
# Phase run — harness is now committed; run the sweep with a fresh budget. Safe to background
# (and to parallelize across DIFFERENT experiments) now that this experiment's build is done.
Agent(subagent_type="nerd:experiment-executor", prompt="
phase=run
Execute plan at docs/research/plans/{entry.id}-plan.md. The harness is already committed in the worktree (build commit: $BUILD_HEAD).
Worktree: {path}. Language: {lang}. Tests: {test_cmd}.
Re-read the plan and the committed harness, run the sweep, and write results to docs/research/results/{entry.id}-results.json. Commit the results. Do NOT rebuild the harness.
", run_in_background=true)
```

For `has_harness: true` experiments the harness already exists in the eval module on `$CURRENT_BRANCH`, so it is present in the worktree created from that branch (Phase 6c, above) — skip `phase=build` and launch `phase=run` directly. Cap *concurrent experiments* at `max_parallel_experiments` from config; within each experiment, build→run is sequential, so an experiment occupies one slot across both its phases.

**Rubric-judged experiments (`instrument: judge_rubric`) have no harness to build.** Like `has_harness: true` experiments, skip `phase=build` entirely and launch only `phase=run` — there is no metric command to wire into an eval module; the judge is the instrument. The run invocation carries the rubric and judge forward so the executor's judge-rubric branch knows what to score against:

```
# Phase run (judge-rubric) — no harness; the judge scores each cell against the rubric.
Agent(subagent_type="nerd:experiment-executor", prompt="
phase=run
Execute plan at docs/research/plans/{entry.id}-plan.md. instrument: judge_rubric.
Worktree: {path}. Language: {lang}. Tests: {test_cmd}.
Rubric: {entry.rubric}  (library id or inline path). Judge: {entry.judge_id}.
Locked rubric hash: {entry.rubric_hash}  (read from the lab-readiness rubric_instrument block; the executor re-hashes the rubric file and aborts with rubric_hash_drift_detected if it no longer matches).
The rubric is already hash-locked (lab-tech Check 3 passed). Do NOT build or expect a committed harness.
Run the judge-rubric branch: for each cell, invoke the judge against the rubric, collect per-criterion scores, evaluate the pass condition, and write results to docs/research/results/{entry.id}-results.json. Commit the results.
", run_in_background=true)
```

(The executor's internal judge-rubric branch — what `phase=run` does when `instrument: judge_rubric` — is defined in `agents/experiment-executor.md`. If a caller ever invokes `phase=build` on a rubric experiment anyway, the executor returns immediately with "no harness needed for judge-rubric mode" rather than building one.)

### Phase 6d: Intern Result Classification

After each experiment-executor completes and writes results JSON, if `INTERN_AVAILABLE == 1`, delegate result-classification per `Skill(skill="nerd:intern-delegation")`. In live mode, attach intern's classification to the results for Phase 8. In shadow mode, compare against report-compiler's eventual classification in Phase 9.

### Phase 6e: Merge Completed Experiments

As each agent completes, merge it back by following **`skills/worktree-lifecycle` §Merge** (canonical procedure — run its bash verbatim). It merges into the re-captured `$CURRENT_BRANCH`, serializes per-experiment, skips on a dirty tree, uses `git merge --abort` for conflicts vs `reset --hard HEAD~1` only for clean-merge-then-tests-fail, and on success cleans up via the fail-safe cleanup gate. Merge conflicts in eval-module files are additive — combine both sides.

## Phase 7: Monitor

Use `/loop 5m` to check on background agents. Merge experiments as they complete. When all are done or failed, proceed.

## Phase 8: Deliver Findings

```
Agent(subagent_type="nerd:report-compiler", prompt="Compile findings from docs/research/results/ into docs/research/findings.md and per-experiment reports. Write theories, verdicts, and edges to project DAG: {dag_path}.", run_in_background=false)
```

Present summary. Then reconcile and clean up worktrees by following **`skills/worktree-lifecycle` §Reconcile** (canonical procedure — run its bash verbatim). It removes only worktrees whose branch is already merged into `$CURRENT_BRANCH` (checking `git branch --merged`, not just `git worktree prune`), deletes the merged branches, surfaces any worktree it couldn't remove instead of swallowing the error, and is gated by the same fail-safe cleanup flag.

## Phase 9: Training Data Extraction (ALWAYS runs)

**Training data is always collected** — regardless of whether the intern is configured. This builds a corpus from every research run so that when someone eventually enables the intern, there's already a body of training data waiting.

Extract training examples from Claude's outputs in this run. For each task type, create JSONL entries from BOTH parameter and performance research:

| Task | Input | Output | Source |
|------|-------|--------|--------|
| parameter-detection | Source file contents | parameter-scanner's JSON results | Phase 2a |
| result-classification | Experiment results JSON (parameter OR performance) | report-compiler's verdict | Phase 8 |
| context-extraction | Source file + function | parameter-scanner's OR perf-specialist's rationale | Phase 2a/2b |
| perf-area-mapping | Source file contents | perf-explorer's area map entries | Phase 2a |
| perf-classification | Performance experiment results JSON | report-compiler's perf verdict | Phase 8 |

**Performance-specific training data:** Tag performance training examples with `"research_type": "performance"` so the intern can learn both parameter and performance result classification.

**Training example format:**
```json
{"task_type": "result-classification", "input": {...}, "output": {...}, "reasoning": "Claude's chain-of-thought explanation", "source_agent": "report-compiler", "created_at": "ISO timestamp", "run_id": "run-YYYY-MM-DD-NNN", "dedup_key": "E001:result-classification", "project": "project-slug"}
```

**Dual write — project-local AND global:**
```bash
mkdir -p .nerd/intern/training-data
mkdir -p ~/.claude/plugins/nerd/intern/training-data
# Append to BOTH: project-local and global corpus
```

**Deduplication:** 24-hour time window on `dedup_key`. **Crash safety:** write-then-fsync, skip malformed trailing lines on read.

## Phase 10: Intern State Update and Auto-Eval (if enabled)

If `INTERN_AVAILABLE == 1` and delegation occurred this run:

1. Read delegation log for this `run_id`, update shadow windows (keep last 25)
2. Check promotion (20/25 agreements → live) and demotion (accuracy below threshold for 3 evals)
3. Auto-eval: if 10+ new training examples since last eval, re-score accuracy by comparing intern's shadow outputs against Claude's outputs in training data (no extra intern calls needed — just scoring)
4. Update `last_run` stats, `lifetime_claude_calls_saved`, write state atomically

## Phase 11: Intern Performance Summary

If `INTERN_AVAILABLE == 1` and any delegation occurred, display:

```
Intern Report — {model} via {provider}
──────────────────────────────────
  This run: {task}: {agreed/total} agreed  {mode} → {new_mode if changed}
  Accuracy: {task}: {prev}% → {new}% {↑↓→}
  Shadow window: {task}: {count}/25 ({agreements} agreements)
  Training examples: {new} new ({total} total)
  Claude calls saved: {lifetime}
```

## Phase 12: Scout for Loop Candidates

After findings are compiled, run the loop-scout to identify what deserves deep iteration:

```
Agent(subagent_type="nerd:loop-scout", prompt="Analyze research findings in docs/research/ and the backlog in .claude/nerd.local.md. Project DAG: {dag_path}. Global index: {dag_dir}/index.json. Identify the best candidates for /nerd-loop continuous improvement. Write synthesis nodes to global index when 3+ verdicts share a pattern. Write recommendations to docs/research/loop-candidates.md.", run_in_background=false)
```

Present the scout's recommendations:

```
Loop Candidates (ranked by potential):

  1. Search Relevance (8/10) — 12% headroom, eval harness ready, 3 files in scope
  2. Prompt Efficiency (7/10) — 99% token reduction possible, clear metric
  3. Sync Pipeline (5/10) — needs eval harness first, broad scope

  Run /nerd-loop "search relevance" to start deep iteration.
  Or /nerd-schedule tonight to run the top candidate overnight.
```

If running in scheduled mode (`NERD_SCHEDULED=1`) and the schedule window has time remaining, automatically launch `/nerd-loop` on the top candidate.

## Phase 13: Cleanup

Stop any build cache daemon started in Phase 6a (e.g., `sccache --stop-server` for Rust). Safe to run even if no daemon was started.

## Error Handling

- Agent fails → mark `failed`, keep worktree, continue others
- Worktree branch exists → add timestamp suffix
- No git repo → run directly, warn about no isolation
- No parameters found → suggest manual topics
- Build fails after merge → auto-revert, mark `failed`

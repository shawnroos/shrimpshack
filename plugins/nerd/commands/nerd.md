---
name: nerd
description: "Let the nerd loose on your codebase. Obsessively finds every tunable parameter, designs rigorous experiments, runs them in worktrees while you sleep, and delivers findings. Use with no args to nerd out on everything, or pass a topic to focus (e.g., /nerd search relevance)."
argument-hint: "[topic]"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---

# nerd — Obsessive Codebase Research Pipeline

Turn the nerd loose. It will find every hardcoded threshold, magic number, and untested heuristic in your codebase, then systematically prove whether they're optimal or not.

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

## Phase 1: Check the Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

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

Split into two groups:
- **Experimentable**: Findings where a shell command can measure the effect (parameter sweeps, benchmarks, I/O counts). Has a valid `experiment_type` like `parameter_sweep`, `comparison`, `ablation`, `algo_benchmark`, `io_benchmark`, `memory_benchmark`, `cache_benchmark`, `network_benchmark`.
- **Analytical**: Findings where the only evaluation is human judgment or code review (has `experiment_type: "analytical"` or `measurability: "analytical"`).

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

Experimentable findings proceed to Phase 3 (experiment design → worktree execution).
Analytical findings proceed to Phase 3 but use the plan-reviewer for **analytical review** — generating competing theories and reasoned recommendations without building sweep harnesses.

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

```
Agent(subagent_type="nerd:lab-tech", prompt="
Validate readiness for experiments: {comma-separated plan paths}.
Project root: {cwd}. Language: {lang}. Test command: {test_cmd}. Build command: {build_cmd}.
Project DAG path: {dag_path}. Max parallel experiments: {max_parallel_experiments}.
Run all checks: data access, config wiring, eval commands, tool availability, worktree readiness, cross-experiment conflicts, and build infrastructure (Check 7).
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

For each `planned` experiment:

```bash
PROJECT_ROOT="$(pwd)"
git worktree add worktrees/nerd-{entry.id} --detach HEAD
cd worktrees/nerd-{entry.id} && git checkout -b nerd/{entry.id}
cd "$PROJECT_ROOT"
```

If `artifact_copy` strategy, clone build artifacts using copy-on-write. The build output directory varies by language (e.g., `target/` for Rust, `node_modules/.cache` for JS, `__pycache__` for Python):
```bash
# macOS (APFS):
cp -c -r "$PROJECT_ROOT/{build_output_dir}/" "$PROJECT_ROOT/worktrees/nerd-{entry.id}/{build_output_dir}/" 2>/dev/null
# Linux (btrfs):
# cp --reflink=auto -r "$PROJECT_ROOT/{build_output_dir}/" "$PROJECT_ROOT/worktrees/nerd-{entry.id}/{build_output_dir}/" 2>/dev/null
```

```
Agent(subagent_type="nerd:experiment-executor", prompt="
Execute plan at docs/research/plans/{entry.id}-plan.md.
Worktree: {path}. Language: {lang}. Tests: {test_cmd}.
Extend the existing eval module with your experiment code. Commit conventionally.
Write results to docs/research/results/{entry.id}-results.json.
Before building, read .claude/nerd.local.md for build_cache_strategy and build_cache_env.
If build_cache_env is set, prefix all build commands with it inline (e.g., for Rust: RUSTC_WRAPPER=sccache cargo build).
If a build fails with cache, retry without it and add cache_fallback: true to results JSON.
", run_in_background=true)
```

Cap parallel agents at `max_parallel_experiments` from config.

### Phase 6d: Intern Result Classification

After each experiment-executor completes and writes results JSON, if `INTERN_AVAILABLE == 1`, delegate result-classification per `Skill(skill="nerd:intern-delegation")`. In live mode, attach intern's classification to the results for Phase 8. In shadow mode, compare against report-compiler's eventual classification in Phase 9.

### Phase 6e: Merge Completed Experiments

As each agent completes, merge immediately:

```bash
git merge nerd/{entry.id} --no-edit
{test_command}  # verify tests pass
```

If tests fail: `git reset --hard HEAD~1`, mark `failed`, keep worktree.
If merge succeeds: `git worktree remove worktrees/nerd-{entry.id}`.

Merge conflicts in eval module files are additive — combine both sides.

## Phase 7: Monitor

Use `/loop 5m` to check on background agents. Merge experiments as they complete. When all are done or failed, proceed.

## Phase 8: Deliver Findings

```
Agent(subagent_type="nerd:report-compiler", prompt="Compile findings from docs/research/results/ into docs/research/findings.md and per-experiment reports. Write theories, verdicts, and edges to project DAG: {dag_path}.", run_in_background=false)
```

Present summary. Clean up remaining worktrees:
```bash
git worktree prune
```

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

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

```yaml
---
max_parallel_experiments: 4
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

Store: `$PROJECT_SLUG`, `$DAG_PATH`, `$DAG_DIR/index.json`, scanner summary, per-experiment summaries.

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

## Phase 2: Obsessive Codebase Scan

Launch the parameter-scanner agent to crawl the codebase:

```
Agent(subagent_type="nerd:parameter-scanner", prompt="Scan {cwd} for tunable parameters. Topic: {user_topic or 'all'}. {scanner_dag_summary}. Return structured JSON list.", run_in_background=false)
```

Present findings. Use AskUserQuestion: "The nerd found {N} research opportunities. Which ones should it investigate?"

Add selections to backlog.

## Phase 3: Experiment Design

For each `proposed` entry, launch plan-reviewer agents **in parallel**:

```
Agent(subagent_type="nerd:plan-reviewer", prompt="Create experiment plan for {entry.title}. Parameter: {entry.parameter} at {entry.file}:{entry.line}. {per_experiment_dag_summary}. Write to docs/research/plans/{entry.id}-plan.md.", run_in_background=true)
```

Update status: `proposed` → `planned`. Wait for all plan agents.

## Phase 4: Review Gate

Present plans. Use AskUserQuestion: "Plans ready. Execute all, review first, or select subset?"

## Phase 4.5: Lab Readiness Check

Before spinning up expensive experiment agents, validate that the lab is ready.

```
Agent(subagent_type="nerd:lab-tech", prompt="
Validate readiness for experiments: {comma-separated plan paths}.
Project root: {cwd}. Language: {lang}. Test command: {test_cmd}. Build command: {build_cmd}.
Project DAG path: {dag_path}. Max parallel experiments: {max_parallel_experiments}.
Run all checks: data access, config wiring, eval commands, tool availability, worktree readiness, cross-experiment conflicts, and build infrastructure (Check 7).
Check 7: Profile the build, detect sccache, select cache strategy, set up caching, write build_cache config to .claude/nerd.local.md. Read infra nodes from the DAG for prior cache verdicts.
Scaffold any missing infrastructure (export scripts, test fixtures). Do NOT create the eval module — Phase 5.1 handles that.
Write report to docs/research/lab-readiness-batch-{timestamp}.md.
", run_in_background=false)
```

**Based on the lab-tech report:**
- **All READY**: Continue to Phase 5.
- **Some SCAFFOLDED**: Lab-tech already fixed these. Continue to Phase 5.
- **Any BLOCKED**: Present blockers to user. Use AskUserQuestion: "Lab-tech found blockers: {blocker_summary}. Skip blocked experiments, or proceed anyway (results may be invalid)?"
  - If skip: remove blocked experiments from this batch, continue with the rest.
  - If proceed: mark experiments as "may produce invalid results" and continue.
  - Note: blockers like dead config fields require code changes that are outside the lab-tech's scope. The user should fix these manually before re-running `/nerd`.

In scheduled mode (`NERD_SCHEDULED=1`): skip blocked experiments automatically, proceed with ready ones.

## Phase 5: Run Experiments in Worktrees

### 5.0: Build Infrastructure Setup

Read the build cache config written by lab-tech Check 7:

```bash
grep -E "^build_cache" .claude/nerd.local.md 2>/dev/null
```

**If `build_cache_strategy` and `build_cache_env` are set:**
- Start any required cache daemon (e.g., `sccache --start-server` for Rust)
- Store the env var prefix from `build_cache_env` for Phase 5.2

**If strategy is `artifact_copy`:**
- Verify the build output directory exists in the main worktree (lab-tech's cache warming should have populated it)
- Note: the copy happens during worktree creation in Phase 5.2

**If strategy is `none` or not set:**
- Proceed without build caching. Experiments will build independently.

### 5.1: Create Shared Eval Scaffold

Before launching experiments, set up consolidated infrastructure on current branch:
```bash
mkdir -p docs/research/plans docs/research/results
```

If no eval module exists (check first — lab-tech in Phase 4.5 does NOT create it), create a scaffold appropriate to the project language. Add a single eval CLI subcommand or script entry point. Each experiment extends this — never creates its own.

### 5.2: Launch Experiment Agents

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

### 5.3: Merge Completed Experiments

As each agent completes, merge immediately:

```bash
git merge nerd/{entry.id} --no-edit
{test_command}  # verify tests pass
```

If tests fail: `git reset --hard HEAD~1`, mark `failed`, keep worktree.
If merge succeeds: `git worktree remove worktrees/nerd-{entry.id}`.

Merge conflicts in eval module files are additive — combine both sides.

## Phase 6: Monitor

Use `/loop 5m` to check on background agents. Merge experiments as they complete. When all are done or failed, proceed.

## Phase 7: Deliver Findings

```
Agent(subagent_type="nerd:report-compiler", prompt="Compile findings from docs/research/results/ into docs/research/findings.md and per-experiment reports. Write theories, verdicts, and edges to project DAG: {dag_path}.", run_in_background=false)
```

Present summary. Clean up remaining worktrees:
```bash
git worktree prune
```

## Phase 8: Scout for Loop Candidates

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

## Phase 9: Cleanup

Stop any build cache daemon started in Phase 5.0 (e.g., `sccache --stop-server` for Rust). Safe to run even if no daemon was started.

## Error Handling

- Agent fails → mark `failed`, keep worktree, continue others
- Worktree branch exists → add timestamp suffix
- No git repo → run directly, warn about no isolation
- No parameters found → suggest manual topics
- Build fails after merge → auto-revert, mark `failed`

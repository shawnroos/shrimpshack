---
name: nerd-this
description: "Context-scoped experiment discovery. Researches only what you're working on right now — infers scope from your current branch, session files, and conversation topics, then groups findings into research themes. Use instead of /nerd when you want focused research on your current work. Use with no args to auto-scope from context, or pass a topic to narrow further (e.g., /nerd-this auth flow)."
argument-hint: "[topic]"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---

# nerd-this — Context-Scoped Experiment Discovery

Research what you're working on right now. Instead of scanning the entire codebase like `/nerd`, this command infers scope from your current session — branch changes, files you've been touching, topics you've been discussing — and groups findings into research themes.

## Input

<user_topic>$ARGUMENTS</user_topic>

## Pre-flight

**Check schedule mode:** If `NERD_SCHEDULED=1` is set, operate fully autonomously — skip all AskUserQuestion calls, make decisions without user input.

**Check global setup:**
```bash
cat ~/.claude/plugins/nerd/hardware-profile.yaml 2>/dev/null
```
If no hardware profile: "Run /nerd-setup first to calibrate your hardware." Stop.

**Auto-init project (if not already initialized):**
Check if this project has been set up for nerd. If not, do it silently:

```bash
if [ ! -f .claude/nerd.local.md ]; then
    mkdir -p docs/research/plans docs/research/results .claude

    if [ -f Cargo.toml ]; then lang="rust"; test_cmd="cargo test"; build_cmd="cargo build";
    elif [ -f package.json ]; then lang="typescript"; test_cmd="bun test"; build_cmd="bun run typecheck";
    elif [ -f pyproject.toml ]; then lang="python"; test_cmd="pytest"; build_cmd="python -m py_compile";
    elif [ -f go.mod ]; then lang="go"; test_cmd="go test ./..."; build_cmd="go build ./...";
    else lang="unknown"; test_cmd="echo 'no tests configured'"; build_cmd="echo 'no build configured'"; fi
```

Create `.claude/nerd.local.md` with defaults (still inside the `if` block — only when no config exists):

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
fi
```

This closes the `if [ ! -f .claude/nerd.local.md ]` block — the config file and gitignore entry are only created on first run.

**Detect project:**
```bash
cat CLAUDE.md .claude/CLAUDE.md 2>/dev/null | head -50
git branch --show-current
```

Store: language, test command, current branch from the local config.

## Phase 1: Scope Resolution

Gather three signals to determine what the user is currently working on. Combine them into a scoped file list for the context-scanner.

### Signal 1: Git Branch Diff

```bash
# Get the default branch
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$default_branch" ]; then
    default_branch=$(git rev-parse --verify origin/main >/dev/null 2>&1 && echo "main" || echo "master")
fi

# Committed changes on this branch vs default
git diff ${default_branch}...HEAD --name-only 2>/dev/null || true

# Uncommitted changes (staged + unstaged)
git diff --name-only 2>/dev/null || true
git diff --cached --name-only 2>/dev/null || true
```

If the current branch IS the default branch, this signal produces no results. That's fine — continue with other signals.

### Signal 2: Session File Access

Introspect your own conversation context. List every file you have Read, Written, or Edited during this conversation session. Include the full path for each file.

**Important:** LLM self-recall of tool history is imperfect, especially in long sessions. This signal may be incomplete. If you are uncertain about which files were accessed, note it and weight Signal 1 (git diff) and Signal 3 (conversation content) more heavily. This signal is a best-effort supplement, not the primary scope source.

If this is the first message in the session (no prior file access), this signal is empty. That's fine.

### Signal 3: Conversation Content

Summarize the key technical topics, features, and systems discussed in this conversation. Extract:
- Specific file paths and function names mentioned
- Module names and architectural concepts discussed
- Technical decisions and trade-offs explored
- The user's stated goals or intent

If there is no prior conversation (this is the first message), this signal is empty.

### Combine Signals

1. **Union** all file paths from signals 1 and 2 into a deduplicated list
2. **Filter out** non-source files:
   - Lock files: `*.lock`, `package-lock.json`, `yarn.lock`, `Gemfile.lock`, `Cargo.lock`
   - Build artifacts: `dist/`, `build/`, `target/`, `out/`, `*.min.*`
   - Dependencies: `vendor/`, `node_modules/`, `.venv/`
   - Generated files: `*.generated.*`, `*.g.*`
   - Binary files, images, fonts
3. If a **topic** was provided in `<user_topic>`, weight the file list toward topic relevance:
   - Keep all files from git diff (they're definitely in scope)
   - For session files, keep only those whose content or path relates to the topic
   - Use conversation content to identify additional directories/modules to include (verify paths exist on disk before adding — skip any hallucinated or non-existent paths)
4. If **all three signals are empty** (fresh session on default branch with no prior conversation):
   - In interactive mode: Use AskUserQuestion: "I can't infer what you're working on. What topic or area should I research? (Or use /nerd for a full codebase scan.)"
   - In scheduled mode: Fall back to full `/nerd` behavior — scan everything.

### Scope Size Check

Count the number of unique source files in the scope.

- **0 files**: "No source files in scope. Try providing a topic: `/nerd-this <topic>`" — Stop.
- **1-49 files**: Good scope. Proceed.
- **50+ files**: Warn the user: "Scope is broad ({N} files). This is close to a full codebase scan. Proceed anyway, or narrow with a topic?" In scheduled mode, proceed but log the warning.

## Phase 2: Scope Confirmation

Present the inferred scope to the user for confirmation. Skip in scheduled mode.

```
Scope inferred from your current work:

  Branch: {branch_name} ({N} files changed vs {default_branch})
  Session: {N} files read/edited
  Topics: {comma-separated topic summary from conversation}

  Scoped to {N} unique source files across:
    {directory}/       ({N} files)
    {directory}/       ({N} files)
    ...

  Proceed with scan? [Y/adjust/cancel]
```

Use AskUserQuestion to confirm. If the user wants to adjust:
- They can type file paths or glob patterns to add (e.g., `+ src/sync/`)
- They can type paths to remove (e.g., `- src/tests/`)
- They can type a topic to re-run scope resolution with a narrower focus

## Phase 3: Thematic Parameter Scan

Launch the context-scanner agent with the confirmed scope:

```
Agent(subagent_type="nerd:context-scanner", prompt="
Scan these files for tunable parameters and group them into research themes:

Files:
{scoped_file_list — one file per line}

Topic: {user_topic or 'inferred from session context'}

Context: {conversation_summary — what the user is working on, why, key decisions}

Start IDs from: {computed_start_id}

(Before this Agent call, compute the start ID: parse all `id:` fields in the backlog YAML, extract the numeric suffix from each (e.g., E042 → 42), take the maximum, add 1, zero-pad to 3 digits, prefix with E. If backlog is empty or has no valid IDs, use E001.)

Return structured JSON with themed parameter groups.
", run_in_background=false)
```

### Handle Results

- **Zero parameters found**: "No tunable parameters found in your scoped files. Try `/nerd` for a full codebase scan, or adjust your scope with `/nerd-this <broader topic>`." — Stop.
- **One theme**: Skip Phase 4, proceed directly with the single theme.
- **2-6 themes**: Continue to Phase 4.

## Phase 4: Theme Selection

Present discovered themes to the user. Skip in scheduled mode (auto-select all).

```
Found {N} research themes in your current work:

  1. [x] {theme.name}
       {theme.description}
       {theme.parameter_count} tunable parameters across {theme.file_count} files

  2. [x] {theme.name}
       {theme.description}
       {theme.parameter_count} tunable parameters across {theme.file_count} files

  ...

All themes selected. Deselect by number (e.g., "drop 3") or press enter to proceed:
```

Use AskUserQuestion. Parse the response:
- Empty / "enter" / "proceed" / "yes" → keep all selected
- "drop N" or "drop N, M" → deselect those themes
- "only N" or "only N, M" → select only those themes

## Phase 5: Backlog Expansion

Expand selected themes into individual backlog entries and merge into `.claude/nerd.local.md`.

### Read Current Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

### Deduplication

For each parameter in the selected themes:
1. Check if the backlog already contains an entry with the same `file` AND `parameter` (variable/constant name)
2. If no `parameter` name match, fall back to matching by `file` AND `line` (approximate — line numbers shift as code changes)
3. If a match exists, skip the duplicate (the existing entry may already be `planned` or `running`)
4. If no match, add the new entry

### Add Entries

For each non-duplicate parameter, create a backlog entry:

```yaml
- id: {parameter.id}
  title: "{parameter.title}"
  parameter: {parameter.parameter}
  file: {parameter.file}
  line: {parameter.line}
  current_value: "{parameter.current_value}"
  category: {parameter.category}
  impact: {parameter.impact}
  rationale: "{parameter.rationale}"
  experiment_type: {parameter.experiment_type}
  sweep_range: "{parameter.sweep_range}"
  status: proposed
  source: nerd-this
  theme: "{theme.name}"
```

### Update Backlog

Edit `.claude/nerd.local.md` to append new entries to the `backlog:` array.

Report: "Added {N} experiments to backlog across {T} themes. ({S} skipped as duplicates.)"

## Phase 6: Experiment Design

For each `proposed` entry from the new batch, launch plan-reviewer agents **in parallel**:

```
Agent(subagent_type="nerd:plan-reviewer", prompt="Create experiment plan for {entry.title}. Parameter: {entry.parameter} at {entry.file}:{entry.line}. Current value: {entry.current_value}. Sweep range: {entry.sweep_range}. Write to docs/research/plans/{entry.id}-plan.md.", run_in_background=true)
```

Update status: `proposed` → `planned`. Wait for all plan agents.

## Phase 7: Review Gate

Present plans. Use AskUserQuestion: "Plans ready. Execute all, review first, or select subset?"

In scheduled mode: execute all.

## Phase 7.5: Lab Readiness Check

Before spinning up expensive experiment agents, validate that the lab is ready.

```
Agent(subagent_type="nerd:lab-tech", prompt="
Validate readiness for experiments: {comma-separated plan paths}.
Project root: {cwd}. Language: {lang}. Test command: {test_cmd}. Build command: {build_cmd}.
Project DAG path: {dag_path}. Max parallel experiments: {max_parallel_experiments}.
Run all checks: data access, config wiring, eval commands, tool availability, worktree readiness, cross-experiment conflicts, and build infrastructure (Check 7).
Check 7: Profile the build, detect sccache, select cache strategy, set up caching, write build_cache config to .claude/nerd.local.md. Read infra nodes from the DAG for prior cache verdicts.
Scaffold any missing infrastructure (export scripts, test fixtures). Do NOT create the eval module — Phase 8.1 handles that.
Write report to docs/research/lab-readiness-batch-{timestamp}.md.
", run_in_background=false)
```

**Based on the lab-tech report:**
- **All READY**: Continue to Phase 8.
- **Some SCAFFOLDED**: Lab-tech already fixed these. Continue to Phase 8.
- **Any BLOCKED**: Present blockers to user. Use AskUserQuestion: "Lab-tech found blockers: {blocker_summary}. Skip blocked experiments, or proceed anyway (results may be invalid)?"
  - If skip: remove blocked experiments from this batch, continue with the rest.
  - If proceed: mark experiments as "may produce invalid results" and continue.

In scheduled mode (`NERD_SCHEDULED=1`): skip blocked experiments automatically, proceed with ready ones.

## Phase 8: Run Experiments in Worktrees

### 8.1: Create Shared Eval Scaffold

```bash
mkdir -p docs/research/plans docs/research/results
```

If no eval module exists, create a scaffold appropriate to the project language. Each experiment extends this — never creates its own.

### 8.2: Launch Experiment Agents

For each `planned` experiment:

```bash
git worktree add worktrees/nerd-{entry.id} --detach HEAD
cd worktrees/nerd-{entry.id} && git checkout -b nerd/{entry.id}
```

```
Agent(subagent_type="nerd:experiment-executor", prompt="
Execute plan at docs/research/plans/{entry.id}-plan.md.
Worktree: {path}. Language: {lang}. Tests: {test_cmd}.
Put code in src/eval/{entry.id}.rs (or equivalent).
Add to existing EvalAction enum. Commit conventionally.
Write results to docs/research/results/{entry.id}-results.json.
Before building, read .claude/nerd.local.md for build_cache_strategy and build_cache_env.
If build_cache_env is set, prefix all cargo/build commands with it inline (e.g., RUSTC_WRAPPER=sccache cargo build).
If a build fails with cache, retry without it and add cache_fallback: true to results JSON.
", run_in_background=true)
```

Cap parallel agents at `max_parallel_experiments` from config.

### 8.3: Merge Completed Experiments

As each agent completes, merge immediately:

```bash
git merge nerd/{entry.id} --no-edit
{test_command}  # verify tests pass
```

If tests fail: `git reset --hard HEAD~1`, mark `failed`, keep worktree.
If merge succeeds: `git worktree remove worktrees/nerd-{entry.id}`.

Merge conflicts in eval module files (mod.rs, EvalAction enum) are additive — combine both sides.

## Phase 9: Monitor

Use `/loop 5m` to check on background agents. Merge experiments as they complete. When all are done or failed, proceed.

## Phase 10: Deliver Findings

```
Agent(subagent_type="nerd:report-compiler", prompt="Compile findings from docs/research/results/ into docs/research/findings.md and per-experiment reports. Write theories, verdicts, and edges to project DAG: {dag_path}.", run_in_background=false)
```

Present summary. Clean up remaining worktrees:
```bash
git worktree prune
```

## Phase 11: Scout for Loop Candidates

After findings are compiled, run the loop-scout to identify what deserves deep iteration:

```
Agent(subagent_type="nerd:loop-scout", prompt="Analyze research findings in docs/research/ and the backlog in .claude/nerd.local.md. Project DAG: {dag_path}. Global index: {dag_dir}/index.json. Identify the best candidates for /nerd-loop continuous improvement. Write synthesis nodes to global index when 3+ verdicts share a pattern. Write recommendations to docs/research/loop-candidates.md.", run_in_background=false)
```

Present the scout's recommendations:

```
Loop Candidates (ranked by potential):

  1. {focus} ({score}/10) — {rationale}
  2. {focus} ({score}/10) — {rationale}
  3. {focus} ({score}/10) — {rationale}

  Run /nerd-loop "{focus}" to start deep iteration.
  Or /nerd-schedule tonight to run the top candidate overnight.
```

If running in scheduled mode (`NERD_SCHEDULED=1`) and the schedule window has time remaining, automatically launch `/nerd-loop` on the top candidate.

## Error Handling

- Agent fails → mark `failed`, keep worktree, continue others
- Worktree branch exists → add timestamp suffix
- No git repo → run directly, warn about no isolation
- No parameters found → suggest topic or /nerd
- Build fails after merge → auto-revert, mark `failed`
- All signals empty → ask for topic (interactive) or fall back to /nerd (scheduled)
- Scope too broad (50+ files) → warn and suggest /nerd

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

**Check setup:**
```bash
cat ~/.claude/plugins/nerd/hardware-profile.yaml 2>/dev/null
```
If no hardware profile: "Run /nerd-setup first to calibrate your hardware." Stop.

**Detect project:**
```bash
ls Cargo.toml package.json pyproject.toml go.mod 2>/dev/null
cat CLAUDE.md .claude/CLAUDE.md 2>/dev/null | head -50
git branch --show-current
```

Store: language, test command, current branch.

## Phase 1: Check the Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

If backlog has `proposed` entries and no topic: skip to Phase 3 — the nerd has already been collecting findings.
If backlog empty or topic specified: continue to Phase 2.

## Phase 2: Obsessive Codebase Scan

Launch the parameter-scanner agent to crawl the codebase:

```
Agent(subagent_type="nerd:parameter-scanner", prompt="Scan {cwd} for tunable parameters. Topic: {user_topic or 'all'}. Return structured JSON list.", run_in_background=false)
```

Present findings. Use AskUserQuestion: "The nerd found {N} research opportunities. Which ones should it investigate?"

Add selections to backlog.

## Phase 3: Experiment Design

For each `proposed` entry, launch plan-reviewer agents **in parallel**:

```
Agent(subagent_type="nerd:plan-reviewer", prompt="Create experiment plan for {entry.title}. Parameter: {entry.parameter} at {entry.file}:{entry.line}. Write to docs/research/plans/{entry.id}-plan.md.", run_in_background=true)
```

Update status: `proposed` → `planned`. Wait for all plan agents.

## Phase 4: Review Gate

Present plans. Use AskUserQuestion: "Plans ready. Execute all, review first, or select subset?"

## Phase 5: Run Experiments in Worktrees

### 5.1: Create Shared Eval Scaffold

Before launching experiments, set up consolidated infrastructure on current branch:
```bash
mkdir -p docs/research/plans docs/research/results
```

If no eval module exists, create a scaffold appropriate to the project language (e.g., `src/eval/mod.rs` for Rust, `src/eval/index.ts` for TS). Add a single `Eval` CLI subcommand. Each experiment extends this — never creates its own.

### 5.2: Launch Experiment Agents

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

Merge conflicts in eval module files (mod.rs, EvalAction enum) are additive — combine both sides.

## Phase 6: Monitor

Use `/loop 5m` to check on background agents. Merge experiments as they complete. When all are done or failed, proceed.

## Phase 7: Deliver Findings

```
Agent(subagent_type="nerd:report-compiler", prompt="Compile findings from docs/research/results/ into docs/research/findings.md and per-experiment reports.", run_in_background=false)
```

Present summary. Clean up remaining worktrees:
```bash
git worktree prune
```

## Error Handling

- Agent fails → mark `failed`, keep worktree, continue others
- Worktree branch exists → add timestamp suffix
- No git repo → run directly, warn about no isolation
- No parameters found → suggest manual topics
- Build fails after merge → auto-revert, mark `failed`

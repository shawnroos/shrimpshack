---
name: nerd-loop
description: "Run a continuous self-improvement loop on a specific aspect of your codebase. The agent edits code, runs it, measures the result, keeps improvements, discards regressions, and repeats indefinitely. Like Karpathy's autoresearch but for any codebase feature. Use: /nerd-loop 'search relevance' or /nerd-loop 'api response time'"
argument-hint: "<research focus>"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---

# nerd-loop — Continuous Self-Improvement Loop

Run an autonomous, never-ending improvement loop on a specific part of your codebase. The agent reads the code, hypothesizes an improvement, makes the change, measures the result, keeps it if better, reverts if not, and repeats — indefinitely until you interrupt it.

This is Karpathy's autoresearch pattern applied to your own code.

## Input

<research_focus>$ARGUMENTS</research_focus>

If empty, ask: "What should the nerd obsess over? Examples: 'search relevance', 'API latency', 'prompt efficiency', 'test coverage', 'bundle size'"

## Step 1: Define the Loop Contract

Before starting, the nerd needs to establish the rules of the loop. Read the codebase and determine:

### 1a: What to optimize (the metric)

Based on the research focus, identify or create a measurable metric:

| Focus | Metric | How to Measure |
|-------|--------|---------------|
| search relevance | nDCG@10 | run eval harness against search_feedback |
| API latency | p95 response time | run benchmark suite |
| prompt efficiency | tokens per call | count tokens in prompt variants |
| test coverage | line coverage % | run coverage tool |
| bundle size | bytes | build and measure |
| memory usage | peak RSS | run with instrumentation |
| compile time | seconds | time the build |

If no eval harness exists for this metric, **build one first** (a minimal script that outputs a single number). This is the equivalent of autoresearch's `evaluate_bpb`.

### 1b: What can be modified (the scope)

Identify the files the agent is allowed to change. Like autoresearch constrains changes to `train.py`, the loop needs boundaries:

```
Determine the relevant files:
- If focus is "search relevance" → src/search/*.rs
- If focus is "prompt efficiency" → src/acp/mod.rs (prompt builders)
- If focus is "API latency" → src/api/*.rs, src/handlers/*.rs
```

Use AskUserQuestion to confirm: "I'll focus on modifying {files}. The metric is {metric}. Does this scope look right?"

### 1c: What's fixed (the constraints)

Establish what CANNOT change:
- The evaluation harness / metric computation
- The test suite (must pass after every change)
- Public API contracts
- Database schema
- Dependencies

### 1d: Write the loop protocol

Create `docs/research/loop-protocol-{focus-slug}.md`:

```markdown
---
focus: "{research_focus}"
metric: "{metric_name}"
metric_command: "{command to measure}"
scope: ["{file1}", "{file2}"]
constraints:
  - Tests must pass: "{test_command}"
  - No new dependencies
  - No public API changes
started_at: "{timestamp}"
iterations: 0
best_metric: null  # filled after baseline measurement in Step 4
---

# Nerd Loop: {research_focus}

## Rules
1. ONLY modify files in scope: {files}
2. After every change, run: {test_command}
3. Measure with: {metric_command}
4. If metric improved AND tests pass → git commit, update best_metric
5. If metric worse OR tests fail → git reset --hard, try something different
6. NEVER STOP. Run until manually interrupted.

## State
- consecutive_discards: 0
- phase: normal          # normal → pivot → escalate → local_maximum
- total_iterations: 0
- total_kept: 0

## Experiment Log
| # | Change | Metric | vs Best | Status | Phase |
|---|--------|--------|---------|--------|-------|
```

## Step 2: Lab Readiness Check

Before measuring baseline or starting the loop, validate the environment:

```
Agent(subagent_type="nerd:lab-tech", prompt="
Validate readiness for a continuous loop on '{research_focus}'. This is loop mode — no experiment plans.
Metric command: {metric_command}. Scope files: {scope_files}.
Project root: {cwd}. Language: {lang}. Test command: {test_cmd}. Build command: {build_cmd}. Project DAG path: {dag_path}.
Check: data access for the metric command, eval command readiness (verify metric_command runs and produces output), tool availability, worktree readiness (disk space for many iterations), and build infrastructure (Check 7 steps 7a-7c, 7f — detect sccache availability and report the env var prefix if available).
Scaffold missing eval infrastructure if needed (you own eval module creation in loop mode).
Write report to docs/research/lab-readiness-loop-{focus-slug}.md.
", run_in_background=false)
```

**Based on the lab-tech report:**
- **READY**: Continue to Step 3.
- **SCAFFOLDED**: Lab-tech fixed the issues. Note: scaffolded files are on the current branch. Continue to Step 3.
- **BLOCKED**: Present blockers. Use AskUserQuestion: "Lab readiness check failed: {blocker_summary}. Fix and retry, or abort?"
  - If fix: user fixes the issue, re-run lab-tech.
  - If abort: stop with a clear message. Do not create the loop branch or protocol file.

## Step 2.5: Start Build Cache (if available)

If the lab-tech report indicates sccache is available (Check 7f reports `[OK] sccache available`):

```bash
sccache --start-server 2>/dev/null
```

Store the env var prefix `RUSTC_WRAPPER=sccache` for use in the loop iteration commands. This benefits loop mode significantly — hundreds of incremental recompilations across iterations get cached.

## Step 3: Create the Loop Branch

```bash
git checkout -b nerd-loop/{focus-slug}
```

## Step 4: Measure Baseline

Run the metric command to establish the starting point:

```bash
{metric_command}
```

Record the baseline in the protocol file.

## Step 5: Launch the Loop

Launch an autonomous agent that runs indefinitely:

```
Agent(subagent_type="nerd:experiment-executor", prompt="
You are running a continuous self-improvement loop.

PROTOCOL: Read docs/research/loop-protocol-{focus-slug}.md for the full rules.

THE LOOP (run forever):

1. THINK: Look at the current code in {scope_files}. Look at the experiment log
   in the protocol file. What has been tried? What worked? What didn't?
   Based on this, hypothesize a specific improvement. Be creative — don't just
   tweak numbers. Try new algorithms, restructure logic, remove unnecessary code,
   add new signals, change data structures.

2. EDIT: Make the change. Keep it focused — one idea per iteration.

3. TEST: Run {test_command}. If sccache is available (check lab-tech report from Step 2),
   prefix with RUSTC_WRAPPER=sccache (e.g., RUSTC_WRAPPER=sccache cargo test).
   If tests fail, revert immediately:
   git reset --hard HEAD
   Log as 'fail (tests)' and try something different.

4. MEASURE: Run {metric_command}. Record the result.

5. DECIDE:
   - If metric improved: git add {scope_files} && git commit -m 'loop: {description}'
     Update the experiment log and best_metric in the protocol file.
     Reset the consecutive_discards counter to 0.
   - If metric same or worse: git reset --hard HEAD
     Log as 'discard' with the metric value.
     Increment consecutive_discards counter.

6. CHECK FOR LOCAL MAXIMUM:
   Track consecutive discards (iterations where the metric didn't improve).

   - **consecutive_discards < 5**: Normal operation. Keep trying.
   - **consecutive_discards reaches 5**: PIVOT. You've exhausted minor variations.
     Log: "Pivot: 5 consecutive discards. Switching approach."
     Try something fundamentally different — new algorithm, structural change,
     remove a component, change the data flow. Reset consecutive_discards to 0.
   - **consecutive_discards reaches 5 AFTER a pivot**: ESCALATE. Two approach
     classes have plateaued.
     Log: "Escalate: plateau after pivot."
     Re-read ALL kept commits. Ask: "Is there a completely different framing
     of this problem?" Try the opposite of what's been working.
     Reset consecutive_discards to 0.
   - **consecutive_discards reaches 5 AFTER an escalation**: LOCAL MAXIMUM REACHED.
     Log: "Local maximum reached after {total_iterations} iterations."
     Log: "Best metric: {best_metric} (improved from {baseline} = {improvement}%)"
     STOP THE LOOP. Proceed to Step 7 (wrap-up).

   This gives the loop 3 chances (normal → pivot → escalate) before concluding
   it has found the local optimum. That's 15 consecutive failed iterations across
   3 different strategic approaches.

7. REFLECT: After every 5 iterations (regardless of discard count), re-read
   the experiment log.
   - What patterns emerge? (Do all architecture changes help? Do parameter tweaks plateau?)
   - What's the ratio of kept to discarded?
   - Are the improvements getting smaller? (diminishing returns)

8. GOTO 1.

IMPORTANT:
- Each iteration should take 2-10 minutes depending on build/test time.
- If you've tried 5 similar ideas and none worked, pivot to a fundamentally different approach.
- Keep a running count of iterations in the protocol file.
- The goal is not just to find a better parameter — it's to find better CODE.
  You can rewrite functions, change algorithms, restructure modules, simplify logic.
  Anything within the scope files is fair game.

CREATIVITY PROMPTS (use when stuck):
- What would happen if I removed this entire function and inlined the logic?
- Is there a simpler data structure that would be faster here?
- Could I precompute this instead of computing it on every call?
- What if I reversed the order of operations?
- Is there a well-known algorithm for this problem that isn't being used?
- What would a 10x improvement require? (Then try for 2x of that.)
- What assumption is this code making that might be wrong?

Hardware: Read ~/.claude/plugins/nerd/hardware-profile.yaml for constraints.
", run_in_background=true)
```

## Step 6: Monitor

Report to the user:

```
Nerd Loop Started
  Focus: {research_focus}
  Metric: {metric_name}
  Baseline: {baseline_value}
  Branch: nerd-loop/{focus-slug}
  Scope: {files}

  The nerd is now obsessively improving your {focus}.
  It will run until you interrupt it.

  Monitor:  cat docs/research/loop-protocol-{focus-slug}.md
  Progress: git log --oneline nerd-loop/{focus-slug} | head -20
  Stop:     interrupt this session
```

Then use `/loop 5m` to periodically check the agent's progress and report iteration count + current best metric.

## Step 7: When Loop Ends (Local Maximum or Interrupted)

The loop ends when either:
- **Local maximum detected**: 15 consecutive discards across 3 strategic phases (normal → pivot → escalate)
- **User interrupts**: manually stops the session
- **Scheduled window closes**: overnight run ends

1. Stop sccache if it was started in Step 2.5: `sccache --stop-server 2>/dev/null`
2. Read the final protocol file for the experiment log
3. Compile a loop report at `docs/research/loop-{focus-slug}-report.md`:

```markdown
---
title: "Nerd Loop: {research_focus}"
status: local_maximum|interrupted|window_closed
total_iterations: {N}
kept: {N}
discarded: {N}
baseline_metric: {value}
best_metric: {value}
improvement: {percent}%
exit_reason: "{why it stopped}"
---

# Loop Results: {research_focus}

## Summary
Ran {total} iterations over {duration}. Kept {kept}, discarded {discarded}.
Improved {metric} from {baseline} to {best} ({improvement}%).

## Exit Reason
{local_maximum: "Plateaued after 15 consecutive discards across 3 strategic phases."}
{interrupted: "Manually stopped by user."}
{window_closed: "Scheduled window ended."}

## Improvement Timeline
| Iteration | Change | Metric | Improvement |
|-----------|--------|--------|-------------|
{rows for kept changes only, showing progression}

## What Worked
{Pattern analysis of kept changes — what types of changes produced improvements?}

## What Didn't Work
{Pattern analysis of discarded changes — what approaches were dead ends?}

## Approaches Tried
- Normal phase: {what was tried, N iterations}
- Pivot phase: {what was tried, N iterations}
- Escalation phase: {what was tried, N iterations}
```

3. List the top changes that were kept (from git log)
4. The branch `nerd-loop/{focus-slug}` contains all the accumulated improvements
5. Ask: "Merge nerd-loop/{focus-slug} into your working branch?"

## Combining with /nerd

The standard `/nerd` pipeline (scan → plan → execute → report) identifies WHAT to research.
`/nerd-loop` does the actual deep, iterative research on a specific area.

A natural workflow:
1. `/nerd` scans the codebase, identifies 10 research opportunities
2. User picks "search relevance" as the highest-priority target
3. `/nerd-loop "search relevance"` runs overnight, making 30+ iterations
4. Next morning: review the loop's findings, merge the improvements

Or schedule it:
```
/nerd-schedule tonight
```
The scheduled runner can alternate between `/nerd` (batch analysis) and `/nerd-loop` (deep iteration) based on what's in the backlog.

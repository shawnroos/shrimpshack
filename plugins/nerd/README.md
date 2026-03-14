# nerd

Your obsessive overnight research assistant for Claude Code. Finds every tunable parameter in your codebase, designs experiments with competing theories, runs them in worktrees while you sleep, and delivers findings that tell you what to keep, what to change, and what to rearchitect.

## Install

```bash
claude plugin marketplace add https://github.com/shawnroos/shrimpshack.git
claude plugin install nerd
```

## Quick Start

```bash
/nerd-setup                        # One-time: calibrate hardware
/nerd                              # Scan → plan → execute → report → scout for loops
/nerd-loop "search relevance"      # Deep continuous iteration on one area
/nerd-schedule tonight             # Schedule overnight runs
/nerd-status                       # Check what the nerd is up to
```

`/nerd-setup` runs once per machine. Projects auto-initialize on first `/nerd` run.

## Two Research Modes

### `/nerd` — Broad Survey

Scans the codebase, identifies tunable parameters, plans experiments with competing theories, executes them in parallel worktrees, compiles findings, then scouts for the best loop candidate.

```
/nerd
  ├─ parameter-scanner finds opportunities
  ├─ You pick which to investigate
  ├─ plan-reviewer generates 3 competing theories per experiment
  ├─ experiment-executor builds harnesses in parallel worktrees
  ├─ report-compiler evaluates which theories held up
  └─ loop-scout recommends the best target for deep iteration
```

### `/nerd-loop` — Deep Iteration

Continuous self-improvement on one area. The agent reads the code, hypothesizes an improvement, makes the change, measures, keeps if better, reverts if not — and repeats until it hits a local maximum.

```
/nerd-loop "search relevance"
  ├─ Establishes baseline metric
  ├─ Loops: edit → test → measure → keep/discard
  ├─ Pivots strategy after 5 consecutive failures
  ├─ Escalates after another 5
  └─ Stops at local maximum (15 failures across 3 strategies)
```

The loop doesn't just sweep parameters — it rewrites algorithms, restructures logic, removes unnecessary code. Anything within the scoped files is fair game.

## Competing Theories

Every experiment generates 3+ competing theories:

| Theory Type | Example |
|-------------|---------|
| **Parameter is wrong** | The threshold of 0.85 should be 0.80 |
| **Model is wrong** | Exponential decay doesn't fit — data is bursty, try power-law |
| **Feature is unnecessary** | LLM curation adds latency but no quality over the algorithmic reranker |
| **Data is the bottleneck** | Thresholds don't matter because 99% of resolution is via exact email match |
| **Architecture is the bottleneck** | Sequential hydration should be parallel — no parameter can fix this |

Reports evaluate each theory as SUPPORTED / REFUTED / INCONCLUSIVE and recommend: **KEEP**, **CHANGE**, **REMOVE**, **REARCHITECT**, or **INVESTIGATE**.

## Overnight Runs

```bash
/nerd-schedule tonight          # 22:00 - 06:00
/nerd-schedule weeknights       # Recurring M-F 22:00-06:00
/nerd-schedule 23:00-05:00      # Custom window
/nerd-schedule cancel           # Stop
```

Scheduled runs are fully autonomous. The nerd runs `/nerd` first, then the loop-scout picks the top finding, and `/nerd-loop` goes deep for the rest of the window. Features: retry on failure, low CPU priority, crash recovery.

## Passive Discovery

A `PostToolUse` hook watches as you code. When you write hardcoded thresholds or magic numbers, the nerd adds them to the project backlog. Next `/nerd` run, there's already a queue waiting.

## Multi-Project Scheduling

Global queue at `~/.claude/plugins/nerd/global-queue.yaml` coordinates across repos:
- Round-robin for fairness
- Max 4 parallel experiments, 2 per project

## Pipeline

```
/nerd-setup (once per machine)
    ↓
/nerd (broad survey)
    ├─ Phase 1-2: Scan for parameters
    ├─ Phase 3:   Plan with competing theories
    ├─ Phase 4:   Review gate
    ├─ Phase 5:   Execute in parallel worktrees
    ├─ Phase 6:   Monitor with /loop
    ├─ Phase 7:   Compile theory-aware findings
    └─ Phase 8:   Scout for loop candidates
                    ↓
/nerd-loop (deep iteration)
    ├─ Baseline → edit → test → measure → keep/discard
    ├─ Reflect every 5 iterations
    ├─ Normal → Pivot → Escalate → Local Maximum
    └─ Report with improvement timeline
```

## Output

```
docs/research/
├── findings.md                 # Executive summary with theory verdicts
├── loop-candidates.md          # Scout recommendations for deep iteration
├── plans/E001-plan.md          # Plans with competing theories
├── results/E001-results.json   # Raw data
├── E001-report.md              # KEEP / CHANGE / REARCHITECT / REMOVE
└── loop-search-relevance-report.md  # Deep loop improvement timeline
```

## Configuration

### Hardware Profile (global)
Created by `/nerd-setup` at `~/.claude/plugins/nerd/hardware-profile.yaml`.

### Project Config (auto-created)
Per-project at `.claude/nerd.local.md`:

```yaml
---
max_parallel_experiments: 4
merge_strategy: auto
auto_cleanup_worktrees: true
language: rust
test_command: "cargo test"
backlog: []
---
```

## Agents

| Agent | Color | Model | Role |
|-------|-------|-------|------|
| `parameter-scanner` | Cyan | Sonnet | Finds tunable parameters |
| `plan-reviewer` | Yellow | Opus | Generates competing theories, reviews plans |
| `experiment-executor` | Green | Sonnet | Builds and runs experiments in worktrees |
| `report-compiler` | Blue | Sonnet | Evaluates theories, writes findings |
| `loop-scout` | Magenta | Sonnet | Identifies best candidates for /nerd-loop |

## Requirements

- Git with worktree support
- Claude Code with agent capabilities
- macOS (for LaunchAgent scheduling)

## Origin

Born from a session where 15 experiments were designed, built, and run across two codebases. The key insight: **the most valuable findings weren't parameter tweaks — they were architectural discoveries that emerged from testing competing theories.**

- Entity resolution thresholds were optimal — **but 99% of resolution was via exact email match, making the fuzzy tier irrelevant** (data was the bottleneck, not the threshold)
- System prompt compression saves 99% tokens — **the feature worked but was sent 3700 tokens of context it never used** (feature was unnecessary in current form)
- Orchestrator weights were dead code — **the LLM generates its own heights, bypassing the weights entirely** (architecture bypasses the parameter)
- Temporal decay was bursty, not exponential — **the model was wrong, not the parameters** (model mismatch)

The nerd packages these patterns into a plugin that runs on any codebase, any night.

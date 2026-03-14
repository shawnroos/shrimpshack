# nerd

Your obsessive overnight research assistant for Claude Code. Finds every tunable parameter in your codebase, designs rigorous experiments, runs them in worktrees while you sleep, and delivers findings with actionable recommendations.

## Quick Start

```bash
/nerd-setup                    # Calibrate your hardware
/nerd                          # Let it loose on your codebase
/nerd search relevance         # Focus on a specific area
/nerd-schedule tonight         # Schedule overnight runs
/nerd-status                   # Check what it's up to
```

## What It Does

Codebases accumulate hardcoded thresholds, magic numbers, and heuristic weights chosen by intuition, not measurement. The nerd finds them all and proves whether they're optimal.

```
/nerd
  |
  +-- parameter-scanner (cyan)
  |     Obsessively greps for: thresholds, weights, prompts, budgets, timing
  |
  +-- You pick which findings to investigate
  |
  +-- plan-reviewer (yellow, opus)
  |     Designs experiments with: hypothesis, metric, sweep, ground truth
  |     Reviews its own plans for gaps before proceeding
  |
  +-- experiment-executor (green) x N parallel
  |     Builds eval harnesses in worktree branches
  |     Runs parameter sweeps, captures results
  |     Auto-merges on success, auto-reverts on test failure
  |
  +-- /loop 5m monitors until queue complete
  |
  +-- report-compiler (blue)
        Writes: docs/research/findings.md + per-experiment reports
        Each finding: KEEP, CHANGE (with code diff), or INVESTIGATE
```

## Overnight Runs

The nerd is designed to work while you sleep:

```bash
/nerd-schedule tonight          # Run 22:00 - 06:00
/nerd-schedule weeknights       # Recurring M-F 22:00-06:00
/nerd-schedule 23:00-05:00      # Custom window
/nerd-schedule cancel           # Stop scheduled runs
```

Scheduled runs use macOS LaunchAgents. Retry on failure (3 attempts), low CPU priority, crash recovery on next session start.

## Passive Discovery

A `PostToolUse` hook watches as you write code. When you create hardcoded thresholds or magic numbers, the nerd silently adds them to the backlog. By the time you run `/nerd`, there's already a queue of findings waiting.

## Multi-Project Scheduling

Running experiments across Arras, Jeans, and other projects? The global queue coordinates:
- Round-robin across projects for fairness
- Max 4 parallel experiments total, 2 per project
- Stored at `~/.claude/plugins/nerd/global-queue.yaml`

## Output

After the nerd finishes, your project has:

```
docs/research/
  findings.md              # Executive summary
  plans/E001-plan.md       # Experiment plans
  results/E001-results.json # Raw sweep data
  E001-report.md           # KEEP / CHANGE / INVESTIGATE
```

## Configuration

### Hardware Profile

Created by `/nerd-setup` at `~/.claude/plugins/nerd/hardware-profile.yaml`.

### Project Config

Per-project at `.claude/nerd.local.md`:

```yaml
---
max_parallel_experiments: 4
merge_strategy: auto
auto_cleanup_worktrees: true
backlog:
  - id: E001
    title: "JW Threshold Tuning"
    status: proposed
    parameter: jw_threshold
    file: src/entities/resolution.rs
    line: 92
    current_value: "0.85"
---
```

## Components

| Type | Name | Purpose |
|------|------|---------|
| `/nerd` | Main command | Full pipeline: scan, plan, execute, report |
| `/nerd-setup` | Setup | Hardware calibration + dependency install |
| `/nerd-schedule` | Schedule | Overnight runs via LaunchAgent |
| `/nerd-status` | Status | Queue and progress monitor |
| `parameter-scanner` | Agent (cyan) | Finds tunable parameters |
| `plan-reviewer` | Agent (yellow) | Reviews experiment plans (Opus) |
| `experiment-executor` | Agent (green) | Runs experiments in worktrees |
| `report-compiler` | Agent (blue) | Writes research reports |
| `SessionStart` | Hook | Checks backlog, detects crashed sessions |
| `PostToolUse:Write` | Hook | Passively discovers tunable parameters |

## Origin

Born from a session where 15 experiments were designed, built, and run across two codebases in one sitting. Key findings from that first run:

- Entity resolution thresholds were already optimal (validated, not assumed)
- System prompt compression saves 99% tokens for query expansion
- Orchestrator layout weights were dead code in the primary path
- Pre-validation heuristics catch 30-40% of design issues at zero API cost
- Temporal decay data was bursty, not exponential — the model was wrong

The nerd packages that workflow so it runs on any codebase, any night.

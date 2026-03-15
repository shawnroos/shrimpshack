# nerd

**Your codebase has hundreds of hardcoded thresholds, magic numbers, and untested heuristics. You don't know which ones matter. The nerd does.**

A Claude Code plugin that obsessively researches your codebase overnight — finding every tunable parameter, designing rigorous experiments with competing theories, running them in isolated worktrees, and delivering findings that tell you what to keep, what to change, and what to rearchitect. It remembers what it learned, so it never wastes time re-testing what it already proved.

## Why

Most "optimization" is guessing. You tweak a threshold, eyeball the result, ship it. The nerd treats your codebase like a research problem:

- **It doesn't just test if a parameter is optimal.** It generates competing theories about *why* it exists — is the parameter wrong? Is the model wrong? Is the feature unnecessary? Is the data the real bottleneck?
- **It runs experiments in parallel worktrees** so your working branch stays clean.
- **It remembers everything** via a persistent knowledge graph, so run 2 builds on run 1's findings instead of rediscovering them.
- **It runs while you sleep.** Schedule it tonight, review the findings tomorrow.

The most valuable findings aren't parameter tweaks. They're architectural discoveries that only emerge when you test competing explanations.

## Install

```bash
claude plugin install nerd
```

## Quick Start

```bash
/nerd-setup                        # One-time hardware calibration
/nerd                              # Let the nerd loose on your codebase
/nerd-loop "search relevance"      # Deep continuous iteration on one area
/nerd-schedule tonight             # Run experiments overnight
```

`/nerd-setup` runs once per machine. Projects auto-initialize on first `/nerd` run.

## What It Actually Does

### `/nerd` — Broad Research

Scans your codebase for every tunable parameter, designs experiments with competing theories, validates the lab environment, runs them in parallel, and delivers structured findings.

```
/nerd "search ranking"
  ├─ parameter-scanner    finds 12 tunable parameters
  ├─ plan-reviewer        generates 3 competing theories per experiment
  ├─ lab-tech             validates data access, config wiring, build cache
  ├─ experiment-executor  runs experiments in parallel worktrees
  ├─ report-compiler      evaluates which theories held up
  └─ loop-scout           recommends the best target for deep iteration
```

### `/nerd-loop` — Deep Iteration

Karpathy's autoresearch pattern applied to your code. Reads the code, hypothesizes an improvement, makes the change, measures, keeps if better, reverts if not — and repeats until it hits a local maximum.

```
/nerd-loop "search relevance"
  ├─ Establishes baseline metric (e.g., nDCG@10)
  ├─ Loops: edit → test → measure → keep/discard
  ├─ Pivots strategy after 5 consecutive failures
  ├─ Escalates after another 5
  └─ Stops at local maximum (15 failures across 3 strategies)
```

It doesn't just sweep parameters — it rewrites algorithms, restructures logic, removes unnecessary code. Anything within the scoped files is fair game.

### `/nerd-this` — Context-Scoped Research

Research just what you're working on right now. Infers scope from your current branch, session files, and conversation topics, then groups findings into research themes.

```
/nerd-this auth flow
  ├─ Infers scope from git diff + session context
  ├─ Groups parameters into research themes
  └─ Runs the full experiment pipeline on selected themes
```

## Competing Theories

This is the core insight. Most experiment tools ask "is this parameter optimal?" The nerd asks "what's actually going on?" by generating 3+ competing theories per experiment:

| Theory Type | What It Tests |
|-------------|---------------|
| **Parameter is wrong** | A different value would improve the metric |
| **Model is wrong** | The mathematical model is inappropriate — try a different one entirely |
| **Feature is unnecessary** | Removing the feature causes no degradation |
| **Data is the bottleneck** | The parameter doesn't matter because the input data is the real problem |
| **Architecture is the bottleneck** | No parameter value can fix this — the architecture needs to change |

Reports evaluate each theory as **SUPPORTED** / **REFUTED** / **INCONCLUSIVE** and recommend: **KEEP**, **CHANGE**, **REMOVE**, **REARCHITECT**, or **INVESTIGATE**.

## Research DAG — The Nerd Remembers

Every theory, verdict, and finding is persisted in a JSON knowledge graph. The nerd gets smarter with every run:

- **Skips dead ends** — won't re-test parameters linked to active REFUTED verdicts
- **Seeds from open threads** — picks up unresolved theories from prior runs
- **Detects staleness** — re-tests when your source files change significantly
- **Synthesizes patterns** — surfaces cross-experiment insights when 3+ verdicts converge

```
~/.claude/plugins/nerd/dag/
├── index.json                    # Cross-project synthesis patterns
└── projects/
    └── projects-arras.json       # Per-project theories, verdicts, edges
```

The DAG has 6 node types (theory, verdict, synthesis, build_profile, cache_verdict, tool_availability), 3 edge types (supports, refutes, spawned), and crash-safe writes (backup → tmp → validate → atomic rename).

## Overnight Runs

```bash
/nerd-schedule tonight             # 22:00 - 06:00
/nerd-schedule weeknights          # Recurring M-F 22:00-06:00
/nerd-schedule 23:00-05:00         # Custom window
/nerd-schedule cancel              # Stop
```

Fully autonomous. The nerd runs `/nerd` first, the loop-scout picks the top finding, then `/nerd-loop` goes deep for the rest of the window. Retry on failure, low CPU priority, crash recovery.

## Lab-Tech Pre-Flight

Before running experiments, the lab-tech agent validates that the environment is ready:

- **Data access** — catches WAL-mode SQLite issues, verifies exports work
- **Config wiring** — confirms struct fields are actually read in execution paths (not dead code)
- **Eval commands** — verifies metric commands run and produce output
- **Build infrastructure** — detects sccache, selects cache strategy, warms build artifacts
- **Cross-experiment conflicts** — flags experiments that would step on each other

If something's missing, it scaffolds the fix (export scripts, test fixtures) rather than just reporting.

## Build Cache Intelligence

For Rust projects running parallel worktree experiments, redundant dependency compilation is the dominant cost. The nerd handles this automatically:

1. **lab-tech** profiles the build, detects sccache, selects the best strategy
2. **experiment-executor** prefixes builds with `RUSTC_WRAPPER=sccache`
3. **report-compiler** records whether the cache strategy worked (cache_verdict nodes in the DAG)
4. Next run, lab-tech reads prior cache verdicts and skips strategies that failed

## Passive Discovery

A `PostToolUse` hook watches as you code. When you write hardcoded thresholds or magic numbers, the nerd silently adds them to the backlog. Next `/nerd` run, there's already a queue waiting.

## Pipeline

```
/nerd-setup (once per machine)
    ↓
/nerd (broad survey)
    ├─ Phase 1-2: Scan + DAG-aware deduplication
    ├─ Phase 3:   Plan with competing theories + prior theory checking
    ├─ Phase 4:   Review gate
    ├─ Phase 4.5: Lab readiness (data, config, build cache, eval commands)
    ├─ Phase 5:   Execute in parallel worktrees with build caching
    ├─ Phase 6:   Monitor
    ├─ Phase 7:   Compile findings + write to Research DAG
    ├─ Phase 8:   Scout for loop candidates + write synthesis
    └─ Phase 9:   Cleanup
                    ↓
/nerd-loop (deep iteration)
    ├─ Lab readiness + sccache lifecycle
    ├─ Baseline → edit → test → measure → keep/discard
    ├─ Normal → Pivot → Escalate → Local Maximum
    └─ Report with improvement timeline
```

## Agents

| Agent | Model | Role |
|-------|-------|------|
| `parameter-scanner` | Sonnet | Finds tunable parameters, consults DAG to skip dead ends |
| `context-scanner` | Sonnet | Scans scoped files and clusters into research themes |
| `plan-reviewer` | Opus | Generates competing theories, checks prior research |
| `lab-tech` | Sonnet | Pre-flight validation, infrastructure scaffolding, build cache setup |
| `experiment-executor` | Sonnet | Builds and runs experiments in worktrees |
| `report-compiler` | Sonnet | Evaluates theories, writes findings and DAG nodes |
| `loop-scout` | Sonnet | Identifies loop candidates, writes synthesis patterns |

## Output

```
docs/research/
├── findings.md                        # Executive summary with theory verdicts
├── loop-candidates.md                 # Scout recommendations for deep iteration
├── lab-readiness-batch-*.md           # Pre-flight validation reports
├── plans/E001-plan.md                 # Experiment plans with competing theories
├── results/E001-results.json          # Raw sweep data
├── fixtures/E002/queries.json         # Lab-tech scaffolded test data
├── E001-report.md                     # KEEP / CHANGE / REARCHITECT / REMOVE
└── loop-search-relevance-report.md    # Deep loop improvement timeline
```

## Requirements

- Git with worktree support
- Claude Code with agent capabilities
- macOS (for LaunchAgent scheduling)

## Origin

Born from a session where 15 experiments were designed, built, and run across two codebases. The key insight: **the most valuable findings weren't parameter tweaks — they were architectural discoveries that emerged from testing competing theories.**

- Entity resolution thresholds were optimal — **but 99% of resolution was via exact email match, making the fuzzy tier irrelevant**
- System prompt compression saves 99% tokens — **the feature worked but was sent 3700 tokens of context it never used**
- Orchestrator weights were dead code — **the LLM generates its own weights, bypassing the config entirely**
- Temporal decay was bursty, not exponential — **the model was wrong, not the parameters**

The nerd packages these patterns into a plugin that runs on any codebase, any night.

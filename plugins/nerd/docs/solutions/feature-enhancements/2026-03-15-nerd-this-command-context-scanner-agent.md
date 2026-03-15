---
title: context-scoped-experiment-discovery-nerd-this
date: 2026-03-15
module: "nerd plugin — commands/nerd-this.md, agents/context-scanner.md"
severity: P2
symptoms:
  - "/nerd always scanned full codebase regardless of user's current work focus"
  - "Users working on specific spikes/features were overwhelmed by irrelevant parameter findings"
  - "No way to scope experiment discovery to current branch, session, or topic"
  - "Parameter selection was individual (flat list), not thematic — mismatched how users think about research areas"
tags:
  - nerd-plugin
  - context-scoping
  - experiment-discovery
  - research-themes
  - session-awareness
  - git-branch-diff
  - parameter-clustering
  - context-scanner
  - nerd-this
  - command-agent-contract
related_issues: []
---

# Context-Scoped Experiment Discovery: /nerd-this Command + Context-Scanner Agent

## Problem

The `/nerd` command only offered full-codebase scanning with optional keyword filtering. Users working on feature spikes needed context-scoped research that matched their thematic thinking ("agent lifecycle management") rather than parameter-level selection ("line 92 threshold"). Running `/nerd` during a spike overwhelmed users with irrelevant findings from unrelated parts of the codebase.

## Root Cause

`/nerd` was designed as a broad discovery tool — scan everything, optionally filter by keyword. This is the wrong entry point for spike work, where the mental model starts from "what am I working on right now?" and organizes around themes, not individual parameters. These are fundamentally different intents that warrant separate commands.

## Investigation Steps

1. **Identified the intent gap:** `/nerd` starts from "scan everything" while spike research starts from "scope to my current work." A flag on `/nerd` was considered but rejected — different intent deserves its own entry point.

2. **Determined scope signals:** Three sources of "what the user is working on" were identified:
   - Git branch diff (most reliable — committed + uncommitted changes vs default branch)
   - Session file access (LLM self-reporting — useful but imperfect)
   - Conversation content (topic and path extraction from the current session)

3. **Resolved granularity:** Thematic grouping (1-6 clusters by functional role) was chosen over parameter-level selection because broad research across related parameters is where the value lies for spike work.

4. **Pipeline reuse:** Phases 6-11 of `/nerd-this` directly reuse `/nerd` Phase 3-8 (plan-reviewer → lab-tech → executor → reporter → loop-scout), avoiding duplication.

## Solution

Two new files created, no existing files modified:

### `commands/nerd-this.md` — The Command (14KB, 11 phases)

**Phases 1-5 are new** (scope resolution → confirmation → thematic scan → theme selection → backlog expansion). **Phases 6-11 reuse** the existing `/nerd` pipeline.

Scope resolution unions three signals, filters non-source files, and validates paths:

```
Signal 1 — Git branch diff:
  git diff ${default_branch}...HEAD --name-only  (committed)
  git diff --name-only                           (uncommitted)

Signal 2 — Session file access:
  LLM self-reports files Read/Written/Edited in session
  CAVEAT: Imperfect recall; supplementary signal only

Signal 3 — Conversation content:
  Extract file paths, function names, module names from discussion
  Validate all paths exist on disk before including
```

Theme selection uses `AskUserQuestion` with all themes selected by default. Users deselect with "drop N" syntax. Backlog expansion deduplicates by `file+parameter` (not `file+line` which shifts).

### `agents/context-scanner.md` — The Agent (7KB)

Sonnet-class agent that receives an explicit file list (not the whole codebase), applies the same parameter detection patterns as `parameter-scanner`, and clusters results into 1-6 themes by functional role. Returns structured JSON with themes containing parameter arrays.

## Review-Driven Fixes

Seven issues were caught during plugin-dev and code review:

| Issue | Risk | Fix |
|-------|------|-----|
| Auto-init `if/fi` block didn't wrap config creation | P0: data loss on repeat runs | Closed the `if` block around both config creation and gitignore update |
| Dedup key was `file+line` | P0: duplicates when code inserted | Changed to `file+parameter` with `file+line` fallback |
| Signal 2 relied on LLM self-recall with no caveat | P0: silently incomplete scope | Added explicit warning about recall limitations |
| Agent required minimum 2 themes; command handled 1 | P2: forced artificial splits | Changed agent minimum to 1 |
| Scope threshold: command said 51+, agent said 50+ | P1: inconsistent behavior | Standardized to 50+ |
| Signal 3 paths from conversation not validated | P1: hallucinated paths in scope | Added existence check before inclusion |
| Start-ID computation was ambiguous prose | P2: incorrect IDs | Made computation explicit with step-by-step instructions |

## Prevention Strategies

### Command-Agent Contract Coordination

All seven issues trace to a single structural problem: **a command template and its agent operate as a split-brain system with no formal contract.** Prevention rules:

1. **Single source of truth for every constant.** No magic numbers duplicated across command and agent files. When a threshold must appear in both, have the command inject it into the agent prompt dynamically.

2. **Idempotent on repeat runs.** Every command must be safe to run twice — no data loss, no duplication. Test by running the command, making no changes, running again, and asserting no side effects.

3. **Mechanical enumeration over generative recall.** Use tool calls (git diff, grep) for facts. Use LLM for reasoning. Never ask the model to enumerate concrete artifacts from its own context without acknowledging the limitation.

4. **Stable dedup keys.** Keys must survive the mutations the command itself causes. `file+parameter_name` is stable; `file+line_number` is not.

5. **Structured agent instructions.** Pseudocode or worked examples for anything involving computation. Natural language arithmetic is probabilistic.

6. **Reference validation.** Every path, ID, or artifact the agent produces gets checked for existence before use.

7. **Boundary behavior specified explicitly.** "Greater than 50" vs "50 or more" — pick one, state it, use it in both files.

### Design Checklist for Future Nerd Commands

Before shipping any new command using the template-plus-agent pattern:

- [ ] All constants appear in exactly one file (or are injected dynamically)
- [ ] Repeat-run test passes (no overwrites, no duplicates)
- [ ] File enumerations use tool output, not LLM memory
- [ ] Dedup keys are content-based, not position-based
- [ ] Agent prompts use pseudocode for computation
- [ ] All generated references are validated against the filesystem
- [ ] Boundary values are tested at N-1, N, and N+1

## Related Documentation

- **Origin brainstorm:** `docs/brainstorms/2026-03-15-nerd-this-brainstorm.md`
- **Implementation plan:** `docs/plans/2026-03-15-feat-nerd-this-context-scoped-experiments-plan.md`
- **Scope confirmation precedent:** `commands/nerd-loop.md` Step 1b (file list confirmation pattern)
- **Parameter detection patterns:** `agents/parameter-scanner.md` (reused by context-scanner)
- **Research DAG integration:** `docs/plans/2026-03-15-feat-research-dag-persistent-memory-plan.md` (future: DAG awareness for nerd-this)
- **Pipeline reuse:** `commands/nerd.md` Phase 3-8 (plan-reviewer → lab-tech → executor → reporter → loop-scout)

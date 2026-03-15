---
title: "Research DAG: Persistent Knowledge Graph for Cross-Session Memory"
category: architecture-decisions
tags:
  - knowledge-graph
  - dag
  - multi-agent
  - session-persistence
  - crash-safety
  - context-management
  - orchestrator-pattern
module: nerd
symptom: "Each /nerd invocation rediscovers the world from scratch, re-testing theories already proved or disproved across sessions"
root_cause: "Pipeline is fully stateless — no persistent store links prior research outcomes to current queries"
solution_type: "Append-only JSON knowledge graph with orchestrator-mediated read access and restricted write permissions"
---

# Research DAG: Cross-Session Memory for Multi-Agent Pipelines

## Problem Statement

The nerd plugin runs 6 LLM agents in a sequential pipeline (scan, plan, review, execute, report, scout). Each run was fully stateless — agents had no memory of prior theories, verdicts, or findings. This caused three concrete failures:

1. **Redundant experiments** — re-testing "fuzzy match threshold" every run after already proving it irrelevant (99% of resolution via exact email match)
2. **Lost insights** — findings existed as flat markdown in `docs/research/` but nothing connected them across sessions
3. **No synthesis** — patterns across multiple experiments were never surfaced

## Root Cause

The pipeline stored per-run artifacts (plans, results, reports) but had no structured, queryable store linking outcomes back to input parameters. Each agent started from zero context. The backlog in `nerd.local.md` tracked what to explore but not what to avoid.

## Solution

A JSON knowledge graph (Research DAG) stored at `~/.claude/plugins/nerd/dag/` with per-project files and a global index.

### Schema

- **6 node types**: theory, verdict, synthesis, build_profile, cache_verdict, tool_availability
- **3 edge types**: supports, refutes, spawned
- **ID convention**: T-prefix (theories), V-prefix (verdicts), S-prefix (synthesis), I-prefix (infra)

### Data Flow

```
report-compiler WRITES theories + verdicts + edges after each run
    ↓
orchestrator computes staleness, generates filtered markdown summaries
    ↓
parameter-scanner READS summary → skips resolved params, seeds from open theories
plan-reviewer READS summary → avoids re-testing, checks prior theories
    ↓
loop-scout READS project DAG + global index → writes synthesis nodes
```

### Key Architectural Decisions

**1. Orchestrator-mediated reads (not raw JSON)**

Agents receive pre-filtered markdown summaries, not the raw DAG file. This prevents context window exhaustion (~310K tokens at 500 nodes with raw JSON vs ~5K with filtered summaries).

**Why this matters:** LLM agents are not JSON parsers. Asking a Sonnet-class agent to parse a 500-node JSON file, extract relevant entries, and continue its primary task degrades both tasks. The orchestrator does the filtering in bash/python and injects a natural-language summary.

**2. Restricted write access**

Only report-compiler (project DAG) and loop-scout (global index) write. Scanner and plan-reviewer are read-only via summaries. This preserves the single-writer-per-file invariant.

**3. Crash-safe write protocol**

```bash
cp dag.json dag.json.bak           # 1. backup
cat > dag.json.tmp << 'JSON'       # 2. write to temp
{...}
JSON
python3 -c "import json; json.load(open('dag.json.tmp'))"  # 3. validate
mv dag.json.tmp dag.json           # 4. atomic rename
```

If validation fails, the temp file is discarded and the original preserved.

**4. INCONCLUSIVE verdicts don't create edges**

Early design mapped INCONCLUSIVE to `supports` edges. This caused false theory matches in plan-reviewer. Fix: INCONCLUSIVE verdicts record the result in the node but create no edge.

**5. Binary staleness via codebase_hash**

Each node stores an 8-char hash of its source files. The orchestrator recomputes hashes and marks nodes `stale` when the hash differs. Binary comparison (changed vs unchanged) rather than percentage-based, because hashes don't support partial comparison.

**6. Synthesis requires 3+ supporting verdicts**

Prevents premature generalization from sparse data.

## Implementation

7 commits, +2539 lines, 18 files:

| File | Change |
|------|--------|
| `schemas/dag-schema.json` | JSON schema for all node/edge types |
| `agents/report-compiler.md` | Step 8: write theories, verdicts, edges, cache verdicts |
| `agents/parameter-scanner.md` | Prior Research Context section |
| `agents/plan-reviewer.md` | Step 1.5: check prior theories (matching rule: 1+ identical source_file AND 1+ identical tag) |
| `agents/loop-scout.md` | Synthesis write + Write/Bash tools added |
| `commands/nerd.md` | DAG auto-init, staleness, summaries, Phase 5.0/9 |
| `commands/nerd-this.md` | Synced prompts with DAG-aware versions |
| `hooks/hooks.json` | DAG file exclusion + backlog dedup |

## Prevention Strategies

### 1. Agent Tool Availability Gaps

**Pattern discovered:** Loop-scout was tasked with writing synthesis nodes but lacked the Write and Bash tools. The crash-safe protocol requires cp, python3, mv — all need Bash.

**Prevention:** For every verb in an agent's prompt (write, execute, validate), verify the corresponding tool is in its tool list. Treat tool sets as capability presets (`crash-safe-writer = [Read, Write, Bash]`).

### 2. Prompt Synchronization Drift Between Commands

**Pattern discovered:** `/nerd-this` had 4 agent prompts that diverged from `/nerd`'s DAG-aware versions — experiments via `/nerd-this` silently bypassed the DAG.

**Prevention:** When modifying a shared agent prompt in one command, grep all command files for the same `Agent(subagent_type=` invocation and update them all. A "prompt lint" that detects divergent prompts for the same agent type across commands would catch this automatically.

### 3. Semantic Edge Type Misuse

**Pattern discovered:** INCONCLUSIVE mapped to `supports` caused downstream agents to treat uncertain results as confirmed.

**Prevention:** Edge types must have unambiguous semantics. When adding a new result type, verify it maps cleanly to an existing edge type or create a new one. The test: "If an agent sees this edge, what action will it take? Is that the correct action for this result?"

### 4. Safe File-Based Inter-Agent Communication

**Pattern discovered:** Report-compiler wrote to the DAG in Step 8.5, then Step 8.7 needed to read it back — but without an explicit re-read instruction, the agent might use stale in-memory state.

**Prevention:** After any file write, add an explicit re-read instruction before subsequent reads of the same file within the same agent. Don't assume the agent tracks file state across its own writes.

### 5. Multi-Command Plugin Feature Checklist

When adding a feature that touches shared agents:

- [ ] Update agent prompt in ALL commands that invoke it (grep for `subagent_type=`)
- [ ] Verify agent has all required tools for new responsibilities
- [ ] Check edge type semantics map correctly to downstream consumers
- [ ] Add explicit re-read after any write that a later step depends on
- [ ] Test first-run behavior (no DAG exists) — agents must degrade gracefully
- [ ] Verify hook exclusions for any new file types the feature creates

## Cross-References

- PR: https://github.com/shawnroos/nerd/pull/1
- Brainstorm: `docs/brainstorms/2026-03-15-research-dag-brainstorm.md`
- Plan: `docs/plans/2026-03-15-feat-research-dag-persistent-memory-plan.md`
- Research chat: `Research chat` (TLA+ and Hyperspace DAG discussion that sparked the idea)

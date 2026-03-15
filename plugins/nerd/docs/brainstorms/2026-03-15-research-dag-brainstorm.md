---
date: 2026-03-15
topic: research-dag
---

# Research DAG — Persistent Memory Across Nerd Runs

## What We're Building

A structured knowledge graph that persists nerd's findings across sessions and projects. Currently nerd is stateless — each run rediscovers the world from scratch. The DAG gives nerd memory: what theories have been tested, what verdicts were reached, and what patterns emerge across findings.

Short-term goals:
- **(A) Session memory** — nerd remembers what it proved/disproved in a project, skips known dead ends
- **(C) Synthesis** — nerd reasons across findings to surface higher-order patterns

Future goal:
- **(B) Cross-project transfer** — findings from one codebase seed hypotheses in another

## Why This Approach

Flat markdown files in `docs/research/` capture findings but nothing connects them. The backlog in `nerd.local.md` tracks what to explore but not what to avoid. The DAG fills both gaps with minimal overhead.

Global location (`~/.claude/plugins/nerd/dag/`) was chosen over per-project files because it's the natural path to cross-project transfer (B) without rearchitecting later.

## Key Decisions

- **Location**: `~/.claude/plugins/nerd/dag/` with per-project files + shared index
- **Node types**: `theory`, `verdict`, `synthesis` — theories included because they help plan-reviewer avoid re-testing hypotheses already explored
- **Edge types**: `supports`, `refutes`, `spawned` — minimal set, sufficient for lineage tracking
- **Staleness**: Nodes get a `codebase_hash` (based on files they reference). parameter-scanner checks if source files changed significantly; marks nodes `stale` if so
- **Synthesis timing**: report-compiler writes to DAG after every run (project-level); loop-scout reads across global index for cross-project patterns
- **No new commands**: DAG is read/written by existing agents, not a separate workflow

## Schema

```
~/.claude/plugins/nerd/dag/
├── index.json                    # synthesis nodes, cross-project edges
├── projects/
│   ├── arras.json               # Arras findings
│   └── {project-slug}.json      # per-project DAG
```

### Node Schema

```json
{
  "id": "T001",
  "type": "theory",
  "project": "arras",
  "title": "Fuzzy matching is irrelevant — 99% resolution via exact email",
  "source_experiment": "E001",
  "source_files": ["src/entities/resolution.rs"],
  "codebase_hash": "a3f2c1",
  "created_at": "2026-03-14T23:30:00Z",
  "status": "active",
  "tags": ["entity-resolution", "data-bottleneck"]
}
```

```json
{
  "id": "V001",
  "type": "verdict",
  "project": "arras",
  "theory_id": "T001",
  "result": "SUPPORTED",
  "evidence": "99.2% of merges used exact email match. Fuzzy tier fired 12 times across 15k entities.",
  "recommendation": "REARCHITECT",
  "source_files": ["src/entities/resolution.rs"],
  "codebase_hash": "a3f2c1",
  "created_at": "2026-03-14T23:45:00Z",
  "status": "active"
}
```

```json
{
  "id": "S001",
  "type": "synthesis",
  "project": null,
  "title": "Data bottleneck > threshold tuning in entity resolution",
  "claim": "In 4/5 projects, entity resolution quality was limited by data coverage, not matching thresholds",
  "supporting_verdicts": ["V001", "V012", "V034"],
  "confidence": "high",
  "created_at": "2026-03-15T06:00:00Z",
  "status": "active"
}
```

### Edge Schema

```json
{
  "from": "V001",
  "to": "T003",
  "type": "spawned",
  "reason": "If fuzzy matching is irrelevant, the entire dedup pipeline could be simplified"
}
```

## Agent Modifications

### parameter-scanner
- **Reads** project DAG before scanning
- Skips parameters linked to REFUTED theories (with active status)
- Seeds scan with open theories (INCONCLUSIVE or spawned but untested)
- Flags `stale` nodes when source files have changed

### plan-reviewer
- **Reads** project DAG when generating competing theories
- Checks if any proposed theory has already been tested
- If SUPPORTED: "Theory already confirmed in E001 — consider building on it"
- If REFUTED: "Theory already disproved in E001 — skip or reformulate"
- Links new theories to existing DAG nodes via `spawned` edges

### report-compiler
- **Writes** to project DAG after each run
- Creates theory nodes from each experiment's competing theories
- Creates verdict nodes from each experiment's results
- Adds edges: verdict → theory (supports/refutes), verdict → new theory (spawned)
- Computes `codebase_hash` from the experiment's source files

### loop-scout
- **Reads** project DAG + global index
- Checks for cross-project patterns when scoring candidates
- Writes synthesis nodes to `index.json` when patterns emerge
- Flags if a loop candidate has a relevant synthesis from another project

## Staleness Protocol

1. When parameter-scanner reads the DAG, for each active node:
   - Hash the current content of `source_files`
   - Compare against stored `codebase_hash`
   - If >30% of lines changed: mark node `stale`
   - If file deleted: mark node `stale`
2. Stale nodes are not trusted but not deleted — they stay as historical record
3. A stale theory can be re-tested (spawns a new experiment, not a duplicate)

## Open Questions

- Should synthesis nodes require a minimum number of supporting verdicts? (Suggest 3+ to avoid premature generalization)
- Should the DAG be prunable via a command, or just grow with staleness markers?
- When cross-project transfer (B) lands, should theories propagate automatically or require user opt-in?

## Next Steps

1. Create the DAG schema as a JSON schema file in the plugin
2. Modify report-compiler to write theory + verdict nodes
3. Modify parameter-scanner to read the DAG and skip/seed
4. Modify plan-reviewer to check theories against DAG
5. Modify loop-scout to write synthesis nodes
6. Add staleness checking to parameter-scanner

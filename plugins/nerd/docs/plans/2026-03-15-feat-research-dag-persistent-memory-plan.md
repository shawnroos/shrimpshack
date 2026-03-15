---
title: "feat: Add Research DAG for Persistent Memory Across Nerd Runs"
type: feat
status: completed
date: 2026-03-15
deepened: 2026-03-15
origin: docs/brainstorms/2026-03-15-research-dag-brainstorm.md
---

# Research DAG — Persistent Memory Across Nerd Runs

## Enhancement Summary

**Deepened on:** 2026-03-15
**Review agents used:** architecture-strategist, code-simplicity-reviewer, data-integrity-guardian, pattern-recognition-specialist, performance-oracle, agent-native-reviewer

### Key Improvements from Review (adopted)
1. **Move staleness checking to the orchestrator** — parameter-scanner lacks Write tool; orchestrator pre-computes and injects a filtered DAG summary
2. **Add crash-safe writes** — write to `.tmp`, validate JSON, rename (atomic on POSIX)
3. **Add backup-before-write** — `cp .json .json.bak` before every write
4. **Add `Write` tool to loop-scout** — required for synthesis node writes to `index.json`
5. **Pre-filter DAG in orchestrator** — pass only relevant nodes to agents as markdown summaries, not full JSON; prevents context window exhaustion at scale
6. **Define theory matching concretely** — "at least 1 identical source_file path AND at least 1 identical tag string" instead of vague "similarity"
7. **Binary staleness** — hash changed = stale (not the underspecified 30% line threshold)
8. **Parent-basename slugs** — avoid project slug collisions
9. **PostToolUse hook exclusion** — prevent hook from firing on DAG file writes

### Simplicity recommendations NOT adopted
- ~~Defer synthesis to v2~~ — synthesis (goal C) is a short-term priority per brainstorm
- ~~Drop edges array~~ — edges carry `reason` context and `spawned` relationships that aren't encoded in verdict nodes
- ~~Drop JSON schema~~ — schema serves as documentation and enables future programmatic validation
- ~~Drop tags~~ — tags drive theory matching and synthesis clustering

### New Risks Discovered
- PostToolUse hook may fire on DAG file writes (add path exclusion)
- DAG exceeds agent context at ~500 nodes without archival (~310K tokens)
- Project slug collisions (e.g., two projects named `api/`)
- Loop-scout lacks Write tool (add it)

---

## Overview

Add a structured knowledge graph (`research-dag`) that persists nerd's theories, verdicts, and synthesized patterns across sessions and projects. Currently nerd is stateless — each `/nerd` run rediscovers the world from scratch, potentially re-testing theories that were already proved or disproved. The DAG gives nerd memory.

(see brainstorm: docs/brainstorms/2026-03-15-research-dag-brainstorm.md)

## Problem Statement / Motivation

Three concrete failure modes today:

1. **Redundant experiments** — nerd finds "fuzzy match threshold" as a tunable parameter every run, even after proving in E001 that "99% of resolution was via exact email match." It wastes an experiment slot.
2. **Lost insights** — findings exist as flat markdown in `docs/research/` but nothing connects them. The insight "data is the bottleneck, not thresholds" doesn't propagate to future experiment design.
3. **No synthesis** — patterns across multiple experiments (e.g., "LLM rerankers add latency without quality in 4/5 projects") are never surfaced because no agent reasons across findings.

## Proposed Solution

A lightweight JSON knowledge graph stored at `~/.claude/plugins/nerd/dag/` with three node types (theory, verdict, synthesis), three edge types (supports, refutes, spawned), and a JSON schema for validation. Four existing agents get DAG awareness — no new agents or commands needed.

(see brainstorm: docs/brainstorms/2026-03-15-research-dag-brainstorm.md for schema details and location rationale)

## Technical Approach

### Architecture

```
~/.claude/plugins/nerd/dag/
├── schema.json                   # JSON schema for DAG validation
├── index.json                    # synthesis nodes, cross-project edges
├── projects/
│   ├── projects-arras.json       # per-project theories + verdicts + edges
│   └── {project-slug}.json
```

**Data flow through the pipeline:**

```
/nerd Pre-flight
  ORCHESTRATOR reads project DAG
    → computes staleness (hashes source files, binary comparison)
    → pre-filters relevant nodes for each agent phase
    → generates markdown summaries (not raw JSON)
    → backs up DAG before any writes
        ↓
/nerd Phase 2 (scan)
  parameter-scanner receives DAG SUMMARY (markdown, not JSON)
    → skips parameters linked to active REFUTED verdicts
    → seeds scan with open/INCONCLUSIVE theories
    → does NOT write to DAG
        ↓
/nerd Phase 3 (plan)
  plan-reviewer receives DAG SUMMARY (per-experiment, filtered by source file overlap)
    → checks proposed theories against existing nodes
    → avoids re-testing already-resolved theories
    → does NOT write to DAG
        ↓
/nerd Phase 7 (report)
  report-compiler WRITES to project DAG
    → creates theory nodes from competing theories sections
    → creates verdict nodes from experiment results
    → creates edges (supports/refutes/spawned)
    → computes codebase_hash per node
    → uses crash-safe write protocol
        ↓
/nerd Phase 8 (scout)
  loop-scout READS project DAG + global index, WRITES synthesis to index.json
    → detects cross-finding patterns (3+ verdicts with same conclusion)
    → writes synthesis nodes to index.json
    → surfaces relevant synthesis from other projects
    → uses crash-safe write protocol
```

### Node Schema

**Theory node:**
```json
{
  "id": "T001",
  "type": "theory",
  "title": "Fuzzy matching is irrelevant — 99% resolution via exact email",
  "source_experiment": "E001",
  "source_files": ["src/entities/resolution.rs"],
  "codebase_hash": "a3f2c1d8",
  "created_at": "2026-03-14T23:30:00Z",
  "status": "active",
  "tags": ["entity-resolution", "data-bottleneck"]
}
```

**Verdict node:**
```json
{
  "id": "V001",
  "type": "verdict",
  "theory_id": "T001",
  "result": "SUPPORTED",
  "evidence": "99.2% of merges used exact email match. Fuzzy tier fired 12 times across 15k entities.",
  "recommendation": "REARCHITECT",
  "source_experiment": "E001",
  "source_files": ["src/entities/resolution.rs"],
  "codebase_hash": "a3f2c1d8",
  "created_at": "2026-03-14T23:45:00Z",
  "status": "active"
}
```

**Synthesis node** (in `index.json`):
```json
{
  "id": "S001",
  "type": "synthesis",
  "project": null,
  "title": "Data bottleneck > threshold tuning in entity resolution",
  "claim": "In 4/5 projects, entity resolution quality was limited by data coverage, not matching thresholds",
  "supporting_verdicts": [
    {"project": "projects-arras", "id": "V001"},
    {"project": "projects-jeans", "id": "V012"}
  ],
  "confidence": "high",
  "created_at": "2026-03-15T06:00:00Z",
  "status": "active"
}
```

*Note (from data-integrity review): synthesis verdict references include project slug to prevent dangling cross-file references.*

### Edge Schema

Edges are stored in the project DAG file's `edges` array. They carry `reason` context that node fields alone don't capture:

```json
{
  "from": "V001",
  "to": "T001",
  "type": "supports",
  "reason": "99.2% exact match rate confirms fuzzy tier is irrelevant"
}
```

```json
{
  "from": "V001",
  "to": "T003",
  "type": "spawned",
  "reason": "If fuzzy matching is irrelevant, the entire dedup pipeline could be simplified"
}
```

Edge types:
- `supports` — verdict confirmed the theory
- `refutes` — verdict disproved the theory
- `spawned` — a finding led to a new hypothesis

### Write Safety Protocol

**All DAG writes must follow this protocol** (enforced in agent prompts for report-compiler and loop-scout):

```bash
# 1. Backup existing
cp "$DAG_FILE" "$DAG_FILE.bak"

# 2. Write to temp file
# (agent writes JSON to $DAG_FILE.tmp)

# 3. Validate JSON
python3 -c "import json; json.load(open('$DAG_FILE.tmp'))" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: Invalid JSON in DAG write. Keeping original."
    rm "$DAG_FILE.tmp"
    exit 1
fi

# 4. Atomic rename
mv "$DAG_FILE.tmp" "$DAG_FILE"
```

If validation fails, the `.tmp` file is removed and the original is preserved. The `.bak` file provides one-step recovery.

### Implementation Phases

#### Phase 1: DAG Schema + Init Infrastructure

Create the DAG directory structure, JSON schema, and initialization logic.

**Files to create:**
- `schemas/dag-schema.json` — JSON schema documenting all node types, edge types, and file structure

**Files to modify:**
- `commands/nerd-setup.md` — add global DAG directory + `index.json` creation
- `commands/nerd.md` — add DAG auto-init + staleness computation to pre-flight
- `hooks/hooks.json` — add path exclusion for `~/.claude/plugins/nerd/dag/`

**DAG init creates:**
```bash
mkdir -p ~/.claude/plugins/nerd/dag/projects
```

**Project slug derivation:** Include parent directory to avoid collisions:
```bash
echo "$(basename "$(dirname "$PWD")")-$(basename "$PWD")" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
```
Example: `/Users/shawnroos/projects/Arras` → `projects-arras`

**Empty project DAG:**
```json
{
  "nodes": [],
  "edges": [],
  "project": "projects-arras",
  "project_path": "/Users/shawnroos/projects/Arras",
  "version": 1
}
```

**Empty global index:**
```json
{
  "nodes": [],
  "edges": [],
  "version": 1
}
```

*`project_path` is stored so slug collisions can be detected. On load, verify `project_path` matches `$PWD`.*

**Acceptance criteria:**
- [x] `schemas/dag-schema.json` validates all three node types and three edge types
- [x] `/nerd` auto-creates project DAG file on first run if missing
- [x] `/nerd-setup` creates the global `dag/` directory and `index.json`
- [x] Project slug includes parent directory to avoid collisions
- [x] `project_path` is stored and verified on load
- [x] PostToolUse hook excludes `dag/` directory from parameter detection
- [x] Schema includes `version` field for future migration

---

#### Phase 2: Report-Compiler Writes to DAG

The most critical phase — the DAG is useless until something writes to it. Report-compiler already has all the data it needs (theories from plans, verdicts from results).

**File to modify:** `agents/report-compiler.md`

**Additions to report-compiler agent prompt (after existing report writing steps):**

1. **Read the project DAG** (path provided in prompt by orchestrator)

2. **For each experiment's competing theories**, create a theory node (schema above)

3. **For each theory verdict**, create a verdict node (schema above)

4. **Create edges:**
   - Verdict → Theory: `supports` or `refutes` (based on result), with `reason` from the evidence summary
   - If a verdict spawns a new hypothesis: Verdict → new Theory with `spawned` edge and `reason` explaining why

5. **Follow the write safety protocol** (backup → write to .tmp → validate → rename)

**ID generation:** `T{NNN}` / `V{NNN}` format. Read existing nodes, find max numeric suffix, increment. Use sorted source_files for deterministic codebase_hash computation.

**Codebase hash:** 8 characters, sorted file order:
```bash
cat $(echo {source_files} | tr ' ' '\n' | sort) | shasum | cut -c1-8
```

**Acceptance criteria:**
- [x] report-compiler creates theory nodes for every competing theory in each experiment plan
- [x] report-compiler creates verdict nodes with correct result (SUPPORTED/REFUTED/INCONCLUSIVE)
- [x] Edges created with type and reason for each verdict→theory relationship
- [x] Spawned theories linked via spawned edges with explanatory reason
- [x] `codebase_hash` is 8-char hash from sorted source file contents
- [x] Write follows crash-safe protocol (backup → tmp → validate → rename)
- [x] Existing nodes AND edges are preserved (append-only within a run)
- [x] DAG file is valid JSON after writing (validated before rename)

---

#### Phase 3: Orchestrator DAG Processing + Parameter-Scanner Reads

**Critical design decision (from agent-native review):** parameter-scanner does NOT read or write the DAG directly. The `/nerd` orchestrator processes the DAG and injects a filtered markdown summary into the agent prompt. This keeps the agent focused on scanning and avoids tool availability issues.

**Files to modify:** `commands/nerd.md` (pre-flight + Phase 2 prompt), `agents/parameter-scanner.md`

**Orchestrator additions (in `/nerd` pre-flight, after DAG init):**

1. **Compute staleness** using binary hash comparison (hash changed = stale):
   ```bash
   # For each active node in the project DAG:
   # - Hash current content of source_files (sorted, 8-char)
   # - Compare against stored codebase_hash
   # - If hash differs: mark node status = "stale"
   # - If source file deleted: mark node status = "stale"
   # Write updated DAG (with crash-safe protocol)
   ```

2. **Generate DAG summary** for parameter-scanner:
   ```markdown
   ## Prior Research (from DAG)

   ### Skip These Parameters (already resolved):
   - src/entities/resolution.rs:92 `jw_threshold` — REFUTED in E001: "99% resolution via exact email". Recommendation: REARCHITECT.

   ### Re-test These (stale — source files changed):
   - src/search/rank.rs:104 `boost_factor` — tested in E005 but source file changed. Previous: INCONCLUSIVE.

   ### Open Hypotheses (untested theories from prior runs):
   - T003: "Pipeline simplification" — spawned from V001, no experiment yet.
   ```

3. **Pass summary in scanner prompt** (not the raw JSON)

**Parameter-scanner additions:**

Add a `## Prior Research Context` section acknowledging DAG context:
- **Skip** parameters listed as "already resolved"
- **Re-test** parameters listed as "stale"
- **Seed** from "open hypotheses" as high-priority entries
- If no prior research section is provided, scan everything (first run behavior)

**Acceptance criteria:**
- [x] Orchestrator computes staleness using binary hash comparison
- [x] Orchestrator generates a markdown summary of DAG state
- [x] Summary is passed as text in the scanner prompt (not raw JSON)
- [x] Scanner skips resolved parameters
- [x] Scanner seeds from open theories
- [x] Scanner works correctly when no DAG summary is provided (first run)

---

#### Phase 4: Plan-Reviewer Reads DAG

Make plan-reviewer check whether proposed theories have already been tested. Like parameter-scanner, the orchestrator provides a filtered summary.

**Files to modify:** `commands/nerd.md` (Phase 3 prompt), `agents/plan-reviewer.md`

**Orchestrator additions:**

Generate a per-experiment DAG summary for plan-reviewer, filtered by source file overlap:
```markdown
## Prior Theories on {parameter} ({file}:{line})

- T001 (SUPPORTED): "Parameter tuning" — confirmed, threshold is optimal. Evidence: ...
- T002 (REFUTED): "Feature is unnecessary" — disproved, removing degraded quality by 12%.
- T003 (INCONCLUSIVE): "Data bottleneck" — needs more data.
- Edge: V001 spawned T003 — "If fuzzy matching is irrelevant, dedup pipeline could be simplified"
```

**Plan-reviewer additions:**

Add after "Step 1: Read the Plan and Codebase Context":

```
### Step 1.5: Check Prior Theories

If the prompt includes a "Prior Theories" section from the DAG:

1. For each theory you are about to generate, check if a similar theory was already tested.
   Two theories match if they share at least 1 identical source_file path AND at least 1 identical tag string.
   - **SUPPORTED**: Note "Theory already confirmed in {source_experiment}. Consider building on this."
   - **REFUTED**: Do NOT include as a competing theory unless your approach is substantially different. Note: "Previously disproved: {evidence}."
   - **INCONCLUSIVE**: Include and design the experiment to resolve it. Note previous evidence.

2. Check spawned edges — theories spawned from prior verdicts are high-priority hypotheses.

3. Add a `## DAG Context` section to the plan listing relevant prior theories, verdicts, and spawned relationships.

If no prior theories are provided, generate theories from scratch (first run behavior).
```

**Acceptance criteria:**
- [x] Orchestrator generates per-experiment DAG summaries filtered by source file overlap
- [x] Summaries include edge context (spawned relationships)
- [x] Plan-reviewer checks proposed theories against prior findings using concrete matching rules
- [x] REFUTED theories are excluded (unless reformulated)
- [x] Spawned theories are flagged as high-priority
- [x] A `## DAG Context` section is added to every plan
- [x] Plan-reviewer works correctly when no prior theories exist

---

#### Phase 5: Loop-Scout Writes Synthesis Nodes

Make loop-scout detect cross-finding patterns and write synthesis nodes to the global index.

**Files to modify:** `agents/loop-scout.md` (add `Write` to tools + synthesis instructions)

**Tool update:** Add `Write` to loop-scout's tool list:
```yaml
tools: ["Read", "Write", "Glob", "Grep"]
```

**Additions to loop-scout agent prompt:**

After analyzing findings and scoring loop candidates:

1. **Load project DAG + global index** (paths provided in prompt by orchestrator)

2. **Detect patterns** across verdict nodes:
   - Group verdicts by tags
   - If 3+ verdicts in the same tag cluster reach the same conclusion, generate a synthesis node
   - Example: 3 verdicts all say "data quality is the bottleneck" → synthesis: "Data coverage dominates threshold tuning in this project"

3. **Write synthesis nodes to `index.json`** using the schema above. Use qualified verdict references (`{"project": "slug", "id": "V001"}`) to prevent dangling cross-file references.

4. **Check existing synthesis nodes** for cross-project relevance:
   - If a synthesis from another project is relevant, mention it in loop candidate recommendations
   - Example: "Note: In project 'jeans', 3 experiments also found LLM rerankers add latency without quality."

5. **Minimum threshold:** Require 3+ supporting verdicts before creating a synthesis node.

6. **Follow the write safety protocol** for `index.json` writes.

**Acceptance criteria:**
- [x] loop-scout has `Write` in its tool list
- [x] loop-scout reads both project DAG and global index
- [x] Synthesis nodes are created when 3+ verdicts share a pattern
- [x] Synthesis verdict references include project slug (qualified references)
- [x] Synthesis nodes are written to `index.json` (not project file)
- [x] Write follows crash-safe protocol
- [x] Existing synthesis nodes from other projects are surfaced when relevant
- [x] Loop candidate recommendations include DAG context

---

#### Phase 6: Orchestration Wiring

Update the `/nerd` command to pass DAG context in agent prompts.

**File to modify:** `commands/nerd.md`

**Changes:**

1. **Pre-flight** — add DAG init + staleness computation + summary generation (see Phase 3)

2. **Phase 2 (scan)** — inject DAG summary into parameter-scanner prompt

3. **Phase 3 (plan)** — inject per-experiment DAG summary into each plan-reviewer prompt

4. **Phase 7 (report)** — add DAG path to report-compiler prompt:
   ```
   Agent(subagent_type="nerd:report-compiler", prompt="... Write theories, verdicts, and edges to project DAG: {dag_path}.", ...)
   ```

5. **Phase 8 (scout)** — add both DAG paths to loop-scout prompt:
   ```
   Agent(subagent_type="nerd:loop-scout", prompt="... Project DAG: {dag_path}. Global index: {index_path}. Write synthesis nodes to global index. ...", ...)
   ```

**Acceptance criteria:**
- [x] All four agent prompts include DAG context (summaries for readers, paths for writers)
- [x] Project slug is derived consistently using parent-basename
- [x] DAG auto-initializes on first `/nerd` run
- [x] `/nerd-setup` creates the global DAG directory and `index.json`

---

## Future: DAG Archival

**Not needed until** a project exceeds ~100 experiments (~300 nodes). At 1-3 runs/week, this is 6-12 months away. The pre-filtering in the orchestrator (passing markdown summaries, not raw JSON) buys significant runway.

**What archival would add:**
- Archive partition for resolved experiments
- Active DAG capped at ~50 experiments
- Archived nodes still queryable but not injected into agent prompts

---

## Acceptance Criteria

- [x] DAG schema supports theory, verdict, and synthesis nodes
- [x] DAG schema supports supports, refutes, and spawned edges
- [x] JSON schema file documents the full DAG structure
- [x] report-compiler writes theories, verdicts, and edges to DAG after every `/nerd` run
- [x] loop-scout writes synthesis nodes to global index when patterns emerge
- [x] Writes follow crash-safe protocol (backup → tmp → validate → rename)
- [x] Orchestrator computes staleness and pre-filters DAG for reader agents
- [x] parameter-scanner receives DAG summary and skips known dead ends
- [x] plan-reviewer receives DAG summary and avoids re-testing resolved theories
- [x] DAG auto-initializes per-project on first run
- [x] All agents degrade gracefully when no DAG exists (first run)
- [x] Existing nerd functionality is unaffected (DAG is additive)
- [x] PostToolUse hook excludes DAG file writes from parameter detection
- [x] Project slug uses parent-basename to avoid collisions

## Success Metrics

- After 3+ runs on the same project, parameter-scanner proposes fewer redundant experiments
- Plan-reviewer references prior findings when generating competing theories
- Synthesis nodes emerge after 3+ related verdicts accumulate
- No JSON corruption events (write safety protocol prevents them)

## Dependencies & Risks

- **Risk**: JSON corruption during write. **Mitigated by:** crash-safe write protocol (backup → tmp → validate → rename). Recovery via `.bak` file.
- **Risk**: DAG grows unbounded and exceeds context. **Mitigated by:** orchestrator pre-filters and passes markdown summaries, not raw JSON. Archival when needed.
- **Risk**: PostToolUse hook fires on DAG writes. **Mitigated by:** path exclusion in hook.
- **Risk**: Project slug collisions. **Mitigated by:** parent-basename slugging + project_path verification on load.
- **Risk**: LLM writes invalid JSON. **Mitigated by:** validation before rename; `.tmp` discarded on failure.
- **Risk**: Dangling cross-file references in synthesis nodes. **Mitigated by:** qualified verdict references (`{"project": "slug", "id": "V001"}`).
- **Risk**: Loop-scout can't write. **Mitigated by:** adding `Write` to its tool list.

## Sources

- **Origin brainstorm:** [docs/brainstorms/2026-03-15-research-dag-brainstorm.md](docs/brainstorms/2026-03-15-research-dag-brainstorm.md) — key decisions: global location for future cross-project transfer, three node types (theory/verdict/synthesis), three edge types (supports/refutes/spawned), staleness via codebase_hash, synthesis requires 3+ supporting verdicts
- **Review findings adopted:** architecture-strategist (consolidate writes to orchestrator), data-integrity-guardian (crash-safe writes, backup, slug collisions, qualified cross-file references), pattern-recognition-specialist (hook exclusion), performance-oracle (pre-filter DAG, markdown summaries), agent-native-reviewer (tool availability, concrete matching rules, binary staleness)
- Research chat observations on Hyperspace's Research DAG concept
- Existing agents: `agents/report-compiler.md`, `agents/parameter-scanner.md`, `agents/plan-reviewer.md`, `agents/loop-scout.md`
- Pipeline orchestration: `commands/nerd.md`

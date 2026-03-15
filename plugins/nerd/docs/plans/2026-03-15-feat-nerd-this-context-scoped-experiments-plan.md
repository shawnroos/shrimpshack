---
title: "feat: Add /nerd-this context-scoped experiment discovery"
type: feat
status: completed
date: 2026-03-15
origin: docs/brainstorms/2026-03-15-nerd-this-brainstorm.md
---

# feat: Add /nerd-this — Context-Scoped Experiment Discovery

## Overview

Add a new `/nerd-this` command that generates experiment proposals scoped to the user's current work session — not the full codebase. It infers scope from three signals (git branch diff, session file access, conversation content) or accepts an explicit topic string, groups discovered parameters into research themes, and feeds selected themes into the existing nerd pipeline.

**Key distinction from `/nerd`:** `/nerd` scans the whole codebase with an optional keyword filter. `/nerd-this` scans only session-relevant files and presents thematic groupings. They are complementary — `/nerd` for broad discovery, `/nerd-this` for "research what I'm working on right now."

(see brainstorm: docs/brainstorms/2026-03-15-nerd-this-brainstorm.md)

## Problem Statement

When working on a spike or feature branch, running `/nerd` scans the entire codebase — overwhelming the user with findings unrelated to their current work. There's no way to say "research what I'm working on right now" without manually specifying a topic and hoping the keyword filter narrows scope effectively. The user thinks in terms of themes ("agent lifecycle management"), not individual parameters ("line 92 threshold"), but `/nerd` only offers parameter-level selection.

## Proposed Solution

### New Files

1. **`commands/nerd-this.md`** — The command definition (follows existing command conventions)
2. **`agents/context-scanner.md`** — New agent that handles scope resolution + thematic parameter scanning

### No Modifications Needed

- `plugin.json` — commands are auto-discovered by convention
- `hooks/hooks.json` — session signals are captured at command time, not via hooks
- All existing agents (plan-reviewer, lab-tech, experiment-executor, report-compiler, loop-scout) — they work as-is downstream of theme selection
- `.claude/nerd.local.md` schema — themes expand into standard backlog entries with an added `source` field

### Architecture

```
User: /nerd-this [optional topic]
    ↓
Pre-flight (same as /nerd: hardware profile, auto-init)
    ↓
Phase 1: Scope Resolution (inline in command)
  • git diff main...HEAD --name-only (+ uncommitted: git diff --name-only)
  • LLM self-reports files read/edited in session
  • LLM summarizes conversation topics
  • Filter out non-source files (*.lock, dist/, vendor/, etc.)
  • If explicit topic provided: weight signals toward topic relevance
  • If all signals empty: ask user for topic (interactive) or skip (scheduled)
    ↓
Phase 2: Show scope summary, user confirms or adjusts
    ↓
Phase 3: Thematic Parameter Scan (context-scanner agent)
  • Scan only scoped files for tunable parameters
  • Cluster results into 2-6 themes by functional area
  • Return themes with parameter counts and descriptions
    ↓
Phase 4: Theme Selection (AskUserQuestion)
  • All themes selected by default
  • User deselects what's irrelevant
  • In scheduled mode: auto-select all
    ↓
Phase 5: Expand themes → individual backlog entries
  • Each parameter becomes a standard backlog entry
  • Added fields: source: "nerd-this", theme: "<theme name>"
  • Dedup by file:line against existing backlog entries
  • Merge into .claude/nerd.local.md
    ↓
Phase 6+: Hand off to existing /nerd pipeline
  • Phase 3-8 of /nerd (plan-reviewer → lab-tech → executor → reporter → loop-scout)
```

---

## Implementation Details

### Phase 1: Scope Resolution (inline in command template)

The three signals and how they're accessed:

**Signal 1: Git branch diff** — programmatic via bash
```bash
# Committed changes on this branch
git diff main...HEAD --name-only 2>/dev/null || true
# Uncommitted changes (staged + unstaged)
git diff --name-only 2>/dev/null || true
git diff --cached --name-only 2>/dev/null || true
```

**Signal 2: Session file access** — LLM self-reporting
The command prompt instructs the LLM to introspect its own conversation context and list files it has read or edited during this session. This is implicit — Claude has this context in its window. The command template includes:
```
List every file you have Read, Written, or Edited during this conversation session.
```

**Signal 3: Conversation content** — LLM self-reporting
```
Summarize the key technical topics, features, and systems discussed in this conversation.
Extract specific file paths, function names, module names, and architectural concepts mentioned.
```

**Signal filtering:**
- Exclude non-source files: `*.lock`, `*.min.*`, `dist/`, `vendor/`, `node_modules/`, `target/`, compiled assets
- Exclude test fixtures and mock data (unless they're the focus)
- If explicit topic provided: the LLM weights signals toward topic relevance when producing the final scoped file list

**Degraded signal handling:**

| Git diff | Session files | Conversation | Behavior |
|----------|--------------|--------------|----------|
| Present  | Present      | Present      | Triangulate all three |
| Present  | Empty        | Empty        | Use git diff (fresh session on feature branch) |
| Empty    | Present      | Present      | Use session + conversation (working on main) |
| Empty    | Empty        | Present      | Use conversation topics to guide scanner broadly |
| Empty    | Empty        | Empty        | Ask user for topic (interactive) or fall back to `/nerd` behavior (scheduled) |

**Scope size guard:** If scoped file list exceeds 50 files, warn user and suggest `/nerd` instead. In scheduled mode, proceed but log the warning.

### Phase 2: Scope Confirmation

Show the user what was inferred before scanning:

```
Scope inferred from your current work:

  Branch: feat/pi-agent-migration (14 files changed vs main)
  Session: 8 files read/edited
  Topics: PI agent architecture, ACP replacement, IPC model, Unix sockets

  Scoped to 18 unique source files across:
    src/agents/       (6 files)
    src/ipc/          (4 files)
    src/session/      (3 files)
    src/mcp/          (5 files)

  Proceed with scan? [Y/adjust/cancel]
```

User can type file paths or directory patterns to add/remove before proceeding. In scheduled mode, skip confirmation.

### Phase 3: Context-Scanner Agent

**New agent: `agents/context-scanner.md`**

This is a purpose-built agent (not an extension of parameter-scanner) because it has a different concern: scoped scanning + thematic grouping. The existing parameter-scanner stays unchanged for `/nerd` use.

```yaml
---
name: context-scanner
model: sonnet
color: white
tools: ["Read", "Glob", "Grep", "Bash"]
description: "Scans a scoped set of files for tunable parameters and clusters results into research themes. Used by /nerd-this for context-scoped experiment discovery."
whenToUse: |
  Use this agent to scan a specific set of files (not the whole codebase) for tunable parameters,
  then group the results into coherent research themes.
  <example>
  Context: User wants to research parameters related to their current spike
  user: "/nerd-this pi agent migration"
  assistant: "I'll use the context-scanner to find and theme-group research opportunities in the scoped files."
  </example>
---
```

**Agent responsibilities:**
1. Scan the provided file list using the same parameter detection patterns as parameter-scanner (numeric thresholds, algorithmic params, temporal params, AI/LLM params, data pipeline params)
2. Apply the same exclusion rules (mathematical constants, UI styling, protocol-defined values, test fixtures)
3. **Cluster results into 2-6 themes** by functional area. Clustering approach: LLM-driven categorization based on the parameter's role in the system, the module it belongs to, and related parameters. This is non-deterministic but matches how spikes are structured — the user thinks thematically.
4. Return structured output:

```json
{
  "themes": [
    {
      "name": "Agent lifecycle management",
      "description": "IPC socket timeouts, process spawn config, graceful shutdown sequences",
      "parameter_count": 12,
      "file_count": 6,
      "parameters": [
        {
          "id": "E042",
          "title": "IPC Socket Timeout",
          "parameter": "ipc_timeout_ms",
          "file": "src/ipc/socket.rs",
          "line": 87,
          "current_value": "5000",
          "category": "temporal",
          "impact": "high",
          "rationale": "...",
          "experiment_type": "parameter_sweep",
          "sweep_range": "1000:10000:1000"
        }
      ]
    }
  ]
}
```

**Edge cases:**
- **Zero parameters found:** Report "No tunable parameters found in scoped files. Try `/nerd` for full codebase scan or adjust scope."
- **One theme:** Skip theme selection, proceed directly with the single theme.
- **Many themes (>6):** Merge the smallest/least-impactful themes into an "Other" bucket.

### Phase 4: Theme Selection UX

Using `AskUserQuestion` (Claude Code's interaction tool, returns free text):

```
Found 4 research themes in your current work:

  1. [x] Agent lifecycle management
       IPC socket timeouts, process spawn config, graceful shutdown sequences
       12 tunable parameters across 6 files

  2. [x] Message serialization pipeline
       Codec buffer sizes, streaming chunk thresholds, backpressure limits
       8 tunable parameters across 3 files

  3. [x] MCP tool registration
       Tool discovery polling interval, capability cache TTL
       4 tunable parameters across 2 files

  4. [x] Migration compatibility layer
       ACP fallback thresholds, feature flag rollout percentages
       6 tunable parameters across 4 files

All themes selected. Deselect by number (e.g., "drop 3") or press enter to proceed:
```

User types "drop 3" to deselect theme 3, or enters to accept all. Multiple deselections: "drop 2, 3".

### Phase 5: Theme → Backlog Entry Expansion

Selected themes expand into individual backlog entries (the downstream pipeline expects this format). Each entry gets:

```yaml
- id: E042
  title: "IPC Socket Timeout"
  parameter: ipc_timeout_ms
  file: src/ipc/socket.rs
  line: 87
  current_value: "5000"
  status: proposed
  source: nerd-this          # NEW: provenance tracking
  theme: "Agent lifecycle"   # NEW: theme grouping metadata
  # ... standard fields
```

**Deduplication:** Before adding, check existing backlog entries by `file` + `line`. If a match exists, skip the duplicate (the existing entry may already be `planned` or `running`).

**Merge into `.claude/nerd.local.md`:** Append to the existing `backlog:` array. The YAML frontmatter is updated in-place.

### Phase 6+: Existing Pipeline Handoff

After backlog merge, the command continues with `/nerd` Phase 3 onward:

1. **Phase 3 (Experiment Design):** Launch plan-reviewer agents for each `proposed` entry
2. **Phase 4 (Review Gate):** User approves/selects plans
3. **Phase 4.5 (Lab Readiness):** Lab-tech validates infrastructure
4. **Phase 5 (Run Experiments):** Experiment-executor in worktrees
5. **Phase 7 (Deliver Findings):** Report-compiler writes findings
6. **Phase 8 (Loop Scout):** Identify candidates for `/nerd-loop`

This reuse is literal — the command template includes the same phase instructions as `/nerd` from Phase 3 onward.

---

## Scheduled Mode Behavior

When `NERD_SCHEDULED=1`:
- **Scope resolution degrades gracefully.** No session context is available — only git branch diff is meaningful. If on a feature branch, use the branch diff. If on main, fall back to full `/nerd` behavior (scan everything).
- **Skip all `AskUserQuestion` calls.** Scope confirmation, theme selection — all auto-accepted.
- **All themes auto-selected.** Broad research by default.
- The scheduled runner (`/nerd-schedule`) could be extended to specify a branch: `NERD_BRANCH=feat/pi-agent` to provide scope even without a session. This is a future enhancement, not part of this plan.

---

## Acceptance Criteria

### Functional Requirements

- [x] `/nerd-this` with no arguments infers scope from session context and produces themed experiment proposals
- [x] `/nerd-this <topic>` narrows scope discovery toward the specified topic
- [x] Git branch diff (committed + uncommitted) is included in scope signals
- [x] Session file access and conversation content are included as scope signals via LLM self-reporting
- [x] Non-source files are filtered from scope (lock files, dist, vendor, node_modules, target)
- [x] Scope summary is shown to user before scanning proceeds
- [x] User can adjust scope before scanning
- [x] Parameters are clustered into 2-6 research themes
- [x] Themes are presented with all selected by default
- [x] User can deselect themes by number
- [x] Selected themes expand into individual backlog entries in `.claude/nerd.local.md`
- [x] Entries include `source: nerd-this` and `theme: "<name>"` metadata
- [x] Duplicate entries (same file + line) are skipped during backlog merge
- [x] After backlog merge, the existing /nerd pipeline (Phase 3-8) executes

### Edge Cases

- [x] All three signals empty → prompts user for topic (interactive) or falls back to /nerd (scheduled)
- [x] Zero parameters found in scope → clear message, suggests /nerd or scope adjustment
- [x] Single theme found → skips theme selection, proceeds directly
- [x] Scope exceeds 50 files → warns user, suggests /nerd
- [x] On `main` branch with no diff → uses session + conversation signals only
- [x] Scheduled mode → uses git branch diff only, auto-selects all themes

### Pre-flight

- [x] Same pre-flight as /nerd (hardware profile check, auto-init project)
- [x] No new dependencies or configuration required

---

## Files to Create

### 1. `commands/nerd-this.md`

Command definition following established conventions:

```yaml
---
name: nerd-this
description: "Context-scoped experiment discovery. Researches what you're working on right now — infers scope from your session, branch, and conversation, groups findings into themes, and runs broad research. Use with no args to auto-scope, or describe your focus."
argument-hint: "[topic]"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---
```

Phases: Pre-flight → Scope Resolution → Scope Confirmation → Thematic Scan (via context-scanner agent) → Theme Selection → Backlog Expansion → Hand off to /nerd Phase 3-8.

### 2. `agents/context-scanner.md`

New agent for scoped scanning + thematic grouping:

```yaml
---
name: context-scanner
model: sonnet
color: white
tools: ["Read", "Glob", "Grep", "Bash"]
description: "Scans a scoped set of files for tunable parameters and clusters results into research themes."
---
```

Body: parameter detection patterns (reused from parameter-scanner skill reference), thematic clustering instructions, structured JSON output format.

---

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-15-nerd-this-brainstorm.md](docs/brainstorms/2026-03-15-nerd-this-brainstorm.md) — Key decisions carried forward: standalone command (not a flag), thematic grouping (not parameter-level), three-signal triangulation, all-themes-selected-by-default.

### Internal References

- Command convention: `commands/nerd.md` (frontmatter, phased structure, agent invocation syntax)
- Agent convention: `agents/parameter-scanner.md` (model, color, tools, output format)
- Backlog format: `.claude/nerd.local.md` YAML frontmatter schema
- Scope confirmation pattern: `commands/nerd-loop.md` Step 1b (file list confirmation)
- SpecFlow analysis: identified 21 gaps, all addressed in this plan (degraded signals, theme-to-entry decomposition, scheduled mode, dedup, scope size guard, multi-select UX)

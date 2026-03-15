---
title: "Parallel worktree builds recompile entire Rust dependency tree"
date: 2026-03-15
category: build-errors
tags:
  - rust
  - sccache
  - worktree
  - parallel-builds
  - cargo
  - compilation-cache
  - agent-architecture
severity: high
component: nerd-pipeline/lab-tech-agent
symptom: "11-hour overnight run caused by 4 worktrees independently recompiling the full Rust dependency tree, saturating CPU with redundant work"
root_cause: "Each git worktree maintains an isolated target/ directory; parallel experiment runs trigger full cold builds per worktree with no shared compilation artifact cache"
---

# Parallel Worktree Builds Recompile Entire Rust Dependency Tree

## Root Cause

Parallel experiment worktrees in the nerd plugin each recompile the full Rust dependency tree independently. With 4 worktrees competing for CPU, a 15-minute build ballooned to 2.5 hours each (11 hours total overnight). The core issue is redundant compilation: the same crate versions are rebuilt from source in every worktree because Cargo treats each worktree's `target/` directory as isolated.

## Solution

A shared compilation cache (sccache) across all worktrees, integrated into 8 files spanning pre-flight validation, build execution, orchestration, scheduling, reporting, and schema.

**1. Pre-flight build profiling (agents/lab-tech.md -- Check 7):** Profiles the project's build characteristics, detects sccache, selects cache strategy, starts the daemon, writes config to `nerd.local.md`.

**2. Cached build execution (agents/experiment-executor.md):** Reads `build_cache_env` from `nerd.local.md` and inline-prefixes build commands. Includes fallback: if build fails with cache, retry without and report `cache_fallback`.

**3. Orchestrator integration (commands/nerd.md):** Phase 5.0 for build infra setup, Phase 5.2 for target_copy with APFS clones, Phase 9 for sccache cleanup.

**4. Loop mode (commands/nerd-loop.md):** Step 2.5 starts sccache, prefixes in iterations, cleanup at exit.

**5. Reporting (agents/report-compiler.md):** Step 8.7 writes `cache_verdict` nodes to DAG.

**6. Schema (schemas/dag-schema.json):** Added `build_profile`, `cache_verdict`, `tool_availability` node types with I-prefixed IDs.

**7. Setup (commands/nerd-setup.md):** Detects sccache/ccache during hardware profiling.

**8. Scheduling (commands/nerd-schedule.md):** Capacity formula uses cached build times.

## Key Technical Decisions

### sccache over shared CARGO_TARGET_DIR

A shared target directory causes file lock contention when multiple Cargo processes write concurrently ("Blocking waiting for file lock on build directory"). sccache is safe for concurrent builds -- each Cargo instance writes to its own `target/` but reads compiled artifacts from the shared cache.

### Inline env var prefixing over shell exports

Claude Code's Bash tool does not persist shell state between calls. `export RUSTC_WRAPPER=sccache` in one call has no effect on subsequent calls. Inline-prefix every build command:

```bash
# Correct:
RUSTC_WRAPPER=sccache cargo build

# Wrong (export lost between Bash calls):
export RUSTC_WRAPPER=sccache
cargo build  # separate Bash call -- export is gone
```

### Cargo fingerprints are path-dependent

Copying `target/` to a different worktree path triggers fingerprint invalidation and full recompilation. The `target_copy` strategy is a best-effort fallback, not a guarantee. Real savings come from sccache.

### Gate cargo check on existing target/

Running `cargo check` on a cold cache IS a full dependency compilation. Only profile if `target/` exists:

```bash
if [ -d target ] && [ -n "$(ls -A target/ 2>/dev/null)" ]; then
    time cargo check 2>&1
fi
```

### APFS clones for file copies

On macOS, `cp -c -r target/` creates copy-on-write clones that are near-instant regardless of size. Always prefer over `cp -r`.

## Code Examples

```bash
# Inline-prefixed build (correct for Claude Code agents)
RUSTC_WRAPPER=sccache cargo build --release 2>&1

# Fallback on cache failure
RUSTC_WRAPPER=sccache cargo build 2>&1
if [ $? -ne 0 ]; then
    cargo build 2>&1  # retry without cache
fi

# APFS clone for target seeding
cp -c -r "$PROJECT_ROOT/target/" "$PROJECT_ROOT/worktrees/nerd-E001/target/"

# sccache lifecycle
sccache --start-server     # Phase 5.0
sccache --show-stats       # verify
sccache --stop-server      # Phase 9 cleanup
```

## Prevention Checklist

- [ ] sccache installed and confirmed running before parallel Rust builds
- [ ] Every cargo invocation uses inline env prefixing, never `export`
- [ ] Each worktree has its own `target/` directory -- no shared `CARGO_TARGET_DIR`
- [ ] Cold-cache detection gate before profiling builds
- [ ] `cp -c -r` (APFS clone) for macOS file copies, never plain `cp -r`
- [ ] Build strategy decisions persisted in DAG for future sessions

## Anti-Patterns to Avoid

| Anti-Pattern | Why It Fails | Correct Alternative |
|---|---|---|
| `export CARGO_TARGET_DIR=shared-target` | File lock contention, fingerprint collisions | Separate `target/` per worktree + sccache |
| `export RUSTC_WRAPPER=sccache` then separate `cargo build` | Shell state lost between Bash calls | `RUSTC_WRAPPER=sccache cargo build` inline |
| `cp -r target/` across worktrees | Fingerprints encode absolute paths; invalidated on copy | sccache for path-independent object dedup |
| `cargo check` on cold cache for profiling | Full dep compilation, not lightweight | Gate on `[ -d target/debug/deps ]` |
| Assuming build knowledge persists across sessions | Session compaction drops context | Persist as DAG nodes, load in pre-flight |

## Related

- `docs/plans/2026-03-15-feat-build-profiling-infra-dag-plan.md` -- original plan
- `docs/brainstorms/2026-03-15-research-dag-brainstorm.md` -- DAG design origin
- `agents/lab-tech.md` Check 7 -- implementation
- `schemas/dag-schema.json` -- infra node types

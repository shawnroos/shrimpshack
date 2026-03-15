---
title: "Parallel worktree builds redundantly recompile dependencies"
date: 2026-03-15
category: build-errors
tags:
  - worktree
  - parallel-builds
  - compilation-cache
  - agent-architecture
  - sccache
severity: high
component: nerd-pipeline/lab-tech-agent
symptom: "Overnight run ballooned due to worktrees independently recompiling the full dependency tree, saturating CPU with redundant work"
root_cause: "Each git worktree maintains isolated build artifacts; parallel experiment runs trigger full cold builds per worktree with no shared compilation cache"
---

# Parallel Worktree Builds Redundantly Recompile Dependencies

## Root Cause

Parallel experiment worktrees in the nerd plugin each recompile dependencies independently. With 4 worktrees competing for CPU, build times balloon dramatically. The core issue is redundant compilation: the same dependency versions are rebuilt from source in every worktree because each worktree's build output directory is isolated.

This problem is most severe in **compiled languages** (Rust, C/C++, Go with CGO). Interpreted/JIT languages (Python, TypeScript) have minimal build overhead.

## Solution

A language-aware build caching system integrated across 8 files spanning pre-flight validation, build execution, orchestration, scheduling, reporting, and schema.

**1. Pre-flight build profiling (agents/lab-tech.md -- Check 7):** Profiles the project's build characteristics, detects cache tools, selects strategy, starts daemon if needed, writes config to `nerd.local.md`.

**2. Cached build execution (agents/experiment-executor.md):** Reads `build_cache_env` from `nerd.local.md` and inline-prefixes build commands. Includes fallback: if build fails with cache, retry without and report `cache_fallback`.

**3. Orchestrator integration (commands/nerd.md):** Phase 5.0 for build infra setup, Phase 5.2 for artifact_copy with APFS clones, Phase 9 for cache cleanup.

**4. Loop mode (commands/nerd-loop.md):** Step 2.5 starts cache daemon, prefixes in iterations, cleanup at exit.

**5. Reporting (agents/report-compiler.md):** Step 8.7 writes `cache_verdict` nodes to DAG.

**6. Schema (schemas/dag-schema.json):** `build_profile`, `cache_verdict`, `tool_availability` node types with I-prefixed IDs.

**7. Setup (commands/nerd-setup.md):** Detects cache tools during hardware profiling.

**8. Scheduling (commands/nerd-schedule.md):** Capacity formula uses cached build times.

## Key Technical Decisions

### Compilation cache daemons over shared build directories

Sharing a single build output directory causes file lock contention when multiple build processes write concurrently. Cache daemons (sccache for Rust, ccache for C/C++) are safe for concurrent builds — each process writes to its own build directory but deduplicates identical compilation units through the shared cache.

### Inline env var prefixing over shell exports

Claude Code's Bash tool does not persist shell state between calls. Always inline-prefix:

```bash
# Correct:
RUSTC_WRAPPER=sccache cargo build

# Wrong (export lost between Bash calls):
export RUSTC_WRAPPER=sccache
cargo build  # separate Bash call -- export is gone
```

### Build fingerprints may be path-dependent

Some build systems (notably Cargo for Rust) encode absolute paths in build fingerprints. Copying build artifacts to a different worktree path may trigger full recompilation. The `artifact_copy` strategy is a best-effort fallback — cache daemons are more reliable.

### Gate incremental build profiling on existing artifacts

Running an incremental build command on a cold cache IS a full dependency compilation. Only profile if build artifacts already exist.

### APFS clones for file copies

On macOS, `cp -c -r` creates copy-on-write clones that are near-instant regardless of size. Always prefer over plain `cp -r`.

## Language-Specific Cache Strategies

| Language | Cache Tool | Env Prefix | Build Dir | Notes |
|----------|-----------|------------|-----------|-------|
| Rust | sccache | `RUSTC_WRAPPER=sccache` | `target/` | Path-dependent fingerprints; sccache strongly preferred |
| C/C++ | ccache | `CC="ccache gcc"` | varies | Works well with artifact_copy too |
| Go | built-in | none | `$GOPATH/pkg` | Go cache is already global; no extra setup needed |
| TypeScript | built-in | none | `node_modules/.cache` | `tsc --incremental` in tsconfig; minimal build cost |
| Python | built-in | none | `__pycache__` | No compilation step; bytecache is automatic |

## Prevention Checklist

- [ ] Cache tool installed and confirmed running before parallel compiled-language builds
- [ ] Every build invocation uses inline env prefixing, never `export`
- [ ] Each worktree has its own build output directory — no shared build dirs
- [ ] Cold-cache detection gate before profiling builds
- [ ] `cp -c -r` (APFS clone) for macOS file copies, never plain `cp -r`
- [ ] Build strategy decisions persisted in DAG for future sessions

## Anti-Patterns to Avoid

| Anti-Pattern | Why It Fails | Correct Alternative |
|---|---|---|
| Shared build output directory | File lock contention, fingerprint collisions | Separate build dir per worktree + cache daemon |
| `export ENV_VAR=...` then separate build command | Shell state lost between Bash calls | Inline prefix: `ENV_VAR=value build_cmd` |
| Copying build artifacts across worktrees blindly | Path-dependent fingerprints may invalidate | Use cache daemon for path-independent dedup |
| Profiling builds on cold cache | Full dep compilation, not incremental | Gate on existing build artifacts |
| Assuming build knowledge persists across sessions | Session compaction drops context | Persist as DAG nodes, load in pre-flight |

## Related

- `docs/plans/2026-03-15-feat-build-profiling-infra-dag-plan.md` -- original plan
- `docs/brainstorms/2026-03-15-research-dag-brainstorm.md` -- DAG design origin
- `agents/lab-tech.md` Check 7 -- implementation
- `schemas/dag-schema.json` -- infra node types

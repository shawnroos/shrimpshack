---
title: "feat: Build Profiling & Infra DAG for Experiment Worktrees"
type: feat
status: completed
date: 2026-03-15
---

# Build Profiling & Infra DAG for Experiment Worktrees

## Overview

Add build infrastructure intelligence to the nerd pipeline so experiment worktrees share compiled artifacts instead of each recompiling the full dependency tree. Persist infrastructure knowledge in a repo-scoped **infra DAG** — a namespace within the research DAG — so nerd remembers what build strategies work, what failed, and what the repo's infra characteristics are across sessions.

Two complementary pieces:
1. **Lab-tech Check 7: Build Infrastructure** — profile builds, detect cache tools, configure artifact sharing, warm caches before spawning worktrees
2. **Infra DAG** — persistent, per-repo memory about build infrastructure (cache strategies, failure history, tool availability, build profiles)

## Problem Statement

When `/nerd` launches 4 parallel worktrees for a Rust project, each independently compiles the entire dependency tree (tokio, serde, futures, etc.). With 4 worktrees competing for CPU, a solo 15-minute build becomes 2.5 hours per worktree. An 11-hour overnight run was observed where most time was spent recompiling dependencies.

The lab-tech agent does pre-flight checks but currently has no awareness of:
- Build duration or dependency tree size
- Available compilation caches (sccache, ccache)
- Opportunities to share build artifacts across worktrees
- Historical build infrastructure knowledge from previous runs

## Proposed Solution

### Part 1: Lab-Tech Check 7 — Build Infrastructure

A new pre-flight check in the lab-tech agent that runs before worktrees are created.

#### Check 7 Steps

**7a. Build Profile** — Measure or recall baseline build characteristics:
- Read infra DAG for cached build profile (skip measurement if fresh)
- If no profile or stale: time a `cargo check` / equivalent, count dependency crates, measure artifact size
- Record: `build_time_cold`, `build_time_incremental`, `dependency_count`, `artifact_size_mb`

**7b. Cache Tool Detection** — Check for available caching mechanisms:
- Rust: `which sccache`, check `RUSTC_WRAPPER` config
- Go: verify `GOCACHE` default is functional (it usually is — Go shares cache by default)
- TypeScript: check for `tsconfig.json` with `incremental: true`, `.tsbuildinfo` files
- Python: verify `pip cache dir` exists (minimal impact — note this in report)
- Record findings to infra DAG

**7c. Cache Strategy Selection** — Choose the right approach based on language and concurrency:

| Language | Parallel Worktrees | Strategy |
|----------|-------------------|----------|
| Rust | Yes | **sccache** (primary) — compilation cache daemon, safe for concurrent builds. Avoid shared `CARGO_TARGET_DIR` — Cargo's file locking causes contention with parallel builds |
| Rust | Yes, no sccache | **Sequential dependency warm** — build deps once in main worktree, then `cp -r target/` to each worktree before they diverge |
| Rust | No (loop mode) | **Incremental compilation** — single worktree, Cargo's built-in incremental is sufficient |
| Go | Any | **No action** — Go's build cache is already global at `~/.cache/go-build` |
| TypeScript | Yes | **tsc incremental** — configure `composite: true` and shared `.tsbuildinfo`. Do NOT symlink `node_modules` (branch-dependent, fragile) |
| Python | Any | **No action** — pip cache is already shared, build time is not the bottleneck |

**7d. Cache Setup & Warming** (batch mode only):
- If sccache: start daemon (`sccache --start-server`), verify it responds (`sccache --show-stats`)
- If target copy strategy: run `cargo build` in main worktree to populate `target/`
- If TypeScript: verify `tsconfig.json` has incremental settings
- Measure warm build time, compare to cold baseline

**7e. Configuration Handoff** — Write cache config to `.claude/nerd.local.md` so experiment-executors can read it:

```yaml
build_cache:
  strategy: sccache          # or: target_copy, incremental, none
  env_vars:
    RUSTC_WRAPPER: sccache
  warm_build_time_seconds: 12
  cold_build_time_seconds: 180
  estimated_savings_per_worktree: "168 seconds"
```

**7f. Report** — Using standard lab-tech status prefixes:
- `[OK] Build cache: sccache active, estimated 4x speedup for parallel builds`
- `[FIXED] sccache server started, compilation cache enabled`
- `[SETUP NEEDED] Install sccache for 4x faster parallel builds: cargo install sccache`
- `[OK] Go build cache: already shared globally, no action needed`
- `[OK] Python: pip cache shared by default, build time is not the bottleneck`

#### Check 7 Mode Applicability

- **Batch mode** (`/nerd`): Full Check 7 (7a-7f). Highest value — multiple worktrees competing.
- **Loop mode** (`/nerd-loop`): Steps 7a-7c and 7f only. Single worktree, but hundreds of iterations benefit from sccache for incremental recompilation. Skip cache warming (7d) and config handoff (7e) — loop runs in-place.

#### Fallback Strategy

If cache configuration causes build failures (detected by experiment-executor):
1. Experiment-executor sees 2 consecutive build failures with cache env vars set
2. Unsets cache env vars, retries build
3. If build succeeds without cache: logs `CACHE_FALLBACK` event
4. Reports cache failure in results JSON
5. Lab-tech records failure in infra DAG so future runs skip that strategy

### Part 2: Infra DAG — Persistent Build Infrastructure Memory

A **namespace within the research DAG** (see [research-dag brainstorm](../brainstorms/2026-03-15-research-dag-brainstorm.md)) that persists infrastructure knowledge per-repo.

#### Why a DAG and Not Just Config

`.claude/nerd.local.md` stores current settings. The infra DAG stores **history and learned knowledge**:
- "sccache caused lock contention on 2026-03-10 with 4 parallel worktrees on this repo"
- "target copy strategy worked reliably for 3 consecutive runs"
- "build time increased 40% after adding the `aws-sdk` dependency on 2026-03-12"
- "this repo's dependency tree is 342 crates, cold build takes 180s on M1 Pro"

This is exactly the kind of knowledge that gets lost between sessions and forces rediscovery.

#### Schema

Lives alongside the research DAG at `~/.claude/plugins/nerd/dag/projects/{project-slug}.json`, in an `infra` namespace:

```json
{
  "research": { "nodes": [...], "edges": [...] },
  "infra": {
    "nodes": [
      {
        "id": "I001",
        "type": "build_profile",
        "project": "arras",
        "title": "Build profile: 342 crates, 180s cold, 12s incremental",
        "data": {
          "language": "rust",
          "dependency_count": 342,
          "build_time_cold_seconds": 180,
          "build_time_incremental_seconds": 12,
          "artifact_size_mb": 2400,
          "measured_at": "2026-03-15T10:00:00Z"
        },
        "source_files": ["Cargo.toml", "Cargo.lock"],
        "codebase_hash": "b4e2a1",
        "status": "active"
      },
      {
        "id": "I002",
        "type": "cache_verdict",
        "project": "arras",
        "title": "sccache: reliable for parallel builds",
        "strategy": "sccache",
        "result": "SUCCESS",
        "evidence": "3 consecutive batch runs with 4 worktrees, no build failures, 4x speedup observed",
        "runs_tested": 3,
        "created_at": "2026-03-15T10:30:00Z",
        "status": "active"
      },
      {
        "id": "I003",
        "type": "cache_verdict",
        "project": "arras",
        "title": "shared CARGO_TARGET_DIR: lock contention with >2 worktrees",
        "strategy": "shared_target_dir",
        "result": "FAILED",
        "evidence": "Builds failed with 'Blocking waiting for file lock on build directory' when 4 worktrees compiled simultaneously",
        "failure_count": 2,
        "created_at": "2026-03-14T22:00:00Z",
        "status": "active"
      },
      {
        "id": "I004",
        "type": "tool_availability",
        "project": null,
        "title": "sccache 0.8.1 available",
        "data": {
          "tool": "sccache",
          "version": "0.8.1",
          "path": "/usr/local/bin/sccache",
          "detected_at": "2026-03-15T09:00:00Z"
        },
        "status": "active"
      }
    ],
    "edges": [
      {
        "from": "I003",
        "to": "I002",
        "type": "spawned",
        "reason": "After shared target dir failed, switched to sccache strategy"
      }
    ]
  }
}
```

#### Node Types

| Type | Purpose | Scope |
|------|---------|-------|
| `build_profile` | Dependency count, build times, artifact sizes | Per-project |
| `cache_verdict` | Success/failure record for a cache strategy | Per-project |
| `tool_availability` | What cache tools are installed on this machine | Global (project: null) |
| `infra_synthesis` | Cross-project patterns (e.g., "sccache reliable on all Rust projects") | Global |

#### Staleness

Uses the same protocol as the research DAG:
- `build_profile` nodes: hash `Cargo.toml` + `Cargo.lock` (or equivalent). If dependencies changed >10%, mark stale and re-measure.
- `cache_verdict` nodes: persist until a contradicting result occurs (e.g., a SUCCESS strategy starts failing).
- `tool_availability` nodes: re-check when `nerd-setup` runs or when lab-tech detects version mismatch.

#### Agent Integration

**Lab-tech (Check 7):**
- **Reads** infra DAG before profiling — skips measurement if `build_profile` is fresh
- **Reads** `cache_verdict` nodes to pick best strategy — prefers strategies with `SUCCESS` verdicts, avoids `FAILED` strategies
- **Writes** new `cache_verdict` after each batch run completes (via report from experiment-executor results)

**Experiment-executor:**
- **Reads** `build_cache` config from `nerd.local.md` (written by lab-tech)
- Sets env vars via `export` before running builds
- **Reports** cache fallback events in results JSON if cache fails mid-experiment

**Report-compiler:**
- **Writes** `cache_verdict` nodes to infra DAG based on experiment results
- If all experiments in a batch built successfully with cache: writes SUCCESS verdict
- If any experiment had CACHE_FALLBACK: writes FAILED verdict with evidence

**nerd-schedule:**
- **Reads** `build_profile` from infra DAG to improve capacity estimates
- Uses `build_time_cold_seconds` vs `warm_build_time_seconds` based on whether cache is expected to be available
- Formula becomes: `experiments_per_hour = 60 / (warm_build_time + test_time + overhead)` when cache is active

**Parameter-scanner (no changes):** Infra DAG is a separate namespace — parameter-scanner only reads research nodes.

### Part 3: Orchestrator Changes (nerd.md)

#### Phase 5.0 (New): Build Infrastructure Setup

Inserted before current Phase 5.1 (eval scaffold):

1. Lab-tech runs Check 7 (part of existing Phase 4.5 lab-tech invocation)
2. Read `build_cache` config from `nerd.local.md` (written by Check 7)
3. If strategy is `sccache`: verify server is running
4. If strategy is `target_copy`: copy `target/` to a staging area for worktree seeding
5. Log estimated time savings for the batch

#### Phase 5.2 (Modified): Worktree Creation

When creating worktrees, include cache setup in the worktree init:

```
For each worktree:
  git worktree add worktrees/nerd-{id} --detach HEAD
  cd worktrees/nerd-{id} && git checkout -b nerd/{id}

  # If target_copy strategy:
  cp -r ${staging_target}/ worktrees/nerd-{id}/target/

  # Cache env vars are consumed by experiment-executor
  # reading nerd.local.md, not set here
```

#### Phase 5.2 (Modified): Agent Prompt

Add to the experiment-executor Agent() prompt:

```
Before building, read .claude/nerd.local.md for build_cache configuration.
If build_cache.env_vars exists, run `export KEY=VALUE` for each entry
before any cargo/build commands.
```

### Part 4: nerd-setup Changes

Add to the calibration step:

1. Detect cache tools: `which sccache`, `which ccache`
2. Record in hardware profile:

```yaml
cache_tools:
  sccache: "/usr/local/bin/sccache"  # or null
  ccache: null
```

3. If sccache found: include in calibration — time a build with sccache vs without

## Acceptance Criteria

- [x] Lab-tech Check 7 runs in batch mode and detects build characteristics
- [x] Lab-tech Check 7 selects appropriate cache strategy per language
- [x] Lab-tech Check 7 runs relevant steps (7a-7c, 7f) in loop mode
- [x] sccache daemon lifecycle managed: start in Check 7, health-checked, cleaned up after batch
- [x] Cache configuration written to `nerd.local.md` and consumed by experiment-executor
- [x] Experiment-executor sets cache env vars before build commands
- [x] Fallback: experiment-executor unsets cache env vars after build failures
- [x] Infra node types added to flat DAG schema (build_profile, cache_verdict, tool_availability)
- [x] `build_profile` nodes created/updated by lab-tech
- [x] `cache_verdict` nodes written by report-compiler based on experiment outcomes
- [x] Stale `build_profile` detection when `Cargo.toml`/`Cargo.lock` change
- [x] Lab-tech reads infra DAG to prefer proven strategies and avoid failed ones
- [x] nerd-schedule capacity calculation uses cached build times when available
- [x] nerd-setup detects sccache/ccache availability
- [x] Go and Python handled correctly (no-op with explanatory report)
- [x] TypeScript handled via tsc incremental, not node_modules symlinks

## Scope Boundaries — Explicitly Excluded

- **Shared `CARGO_TARGET_DIR` for parallel builds** — Cargo's file locking makes this unsafe with >1 concurrent build. Use sccache instead.
- **Node `node_modules` symlinking across worktrees** — Branch-dependent, fragile. Each worktree runs its own `npm install`.
- **cargo-nextest integration** — Future enhancement, out of scope.
- **Cross-project infra transfer** — The infra DAG is per-project for now. Cross-project synthesis (e.g., "sccache works on all Rust projects") is a future extension aligned with the research DAG's cross-project transfer goal.
- **Auto-installing sccache** — Lab-tech reports `[SETUP NEEDED]` with install instructions but does not install tools. User's machine, user's choice.
- **Disk space management for shared caches** — Check 7 reports artifact sizes but does not implement cache eviction. Existing Check 5 disk space check provides basic protection.

## Implementation Sequence

### Phase 1: Infra DAG Schema + Lab-Tech Check 7 (Core)

1. Define infra DAG node schemas in `schemas/`
2. Add Check 7 to `agents/lab-tech.md` (batch and loop mode)
3. Add `build_cache` section to `nerd.local.md` configuration spec
4. Add `cache_tools` to `nerd-setup.md` calibration

### Phase 2: Orchestrator + Executor Integration

5. Add Phase 5.0 to `commands/nerd.md`
6. Modify experiment-executor prompt to consume cache config
7. Add fallback detection to experiment-executor error handling
8. Modify nerd-schedule capacity formula

### Phase 3: Persistence + Learning

9. Extend report-compiler to write `cache_verdict` nodes
10. Extend lab-tech to read infra DAG for strategy selection
11. Add staleness detection for `build_profile` nodes
12. Add infra DAG writing to lab-tech post-batch

## System-Wide Impact

### Interaction Graph

Lab-tech Check 7 → writes `nerd.local.md` → experiment-executor reads config → sets env vars → cargo/build uses cache → results JSON includes cache status → report-compiler writes infra DAG → next lab-tech Check 7 reads infra DAG.

sccache lifecycle: lab-tech starts server → all experiment-executors use it → last experiment completes → nerd.md Phase 7 cleanup stops server.

### Error Propagation

- sccache server crash → experiment-executor build fails → fallback unsets `RUSTC_WRAPPER` → build succeeds without cache → CACHE_FALLBACK logged → report-compiler writes FAILED verdict → future runs avoid sccache (until manually reset)
- Stale build profile → lab-tech re-measures → updated profile replaces stale node
- Disk exhaustion → existing Check 5 catches before worktree creation. Shared cache size is additive info in Check 7 report.

### State Lifecycle Risks

- sccache server process could orphan if nerd.md crashes before Phase 7 cleanup. Mitigation: `sccache --stop-server` in a trap or in nerd-schedule's cleanup script.
- Infra DAG writes happen in report-compiler (end of pipeline). If pipeline crashes before reporting, verdict is not recorded. This is acceptable — the strategy will be re-evaluated next run.

## Sources & References

### Internal References

- Lab-tech agent: `agents/lab-tech.md` — Check 5 (Worktree Readiness) is the insertion neighbor
- Nerd orchestrator: `commands/nerd.md` — Phase 5.1-5.2 worktree creation
- Experiment executor: `agents/experiment-executor.md` — Step 2 language detection, error handling
- Nerd setup: `commands/nerd-setup.md` — hardware profile calibration
- Nerd schedule: `commands/nerd-schedule.md` — capacity formula at line 39-42
- Research DAG brainstorm: `docs/brainstorms/2026-03-15-research-dag-brainstorm.md` — DAG schema, staleness protocol, agent integration pattern

### Key Design Decisions

1. **sccache over shared CARGO_TARGET_DIR** — Cargo's file locking makes shared target dirs unsafe for parallel builds. sccache is a compilation cache that works safely with concurrent builds.
2. **Infra nodes in flat DAG array** — Uses the same `nodes` array as research nodes, distinguished by `type` field (build_profile, cache_verdict, tool_availability) and `I`-prefixed IDs. No namespaced schema — avoids breaking the existing DAG format. Review-driven change from original namespace proposal.
3. **Config handoff via nerd.local.md with flat keys** — Agent() subagents don't inherit shell env vars. Writing flat config keys (`build_cache_strategy`, `build_cache_env`) to nerd.local.md, read by experiment-executors who prefix build commands inline (e.g., `RUSTC_WRAPPER=sccache cargo build`). Review-driven change: inline env vars, not `export`, because shell state doesn't persist between Bash tool calls.
4. **Rust-first scope** — The problem is most acute for Rust (long compile times, large dependency trees). Go and Python are effectively no-ops. TypeScript gets incremental compilation only.
5. **No auto-install of tools** — `[SETUP NEEDED]` with instructions, not silent installation. Respects user's machine autonomy.
6. **Fallback on first cache failure** — If build fails with cache env vars, retry once without them. If the retry succeeds, it's a cache problem — report CACHE_FALLBACK. Review-driven simplification from original "2 consecutive failures" protocol — LLM agents don't reliably maintain failure counters across tool calls.

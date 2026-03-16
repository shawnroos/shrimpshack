---
name: performance-analysis
description: "Reference card for performance research — anti-pattern catalog, profiling tool reference, metric command templates, and measurability gate criteria. Use when writing performance experiment plans or analyzing performance findings."
---

# Performance Analysis Reference

## Principle: Measure Before Optimizing

Every performance finding MUST be measurable. No "this looks slow" — there must be a metric command that produces a number, a direction (lower/higher is better), and a baseline estimate. If you can't measure it, you can't research it.

## Performance Anti-Pattern Catalog

### Algorithmic Complexity

| Anti-Pattern | Example | Fix |
|---|---|---|
| Nested linear search | `for x in items { for y in items { if x == y } }` | Use a HashSet for O(1) lookup |
| Sort-then-search | Sort entire collection to find min/max | Use `min()`/`max()` in one pass |
| Repeated filtering | Multiple `.filter()` calls on same collection | Combine predicates in one pass |
| Quadratic string building | `result += str` in a loop | Use StringBuilder/join/push_str |
| Full sort for top-N | Sort entire array to take first 3 | Use partial sort or min-heap |

### I/O Patterns

| Anti-Pattern | Example | Fix |
|---|---|---|
| N+1 queries | `for user in users { db.get_profile(user.id) }` | `db.get_profiles(user_ids)` |
| Serial await | `for url in urls { await fetch(url) }` | `Promise.all(urls.map(fetch))` |
| Sync I/O on hot path | `fs.readFileSync()` in request handler | `fs.readFile()` or cache at init |
| Read-after-write | `db.insert(x); return db.get(x.id)` | Return inserted data directly |
| Missing connection pool | `new Client()` per request | Shared client with connection pool |

### Memory Patterns

| Anti-Pattern | Example | Fix |
|---|---|---|
| Clone in hot loop | `for item in items { process(item.clone()) }` | Use references/borrows |
| Unbounded buffer | `let mut buf = Vec::new(); loop { buf.push(...) }` | Set capacity limit or use streaming |
| Unnecessary intermediate | `.collect().iter().map()` | Chain iterators without collecting |
| Large stack allocation | `let buf: [u8; 1_000_000]` on stack | Use heap allocation (`Vec`) |
| Leaked closures | Event listener captures large context | Capture only needed fields |

### Caching Opportunities

| Anti-Pattern | Example | Fix |
|---|---|---|
| Repeated regex compile | `new RegExp(pattern)` in loop | Compile once at module level |
| Redundant derivation | Recompute same hash every access | Cache derived value, invalidate on change |
| Cold-start spike | Lazy init on first request | Warm caches/pools at startup |
| No memoization | Pure function called 100x with same args | `@cache` / `memoize()` wrapper |
| Over-invalidation | Clear entire cache on any write | Invalidate specific entry only |

### Network Patterns

| Anti-Pattern | Example | Fix |
|---|---|---|
| Chatty API | One POST per entity in loop | Batch endpoint with array body |
| No connection reuse | New HTTP client per request | Shared client with keep-alive |
| Retry storm | Retry immediately, no backoff | Exponential backoff + jitter + circuit breaker |
| Over-fetching | GET full object, use 2 fields | GraphQL, sparse fieldsets, or dedicated endpoint |
| No compression | Large JSON payloads uncompressed | Enable gzip/brotli, use ETags |

## Profiling Tool Reference

### By Language and Category

| Category | Rust | Python | TypeScript/Node | Go |
|----------|------|--------|-----------------|-----|
| Benchmark | `criterion`, `hyperfine` | `pytest-benchmark`, `timeit` | project bench suite, `hyperfine` | `go test -bench` |
| CPU Profile | `cargo flamegraph`, `perf` | `py-spy`, `scalene` | `clinic.js`, `0x` | `pprof` |
| Memory | `heaptrack` (Linux), `leaks` (macOS) | `tracemalloc`, `memory_profiler` | `--inspect`, `clinic heapprofile` | `pprof` (heap) |
| I/O | `strace`/`dtrace` | `py-spy` | `clinic doctor` | `trace` |
| Network | `curl`, `wrk`, `k6` | `locust` | `autocannon` | `vegeta` |

### Cross-Language Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `hyperfine` | CLI benchmark runner | `brew install hyperfine` / `cargo install hyperfine` |
| `wrk` | HTTP benchmark | `brew install wrk` |
| `k6` | Load testing | `brew install k6` |
| `jq` | JSON metric extraction | `brew install jq` |

## Metric Command Templates

### Latency / Throughput

```bash
# CLI benchmark
hyperfine --runs 20 '{command}'

# HTTP endpoint
wrk -t2 -c10 -d10s http://localhost:{port}/{path}

# Single request timing
curl -o /dev/null -s -w '%{time_total}\n' http://localhost:{port}/{path}
```

### Memory

```bash
# Peak RSS (macOS)
/usr/bin/time -l {command} 2>&1 | grep 'maximum resident'

# Peak RSS (Linux)
/usr/bin/time -v {command} 2>&1 | grep 'Maximum resident'

# Rust heap profiling
DHAT_LOG=1 cargo run --release -- {args}
```

### I/O / Query Count

```bash
# Count SQL queries (Node)
NODE_DEBUG=sql {command} 2>&1 | grep -c 'SELECT\|INSERT\|UPDATE\|DELETE'

# Count HTTP requests
NODE_DEBUG=http {command} 2>&1 | grep -c 'HTTP/'

# Count syscalls (Linux)
strace -c {command} 2>&1
```

### Build / Compile Time

```bash
# Timed build
hyperfine --runs 3 '{build_command}'

# Incremental build
hyperfine --runs 5 --prepare 'touch {file}' '{build_command}'
```

## Measurability Gate

Every performance finding MUST pass this gate:

| Field | Required | Description |
|-------|----------|-------------|
| `metric` | Yes | What is being measured (e.g., `latency_ms`, `query_count`, `peak_rss_kb`) |
| `metric_command` | Yes | Exact shell command that produces the measurement |
| `metric_direction` | Yes | `lower_is_better` or `higher_is_better` |
| `baseline_estimate` | Yes | Rough estimate before formal measurement |
| `measurability` | Yes | `experimentable` (can run automated) or `analytical` (code review only) |

**For `analytical` findings:** Set `metric_command` to `"manual_review"` and `baseline_estimate` to a qualitative description (e.g., "potential connection leak under high concurrency"). Analytical findings skip the experiment pipeline — they appear in the report as recommendations for manual investigation, not as automated experiments.

**For `experimentable` findings:** All five fields must have concrete, runnable values. Findings without all five fields are **rejected** — they cannot enter the experiment pipeline.

## Before/After Metrics Format

Results JSON from experiments MUST include structured metrics:

```json
{
  "metrics": {
    "before": {
      "value": 245.3,
      "unit": "ms",
      "samples": 20,
      "stddev": 12.1
    },
    "after": {
      "value": 18.7,
      "unit": "ms",
      "samples": 20,
      "stddev": 2.3
    },
    "improvement_pct": 92.4,
    "direction": "lower_is_better"
  }
}
```

This is structured data, not prose in reports. The report-compiler uses these numbers directly.

## Performance Finding Schema

All specialist agents output findings in this schema:

```json
{
  "id": "E001",
  "title": "Human-readable description",
  "research_type": "performance",
  "category": "algorithmic_complexity|io_patterns|memory_patterns|caching_opportunities|network_patterns",
  "file": "src/path/to/file.ext",
  "function": "functionName",
  "line": 42,
  "current_behavior": "What the code does now",
  "proposed_improvement": "What it should do instead",
  "impact": "high|medium|low",
  "measurability": "experimentable|analytical",
  "metric": "metric_name",
  "metric_command": "shell command to measure",
  "metric_direction": "lower_is_better|higher_is_better",
  "experiment_type": "algo_benchmark|io_benchmark|memory_benchmark|cache_benchmark|network_benchmark",
  "area_id": "A001",
  "rationale": "Why this matters with rough numbers",
  "baseline_estimate": "Rough estimate before measurement",
  "dedup_key": "file:function:metric_type"
}
```

**Key differences from parameter findings:**
- `current_behavior`/`proposed_improvement` instead of `current_value`/`sweep_range`
- `function` field for stable dedup (functions are more stable than line numbers)
- `dedup_key`: `file+function+metric_type` not `file+line`
- `metric` + `metric_command` + `metric_direction` are mandatory

---
name: intern-training
description: "Reference for intern training data formats, benchmark structure, and evaluation protocol. Use when running aptitude tests, collecting training data, or evaluating intern performance."
---

# Intern Training Reference

## Benchmark Seed Data

Located at `${CLAUDE_PLUGIN_ROOT}/skills/intern-training/benchmark-seed/`.

### Structure

```
benchmark-seed/
├── manifest.json                    # Version, counts, language coverage
├── parameter-detection/             # 5 examples
│   ├── pd-001-rust-search.json
│   ├── pd-002-python-retry.json
│   ├── pd-003-ts-cache.json         # Includes false positives (PI, HTTP_OK)
│   ├── pd-004-go-ratelimit.json
│   └── pd-005-python-ml.json        # Includes RANDOM_SEED (not tunable)
├── result-classification/           # 5 examples
│   ├── rc-001-clear-improvement.json
│   ├── rc-002-clear-regression.json
│   ├── rc-003-neutral.json
│   ├── rc-004-mixed-signals.json    # Hard: throughput up but latency/memory up
│   └── rc-005-subtle-regression.json # Medium: overfitting pattern
└── context-extraction/              # 4 examples
    ├── ce-001-auth-middleware.json
    ├── ce-002-cache-eviction.json
    ├── ce-003-rate-limiter.json
    └── ce-004-retry-backoff.json
```

### Example Format

Each benchmark example is a JSON file with:
- `id`: Unique identifier (e.g., "pd-001-rust-search")
- `language`: Programming language (for parameter-detection and context-extraction)
- `difficulty`: easy, medium, or hard
- `context_tokens`: Approximate token count of input
- `input`: The input to send to the intern
- `expected_output`: The ground truth output to score against
- `notes`: Optional notes about tricky aspects (false positives to avoid, etc.)

## Training Data Format (JSONL)

Stored at `.nerd/intern/training-data/{task_type}.jsonl`.

Each line is a JSON object:
```json
{
  "task_type": "result-classification",
  "input": {"experiment_id": "E001", "results": {}},
  "output": {"classification": "improved", "evidence": "..."},
  "reasoning": "Claude's chain-of-thought explanation",
  "source_agent": "report-compiler",
  "created_at": "2026-03-15T10:30:00Z",
  "run_id": "run-2026-03-15-001",
  "dedup_key": "E001:result-classification"
}
```

The `reasoning` field captures Claude's chain-of-thought for knowledge distillation in v2.

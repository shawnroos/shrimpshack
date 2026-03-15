---
name: intern-delegation
description: "Canonical delegation protocol for the nerd intern. Reference this when delegating tasks to the local LLM in /nerd or /nerd-this orchestrators. Defines health checks, timeouts, confidence gating, shadow comparison, fallback, and logging."
---

# Intern Delegation Protocol

The orchestrator (not individual agents) handles all intern delegation. Agents stay as clean primitives — they do their job. The orchestrator wraps agent calls with an intern-first-or-shadow layer.

## Pre-Run Health Check (Phase 0)

Run once at the start of every `/nerd` or `/nerd-this` run when `intern.enabled: true`.

```bash
# Health check: GET /v1/models with 5-second timeout
INTERN_ENDPOINT=$(cat .claude/nerd.local.md | grep 'endpoint:' | head -1 | awk '{print $2}')
INTERN_MODEL=$(cat .claude/nerd.local.md | grep 'model:' | head -1 | awk '{print $2}')
BASE_URL="${INTERN_ENDPOINT%/chat/completions}"

HEALTH=$(curl -s -m 5 "${BASE_URL}/models" 2>/dev/null)
```

**Pass criteria:**
1. HTTP response received within 5 seconds
2. Response is valid JSON with a `data` array
3. At least one model in the array
4. Model name in response matches `intern.model` in config

**If health check fails:** Disable all delegation for this run. Log: `"intern_health_check": "failed"` to delegation log. Continue run normally (Claude handles everything).

## Delegation Decision (Per Task)

For each delegatable task during the run, the orchestrator checks intern state from `.nerd/intern/state.json`:

```
Read task mode from state.json → intern.tasks.{task_type}.mode

If mode == "live":
  → Call intern, validate, gate on confidence
  → If passes: use result, skip Claude for this task
  → If fails: call Claude, pass intern's failed attempt as context

If mode == "shadow":
  → Call intern (non-blocking if possible)
  → Call Claude (always, result is authoritative)
  → Compare outputs, log agreement
  → Use Claude's result

If mode == "disabled":
  → Skip intern, call Claude normally
```

## Calling the Intern

```bash
RESPONSE=$(curl -s -m 30 --connect-timeout 3 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${NERD_INTERN_API_KEY:-EMPTY}" \
  -d '{
    "model": "{intern.model}",
    "messages": [
      {"role": "system", "content": "{task-specific system prompt}"},
      {"role": "user", "content": "{task input as JSON}"}
    ],
    "temperature": 0,
    "max_tokens": {task-specific limit}
  }' \
  "{intern.endpoint}")
```

**Max tokens by task:**
| Task | max_tokens | temperature |
|------|-----------|-------------|
| parameter-detection | 2048 | 0 |
| result-classification | 512 | 0 |
| context-extraction | 1024 | 0 |

## Timeouts

| Layer | Timeout | Purpose |
|-------|---------|---------|
| Connection | 3 seconds | Detect endpoint down fast |
| Total request | 30 seconds | Prevent runaway generation |

The `--connect-timeout 3` and `-m 30` curl flags handle both. If the intern is slow, it will hit the 30s timeout and count toward the failure budget.

## Output Validation

Before using any intern output:

1. **Parse JSON** — malformed response = confidence 0, fallback
2. **Validate schema** — required fields must be present per task type:
   - parameter-detection: `parameters` array with `name`, `file`, `line`, `value` per entry
   - result-classification: `classification` (one of improved/regressed/neutral), `evidence` string
   - context-extraction: `summary` string (10-500 chars)
3. **Check confidence** — response must include `confidence` field (0.0-1.0)
4. **Gate on threshold** — if `confidence < intern.confidence_threshold` (default 0.8), fallback

**Any validation failure = confidence 0 = automatic fallback to Claude.**

## Shadow Comparison

When a task is in `shadow` mode, both the intern and Claude produce output. Compare them:

| Task | Agreement Metric | Agreement Threshold |
|------|-----------------|---------------------|
| parameter-detection | F1 score of detected parameters | F1 >= 0.8 |
| result-classification | Exact match of classification | Exact match |
| context-extraction | Jaccard similarity of key terms | Jaccard >= 0.7 |

**Rolling window:** Track last 25 shadow comparisons per task. Promotion requires 20/25 agreements (not consecutive — tolerates Claude's non-determinism).

**Demotion:** If accuracy drops below the mode's threshold for 3 consecutive evals, demote one level.

## Fallback with Context

When the intern fails and Claude takes over, pass the intern's attempt as additional context:

```
"The intern attempted this task and produced: {intern_output}
It failed validation because: {failure_reason}
Please handle this task from scratch, but the intern's attempt may contain useful partial work."
```

This creates higher-quality training data (Claude correcting specific intern errors) and may improve Claude's response.

## Failure Budget

Track failures per run. If the intern fails back to Claude more than 3 times in a single run, disable delegation for the remainder of that run. This prevents cascading latency from a misbehaving model.

Persistent failure is handled by the shadow window's demotion criteria — if accuracy drops below threshold, the task demotes automatically. No separate circuit breaker needed.

## Delegation Logging

Append to `.nerd/intern/delegation-log.jsonl` after each delegation attempt:

```json
{
  "run_id": "run-2026-03-15-001",
  "task_type": "parameter-detection",
  "mode": "live",
  "intern_called": true,
  "intern_latency_ms": 2340,
  "intern_confidence": 0.85,
  "validation_passed": true,
  "result_used": "intern",
  "agreement": null,
  "timestamp": "2026-03-15T10:30:00Z"
}
```

For shadow mode, `result_used` is always `"claude"` and `agreement` is `true/false`.

## Post-Run State Update (Phase 7.6 equivalent)

After all phases complete, the orchestrator reads the delegation log for this run and updates `.nerd/intern/state.json` atomically:

1. For each shadow task: update the rolling window (append agreement/disagreement, trim to last 25)
2. Check promotion criteria: if 20/25 agreements, promote to live
3. Check demotion criteria: track consecutive low-accuracy runs
4. Check circuit breaker: if 5 consecutive live failures, demote to shadow
5. Write updated state.json (single atomic write)

## Config vs State Split

**User preferences** in `nerd.local.md` (human-editable):
```yaml
intern:
  enabled: true
  model: qwen3.5-4b-q4
  endpoint: http://localhost:11434/v1/chat/completions
  confidence_threshold: 0.8
  delegation_timeout_seconds: 30
  collect_training_data: true
```

**Runtime state** in `.nerd/intern/state.json` (machine-managed):
```json
{
  "tasks": {
    "parameter-detection": {
      "mode": "shadow",
      "accuracy": 0.76,
      "shadow_window": [true, true, false, true, true],
      "promoted_at": null
    }
  },
  "last_run": {
    "delegated": 3,
    "fallbacks": 1,
    "total_intern_time_ms": 7200
  },
  "lifetime_claude_calls_saved": 0
}
```

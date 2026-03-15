---
name: intern-delegation
description: "Canonical delegation protocol for the nerd intern. Reference this when delegating tasks to the local LLM in /nerd or /nerd-this orchestrators. Defines health checks, timeouts, confidence gating, shadow comparison, fallback, and logging."
---

# Intern Delegation Protocol

The orchestrator (not individual agents) handles all intern delegation. Agents stay as clean primitives — they do their job. The orchestrator wraps agent calls with an intern-first-or-shadow layer.

## Pre-Run Health Check (Phase 0)

Run once at the start of every `/nerd` or `/nerd-this` run when `intern.enabled: true`.

```bash
INTERN_PROVIDER=$(grep -A10 'intern:' .claude/nerd.local.md 2>/dev/null | grep 'provider:' | head -1 | awk '{print $2}')
INTERN_MODEL=$(grep -A10 'intern:' .claude/nerd.local.md 2>/dev/null | grep 'model:' | head -1 | awk '{print $2}')

if [ "$INTERN_PROVIDER" = "ollama" ] || [ -z "$INTERN_PROVIDER" ]; then
  # Ollama: use native /api/tags endpoint
  HEALTH=$(curl -s -m 5 "http://localhost:11434/api/tags" 2>/dev/null)
else
  # Other providers: use OpenAI-compatible endpoint
  INTERN_ENDPOINT=$(grep -A10 'intern:' .claude/nerd.local.md 2>/dev/null | grep 'endpoint:' | head -1 | awk '{print $2}')
  HEALTH=$(curl -s -m 5 "${INTERN_ENDPOINT%/chat/completions}/models" 2>/dev/null)
fi
```

**Pass criteria:**
1. HTTP response received within 5 seconds
2. Response is valid JSON
3. The configured model is available (for Ollama: appears in `/api/tags` model list)
4. For Ollama: model name match is substring-based (e.g., `qwen3:4b` matches `qwen3:4b`)

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

**Provider-aware calling.** Different providers have different APIs. The protocol adapts based on the `provider` field in config.

### Ollama (default for most users)

Use Ollama's **native API** (`/api/chat`), NOT the OpenAI-compatible endpoint. Required because:
- Qwen3 and other thinking models use reasoning tokens that consume the entire token budget via the OpenAI endpoint
- The native API supports `"think": false` to disable the reasoning field (though models may still reason in content — see Response Parsing below)

```bash
RESPONSE=$(curl -s -m 180 --connect-timeout 5 \
  -H "Content-Type: application/json" \
  -d '{
    "model": "{intern.model}",
    "messages": [
      {"role": "system", "content": "{task-specific system prompt}"},
      {"role": "user", "content": "{task input}"}
    ],
    "stream": false,
    "think": false,
    "options": {"temperature": 0, "num_predict": 4096}
  }' \
  "http://localhost:11434/api/chat")

# Parse: extract content from native response
CONTENT=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['message']['content'])")
```

### Other providers (MLX-LM, llama.cpp, vLLM)

Use the OpenAI-compatible endpoint:

```bash
RESPONSE=$(curl -s -m 180 --connect-timeout 5 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${NERD_INTERN_API_KEY:-EMPTY}" \
  -d '{
    "model": "{intern.model}",
    "messages": [...],
    "temperature": 0,
    "max_tokens": 4096
  }' \
  "{intern.endpoint}/v1/chat/completions")
```

### Response Parsing (Critical — learned from testing)

**Small models cannot reliably return pure JSON.** Even with `think: false` and explicit "return ONLY JSON" instructions, models like Qwen3 produce reasoning text with JSON embedded. The delegation protocol MUST:

1. **Strip `<think>` tags:** `re.sub(r'<think>.*?</think>', '', content, flags=re.DOTALL)`
2. **Extract JSON from reasoning text:** Try parsing the full content as JSON first. If that fails, search for JSON objects containing the expected key (e.g., `"parameters"`, `"classification"`, `"summary"`) using regex.
3. **Fallback extraction:** For parameter-detection, if no JSON found, search for parameter names mentioned in the raw text.

```python
import re, json

def extract_json(text, expected_key):
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()
    try: return json.loads(text)
    except: pass
    # Find outermost JSON object
    start = text.find('{')
    if start >= 0:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == '{': depth += 1
            elif text[i] == '}': depth -= 1
            if depth == 0:
                try: return json.loads(text[start:i+1])
                except: break
    return None
```

### Timeouts

| Layer | Timeout | Purpose |
|-------|---------|---------|
| Connection | 5 seconds | Detect endpoint down (allow model loading) |
| Total request | 180 seconds | Allow cold model loading + thinking + generation |

**Why 180s, not 30s:** Testing showed 60-180s per call on a 4B model on M1 Pro. First calls are slowest (model loading). The failure budget (3 per run) prevents cascading delays even with generous timeouts.

### Latency expectations by hardware

| Hardware | 4B model | 1B model |
|----------|---------|---------|
| M1 Pro 16GB | 60-180s | 20-60s |
| M2/M3/M4 32GB+ | 20-60s | 10-30s |
| CUDA 16GB+ | 10-30s | 5-15s |

Shadow mode (background) tolerates high latency. Live mode requires <30s per call to be practical — may need a smaller model or faster hardware.

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
  provider: ollama                   # ollama, mlx-lm, llama-cpp, vllm
  model: qwen3:4b
  endpoint: http://localhost:11434   # base URL — Ollama uses /api/chat, others use /v1/chat/completions
  confidence_threshold: 0.8
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

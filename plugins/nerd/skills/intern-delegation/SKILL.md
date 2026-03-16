---
name: intern-delegation
description: "Canonical delegation protocol for the nerd intern. Reference this when delegating tasks to the local LLM in /nerd or /nerd-this orchestrators. Defines health checks, timeouts, confidence gating, shadow comparison, fallback, and logging."
---

# Intern Delegation Protocol

The orchestrator (not individual agents) handles all intern delegation. Agents stay as clean primitives — they do their job. The orchestrator wraps agent calls with an intern-first-or-shadow layer.

## Pre-Run Health Check (Phase 0)

Run once at the start of every `/nerd` or `/nerd-this` run when `intern.enabled: true`.

The orchestrator resolves the config source (global or project) during pre-flight and passes the values. The health check consumes those values — it does NOT read config files directly.

```bash
# These values are passed from the orchestrator's pre-flight resolution:
# INTERN_PROVIDER, INTERN_MODEL, INTERN_ENDPOINT

if [ "$INTERN_PROVIDER" = "ollama" ] || [ -z "$INTERN_PROVIDER" ]; then
  # Ollama: use native /api/tags endpoint
  HEALTH=$(curl -s -m 5 "http://localhost:11434/api/tags" 2>/dev/null)
  # Verify model is loaded
  echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); models=[m['name'] for m in d.get('models',[])]; sys.exit(0 if any('${INTERN_MODEL}' in m for m in models) else 1)" 2>/dev/null
else
  # Other providers: use OpenAI-compatible endpoint
  HEALTH=$(curl -s -m 5 "${INTERN_ENDPOINT}/v1/models" 2>/dev/null)
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
  → Call intern in background
  → Call Claude (always, result is authoritative)
  → Compare outputs, log agreement (counts toward promotion)
  → Use Claude's result

If mode == "disabled":
  → Call intern in background (always-shadow)
  → Call Claude (always, result is authoritative)
  → Compare outputs, log as passive observation (does NOT count toward promotion)
  → Use Claude's result
  → Training data still collected
```

**Key difference between shadow and disabled:** Both run the intern alongside Claude. Shadow agreements count toward the 20/25 promotion threshold. Disabled observations are logged but don't count — they're passive learning. This lets the intern build training data on tasks it hasn't formally "earned" yet.

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

1. **Parse JSON** — use the extract_json() function above. Malformed response = confidence 0, fallback
2. **Validate schema** — required fields must be present per task type:
   - parameter-detection: `parameters` array with `name`, `file`, `line`, `value` per entry
   - result-classification: `classification` (one of improved/regressed/neutral), `evidence` string
   - context-extraction: `summary` string (10-500 chars)
   - perf-area-mapping: `areas` array with `file`, `function`, `characteristics` per entry
   - perf-classification: `classification` (one of improved/regressed/neutral), `evidence` string, `metrics` object
3. **Check confidence** — response must include `confidence` field (0.0-1.0)
4. **Gate on threshold** — if `confidence < intern.confidence_threshold` (default 0.8), fallback

**Any validation failure = confidence 0 = automatic fallback to Claude.**

## Shadow Comparison

When a task is in `shadow` or `disabled` (always-shadow) mode, both the intern and Claude produce output. Compare them:

| Task | Agreement Metric | Agreement Threshold |
|------|-----------------|---------------------|
| parameter-detection | F1 score of detected parameters | F1 >= 0.8 |
| result-classification | Exact match of classification | Exact match |
| context-extraction | Jaccard similarity of key terms | Jaccard >= 0.7 |
| perf-area-mapping | F1 score of identified areas (by file+function) | F1 >= 0.7 |
| perf-classification | Exact match of classification | Exact match |

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

## Config Resolution: Global Default, Local Override

The intern is configured **globally** by default so it shadows across all projects. Per-project overrides are optional.

### Resolution order (first match wins):

1. **Project-local config:** `.claude/nerd.local.md` → `intern:` section
2. **Global config:** `~/.claude/plugins/nerd/intern/config.yaml`
3. **Not configured:** intern is inactive

```bash
# Resolution logic
if grep -q "intern:" .claude/nerd.local.md 2>/dev/null; then
  # Project-level override — use it (may disable intern for this project)
  SOURCE="project"
elif [ -f ~/.claude/plugins/nerd/intern/config.yaml ]; then
  # Global config — use it
  SOURCE="global"
else
  # No intern configured
  SOURCE="none"
fi
```

### State resolution (same pattern):

1. **Project-local state:** `.nerd/intern/state.json` (if project config exists)
2. **Global state:** `~/.claude/plugins/nerd/intern/state.json`

**Why global state:** The intern's competence is about the model, not the codebase. Shadow agreements from project A count toward promotion just as much as agreements from project B. Global state means the intern earns live mode faster across all your work.

**Training data is dual-written:** Both project-local (`.nerd/intern/training-data/`) AND global (`~/.claude/plugins/nerd/intern/training-data/`). The global corpus includes a `project` field for traceability. This means the intern's aptitude test and auto-eval can draw from all prior research runs across all projects.

### Global config (`~/.claude/plugins/nerd/intern/config.yaml`):
```yaml
provider: ollama
model: qwen3:4b
endpoint: http://localhost:11434
confidence_threshold: 0.8
collect_training_data: true
```

### Global state (`~/.claude/plugins/nerd/intern/state.json`):
```json
{
  "tasks": {
    "parameter-detection": {
      "mode": "shadow",
      "accuracy": 0.96,
      "shadow_window": [true, true, false, true, true],
      "promoted_at": null
    },
    "result-classification": { "mode": "shadow", "accuracy": 0.60, "shadow_window": [], "promoted_at": null },
    "context-extraction": { "mode": "disabled", "accuracy": 0.46, "shadow_window": [], "promoted_at": null },
    "perf-area-mapping": { "mode": "disabled", "accuracy": 0.0, "shadow_window": [], "promoted_at": null },
    "perf-classification": { "mode": "disabled", "accuracy": 0.0, "shadow_window": [], "promoted_at": null }
  },
  "last_run": {
    "delegated": 3,
    "fallbacks": 1,
    "total_intern_time_ms": 7200
  },
  "lifetime_claude_calls_saved": 0
}
```

### Per-project override (`.claude/nerd.local.md`):
```yaml
intern:
  enabled: false          # Disable intern for this project
  # Or override specific settings:
  # model: qwen3:1b       # Use a smaller model for this project
  # confidence_threshold: 0.9  # Be more conservative here
```

**State migration:** When adding a project-local intern config for the first time, the orchestrator should copy the current global state.json to `.nerd/intern/state.json` as a starting point. This preserves accumulated shadow history. If `.nerd/intern/state.json` already exists, do not overwrite it.

### Per-project disable:
```yaml
intern:
  enabled: false
```

## Always-Shadow: Every Run is a Learning Opportunity

**When the intern is configured (global or local), it ALWAYS shadows Claude on research tasks** — even if all task modes are `disabled`. The shadow comparison is free (the local model runs on your hardware, Claude is already running for the research job).

The behavior per mode:
- **`live`**: Intern goes first. If confident enough, use its result. Otherwise fall back to Claude.
- **`shadow`**: Both run. Use Claude's result. Compare and log agreement.
- **`disabled`**: Both run. Use Claude's result. Compare and log — but don't count toward promotion. This is passive observation that builds training data without affecting promotion thresholds.

**Why always-shadow for disabled tasks:** The intern needs volume to improve. Waiting for a task to be manually promoted to `shadow` before collecting any data wastes every research run in between. Passive shadowing on disabled tasks builds training data and lets the user see improvement trends in `/nerd-intern status` before deciding to promote.

**The only time the intern doesn't run:** When there is no intern configured at all (no global config, no project config), or when the endpoint health check fails at Phase 0.

---
name: nerd-intern
description: "Train a local LLM to handle lightweight research tasks. Your intern starts dumb (really dumb) but learns from every nerd run and earns responsibility through demonstrated competence. Requires a local LLM serving stack (Ollama, MLX-LM, llama.cpp, or vLLM)."
argument-hint: "[setup|status|reset]"
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,Agent,AskUserQuestion"
---

# Nerd Intern

<user_subcommand>$ARGUMENTS</user_subcommand>

Parse the subcommand from `$ARGUMENTS`. If empty or unrecognized, show help:

```
Nerd Intern — Train a local LLM research assistant

  /nerd-intern setup   — detect hardware, pick model, run aptitude test
  /nerd-intern status  — see what your intern can (and can't) do
  /nerd-intern reset   — wipe state, start over (preserves training data)

  Warning: nerd interns are dumb AF to begin with.
  Requires: A local LLM serving stack (Ollama, MLX-LM, llama.cpp, or vLLM)
```

---

## Subcommand: setup

### Step 1: Detect Hardware

```bash
# Platform
uname -s

# Memory (macOS)
sysctl -n hw.memsize 2>/dev/null | awk '{print $1/1024/1024/1024 " GB"}'

# Memory (Linux)
grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2/1024/1024 " GB"}'

# GPU type
# macOS: always Metal on Apple Silicon
system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model"
# Linux: check CUDA
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null
```

Determine GPU type: `metal` (macOS Apple Silicon), `cuda` (NVIDIA), `cpu` (no GPU detected).

### Step 2: Detect Providers

```bash
which ollama 2>/dev/null
python3 -c "import mlx_lm" 2>/dev/null && echo "mlx-lm available"
which llama-server 2>/dev/null || which llama.cpp 2>/dev/null
```

### Step 3: Get Model and Endpoint

**Autonomous mode (`NERD_SCHEDULED=1` or CLI arguments provided):**
If `$ARGUMENTS` contains `--provider` and `--model` flags (e.g., `/nerd-intern setup --provider ollama --model qwen3.5-4b-q4`), use those directly. Otherwise, auto-detect: pick the first available provider from Step 2, select the recommended model for the detected RAM tier, use the provider's default endpoint. Log the auto-selected configuration and proceed without interaction.

**Interactive mode (default):**
If no existing intern config in `.claude/nerd.local.md`, use AskUserQuestion:

"Which local LLM provider and model are you using?"

Options based on detected providers:
1. Ollama (detected at {path}) — endpoint: http://localhost:11434/v1/chat/completions
2. MLX-LM (detected) — endpoint: http://localhost:8080/v1/chat/completions
3. llama.cpp (detected at {path}) — endpoint: http://localhost:8080/v1/chat/completions
4. vLLM — endpoint: http://localhost:8000/v1/chat/completions
5. Custom endpoint (I'll provide the URL)

Then ask for the model name. Suggest based on hardware:

| RAM | Recommended |
|-----|-------------|
| 8GB | Gemma 3 1B-Q4_K_M, Qwen 3.5 0.8B-Q4_K_M |
| 16GB | Qwen 3.5 4B-Q4_K_M, Phi-4 Mini-Q4_K_M |
| 32GB+ | Qwen 3.5 9B-Q4_K_M, StarCoder 2 7B-Q4_K_M |
| 64GB+ | Qwen 2.5 Coder 32B-Q4_K_M |

### Step 4: Test Endpoint

```bash
ENDPOINT="{selected_endpoint}"
MODEL="{selected_model}"
BASE_URL="${ENDPOINT%/chat/completions}"

# Health check
curl -s -m 5 "${BASE_URL}/models" 2>/dev/null
```

If the endpoint is not reachable:

**In scheduled mode (`NERD_SCHEDULED=1`):** Attempt auto-start before failing:
- Ollama: `ollama serve &>/dev/null & sleep 5` then retry health check
- If still unreachable: log error and exit setup gracefully (intern remains disabled)

**In interactive mode:** Help the user start their provider:
- Ollama: "Run `ollama serve` in another terminal, then `ollama pull {model}`"
- MLX-LM: "Run `mlx_lm.server --model {model}` in another terminal"
- llama.cpp: "Run `llama-server -m {model_path}` in another terminal"

### Step 5: Run Aptitude Test

**Check benchmark availability** (three sources, in priority order):
```bash
# 1. Global training corpus (from all prior /nerd runs across all projects)
ls ~/.claude/plugins/nerd/intern/training-data/*.jsonl 2>/dev/null | head -1

# 2. Project-local benchmarks
ls .nerd/intern/benchmark/ 2>/dev/null

# 3. Seed benchmarks bundled with the plugin
ls ${CLAUDE_PLUGIN_ROOT}/skills/intern-training/benchmark-seed/ 2>/dev/null
```

**Use the global corpus first** — it contains real examples from the user's own codebases. Seed benchmarks are the fallback for first-time users who haven't run `/nerd` yet.

If none exist: "No benchmark data available yet. Run `/nerd` on any project first to build training data, then re-run `/nerd-intern setup`." In scheduled mode, log this and exit gracefully.

If benchmarks are available, invoke the intern-evaluator agent:

```
Agent(subagent_type="nerd:intern-evaluator", prompt="
  Run aptitude test for the intern.
  Endpoint: {endpoint}
  Model: {model}
  Benchmark path: ${CLAUDE_PLUGIN_ROOT}/skills/intern-training/benchmark-seed/
  Project benchmark path: .nerd/intern/benchmark/
")
```

### Step 6: Choose Scope

Use AskUserQuestion (skip in autonomous mode — default to global):

"Configure the intern globally or for this project only?"

Options:
1. **Global (recommended)** — shadows across all projects, learns faster
2. **This project only** — isolated config and state

In autonomous mode (`NERD_SCHEDULED=1`): default to global.

### Step 7: Write Config

**If global (default):**

```bash
mkdir -p ~/.claude/plugins/nerd/intern
```

Write `~/.claude/plugins/nerd/intern/config.yaml`:
```yaml
provider: {provider}
model: {model}
endpoint: {endpoint}
confidence_threshold: 0.8
collect_training_data: true
setup_timestamp: "{ISO timestamp}"
gpu_type: "{metal|cuda|cpu}"
```

Write `~/.claude/plugins/nerd/intern/state.json`:
```json
{
  "tasks": {
    "parameter-detection": {
      "mode": "{mode from aptitude test}",
      "accuracy": {score},
      "shadow_window": [],
      "promoted_at": null
    },
    "result-classification": {
      "mode": "{mode from aptitude test}",
      "accuracy": {score},
      "shadow_window": [],
      "promoted_at": null
    },
    "context-extraction": {
      "mode": "{mode from aptitude test}",
      "accuracy": {score},
      "shadow_window": [],
      "promoted_at": null
    },
    "perf-area-mapping": {
      "mode": "disabled",
      "accuracy": 0.0,
      "shadow_window": [],
      "promoted_at": null
    },
    "perf-classification": {
      "mode": "disabled",
      "accuracy": 0.0,
      "shadow_window": [],
      "promoted_at": null
    }
  },
  "last_run": null,
  "lifetime_claude_calls_saved": 0
}
```

**If project-only:**

Write intern config to `.claude/nerd.local.md` under the `intern:` key:
```yaml
intern:
  enabled: true
  provider: {provider}
  model: {model}
  endpoint: {endpoint}
  confidence_threshold: 0.8
  collect_training_data: true
```

Write state to `.nerd/intern/state.json` (same format as global).

**Always create project-local training data directory** (training data is always per-project):

```bash
mkdir -p .nerd/intern/training-data
mkdir -p .nerd/intern/eval
mkdir -p .nerd/intern/benchmark
```

### Step 8: Confirm

Display the aptitude test results and final configuration. End with:

```
Intern configured ({scope}). Your {model} is ready.

Your intern will shadow Claude on every /nerd and /nerd-this run:
- Tasks scored above 0.6: active shadow (counts toward promotion)
- Tasks below 0.6: passive shadow (learns but doesn't promote yet)
- All tasks: collecting training data for future improvement

The intern shadows automatically — no action needed. It learns from every research job.

Run /nerd-intern status anytime to check progress.
```

Where `{scope}` is "global — active across all projects" or "this project only".

---

## Subcommand: status

### Read State

```bash
cat .claude/nerd.local.md 2>/dev/null
cat .nerd/intern/state.json 2>/dev/null
```

### Health Check

```bash
ENDPOINT=$(parse from nerd.local.md)
BASE_URL="${ENDPOINT%/chat/completions}"
curl -s -m 5 "${BASE_URL}/models" 2>/dev/null
```

### Training Data Counts

```bash
for task in parameter-detection result-classification context-extraction; do
  count=$(wc -l < ".nerd/intern/training-data/${task}.jsonl" 2>/dev/null || echo 0)
  echo "${task}: ${count} examples"
done
```

### Display

```
Intern Status — {model} via {provider}

  Endpoint: {endpoint} {healthy_check}

  Tasks:
  ┌─────────────────────┬──────────┬──────────┬───────────────┐
  │ Task                │ Accuracy │ Mode     │ Claude saved  │
  ├─────────────────────┼──────────┼──────────┼───────────────┤
  │ param-detection     │ {acc}%   │ {mode}   │ {count}/run   │
  │ result-classif.     │ {acc}%   │ {mode}   │ {count}/run   │
  │ context-extraction  │ {acc}%   │ {mode}   │ {count}/run   │
  └─────────────────────┴──────────┴──────────┴───────────────┘

  Last run: {delegated} delegated, {fallbacks} fallback(s)
  Training data: {total} examples across 3 task types
  Lifetime Claude calls saved: {count}
```

If intern is not configured: "No intern configured. Run `/nerd-intern setup` to get started."

---

## Subcommand: reset

### Confirm

In scheduled mode (`NERD_SCHEDULED=1`): skip confirmation, proceed directly.

In interactive mode: Use AskUserQuestion: "Reset your intern? This wipes all task progress and state. Training data is preserved."

Options:
1. Yes, reset everything
2. No, cancel

### Execute Reset

```bash
# Wipe state (preserves training data)
rm -f .nerd/intern/state.json
rm -f .nerd/intern/delegation-log.jsonl

# Remove eval history
rm -rf .nerd/intern/eval/

# Keep training data and benchmarks intact
# .nerd/intern/training-data/ is preserved
# .nerd/intern/benchmark/ is preserved
```

Remove `intern:` section from `.claude/nerd.local.md` (or set `intern.enabled: false`).

Display: "Intern reset. Training data preserved ({count} examples). Run `/nerd-intern setup` to start fresh."

---

## Error Handling

- If `$ARGUMENTS` is not one of `setup`, `status`, `reset`: show help text
- If endpoint unreachable during setup: guide user to start their provider
- If no intern config exists for status/reset: suggest running setup first
- If `.nerd/intern/` directory doesn't exist: create it during setup

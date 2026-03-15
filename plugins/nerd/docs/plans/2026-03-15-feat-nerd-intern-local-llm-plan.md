---
title: "feat: Nerd Intern — Local LLM Research Assistant with Curriculum Learning"
type: feat
status: implemented
date: 2026-03-15
deepened: 2026-03-15
---

## Enhancement Summary

**Deepened on:** 2026-03-15
**Research agents used:** 12 (Unsloth fine-tuning, vLLM/SGLang inference, quantization optimization, knowledge distillation, evaluation harness, architecture strategist, code simplicity, agent-native architecture, plugin development, DAG architecture learnings, command-agent contract learnings, ML web research)

### Key Improvements (v1 Scope Reduction)

1. **Cut to 3 tasks for v1** — parameter-detection, result-classification, context-extraction. Defer hypothesis-generation and experiment-triage (models can't do them yet — the plan's own aptitude test proves this).
2. **Cut to 3 commands** — setup, status, reset. Promotion is automatic. Training loop deferred to v2.
3. **Move delegation logic to orchestrator** — don't embed delegation blocks in 5 agents. The orchestrator handles tier selection, agents stay as clean primitives.
4. **Rolling shadow agreement window** (20/25) instead of consecutive-with-reset. Prevents Claude's non-determinism from permanently blocking promotion.
5. **Add adapter deployment pipeline** — the biggest missing piece. After QLoRA training, adapters must be merged, converted to GGUF, and registered with Ollama.
6. **Add chain-of-thought to training data** — capture Claude's reasoning traces, not just final outputs. This is knowledge distillation, not just supervised fine-tuning.
7. **Use per-task LoRA adapters** — prevents training on a hard task from degrading a mastered task.
8. **Split config from runtime state** — user preferences in nerd.local.md, mutable state in .nerd/intern/state.json.
9. **Make Phase 7.5 conditional** on `intern.enabled` or explicit `intern.collect_training_data` flag, not always-on.
10. **Layered timeouts** — connection (3s), first token (15s), total (30s) instead of flat 30s.

### Critical Gaps Discovered

- **No adapter deployment pipeline** (quantization agent) — trained adapters can't reach the inference server without merge → GGUF convert → register flow
- **Training and inference can't share GPU** (inference agent) — must stop Ollama before training on 16GB machines
- **Intern DAG schema must relax `source_experiment`** (architecture review) — intern doesn't run experiments, needs `intern_metadata.run_id` instead
- **Idempotency not tested** (contract learnings) — running setup/phases twice must produce no duplicates
- **Report-compiler write ambiguity** (DAG learnings) — plan says both report-compiler and Phase 7.6 write intern DAG, violating single-writer invariant

### v1 vs v2 Scope Split

| v1 (Ship First) | v2 (Earn Later) |
|-----------------|-----------------|
| 3 tasks: param-detection, result-classification, context-extraction | hypothesis-generation, experiment-triage |
| 3 commands: setup, status, reset | train, eval (as separate commands) |
| Shadow + live modes | Intern DAG + convergence levels |
| Passive training data collection | Active QLoRA training loop |
| Automatic promotion/demotion | Manual promote override |
| Delegation at orchestrator level | Per-task LoRA adapters |

---

# Nerd Intern: Local LLM Research Assistant

## Overview

An opt-in system that lets users train a local LLM (the "intern") to gradually take over lightweight research tasks from Claude. The intern starts useless, learns from every nerd run, and earns responsibility through demonstrated competence. The intern gets its own DAG (notebook) where it records observations — convergence between the intern DAG and the real DAG is the primary measure of whether the intern is developing judgment, not just pattern matching.

**Tagline:** *Want to train a nerd intern? Install a local LLM and slowly train it to take on lightweight research tasks. Warning: nerd interns are dumb AF to begin with.*

## Problem Statement

Every `/nerd` run makes dozens of Claude API calls for tasks that range from genuinely hard (hypothesis generation, experiment design) to relatively mechanical (parameter detection, result classification). A local LLM could handle the mechanical tasks — if we can figure out which tasks it can actually do, and prevent it from corrupting research when it gets things wrong.

The challenge isn't "can a small model do useful work?" — it's "how do we let it contribute without trusting it, measure whether it's improving, and promote it safely?"

## Proposed Solution

A curriculum learning system with an intern metaphor throughout:

1. **Setup**: User picks a model and provider. Aptitude test reveals what the model can actually do (expect surprises — difficulty ordering is not what you'd assume).
2. **Shadow mode**: Intern runs alongside Claude, comparing outputs. No contribution to real results. Builds agreement history.
3. **Live mode**: Intern handles tasks it's proven competent at. Claude handles the rest. Fallback on low confidence.
4. **Intern DAG**: The intern's private notebook. Convergence with the real DAG measures judgment, not just task accuracy.
5. **Training loop** (optional): Karpathy-style 5-minute QLoRA cycles on accumulated training data from nerd runs.

## Technical Approach

### Architecture

```
User installs local LLM (Ollama, MLX-LM, etc.)
         │
         ▼
  /nerd-intern setup
  ├── Detect hardware (RAM, GPU/Metal/CUDA)
  ├── Test endpoint connectivity
  ├── Run aptitude test (score all 5 tasks)
  └── Write config to nerd.local.md
         │
         ▼
  Every /nerd or /nerd-this run:
  ├── Phase 0: Health check intern endpoint
  ├── Phases 1-7: Normal pipeline with delegation hooks
  │   ├── Live tasks → call intern first, confidence gate, fallback
  │   ├── Shadow tasks → call both, compare, log agreement
  │   └── Disabled/training → skip intern
  ├── Phase 7.5: Extract training data (ALWAYS, even without intern)
  └── Phase 7.6: Write intern DAG, compute convergence
         │
         ▼
  /nerd-intern train (optional, user-triggered)
  ├── Validate minimum examples (50 per task)
  ├── Run QLoRA cycle (5 min)
  ├── Eval against held-out set
  └── Update accuracy scores
```

### Provider Abstraction

All providers serve the same OpenAI-compatible chat completions API:

```
Ollama:    http://localhost:11434/v1/chat/completions
MLX-LM:   http://localhost:8080/v1/chat/completions
llama.cpp: http://localhost:8080/v1/chat/completions
vLLM:      http://localhost:8000/v1/chat/completions
```

Nerd doesn't know or care which is running. It sends prompts, gets completions.

### The Intern DAG

Stored separately at `~/.claude/plugins/nerd/dag/projects/{slug}-intern.json`. Uses the same schema as the real DAG with additional fields:

```json
{
  "nodes": [
    {
      "id": "t001",
      "type": "theory",
      "title": "Fuzzy match threshold is too aggressive",
      "confidence": 0.72,
      "intern_metadata": {
        "task_type": "hypothesis-generation",
        "model": "qwen3.5-4b-q4",
        "latency_ms": 2340,
        "run_id": "run-2026-03-15-001"
      },
      "source_files": ["src/search.rs"],
      "tags": ["search", "threshold"]
    }
  ],
  "edges": [],
  "project": "projects-arras",
  "version": 1
}
```

**Who writes the intern DAG:** A post-processing step in Phase 7.6 (after training data extraction). This follows the real DAG's single-writer architecture — the orchestrator collects intern outputs from the run and writes them in a single atomic operation using the crash-safe protocol (backup → tmp → validate → rename).

**Convergence measurement:**
1. For each real DAG node from the latest run, find the intern's corresponding node (matched by `source_files` + `tags`, NOT `source_experiment` — the intern doesn't run experiments)
2. Compare: theory tag overlap, verdict result exact match, recommendation match
3. Convergence rate = agreeing nodes / total comparable nodes

**Convergence levels:**

| Level | Description | Promotion | Demotion |
|-------|-------------|-----------|----------|
| 0 | Private — only training loop reads it | Default | N/A |
| 1 | Report-compiler reads as "additional observations" | >= 0.5 sustained 3 runs | < 0.5 for 3 consecutive runs |
| 2 | Agreeing observations auto-merge to real DAG | >= 0.7 sustained 5 runs | < 0.7 for 3 consecutive runs |
| 3 | Intern proposes nodes, Claude approves | >= 0.85 sustained 10 runs | < 0.85 for 3 consecutive runs |

### Tasks and Scoring

| Task | Input | Expected Output | Scoring Metric | Shadow Agreement Threshold |
|------|-------|----------------|----------------|---------------------------|
| parameter-detection | Source file (200 lines) | JSON list of parameters | Precision + recall (F1) | F1 >= 0.8 |
| result-classification | Experiment results JSON | improved/regressed/neutral | Exact match | Exact match |
| context-extraction | Source file + function | 2-3 sentence summary | Key term overlap (Jaccard) | Jaccard >= 0.7 |
| hypothesis-generation | Parameter + context | List of hypotheses | Coverage of hypothesis types | >= 2 matching type categories |
| experiment-triage | Findings summary | Ranked candidates | Rank correlation (Kendall's tau) | tau >= 0.6 |

### Task Mode Progression

| Mode | Symbol | Description |
|------|--------|-------------|
| disabled | `nope` | Aptitude too low to bother |
| training | `train` | Being trained on, not used in runs |
| shadow | `shadow` | Runs alongside Claude, comparing outputs |
| live | `live` | Outputs used in real nerd runs |

**Promotion thresholds:**

| Transition | Requirement |
|-----------|-------------|
| disabled → training | Accuracy >= 0.3 on aptitude test |
| training → shadow | Accuracy >= 0.6 on eval |
| shadow → live | Accuracy >= 0.8 AND 20 consecutive shadow agreements |

**Demotion:** If accuracy drops below the current level's threshold for 3 consecutive evals, demote one level.

### Confidence Scoring

**Primary mechanism:** Request a structured JSON response with a `confidence` field (0.0-1.0) where the model self-rates. This is unreliable for absolute calibration but sufficient for relative gating when combined with output validation.

**Validation layer:** Before using any intern output:
1. Parse the response as JSON — malformed response = confidence 0
2. Validate required schema fields present — missing fields = confidence 0
3. Check self-reported confidence against threshold
4. In shadow mode, track calibration drift (does self-reported confidence correlate with actual accuracy?)

**Why not logprobs:** Most local LLM providers don't reliably expose token-level logprobs. Self-reported confidence + structural validation is more portable across providers.

**Delegation timeout:** 30 seconds per request (configurable). If the intern doesn't respond, fall back to Claude silently and log the timeout.

### Critical Design Decision: Training Data in Live Mode

**Rule: Phase 7.5 ALWAYS calls Claude for training data generation, regardless of delegation mode.**

When a task is in `live` mode and the intern handles it during the run, Phase 7.5 still calls Claude to produce the "ground truth" output for that task. This means:
- Live mode saves Claude calls during Phases 1-7 (the actual work)
- Phase 7.5 still makes Claude calls for training data
- Training data is never contaminated by intern outputs
- Safety Rule 4 (training data from Claude only) is preserved

**Net savings:** Live mode saves calls during the run itself. Training data generation is a background cost that decreases as a percentage as the intern handles more tasks. Users can disable training data generation if they don't plan to use the training loop.

### Integration with Existing Agents

Each agent gets a conditional delegation block following the same pattern:

```
## Intern Delegation (if enabled)

If intern config is provided AND {task} mode is `live`:
  1. Call intern endpoint: curl -s -m 30 {endpoint} -d '{prompt}'
  2. Parse response, validate JSON structure
  3. If valid AND confidence >= threshold: use intern result
  4. Otherwise: proceed with normal {agent} logic (Claude handles it)
  5. Log delegation result to .nerd/intern/delegation-log.jsonl

If {task} mode is `shadow`:
  1. Call intern endpoint (same as above)
  2. Proceed with normal {agent} logic regardless
  3. Compare intern result vs Claude result using {agreement metric}
  4. Log agreement/disagreement
  5. If agreement: increment shadow_agreements in config
  6. If disagreement: reset shadow_agreements to 0
```

**Agent integration points:**

| Agent | Intern Task | Integration Point |
|-------|-------------|-------------------|
| parameter-scanner | parameter-detection | Initial scan — intern proposes parameters |
| experiment-executor | result-classification | Post-experiment — intern classifies outcome |
| report-compiler | (reads intern DAG) | Phase 7 — additional observations at convergence level 1+ |
| plan-reviewer | hypothesis-generation | Theory generation — intern proposes starting hypotheses |
| loop-scout | experiment-triage | Candidate ranking — intern provides initial ranking |

**Commands that need delegation blocks:** Both `commands/nerd.md` AND `commands/nerd-this.md` invoke these agents. Both must be modified.

### Concurrency Handling

When `max_parallel_experiments` > 1, multiple agents may try to call the intern simultaneously. Most local LLM servers serialize requests (Ollama queues them).

**Strategy:** Do not batch or parallelize intern requests. Accept that delegation adds sequential latency. The delegation timeout (30s) prevents indefinite blocking. If total intern latency exceeds a budget (configurable, default 5 minutes per run), remaining tasks fall back to Claude.

### Training Data Generation (Always-On)

Phase 7.5 in the orchestrator extracts training examples after every run:

| Task | Input Source | Output Source |
|------|-------------|---------------|
| parameter-detection | File contents | parameter-scanner's JSON results |
| result-classification | Experiment results JSON | report-compiler's verdict |
| context-extraction | Source file | parameter-scanner's rationale field |
| hypothesis-generation | Parameter + context | plan-reviewer's competing theories |
| experiment-triage | Findings summary | loop-scout's ranked candidates |

**Stored as JSONL** at `.nerd/intern/training-data/{task_type}.jsonl`

**Training example schema:**
```json
{
  "task_type": "result-classification",
  "input": {"experiment_id": "E001", "results": {}, "plan": {}},
  "output": {"classification": "improved", "evidence": "nDCG improved 3.2%"},
  "source_agent": "report-compiler",
  "created_at": "2026-03-15T10:30:00Z",
  "run_id": "run-2026-03-15-001",
  "dedup_key": "E001:result-classification"
}
```

**Deduplication:** The `dedup_key` field prevents duplicate examples from repeated runs on the same experiments. Before appending, check if the key already exists in the JSONL file.

**Crash safety:** Append operations use write-then-fsync. On read, skip malformed trailing lines (partial writes from crashes).

**Minimum training threshold:** 50 examples per task type before `/nerd-intern train` will run QLoRA. Below that: "Need N more examples. Run /nerd a few more times."

### Training Loop

```
/nerd-intern train

1. Read training data from .nerd/intern/training-data/
2. Validate minimum examples (50 per task)
3. Split: 80% train, 20% held-out eval
4. Run QLoRA fine-tuning (configurable cycle_minutes, default 5)
   - Framework: Unsloth (primary) or MLX fine-tuning
   - 4-bit quantized base, LoRA adapters in fp16
   - lora_r: 16, lora_alpha: 16 (per Unsloth recommendation for Qwen3.5)
5. Evaluate on held-out set
6. If accuracy improved: save adapter weights, update config
7. If accuracy regressed: discard adapter, keep previous
8. Report: loss delta, accuracy per task, promotion status
```

**Adapter storage:** `.nerd/intern/adapters/{model-name}/`

**Model switching:** Changing models in config triggers full re-setup: re-run aptitude test, reset task modes. Old adapters preserved under their model-name directory. Training data is model-agnostic and reused.

**Interruption recovery:** QLoRA checkpoints every 100 steps. If interrupted, next cycle resumes from last checkpoint.

### The Aptitude Test

Run during `/nerd-intern setup` and repeatable via `/nerd-intern eval`.

**Test data:** Seed benchmarks bundled with the plugin at `skills/intern-training/benchmark-seed/`. These are language-agnostic examples from diverse codebases (Rust, TypeScript, Python, Go). As the user runs nerd, project-specific examples accumulate and supplement the seed data.

**Scoring output:**
```
🧑‍🎓 Intern Aptitude Test — qwen3.5-4b-q4 via Ollama

  parameter-detection:    0.46  📚 training  "Shows promise. Can spot obvious thresholds."
  result-classification:  0.88  👀 shadow    "Pretty reliable on binary improve/regress."
  context-extraction:     0.62  👀 shadow    "Summaries capture the gist."
  hypothesis-generation:  0.16  🚫 disabled  "lol no"
  experiment-triage:      0.31  📚 training  "Gets the obvious top pick right sometimes."

  GPU: Apple M4 Pro (Metal)
  Training feasible: Yes (QLoRA fits in 10GB)
  Estimated training time per cycle: ~4 minutes
```

### Safety Rules

1. **Intern NEVER gets unsupervised write access to the real DAG** — even at convergence level 3, Claude approves
2. **Confidence gating** — outputs below threshold (default 0.8) fall back to Claude
3. **Shadow mode before live** — 20 consecutive agreements required before promotion
4. **Training data from Claude only** — Phase 7.5 always calls Claude, never uses intern output as ground truth
5. **Endpoint health check** — if local LLM is down, all tasks silently fall back to Claude
6. **Output validation** — malformed/truncated intern output = automatic fallback, confidence 0
7. **Delegation timeout** — 30s per request, configurable
8. **Convergence demotion** — levels demote if convergence drops below threshold for 3 runs
9. **The intern can be fired** — `/nerd-intern reset` wipes adapters, resets modes, clears intern DAG
10. **No API keys in config** — endpoint auth via environment variable `NERD_INTERN_API_KEY`, not nerd.local.md

### Status and Observability

```
/nerd-intern status

🧑‍🎓 Intern Status — qwen3.5-4b-q4 via Ollama

  Endpoint: http://localhost:11434 ✓ healthy
  Training: enabled (Unsloth QLoRA), 47 cycles completed

  Tasks:
  ┌─────────────────────┬──────────┬──────────┬───────────────┐
  │ Task                │ Accuracy │ Mode     │ Claude saved  │
  ├─────────────────────┼──────────┼──────────┼───────────────┤
  │ result-classif.     │ 94%      │ ✅ live  │ ~40/run       │
  │ context-extraction  │ 76%      │ 👀 shadow│ 0 (learning)  │
  │ param-detection     │ 58%      │ 📚 train │ 0             │
  │ hypothesis-gen      │ 22%      │ 🚫 nope  │ 0             │
  │ experiment-triage   │ 41%      │ 📚 train │ 0             │
  └─────────────────────┴──────────┴──────────┴───────────────┘

  DAG Convergence: Level 1 (0.74 rate, ↑ from 0.68)
  Last run: 3 delegated, 1 fallback, 2 shadow agreements

  Training data: 312 examples across 5 task types
  Lifetime Claude calls saved: ~1,200 across 30 runs
```

## Config Schema (nerd.local.md)

```yaml
intern:
  enabled: false
  provider: ollama
  model: qwen3.5-4b-q4
  endpoint: http://localhost:11434/v1/chat/completions
  confidence_threshold: 0.8
  delegation_timeout_seconds: 30
  max_intern_time_per_run_seconds: 300
  gpu_type: metal                    # metal, cuda, cpu, none
  tasks:
    parameter-detection:
      mode: disabled
      accuracy: 0.0
      shadow_agreements: 0
      promoted_at: null
    result-classification:
      mode: disabled
      accuracy: 0.0
      shadow_agreements: 0
      promoted_at: null
    context-extraction:
      mode: disabled
      accuracy: 0.0
      shadow_agreements: 0
      promoted_at: null
    hypothesis-generation:
      mode: disabled
      accuracy: 0.0
      shadow_agreements: 0
      promoted_at: null
    experiment-triage:
      mode: disabled
      accuracy: 0.0
      shadow_agreements: 0
      promoted_at: null
  training:
    enabled: false
    framework: unsloth
    cycle_minutes: 5
    total_cycles: 0
    min_examples_per_task: 50
    data_path: .nerd/intern/training-data/
    adapter_path: .nerd/intern/adapters/
  dag:
    convergence_level: 0
    convergence_rate: 0.0
    convergence_history: []          # Last 50 entries, auto-pruned
```

## Data Storage

```
.nerd/intern/
├── training-data/
│   ├── parameter-detection.jsonl
│   ├── result-classification.jsonl
│   ├── context-extraction.jsonl
│   ├── hypothesis-generation.jsonl
│   └── experiment-triage.jsonl
├── adapters/
│   └── {model-name}/
│       ├── adapter_config.json
│       └── adapter_model.safetensors
├── eval/
│   └── {timestamp}.json
├── delegation-log.jsonl             # Per-run delegation decisions
└── benchmark/                       # Project-specific benchmark data
    └── {task-type}/
        ├── inputs/
        └── expected/
```

## System-Wide Impact

### Interaction Graph

```
/nerd-intern setup → writes intern config to nerd.local.md
                   → triggers aptitude test via intern-evaluator agent

/nerd run (Phases 1-7) → each agent reads intern config
                       → delegates if task mode is live/shadow
                       → calls local LLM endpoint
                       → falls back to Claude on low confidence or timeout
                       → logs delegation decisions

/nerd run (Phase 7.5)  → extracts training data from Claude's outputs
                       → appends to JSONL files (always, even without intern)

/nerd run (Phase 7.6)  → collects intern observations from the run
                       → writes to intern DAG (crash-safe protocol)
                       → computes convergence vs real DAG
                       → updates convergence_history in config

/nerd-intern train     → reads training data JSONL
                       → runs QLoRA via Unsloth/MLX
                       → writes adapter weights
                       → updates accuracy scores in config
```

### Error Propagation

| Error | Where | Recovery |
|-------|-------|----------|
| Intern endpoint down | Delegation | Silent fallback to Claude, log warning |
| Intern returns malformed JSON | Delegation | Confidence = 0, fallback to Claude |
| Intern timeout (>30s) | Delegation | Kill request, fallback to Claude |
| Training data JSONL corrupted | Training | Skip malformed trailing lines on read |
| QLoRA OOM | Training | Abort cycle, preserve previous adapters |
| Training interrupted | Training | Resume from last checkpoint (100-step intervals) |
| Model switched | Setup | Re-run aptitude test, reset task modes, preserve training data |
| Convergence drops | DAG | Auto-demote convergence level after 3 consecutive drops |

### State Lifecycle Risks

- **Intern DAG orphaned after reset:** `/nerd-intern reset` clears the intern DAG along with adapters and task modes. Training data is preserved.
- **Shadow agreement counter inflated by Claude variance:** Claude is non-deterministic. A disagreement could be Claude's variance, not the intern's error. Mitigation: shadow agreement threshold (20) is high enough to absorb occasional noise.
- **Training data stale after codebase change:** Training examples from old code may not apply after refactoring. Mitigation: training examples include `dedup_key` with experiment context — stale examples are diluted by fresh ones as the user runs more nerd cycles.

### API Surface Parity

Both `/nerd` and `/nerd-this` invoke the same agents and must both include intern delegation blocks. `/nerd-loop` does NOT delegate to the intern (it's a tight optimization loop where latency matters and the intern adds noise).

## Acceptance Criteria

### Functional Requirements

- [ ] `/nerd-intern setup` detects hardware (RAM, GPU type), tests endpoint, runs aptitude test, writes config
- [ ] `/nerd-intern status` displays task modes, accuracy, convergence, delegation stats, Claude savings
- [ ] `/nerd-intern train` runs QLoRA cycle with minimum example enforcement
- [ ] `/nerd-intern eval` re-runs aptitude test and shows improvement over time
- [ ] `/nerd-intern promote` advances eligible tasks to next mode
- [ ] `/nerd-intern reset` wipes adapters, modes, and intern DAG; preserves training data
- [ ] Phase 7.5 training data generation runs on every `/nerd` and `/nerd-this` run (even without intern)
- [ ] Phase 7.6 writes intern DAG and computes convergence
- [ ] Delegation works for all 5 task types across both `/nerd` and `/nerd-this`
- [ ] Shadow mode correctly compares outputs and tracks agreements
- [ ] Live mode correctly gates on confidence and falls back to Claude
- [ ] Convergence levels promote and demote correctly

### Non-Functional Requirements

- [ ] Delegation timeout prevents blocking (30s default)
- [ ] Per-run intern time budget prevents runaway latency (5min default)
- [ ] Training data uses dedup keys to prevent duplicates
- [ ] JSONL writes handle crashes gracefully (skip malformed lines on read)
- [ ] Intern DAG uses crash-safe write protocol
- [ ] No API keys stored in config files (use env var)
- [ ] Entire feature is opt-in — nerd works identically without intern

### Quality Gates

- [ ] All existing `/nerd` tests pass with intern disabled
- [ ] Delegation fallback tested: endpoint down, timeout, malformed response
- [ ] Shadow comparison tested: agreement and disagreement paths
- [ ] Training loop tested: minimum threshold enforcement, checkpoint recovery
- [ ] Config backwards-compatible: old nerd.local.md without `intern:` section works fine

## Scope Boundaries

### Explicitly Included
- Setup, status, train, eval, promote, reset commands
- Aptitude test with seed benchmarks
- Training data generation (always-on)
- Delegation in `/nerd` and `/nerd-this`
- Intern DAG with convergence measurement
- Shadow and live task modes

### Explicitly Excluded
- Intern delegation in `/nerd-loop` (too latency-sensitive)
- Automatic model download/installation (user manages their own LLM stack)
- Multi-model support (one model at a time per project)
- Distributed training (single machine only)
- Real-time inference during code editing (only during nerd runs)

## Files to Create

| File | Purpose |
|------|---------|
| `commands/nerd-intern.md` | Main command with subcommand dispatch (setup, status, train, eval, promote, reset) |
| `agents/intern-evaluator.md` | Runs aptitude test, ongoing evaluation, aptitude scoring |
| `schemas/intern-dag-schema.json` | Intern DAG schema (mirrors real DAG + confidence + intern_metadata) |
| `schemas/training-example-schema.json` | Training data JSONL format |
| `skills/intern-training/SKILL.md` | Training loop reference (frameworks, QLoRA config, data format, seed benchmarks) |

## Files to Modify

| File | Change |
|------|--------|
| `commands/nerd.md` | Add Phase 7.5 (training data extraction) and Phase 7.6 (intern DAG), intern delegation dispatch in Phases 2/5/7/8 |
| `commands/nerd-this.md` | Same delegation dispatch as nerd.md — must stay synchronized |
| `commands/nerd-setup.md` | Add intern hardware detection (GPU type, provider availability) |
| `commands/nerd-status.md` | Add intern status display section |
| `agents/parameter-scanner.md` | Add intern delegation block for parameter-detection |
| `agents/experiment-executor.md` | Add intern delegation block for result-classification |
| `agents/report-compiler.md` | Read intern DAG at convergence level 1+, write intern DAG nodes |
| `agents/plan-reviewer.md` | Add intern delegation block for hypothesis-generation |
| `agents/loop-scout.md` | Add intern delegation block for experiment-triage |
| `hooks/hooks.json` | Add `.nerd/intern/` to PostToolUse exclusion |
| `.gitignore` | Add `.nerd/intern/` |

## Implementation Phases

### Phase 1: Foundation (standalone, no existing file changes)
1. `schemas/intern-dag-schema.json`
2. `schemas/training-example-schema.json`
3. `skills/intern-training/SKILL.md` (including seed benchmark structure)
4. `agents/intern-evaluator.md`

### Phase 2: Command Shell
5. `commands/nerd-intern.md` — all 6 subcommands

### Phase 3: Training Data Pipeline (always-on, most important early step)
6. Modify `commands/nerd.md` — add Phase 7.5 training data extraction
7. Modify `commands/nerd-this.md` — same Phase 7.5
8. Modify `.gitignore` — add `.nerd/intern/`
9. Modify `hooks/hooks.json` — add `.nerd/intern/` exclusion

### Phase 4: Agent Delegation (one at a time, each independent)
10. `agents/parameter-scanner.md` — parameter-detection delegation
11. `agents/experiment-executor.md` — result-classification delegation
12. `agents/report-compiler.md` — intern DAG read + write
13. `agents/plan-reviewer.md` — hypothesis-generation delegation
14. `agents/loop-scout.md` — experiment-triage delegation

### Phase 5: Orchestrator Integration
15. Full intern delegation dispatch in `commands/nerd.md` (Phase 0 health check, per-phase delegation)
16. Same dispatch in `commands/nerd-this.md`
17. Intern hardware detection in `commands/nerd-setup.md`
18. Intern status display in `commands/nerd-status.md`

### Phase 6: Intern DAG and Convergence
19. Phase 7.6 in orchestrator — collect intern outputs, write intern DAG, compute convergence
20. Convergence level promotion/demotion logic

## Alternative Approaches Considered

**1. Replace agents entirely instead of delegation blocks.**
Rejected: too risky. The intern is unreliable. Delegation with fallback preserves the existing pipeline as the safety net.

**2. Shared DAG instead of separate intern DAG.**
Rejected: the intern would contaminate the real DAG with low-confidence observations. Convergence measurement requires two separate sources of truth.

**3. Logprob-based confidence scoring.**
Deferred: not all providers expose logprobs. Self-reported confidence + structural validation is more portable. Can add logprob support later as an enhancement.

**4. MLX-only training (no Unsloth).**
Rejected as sole option: Unsloth is faster and supports more models. MLX fine-tuning is supported as an alternative for users who prefer Apple-native tooling.

## Model Recommendations by Hardware

| RAM | GPU | Recommended Models | Training Feasible |
|-----|-----|-------------------|-------------------|
| 8GB | Metal | Gemma 3 1B-Q4, Qwen 3.5 0.8B | Marginal (small models only) |
| 16GB | Metal | Qwen 3.5 4B-Q4, Phi-4 Mini-Q4 | Yes |
| 32GB+ | Metal | Qwen 3.5 9B-Q4, StarCoder 2 7B | Yes, comfortable |
| 64GB+ | Metal | Qwen 2.5 Coder 32B-Q4 | Yes, large models |
| 16GB+ | CUDA | Same as Metal equivalents | Yes |
| Any | None | Inference only (small Q4 models) | No (CPU QLoRA is impractical) |

## Research Insights (from /deepen-plan)

### Knowledge Distillation (Critical for Training Pipeline)

The plan's training data captures only input/output pairs — the weakest form of distillation. Claude's agents already produce reasoning (rationales, competing theories, evidence chains). Capturing these dramatically improves student learning.

**Changes for v2 training pipeline:**
- Add `reasoning` field to training example schema — capture the agent's chain-of-thought, not just the final answer
- Generate 3-5 teacher outputs per input at temperature 0.7 (triples data accumulation rate)
- Use per-task LoRA adapters to prevent task interference during multi-task training
- Use a fixed chronological eval set (split by `run_id`, not random) to detect overfitting
- Relax dedup to 24-hour window instead of exact key match — preserves natural output diversity
- Gate adapter acceptance on seed benchmark non-regression (reject if seed accuracy drops >5pp)
- Add replay sampling from full history each cycle to prevent catastrophic forgetting

### Quantization (Critical Gap: Adapter Deployment)

**The biggest missing piece in the plan:** After QLoRA training produces LoRA adapters (bitsandbytes NF4 format), they cannot be used in Ollama (GGUF format) without a conversion pipeline:

1. Load base HuggingFace model in bitsandbytes NF4
2. Merge LoRA adapters into base model
3. Export merged model to FP16
4. Convert to GGUF format
5. Quantize GGUF to Q4_K_M
6. Register with Ollama via `ollama create`

**For MLX users:** MLX fine-tuning produces MLX-native adapters that work directly with MLX-LM inference — no conversion needed. This is the simpler end-to-end path for Mac users.

**Other quantization findings:**
- Always recommend Q4_K_M specifically (not generic "Q4") — it's the community standard with <2% accuracy loss
- imatrix-quantized models (from community quantizers on HuggingFace) score noticeably higher on aptitude tests
- Training and inference cannot share GPU simultaneously on 16GB machines — must stop Ollama before training
- `bnb_4bit_use_double_quant=True` saves ~0.4GB with negligible quality impact

### Inference Serving (Provider-Specific Behavior)

**Ollama:** Serializes to 4 concurrent max. Good for single-user. Intern requests queue, meaning 4 parallel experiment agents = 4x sequential latency.

**vLLM:** 3-6x throughput via continuous batching. Supports LoRA hot-swapping without restart. Best for users with CUDA GPUs who want maximum delegation throughput.

**SGLang:** RadixAttention shares KV cache across requests with common prefixes — ideal for intern workloads where all requests share the same system prompt template per task type.

**Health check:** Use `GET /v1/models` (5-second timeout), supported by all providers. Verify the returned model name matches config to catch stale model serving.

**Layered timeouts (recommended):**
| Layer | Timeout | Purpose |
|-------|---------|---------|
| Connection | 3 seconds | Detect endpoint down fast |
| First token (TTFT) | 15 seconds | Detect stuck model/OOM |
| Total request | 30 seconds | Prevent runaway generation |
| Per-run budget | 300 seconds | Cap total intern cost per run |

### Evaluation Harness (Statistical Rigor)

**50 examples is too few for reliable evaluation.** At n=50 and accuracy 0.80, the 95% CI is [0.67, 0.89]. Promotion thresholds sit inside this interval.

**Recommendations:**
- Separate eval minimums (40+ held-out) from training minimums (50 examples)
- Split train/eval by `run_id`, not randomly — prevents temporal leakage
- Report confidence intervals: `accuracy: 0.76 [0.65-0.85, n=50]`
- Track calibration (ECE), reliability (self-consistency across 5 runs), latency percentiles (p50/p95/p99)
- Track "dangerous failure ratio" — wrong answer + high confidence. If >10%, auto-demote regardless of accuracy.
- Version the seed benchmark. Rotate 20% of examples per plugin release to prevent memorization.
- Structure seed benchmarks with difficulty tiers (easy/medium/hard) x languages (4+) x context lengths (short/medium/long)

### Architecture Review (Structural Improvements)

**Move delegation to orchestrator, not agents.** Instead of embedding near-identical delegation blocks in 5 agent files across 2 commands (10 locations to synchronize), the orchestrator handles tier selection:
```
Orchestrator receives task → check intern config → if live: call intern, validate, gate → if passes: use result → else: call Claude agent
```
This keeps agents as clean primitives and eliminates prompt sync drift — the #1 historical cause of bugs in this codebase.

**Extract delegation protocol to a skill.** Create `skills/intern-delegation/SKILL.md` as the single source of truth for the delegation pattern, rather than duplicating in every agent.

**Defer config state updates to Phase 7.6.** Agents log to `delegation-log.jsonl` (append-only, no contention). The orchestrator aggregates and updates config atomically in Phase 7.6. This prevents race conditions when parallel agents both increment `shadow_agreements`.

**Intern DAG schema must fork properly.** The real DAG requires `source_experiment` on theory nodes. The intern DAG must make this optional, using `intern_metadata.run_id` as provenance instead.

**Convergence level 2 auto-merge has a timing issue.** The real DAG is written in Phase 7, but the intern DAG is written in Phase 7.6 (after). Auto-merge must happen at the start of the *next* run during Pre-flight DAG computation. Document this one-run lag as intentional.

### Agent-Native Architecture (Reframing)

**The intern is a model tier, not a separate agent.** The delegation pattern maps to tier selection: local (free) → fast (Haiku) → balanced (Sonnet) → powerful (Opus). The intern competes with Haiku on mechanical tasks — the real question is whether it can beat Haiku for this specific domain.

**Build empirical calibration, don't trust self-reported confidence.** Track actual accuracy per confidence band in shadow mode. If the model says 0.8 but is right 60% of the time at that band, the system knows 0.8 means 0.6. Gate on empirical accuracy, not self-report.

**Add a runtime circuit breaker.** If a task in live mode fails back to Claude 5 consecutive times, auto-demote to shadow. This is separate from (and faster than) eval-based demotion.

**Pass failed intern output to Claude during fallback.** "The intern attempted this and produced [X], which failed because [Y]." This gives Claude signal and creates higher-quality training data than Claude working from scratch.

### Plugin Development (Structural Fixes)

- Add full frontmatter to `intern-evaluator.md` (name, description with `<example>` blocks, model, color, tools)
- Use `${CLAUDE_PLUGIN_ROOT}` for plugin-bundled resource paths (benchmark seeds, schemas)
- Add `argument-hint: "[setup|status|reset]"` and `allowed-tools` to command frontmatter
- Consider splitting config (user preferences) from runtime state (accuracy, shadow_agreements) into separate files
- `delegation-log.jsonl` needs a dedup key for idempotency on repeat runs

### Unsloth Fine-Tuning (v2 Training Config)

When the training loop is implemented in v2:
- Change `lora_alpha` from 16 to **32** (2x rank, per Unsloth's explicit recommendation)
- Add `use_gradient_checkpointing = "unsloth"` (30% memory savings over standard)
- Set `lora_dropout = 0` (unreliable for short runs per arxiv 2410.09692)
- Use `max_steps` as primary training limiter (not epochs), calculated from `cycle_minutes`
- Target all 7 linear layers: `q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj`
- Use `save_total_limit = 3` to prevent checkpoint disk bloat
- Default `learning_rate = 2e-4`, `per_device_train_batch_size = 2`, `gradient_accumulation_steps = 8`

### Institutional Learnings Applied

**From DAG architecture learning:**
- Single-writer invariant: Phase 7.6 is the sole intern DAG writer. Remove the conflicting statement about report-compiler writing intern DAG nodes.
- Add explicit re-read instruction between intern DAG write and convergence computation in Phase 7.6
- Add staleness hashing to intern DAG nodes (reuse `codebase_hash` pattern from real DAG)
- First-run test: what happens when intern is enabled but no intern DAG exists yet?

**From command-agent contract learning:**
- Delegation blocks duplicated across commands is the exact pattern that caused 7 P0/P1 bugs. Extract to shared skill.
- Add idempotency acceptance criterion: "Running every phase twice with no changes produces no duplicates"
- Add boundary value tests for all promotion/demotion thresholds
- Validate `source_files` in intern DAG nodes against filesystem before writing

## Sources & References

### Internal References
- DAG schema and crash-safe protocol: `schemas/dag-schema.json`, `docs/solutions/architecture-decisions/research-dag-cross-session-memory.md`
- Optional feature integration pattern: `docs/solutions/build-errors/parallel-worktree-rust-compilation.md`
- Command-agent contract pitfalls: `docs/solutions/feature-enhancements/2026-03-15-nerd-this-command-context-scanner-agent.md`
- Existing agent delegation patterns: `agents/parameter-scanner.md`, `agents/report-compiler.md`

### External References
- [Qwen 3.5 Small Model Series](https://blog.mean.ceo/qwen-3-5-small-model-series-release/)
- [Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct) — 82.6% HumanEval at 3.8B params
- [Gemma 3 270M](https://developers.googleblog.com/en/introducing-gemma-3-270m/)
- [Qwen3.5 Fine-tuning with Unsloth](https://unsloth.ai/docs/models/qwen3.5/fine-tune)
- [MLX-LM Fine-tuning on Mac](https://markaicode.com/run-fine-tune-llms-mac-mlx-lm/)
- [Best Open Source LLMs for Coding 2026](https://www.siliconflow.com/articles/en/best-open-source-LLMs-for-coding)
- [Ollama vs vLLM Performance Benchmarking](https://developers.redhat.com/articles/2025/08/08/ollama-vs-vllm-deep-dive-performance-benchmarking) — vLLM 3-6x throughput at high concurrency
- [Profiling QLoRA on Consumer GPUs (RTX 4060)](https://arxiv.org/abs/2509.12229) — 1.5B model: 10K tokens in 15.9s
- [LLM Confidence via Logprobs](https://ericjinks.com/blog/2025/logprobs/) — practical confidence extraction
- [5 Methods for Calibrating LLM Confidence](https://latitude.so/blog/5-methods-for-calibrating-llm-confidence-scores)
- [BigCode Evaluation Harness](https://github.com/bigcode-project/bigcode-evaluation-harness) — pass@k methodology

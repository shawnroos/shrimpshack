---
name: nerd-setup
description: "One-time global setup for the nerd plugin. Detects hardware, installs the training variant (MLX for Apple Silicon, original for NVIDIA), runs calibration benchmarks, and saves a hardware profile. Only needs to run once per machine — projects auto-initialize on first /nerd run."
allowed-tools: "Read,Write,Edit,Bash,Glob,Grep,AskUserQuestion,Agent"
---

# Nerd Setup

Run first-time setup for the nerd plugin. This command:
1. Detects hardware capabilities
2. Installs the appropriate training variant
3. Runs calibration benchmarks
4. Saves a hardware profile
5. Initializes the project research structure

## Step 1: Detect Hardware

```bash
# Detect platform
uname -s  # Darwin or Linux

# Detect chip
system_profiler SPHardwareDataType 2>/dev/null | grep -E "Chip|Memory|Model"

# Detect GPU
# macOS: check for Apple Silicon
sysctl -n machdep.cpu.brand_string 2>/dev/null

# Linux: check for NVIDIA
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null
```

Classify the hardware:

| Hardware | Training Variant | Expected Performance |
|----------|-----------------|---------------------|
| Apple Silicon M1 (16GB) | autoresearch-mlx | ~3-4 experiments/hour |
| Apple Silicon M1 Pro/Max (32GB+) | autoresearch-mlx | ~6-8 experiments/hour |
| Apple Silicon M2/M3/M4 | autoresearch-mlx | ~8-12 experiments/hour |
| NVIDIA GPU (24GB+) | autoresearch (original) | ~8-12 experiments/hour |
| NVIDIA GPU (80GB+, H100) | autoresearch (original) | ~12+ experiments/hour |
| No GPU / CPU only | Skip LLM training | Codebase experiments only |

## Step 2: Install Nerd Training

Based on hardware detection:

### Apple Silicon (MLX variant)
```bash
# Check if already installed
if [ -d "$HOME/projects/autoresearch-mlx" ]; then
    echo "autoresearch-mlx already installed"
else
    cd ~/projects
    git clone https://github.com/trevin-creator/autoresearch-mlx.git
    cd autoresearch-mlx

    # Check Python version compatibility (needs <3.14)
    python_version=$(python3 --version | grep -oP '\d+\.\d+')

    # Install with compatible Python
    if command -v uv &>/dev/null; then
        uv sync --python 3.12 2>&1 || uv sync 2>&1
    else
        echo "Installing uv first..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        uv sync --python 3.12 2>&1
    fi

    # Prepare data
    uv run prepare.py
fi
```

### NVIDIA (Original variant)
```bash
if [ -d "$HOME/projects/autoresearch" ]; then
    echo "autoresearch already installed"
else
    cd ~/projects
    git clone https://github.com/karpathy/autoresearch.git
    cd autoresearch
    uv sync
    uv run prepare.py
fi
```

### No GPU
Inform the user: "No GPU detected. LLM training experiments via /nerd will be skipped. Codebase parameter experiments will still work."

## Step 3: Hardware Calibration

Run a calibration benchmark to establish this machine's performance profile.

### For LLM Training (if GPU available)

```bash
cd ~/projects/autoresearch-mlx  # or autoresearch
```

**Memory calibration:**
Check available memory and determine the maximum safe eval batch size:

```bash
# macOS: get total memory
memory_gb=$(sysctl -n hw.memorysize 2>/dev/null | awk '{print $1/1073741824}')

# Metal max buffer size is ~75% of total memory
# Eval batch size must fit within this
```

| Total Memory | Max Eval Batch Size | Model Size Headroom |
|-------------|--------------------|--------------------|
| 8 GB | 16 | Very constrained |
| 16 GB | 64 | Limited — depth ≤ 4 |
| 32 GB | 128 | Comfortable |
| 64 GB+ | 256 | Full default |

If the current `FINAL_EVAL_BATCH_SIZE` in `train.py` exceeds the safe limit for this hardware, update it.

**Timing calibration:**
Run one baseline experiment to measure actual performance:

```bash
uv run train.py 2>&1
```

Extract from output:
- `val_bpb` — baseline quality
- `training_seconds` — actual training time
- `total_seconds` — total time including compile + eval
- `peak_vram_mb` — peak memory usage
- `num_steps` — steps completed in 5-minute budget
- `num_params_M` — model parameter count

### Build Cache Tools

Detect available compilation cache tools for compiled languages:

```bash
# sccache — compilation cache (Rust, C/C++)
SCCACHE_PATH=$(which sccache 2>/dev/null)
SCCACHE_VERSION=$(sccache --version 2>/dev/null | head -1)

# ccache — compilation cache (C/C++)
CCACHE_PATH=$(which ccache 2>/dev/null)
```

These are recorded in the hardware profile so lab-tech Check 7 can read them without re-detecting every run. Only relevant for compiled languages — Python, TypeScript, and Go have built-in caching.

### For Codebase Experiments

Run a quick compile + test timing:

```bash
# Detect build system and time a build + test cycle
if [ -f "Cargo.toml" ]; then
    time cargo build 2>&1 | tail -3
    time cargo test 2>&1 | tail -3
elif [ -f "package.json" ]; then
    time bun run typecheck 2>&1 | tail -3
    time bun test 2>&1 | tail -3
elif [ -f "pyproject.toml" ]; then
    time python -m py_compile $(find . -name '*.py' -not -path './.*' | head -5) 2>&1
    time pytest 2>&1 | tail -3
elif [ -f "go.mod" ]; then
    time go build ./... 2>&1 | tail -3
    time go test ./... 2>&1 | tail -3
fi
```

## Step 4: Save Hardware Profile

Write the calibration results to the global nerd config:

```bash
mkdir -p ~/.claude/plugins/nerd/logs
```

Ensure machine-specific files are never committed. Create or update `.gitignore` in the plugin directory:

```bash
cat > ~/.claude/plugins/nerd/.gitignore << 'EOF'
hardware-profile.yaml
global-queue.yaml
logs/
dag/
EOF
```

**Initialize the Research DAG directory:**

```bash
mkdir -p ~/.claude/plugins/nerd/dag/projects

# Create global index if it doesn't exist
if [ ! -f ~/.claude/plugins/nerd/dag/index.json ]; then
    echo '{"nodes":[],"edges":[],"version":1}' > ~/.claude/plugins/nerd/dag/index.json
fi
```

Write to `~/.claude/plugins/nerd/hardware-profile.yaml`:

```yaml
# Auto-generated by /nerd-setup
# Re-run /nerd-setup to recalibrate

hardware:
  platform: darwin          # darwin or linux
  chip: "Apple M1 Pro"
  memory_gb: 16
  gpu_type: apple_silicon   # apple_silicon, nvidia, none

llm_training:
  variant: autoresearch-mlx
  install_path: ~/projects/autoresearch-mlx
  eval_batch_size: 64
  baseline_val_bpb: 2.793067
  steps_per_5min: 3
  total_seconds_per_experiment: 1156
  experiments_per_hour: 3.1
  peak_memory_mb: 11024
  model_params_M: 11.5
  model_depth: 4

codebase:
  build_time_seconds: 6.5
  test_time_seconds: 12.3
  test_count: 477
  language: auto-detected              # rust, typescript, python, go, etc.

cache_tools:
  sccache: null                        # path if installed, relevant for Rust/C/C++
  sccache_version: null
  ccache: null                         # path if installed, relevant for C/C++

calibrated_at: "2026-03-14T00:00:00Z"
```

## Step 5: Verify and Report

Display the setup summary:

```
Nerd Setup Complete
═══════════════════════════

Hardware: {chip} ({memory_gb}GB)
GPU: {gpu_type}
LLM Training: {variant} installed at {install_path}
  Baseline: val_bpb {baseline} | {steps}/5min | ~{rate} experiments/hour
  Eval batch: {eval_batch_size}

Hardware profile saved to: ~/.claude/plugins/nerd/hardware-profile.yaml

Launching the nerd on this codebase...
```

## Step 6: Launch /nerd Immediately

After setup completes, run the full nerd pipeline on the current project without waiting for the user to type another command:

```
Skill(skill="nerd")
```

This auto-initializes the project (creates `docs/research/`, `.claude/nerd.local.md`) and starts the scan → plan → execute → report pipeline. The user goes from zero to running experiments in one command.

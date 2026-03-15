---
name: nerd-status
description: "Check the status of the nerd queue, running experiments, and backlog. Shows progress, completed findings, and pending proposals."
allowed-tools: "Read,Bash,Glob"
---

# Nerd Status

Display the current state of the nerd pipeline.

## Read Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

Parse the YAML frontmatter for backlog entries.

## Check Worktrees

```bash
git worktree list 2>/dev/null | grep "nerd-"
```

## Check Results

```bash
ls docs/research/results/*.json 2>/dev/null | wc -l
ls docs/research/*-report.md 2>/dev/null | wc -l
```

## Display Status

Format output as:

```
Nerd Status
═══════════════════

Backlog:
  Proposed: {count}
  Planned:  {count}
  Running:  {count}
  Complete: {count}
  Failed:   {count}

Active Worktrees:
  worktrees/nerd-E001 → nerd/E001 (running)
  worktrees/nerd-E002 → nerd/E002 (running)

Recent Findings:
  E001: JW threshold optimal at 0.85 [KEEP]
  E002: RRF k=40 beats k=60 by 3% [CHANGE]

Reports: docs/research/
```

If backlog is empty: "No research backlog. Run /nerd to analyze the codebase."

## Intern Status (if configured)

Check if intern is enabled:

```bash
grep -q "intern:" .claude/nerd.local.md 2>/dev/null && grep -q "enabled: true" .claude/nerd.local.md 2>/dev/null
```

If intern is enabled, read state and display:

```bash
cat .nerd/intern/state.json 2>/dev/null
```

```bash
# Health check
ENDPOINT=$(grep 'endpoint:' .claude/nerd.local.md | head -1 | awk '{print $2}')
BASE_URL="${ENDPOINT%/chat/completions}"
curl -s -m 5 "${BASE_URL}/models" 2>/dev/null
```

```bash
# Training data counts
for task in parameter-detection result-classification context-extraction; do
  wc -l < ".nerd/intern/training-data/${task}.jsonl" 2>/dev/null || echo "0"
done
```

Display intern section:

```
Intern: {model} via {provider}
  Endpoint: {endpoint} {healthy/unhealthy}
  Tasks:
    param-detection:    {acc}% {mode}  ({shadow_window_size} shadow comparisons)
    result-classif.:    {acc}% {mode}  ({shadow_window_size} shadow comparisons)
    context-extraction: {acc}% {mode}  ({shadow_window_size} shadow comparisons)
  Last run: {delegated} delegated, {fallbacks} fallback(s)
  Training data: {total} examples
  Claude calls saved: {lifetime_count}
```

If intern not configured, show nothing (don't clutter status for users who haven't opted in).

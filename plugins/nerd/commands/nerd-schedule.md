---
name: nerd-schedule
description: "Schedule nerd experiments to run at specific times (e.g., overnight). Uses macOS LaunchAgent for scheduling."
argument-hint: "[tonight|weeknights|HH:MM-HH:MM|cancel]"
allowed-tools: "Read,Write,Bash,AskUserQuestion"
---

# Nerd Schedule

Schedule when experiments run. Supports overnight windows and recurring schedules.

## Input

<time_spec>$ARGUMENTS</time_spec>

## Parse Time Spec

- `tonight` / `overnight` → 22:00 to 06:00 today
- `weeknights` → Recurring M-F 22:00-06:00
- `HH:MM-HH:MM` → Custom window (e.g., `23:00-05:00`)
- `cancel` / `stop` → Remove scheduled runs
- Empty → Show current schedule and ask

**Time handling:** If `tonight` is specified and the start hour has already passed, check the current time:
- If still within the window (e.g., it's 23:20 and window is 22:00-06:00), start immediately by setting the trigger to 5 minutes from now.
- If the window has fully passed, schedule for tomorrow and inform the user.

## Check Prerequisites

```bash
cat ~/.claude/plugins/nerd/hardware-profile.yaml 2>/dev/null | grep experiments_per_hour
```

If no hardware profile: "Run /nerd-setup first."

## Calculate Capacity

```
experiments_per_hour = {from hardware profile}
window_hours = (stop - start)
capacity = experiments_per_hour * window_hours
```

**Build cache adjustment:** Check the project's `.claude/nerd.local.md` for `build_cache_strategy` and `build_time_warm_seconds`. If a cache strategy is active (sccache or target_copy), the effective build time per experiment is lower, increasing throughput:

```
# If build cache is available:
effective_build_time = build_time_warm_seconds   # from nerd.local.md (e.g., 12s)
# Otherwise:
effective_build_time = build_time_seconds         # from hardware profile (e.g., 180s)

# Adjusted rate (if hardware profile has per-experiment timing):
# Use measured agent_overhead_seconds from hardware profile if available, else default 60s
agent_overhead = agent_overhead_seconds from hardware profile, or 60 if not yet measured
adjusted_experiments_per_hour = 60 / ((effective_build_time + test_time_seconds + agent_overhead) / 60)
```

Use `adjusted_experiments_per_hour` for capacity calculation when cache config is present. The overhead value is self-correcting — after each batch run, the report-compiler computes median actual overhead from DAG timestamps and writes it back to the hardware profile. Display the adjustment in the confirmation output.

## Register in Global Queue

Multiple projects on this machine may schedule nerd. The global queue coordinates:

```bash
QUEUE="$HOME/.claude/plugins/nerd/global-queue.yaml"
```

When scheduling, append this project's backlog experiments to the global queue:

```yaml
queue:
  - project: "{cwd}"
    experiment_id: "{id}"
    priority: medium
    status: pending
    estimated_minutes: {est}
```

**Concurrency rules** (enforced by the runner):
- `max_codebase_experiments`: derived from hardware profile — `floor((memory_gb - 2) / 2)`, clamped to 2-8. Batch mode uses a smaller reserve (2GB) than interactive (4GB) since no user workload competes. Falls back to 4 if no hardware profile.
- `max_per_project`: equals `max_codebase_experiments` when only one project is queued (no capacity waste for solo developers); otherwise `ceil(max_codebase_experiments / active_project_count)` for fair sharing.
- Round-robin within priority tiers for fairness across projects

Show global queue state before confirming:
```
Global Queue: {N} experiments across {M} projects
  Arras: 6 pending (~4.5 hrs)
  Jeans: 2 pending (~1.5 hrs)
```

## Create Runner Script

```bash
mkdir -p ~/.claude/plugins/nerd/scripts ~/.claude/plugins/nerd/logs

cat > ~/.claude/plugins/nerd/scripts/scheduled-run.sh << 'RUNNER'
#!/bin/bash
# Nerd scheduled runner — resilient to transient failures

LOG="$HOME/.claude/plugins/nerd/logs/$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date): $1" >> "$LOG"; }

log "Nerd starting (project: $PROJECT_DIR)"

if [ -z "${PROJECT_DIR:-}" ]; then
    log "ERROR: PROJECT_DIR not set. Exiting."
    exit 1
fi

cd "$PROJECT_DIR" || { log "ERROR: Cannot cd to $PROJECT_DIR"; exit 1; }

# Run with retry on transient failures (max 3 attempts)
attempt=0
max_attempts=3
while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    log "Attempt $attempt/$max_attempts"

    NERD_SCHEDULED=1 claude --print --allow-dangerously-skip-permissions --dangerously-skip-permissions -p "
Run /nerd. Execute all backlog experiments autonomously.
Use /loop 5m to monitor agents. Merge completed experiments.
When all done, compile reports and exit.
Never ask questions — make all decisions autonomously.
" >> "$LOG" 2>&1

    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        log "Nerd completed successfully"
        break
    else
        log "WARNING: claude exited with code $exit_code"
        if [ "$attempt" -lt "$max_attempts" ]; then
            # Exponential backoff with jitter: ~10s, ~45s
            base_delay=$((10 * (2 ** (attempt - 1))))
            jitter=$((RANDOM % (base_delay / 2 + 1)))
            delay=$((base_delay + jitter))
            log "Retrying in ${delay} seconds (backoff attempt $attempt)..."
            sleep "$delay"
        else
            log "ERROR: All $max_attempts attempts failed"
        fi
    fi
done

log "Nerd session ended"
RUNNER

chmod +x ~/.claude/plugins/nerd/scripts/scheduled-run.sh
```

## Register LaunchAgent

```bash
PLIST="$HOME/Library/LaunchAgents/com.nerd.scheduled.plist"

cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nerd.scheduled</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HOME}/.claude/plugins/nerd/scripts/scheduled-run.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NERD_SCHEDULED</key>
        <string>1</string>
        <key>PROJECT_DIR</key>
        <string>{cwd}</string>
        <key>PATH</key>
        <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StartCalendarInterval</key>
    {calendar_interval_entries}
    <key>StandardOutPath</key>
    <string>${HOME}/.claude/plugins/nerd/logs/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.claude/plugins/nerd/logs/launchd-err.log</string>
    <key>Nice</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

launchctl load "$PLIST"
```

**Calendar interval entries by schedule type:**
- `tonight`: Single `<dict>` with today's weekday + start hour
- `weeknights`: Five `<dict>` entries for Mon(1)-Fri(5) at start hour
- Custom: Single daily entry at start hour

## Confirm

```
Nerd Scheduled
  Window: {start} - {stop}
  Capacity: ~{capacity} experiments per window
  Project: {cwd}
  Logs: ~/.claude/plugins/nerd/logs/

  /nerd-status to check progress
  /nerd-schedule cancel to remove
```

## Cancel

```bash
launchctl unload ~/Library/LaunchAgents/com.nerd.scheduled.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.nerd.scheduled.plist 2>/dev/null
echo "Schedule cancelled."
```

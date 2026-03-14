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
- `max_codebase_experiments: 4` — total parallel across ALL projects
- `max_per_project: 2` — prevent one project hogging the window
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

    NERD_SCHEDULED=1 claude --print --dangerously-skip-permissions -p "
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
            log "Retrying in 30 seconds..."
            sleep 30
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
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
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

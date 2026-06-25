#!/bin/bash
# Reflect trigger hook — writes a flag file when completion events fire.
# Coalesces within a 10-minute window so clusters of events trigger one reflect.

FLAG="$HOME/.claude/.reflect-pending"
WINDOW=600  # 10 minutes in seconds

# Read the trigger reason from arg or env
REASON="${1:-unknown}"

# If flag already exists and is fresh (< 10 min old), don't overwrite — coalesce.
if [ -f "$FLAG" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$FLAG" 2>/dev/null || echo 0) ))
    if [ "$AGE" -lt "$WINDOW" ]; then
        # Append to existing flag instead of overwriting
        echo "$REASON @ $(date -Iseconds) [coalesced]" >> "$FLAG"
        exit 0
    fi
fi

# Fresh flag
echo "$REASON @ $(date -Iseconds)" > "$FLAG"

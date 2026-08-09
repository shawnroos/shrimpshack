#!/usr/bin/env bash
# trigger-nudge.sh — PostToolUse(Bash) hook. If the command an agent just ran
# matches a trigger a memory DECLARED, emit a one-or-two-line pointer nudge.
#
# Fires on every Bash call (~453 in the motivating session), so the cheap bails
# come first and in this order:
#   1. no compiled manifest      -> exit 0 before anything is spawned
#   2. no jq                     -> exit 0 (extraction is jq's only job here)
#   3. empty command             -> exit 0
# python3 is spawned only once all three pass.
#
# Input is JSON on STDIN — `$TOOL_INPUT` does NOT exist for `"type": "command"`
# hooks (it is real only for `"type": "prompt"` hooks), and a matcher written
# against it greps an empty string and never fires. Stdin is saved to a temp file
# and read twice rather than held in a shell variable: `echo "$json" | jq` mangles
# backslashes, and a Bash command is exactly the payload full of them.
#
# Output is the JSON `hookSpecificOutput` shape, NOT seeded-recall.sh's raw-stdout
# idiom: raw stdout is an injection channel for `UserPromptSubmit` only, while
# PostToolUse stdout goes to the transcript rather than to the model.
# `additionalContext` is confirmed real for PostToolUse on the running build.
# The JSON is assembled in python and passed through untouched — building it in
# shell would mean escaping arbitrary memory text into a JSON string by hand.
#
# Fail-open ALWAYS: every path exits 0. A nudge that cannot be produced is a
# non-event; a hook that returns non-zero is a broken session.
#
#   env: MEMORY_DIR                 override the store (tests)
#        MEMORY_TRIGGER_FLAG_DIR    override the per-session dedupe flag dir
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ -n "${MEMORY_DIR:-}" ]; then
  STORE="$MEMORY_DIR"
else
  SLUG="-${HOME#/}"
  SLUG="${SLUG//\//-}"
  STORE="$HOME/.claude/projects/$SLUG/memory"
fi

# 1. No manifest -> nothing can match. This is also the fail-open answer for a
#    store that has never compiled one.
[ -f "$STORE/TRIGGERS.json" ] || exit 0

# 2. jq is the extractor. Absent -> exit 0 (same posture as the sibling matcher).
command -v jq >/dev/null 2>&1 || exit 0

TMPIN="$(mktemp -t trigger-nudge 2>/dev/null)" || exit 0
trap 'rm -f "$TMPIN"' EXIT
cat > "$TMPIN" 2>/dev/null || exit 0

CMD="$(jq -r '.tool_input.command // empty' < "$TMPIN" 2>/dev/null)" || exit 0
SESSION="$(jq -r '.session_id // empty' < "$TMPIN" 2>/dev/null)" || true

# 3. Nothing to match against.
[ -n "$CMD" ] || exit 0

# `printf '%s'` does not interpret escapes in its ARGUMENT, so a command full of
# backslashes reaches python byte-for-byte.
printf '%s' "$CMD" | python3 "$PLUGIN_ROOT/scripts/scoped-memory/triggers.py" \
  match --store "$STORE" --session "${SESSION:-}" --cwd "$PWD" 2>/dev/null || true

exit 0

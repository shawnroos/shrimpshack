#!/usr/bin/env bash
# fake-claude.sh — stand-in for the `claude` binary in gateway plugin tests.
#
# lib/launch.sh materializes a session by running a seed prompt headlessly
# through `claude`. Pointing launch.sh at this script instead lets the whole
# launch path — session-id capture, transcript resolution, the resume handle —
# run with no real CLI, no real gateway, and no spend.
#
# WHY IT RECORDS ARGV AND ENV
# KTD6 says the gateway token never appears in a process argument, because argv
# is readable from the process table by any other process on the box. A claim
# like that is only worth what asserts it, so this fixture writes down exactly
# what it was invoked with and U3/U4 assert the token literal is absent from
# the argv record and present only in the env record.
#
# Records APPEND, never truncate: the attach test invokes this twice (launch,
# then the printed attach command) and asserts across both invocations.
#
# Environment:
#   FAKE_CLAUDE_RECORD_DIR   where argv/env/cwd records land
#                            (default: $TMPDIR/fake-claude-record)
#   FAKE_CLAUDE_PROJECTS_ROOT  test-controlled stand-in for ~/.claude/projects
#                            (default: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects)
#   FAKE_CLAUDE_SESSION_ID   session id to emit (default: a deterministic fake)
#   FAKE_CLAUDE_MODE         ok | fail | error | hang   (default: ok)
#                            fail exits 1 with stderr, for the "seed run failed,
#                            never print a handle to a session that does not
#                            exist" case
#                            error exits 0 but reports is_error=true in the
#                            result JSON — the CLI's own "this turn failed"
#                            shape, which launch.sh must refuse to print a
#                            handle for (R8)
#                            hang writes its pid to $REC_DIR/pid, then execs a
#                            long sleep — for the R2 deadline/reap tests, whose
#                            assertions need the pid of the thing that must die
#   FAKE_CLAUDE_RESULT_TEXT  the assistant text in the result JSON
#
# Transcript path encoding mirrors Claude Code: the session's project directory
# is the absolute cwd with every non-alphanumeric byte replaced by '-', so
# /Users/x/p -> -Users-x-p. launch.sh must derive the path with the SAME rule,
# which is why it is stated here rather than left implicit.

set -euo pipefail

MODE="${FAKE_CLAUDE_MODE:-ok}"
REC_DIR="${FAKE_CLAUDE_RECORD_DIR:-${TMPDIR:-/tmp}/fake-claude-record}"
SESSION_ID="${FAKE_CLAUDE_SESSION_ID:-11111111-2222-3333-4444-555555555555}"
RESULT_TEXT="${FAKE_CLAUDE_RESULT_TEXT:-fixture seed answer}"

mkdir -p "$REC_DIR"

# --- record the invocation -------------------------------------------------
{
  echo "--- invocation $(date +%s) ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$REC_DIR/argv"

{
  echo "--- invocation $(date +%s) ---"
  env
} >> "$REC_DIR/env"

printf '%s\n' "$PWD" >> "$REC_DIR/cwd"

# --- parse the flags launch.sh uses ---------------------------------------
model=""
prompt=""
output_format=""
resume=""
prev=""
for a in "$@"; do
  case "$prev" in
    --model) model="$a" ;;
    --output-format) output_format="$a" ;;
    -p|--print) prompt="$a" ;;
    --resume) resume="$a" ;;
  esac
  prev="$a"
done

if [[ "$MODE" == "fail" ]]; then
  echo "fake-claude: seed run failed (FAKE_CLAUDE_MODE=fail)" >&2
  exit 1
fi

if [[ "$MODE" == "hang" ]]; then
  # exec, so the recorded pid IS the sleeping process — a TERM to it ends the
  # hang directly instead of orphaning a child sleep.
  printf '%s\n' "$$" >> "$REC_DIR/pid"
  exec sleep 600
fi

# A resume run reuses the session it was handed rather than minting a new one —
# that is what makes the handle's promise ("this resumes the same session")
# assertable end to end.
if [[ -n "$resume" ]]; then
  SESSION_ID="$resume"
fi

# --- write the fake transcript --------------------------------------------
projects_root="${FAKE_CLAUDE_PROJECTS_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
encoded="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
transcript_dir="$projects_root/$encoded"
mkdir -p "$transcript_dir"
transcript="$transcript_dir/$SESSION_ID.jsonl"
{
  printf '{"type":"user","sessionId":"%s","cwd":"%s","message":{"role":"user","content":%s}}\n' \
    "$SESSION_ID" "$PWD" "$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  printf '{"type":"assistant","sessionId":"%s","cwd":"%s","message":{"role":"assistant","model":"%s","content":[{"type":"text","text":%s}]}}\n' \
    "$SESSION_ID" "$PWD" "$model" \
    "$(printf '%s' "$RESULT_TEXT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
} >> "$transcript"

# --- emit the result -------------------------------------------------------
# Shape follows `claude -p --output-format json`. U4 treats this shape as an
# observed contract, not a guarantee: the fixture pins what launch.sh relies on
# so real-CLI drift surfaces as a test failure instead of a silent miss.
if [[ "$output_format" == "json" ]]; then
  # In error mode the CLI exits 0 but the result object says the turn FAILED —
  # a real shape (`claude -p` reports tool/turn failures this way), and the one
  # launch.sh's is_error branch exists for (R8).
  python3 - "$SESSION_ID" "$RESULT_TEXT" "$model" "$MODE" <<'PY'
import json, sys
session_id, result, model, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    "type": "result",
    "subtype": "error_during_execution" if mode == "error" else "success",
    "is_error": mode == "error",
    "num_turns": 1,
    "session_id": session_id,
    "result": result,
    "model": model,
    "usage": {"input_tokens": 11, "output_tokens": 7},
}))
PY
else
  printf '%s\n' "$RESULT_TEXT"
fi

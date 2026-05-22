#!/usr/bin/env bash
# claude-modes V2 (U11): PostToolUse Write hook — R20 adoption-consent prompt
# for Claude-tool writes into ~/.claude/commands/ or ~/.claude/agents/.
#
# Contract: ALWAYS exits 0 (rel-001). PostToolUse hooks must never block
# the harness.
#
# Behavior:
#   1. Presence gate: silent exit if ~/.claude/modes/ is absent.
#   2. Read PostToolUse event JSON from stdin (tool_name + tool_input + tool_response).
#   3. Filter:
#        - tool_name == "Write"
#        - file_path under ~/.claude/commands/*.md or ~/.claude/agents/*.md
#          (realpath + boundary check via Python)
#        - basename does NOT match excluded patterns: .tmp-*, *.backup, .draft-*
#        - target is not already a symlink into .user-catalog/
#      Any filter miss → silent exit 0.
#   4. Determine interactivity:
#        - non-interactive iff stdin is NOT a TTY AND CLAUDE_NON_INTERACTIVE != "0"
#          (the explicit "0" lets test harnesses force interactive mode)
#        - non-interactive → exit 0 silently. File stays global.
#          (security-lens default-N safety; no consent without confirmation.)
#   5. Interactive prompt with default N:
#        "Tag /<basename> as a <active-mode>-mode <commands|agents>? [y/N]"
#      Read 1 char from /dev/tty. Test override:
#        CLAUDE_MODES_ADOPT_ASSUME_YES=1 → treat as y without reading TTY.
#   6. On y/Y → invoke lib/adopt-file.sh; audit source=post-tool-use.
#      On N or anything else → audit "adopt_skip" with reason=user-N.
#
# Test harness note (advisor finding): /dev/tty redirection isn't reliably
# scriptable from `read -n 1 < /dev/tty`. CLAUDE_MODES_ADOPT_ASSUME_YES=1 is
# the test-only env var that simulates the Y branch without TTY plumbing.
# It is documented here and in the test file but is NOT a user-facing API.

set -uo pipefail

# ── 1. Presence gate ─────────────────────────────────────────────────
[ -d "${HOME}/.claude/modes" ] || exit 0

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/audit.sh
. "${PLUGIN_ROOT}/lib/audit.sh"
# shellcheck source=../lib/active-mode.sh
. "${PLUGIN_ROOT}/lib/active-mode.sh"  # sec-005: read_validated_mode_body
# shellcheck source=../lib/sanitize.sh
. "${PLUGIN_ROOT}/lib/sanitize.sh"     # terminal-escape: claude_modes::sanitize_for_display

# Stage stdin to a tempfile so we can re-parse fields without consuming
# stdin (which we may need to inspect for TTY-ness).
stdin_tmp=$( (umask 077 && mktemp -t claude-modes-postwrite.XXXXXX) ) || exit 0
trap 'rm -f "$stdin_tmp"' EXIT

# Read whatever stdin holds (the PostToolUse event JSON, or empty if not
# invoked by Claude Code).
cat > "$stdin_tmp" 2>/dev/null || true

# ── 2. Extract tool_name + tool_input.file_path ──────────────────────
extract_fields() {
  "$CLAUDE_MODES_PYTHON3" - "$stdin_tmp" <<'PYEOF' 2>/dev/null || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f) or {}
except Exception:
    sys.exit(0)
tn = data.get("tool_name") or ""
ti = data.get("tool_input") or {}
fp = ti.get("file_path") or ""
sid = data.get("session_id") or ""
# Tab-separated so the shell can split with IFS.
sys.stdout.write(f"{tn}\t{fp}\t{sid}")
PYEOF
}

fields=$(extract_fields)
tool_name="${fields%%$'\t'*}"
session_id="${fields##*$'\t'}"
# Middle field (file_path) is everything between the first and last tab.
file_path="${fields#*$'\t'}"
file_path="${file_path%$'\t'*}"

[ "$tool_name" = "Write" ] || exit 0
[ -n "$file_path" ] || exit 0

# Tilde expansion just in case the harness passes "~/..." paths literally.
case "$file_path" in
  "~/"*) file_path="${HOME}/${file_path#~/}" ;;
esac

# ── 3. Path filter: under ~/.claude/{commands,agents}/*.md ───────────
commands_live="${HOME}/.claude/commands"
agents_live="${HOME}/.claude/agents"
user_catalog_root="${HOME}/.claude/modes/.user-catalog"

# Realpath via Python (macOS portability).
file_resolved=$("$CLAUDE_MODES_PYTHON3" -c \
  'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
  "$file_path" 2>/dev/null)
[ -n "$file_resolved" ] || exit 0

# Trailing-/ boundary check.
category=""
for boundary_base in "$commands_live:commands" "$agents_live:agents"; do
  dir="${boundary_base%:*}"
  cat="${boundary_base#*:}"
  resolved_dir=$("$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$dir" 2>/dev/null)
  [ -n "$resolved_dir" ] || continue
  case "$file_resolved" in
    "$resolved_dir"/*)
      category="$cat"
      break
      ;;
  esac
done
[ -n "$category" ] || exit 0

# Basename + extension filter.
basename=$(basename "$file_resolved")
case "$basename" in
  *.md) ;;
  *) exit 0 ;;
esac

# Temp-file exclusion patterns.
case "$basename" in
  .tmp-*|*.backup|.draft-*) exit 0 ;;
esac

# If the live path is already a symlink into .user-catalog/, this file
# is already adopted — nothing to do.
if [ -L "$file_path" ]; then
  link_resolved=$("$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$file_path" 2>/dev/null)
  resolved_uc=$("$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$user_catalog_root" 2>/dev/null)
  case "$link_resolved" in
    "$resolved_uc"/*) exit 0 ;;
  esac
fi

# Confirm the file actually exists as a regular file (not yet symlink).
# `[ -f X ]` follows symlinks; combine with `[ ! -L X ]`.
[ -f "$file_path" ] && [ ! -L "$file_path" ] || exit 0

# ── 4. Determine active mode (sec-005: edge-strip + validate) ────────
active_mode_file="${HOME}/.claude/modes/.last-active-mode"
active_mode=""
if [ -f "$active_mode_file" ]; then
  active_mode=$(claude_modes::read_validated_mode_body "$active_mode_file" 2>/dev/null) || active_mode=""
fi
# No active mode → nothing to scope to; silent exit.
[ -n "$active_mode" ] || exit 0

# ── agent-native-001: untagged-file marker for the agent ─────────────
# The adoption prompt is shown to the HUMAN via /dev/tty. When it's skipped
# (non-interactive) or declined, the only record was an audit event the
# AGENT can't see — breaking agent-native parity (anything the user is
# prompted about, the agent should be able to discover and act on). We write
# a one-shot session marker that lib/inject-prose.sh consumes verbatim into
# the next UserPromptSubmit's systemMessage, so the agent learns there's an
# untagged file and how to adopt it.
#
# session_key mirrors inject-prose.sh's derivation (session_id, else
# ppid-<PPID>). Parity is exact whenever the harness supplies session_id
# (the normal case). The ppid fallback is for off-harness invocation only;
# its parity gap is rel-002's scope, not this fix's.
session_key="${session_id:-ppid-${PPID:-noppid}}"
__sessions_dir="${HOME}/.claude/modes/.sessions"
__untagged_marker="${__sessions_dir}/${session_key}.untagged-files"

# Append a self-describing entry (inject-prose cats the marker verbatim, no
# header of its own — so the marker must carry its own header). The header
# is written once; entries accumulate across skips in the same session.
__note_untagged_file() {
  local reason="$1"
  mkdir -m 0700 -p "$__sessions_dir" 2>/dev/null || true
  if [ ! -f "$__untagged_marker" ]; then
    ( umask 077 && printf 'Untagged files written this session (not scoped to any mode):\n' > "$__untagged_marker" ) 2>/dev/null || return 0
  fi
  ( umask 077 && printf '  - %s (%s; would tag as %s-mode; %s)\n    Adopt with: /mode:adopt %s\n' \
      "$basename" "$category" "$active_mode" "$reason" "$file_path" >> "$__untagged_marker" ) 2>/dev/null || true
}

# ── 5. Interactivity gate ────────────────────────────────────────────
# Non-interactive iff: stdin is not a TTY AND CLAUDE_NON_INTERACTIVE != "0".
# (Most hooks run with stdin piped → -t 0 is false. The env var lets a
# test harness force "treat as interactive" by setting it to "0".)
is_interactive=0
if [ -t 0 ]; then
  is_interactive=1
fi
case "${CLAUDE_NON_INTERACTIVE:-}" in
  1) is_interactive=0 ;;
  0) is_interactive=1 ;;
esac

if [ "$is_interactive" -eq 0 ]; then
  # Default-N safety: never auto-adopt without user confirmation.
  claude_modes::audit_event "adopt_skip" \
    "file=${basename}" \
    "mode=${active_mode}" \
    "category=${category}" \
    "source=post-tool-use" \
    "reason=non-interactive" >/dev/null 2>&1 || true
  __note_untagged_file "skipped: non-interactive"
  exit 0
fi

# ── 6. Interactive prompt (or test-mode auto-yes) ────────────────────
answer=""
if [ "${CLAUDE_MODES_ADOPT_ASSUME_YES:-}" = "1" ]; then
  answer="y"
else
  # Print the prompt to /dev/tty so it surfaces in the user's terminal
  # regardless of how stdout is wired. Read 1 char from /dev/tty.
  printf 'Tag /%s as a %s-mode %s? [y/N] ' \
    "$(claude_modes::sanitize_for_display "$basename")" "$active_mode" "$category" > /dev/tty 2>/dev/null || exit 0
  # rel re-review: 5s timeout so an AFK user (TTY attached but absent) can't
  # block the PostToolUse hook until the harness SIGKILLs it. Timeout/read
  # failure → empty answer → treated as N (skip), writing the untagged marker
  # below. Mirrors the trust-gate's -t 30 pattern (cascade-engine.sh).
  read -r -t 5 -n 1 answer < /dev/tty 2>/dev/null || answer=""
  printf '\n' > /dev/tty 2>/dev/null || true
fi

case "$answer" in
  y|Y)
    # Delegate to adopt-file.sh; pass "post-tool-use" as source metadata.
    if bash "${PLUGIN_ROOT}/lib/adopt-file.sh" "$file_path" post-tool-use; then
      :
    else
      # adopt-file.sh prints its own error; we still exit 0 per rel-001.
      :
    fi
    ;;
  *)
    claude_modes::audit_event "adopt_skip" \
      "file=${basename}" \
      "mode=${active_mode}" \
      "category=${category}" \
      "source=post-tool-use" \
      "reason=user-N" >/dev/null 2>&1 || true
    __note_untagged_file "skipped: you declined the tag prompt"
    ;;
esac

exit 0

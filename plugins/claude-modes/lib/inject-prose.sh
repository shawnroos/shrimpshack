#!/usr/bin/env bash
# claude-modes V2: R25 UserPromptSubmit prose-injection logic.
#
# Invoked as: bash lib/inject-prose.sh <stdin-event-tmpfile>
#
# Reads:
#   - Event JSON (session_id, prompt) from the tmpfile.
#   - Active mode resolution from one of, in order:
#       a) <repo>/.claude/modes/<branch-slug>.mode      (per-branch state)
#       b) ~/.claude/modes/.last-active-mode             (user-global fallback)
#     If neither resolves, no active mode → no prose injection.
#   - Mode YAML at ~/.claude/modes/<mode>.yaml (via mode-yaml.sh).
#   - Pending one-time markers in ~/.claude/modes/.sessions/<session>.*
#     (.divergence-toast, .untagged-files) — consumed on read.
#   - One-time install notice ~/.claude/modes/.first-install.notice
#     (consumed on read).
#
# Writes:
#   - {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
#     "additionalContext": "..."}} JSON object on stdout (single line,
#     json.dumps for safe escaping). The harness inserts additionalContext
#     as a HIDDEN system-reminder Claude sees on the next model request;
#     the text does NOT appear in the chat transcript. (See Claude Code
#     Hooks reference, UserPromptSubmit output schema.)
#   - First-injection marker ~/.claude/modes/.sessions/<session>.injected
#     (used to suppress the "Active mode: <name>" header on subsequent
#     prompts in the same session).
#
# Contract:
#   - rel-001: always exits 0. UserPromptSubmit hooks must NEVER block prompts.
#     Every mutation is wrapped `|| true`; the terminal emit is wrapped too.
#   - 7-day marker pruning is owned by SessionStart (scripts/on-session-start.sh
#     runs `find .sessions -mtime +7 -delete`), not duplicated here.
#   - Per V1: no `set -e`. `set -uo pipefail` only; rely on explicit `|| true`.

set -uo pipefail

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/mode-yaml.sh
. "$SCRIPT_DIR/mode-yaml.sh"
# shellcheck source=lib/audit.sh
. "$SCRIPT_DIR/audit.sh"
# shellcheck source=lib/active-mode.sh
# Canonical active-mode resolver. Sourcing the full chain (active-mode →
# validate-mode-name + repo-root) costs <1ms/call (measured) — negligible
# against the ~6 python3 YAML re-parses this hook already does per prompt. No
# inline resolver/validator copies; read_active_mode_name is the one source of
# truth, shared with /mode:status and the statusline.
. "$SCRIPT_DIR/active-mode.sh"

# ──────────────────────────────────────────────────────────────────────────
# Helpers.

# Emit the prose as HIDDEN context to the next model call, wrapped in
# the documented Claude Code hook output envelope:
#
#   {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
#                            "additionalContext": "<msg>"}}
#
# The harness reads this and inserts <msg> as a system-reminder Claude
# sees on the next model request, but the text does NOT appear in the
# chat transcript. (See Claude Code Hooks reference, UserPromptSubmit
# output schema.)
#
# WHY NOT systemMessage: pre-fix this lib emitted {"systemMessage": "..."},
# which the docs document as "warning message shown to the user" — i.e.
# user-visible UI text, not hidden context. The harness duly rendered the
# whole prose block (active-mode header, philosophy, scope, lens, R31
# subagent-dispatch guidance) as visible chat content on every prompt
# ("⎿  UserPromptSubmit says: ..."). additionalContext is the right key.
#
# ensure_ascii=False keeps emoji as valid UTF-8 (RFC 7159) — V1 had a bug
# where the default True produced lone surrogate halves on macOS Python.
__emit_system_message() {
  local msg="$1"
  "$CLAUDE_MODES_PYTHON3" -c '
import sys, json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": sys.argv[1],
    }
}, ensure_ascii=False))
' "$msg"
}

# Extract a field from the event JSON.
# Args: <tmpfile> <field-name>
# Prints the field value on stdout (empty if missing/null/parse-error).
__extract_event_field() {
  local tmpfile="$1"
  local field="$2"
  "$CLAUDE_MODES_PYTHON3" - "$tmpfile" "$field" <<'PYEOF' 2>/dev/null || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f) or {}
except Exception:
    data = {}
v = data.get(sys.argv[2])
if v is None:
    sys.exit(0)
sys.stdout.write(str(v))
PYEOF
}


# Consume a one-shot marker file: print its contents, then delete it.
# If the file doesn't exist, prints nothing. Used for divergence-toast,
# untagged-files, and first-install.notice.
__consume_marker() {
  local marker_path="$1"
  if [ -f "$marker_path" ]; then
    cat "$marker_path" 2>/dev/null || true
    rm -f "$marker_path" 2>/dev/null || true
  fi
}

# Returns 0 (true) if this is the first injection for this session.
# Side-effect on first call: creates the .injected marker so subsequent
# prompts see this function return 1.
__is_first_injection() {
  local session_key="$1"
  local sessions_dir="${HOME}/.claude/modes/.sessions"

  # 0700 so only the user can read the marker filenames (which contain
  # session IDs — low-sensitivity but still bounded).
  mkdir -m 0700 -p "$sessions_dir" 2>/dev/null || true

  local marker="${sessions_dir}/${session_key}.injected"
  if [ -f "$marker" ]; then
    return 1
  fi
  ( umask 077 && : > "$marker" ) 2>/dev/null || true
  return 0
}

# Extract the leading slash-command token from a prompt (or empty).
# E.g. "  /ce-plan foo bar" → "/ce-plan"
# E.g. "/plugin:cmd" → "/plugin:cmd"
# E.g. "hello world" → ""
__extract_slash_command() {
  local prompt="$1"
  local trimmed
  trimmed="${prompt#"${prompt%%[! ]*}"}"  # strip leading spaces
  case "$trimmed" in
    /[a-zA-Z]*)
      printf '%s' "${trimmed%% *}"
      ;;
    *)
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────
# Main.

main() {
  local stdin_file="${1:-}"
  [ -n "$stdin_file" ] || exit 0
  [ -f "$stdin_file" ] || exit 0

  # Extract event fields.
  local session_id prompt
  session_id=$(__extract_event_field "$stdin_file" "session_id")
  prompt=$(__extract_event_field "$stdin_file" "prompt")

  # adv-3 carry-forward: if harness didn't pass a session_id, derive a
  # stable per-parent-process key so the first-injection marker still
  # debounces correctly within a single Claude Code session.
  local session_key="$session_id"
  if [ -z "$session_key" ]; then
    session_key="ppid-${PPID:-noppid}"
  fi

  # Resolve the active mode via the canonical resolver (active-mode.sh).
  # Empty string ⇒ no mode set anywhere. read_active_mode_name applies the
  # same gated repo-root walk + .mode-body validation as /mode:status and the
  # statusline — one source of truth, no inline copy.
  local mode_name
  mode_name=$(claude_modes::read_active_mode_name)

  # Consume one-time markers BEFORE we decide whether to inject. Markers
  # like a divergence toast should fire even if no mode is currently
  # active (the toast is the message that something happened).
  local sessions_dir="${HOME}/.claude/modes/.sessions"
  local divergence_marker="${sessions_dir}/${session_key}.divergence-toast"
  local untagged_marker="${sessions_dir}/${session_key}.untagged-files"
  local install_notice="${HOME}/.claude/modes/.first-install.notice"

  local divergence_text untagged_text install_text
  divergence_text=$(__consume_marker "$divergence_marker")
  untagged_text=$(__consume_marker "$untagged_marker")
  install_text=$(__consume_marker "$install_notice")

  # If neither an active mode nor any pending markers exist, exit silently.
  if [ -z "$mode_name" ] \
     && [ -z "$divergence_text" ] \
     && [ -z "$untagged_text" ] \
     && [ -z "$install_text" ]; then
    exit 0
  fi

  # Build the additionalContext body piece-by-piece (see header — emitted
  # via hookSpecificOutput.additionalContext, NOT systemMessage).
  local sections=()
  local is_first=0

  if [ -n "$mode_name" ]; then
    # Try to resolve & validate the mode YAML. Any failure → drop the mode
    # contribution gracefully (still emit pending-marker text if present).
    local yaml_file mode_yaml_ok=0
    if yaml_file=$(claude_modes::resolve_mode_file "$mode_name" 2>/dev/null) \
       && [ -n "$yaml_file" ] \
       && claude_modes::validate_schema_version "$yaml_file" 2>/dev/null; then
      mode_yaml_ok=1
    fi

    if [ "$mode_yaml_ok" = "1" ]; then
      # First-injection-per-session header.
      if __is_first_injection "$session_key"; then
        is_first=1
        sections+=("Active mode: ${mode_name} (${yaml_file})")
      fi

      # Prose layer: philosophy / scope / lens (whichever are present).
      local body=""
      local field val
      for field in philosophy scope lens; do
        val=$(claude_modes::get_field "$yaml_file" "$field" 2>/dev/null || true)
        if [ -n "$val" ]; then
          body+="${field^}: ${val}"$'\n\n'
        fi
      done

      # Constraints — bulleted.
      local constraints
      constraints=$(claude_modes::get_constraints "$yaml_file" 2>/dev/null || true)
      if [ -n "$constraints" ]; then
        body+="Constraints:"$'\n'
        while IFS= read -r c; do
          [ -n "$c" ] && body+="  - ${c}"$'\n'
        done <<< "$constraints"
        body+=$'\n'
      fi

      # Command-heuristic for the prompt's leading slash command, if any.
      local cmd_token
      cmd_token=$(__extract_slash_command "$prompt")
      if [ -n "$cmd_token" ] && claude_modes::has_heuristic "$yaml_file" "$cmd_token" 2>/dev/null; then
        local h_field h_val
        for h_field in focus bar behavior scope; do
          h_val=$(claude_modes::get_heuristic "$yaml_file" "$cmd_token" "$h_field" 2>/dev/null || true)
          if [ -n "$h_val" ]; then
            body+="Heuristic for ${cmd_token} (${h_field}): ${h_val}"$'\n'
          fi
        done
        body+=$'\n'
      fi

      # Subagent-dispatch guidance (R31): give primacy to mode-specified
      # agents and propagate the mode's lens to subagent dispatches. The
      # UserPromptSubmit hook only fires for the user's prompt to the main
      # agent; subagents dispatched via Task DO inherit the catalog (so they
      # see the same shrunken plugin set), but they DON'T automatically read
      # the active mode's philosophy/lens/constraints unless the orchestrator
      # forwards them in the dispatch prompt. This block makes that forwarding
      # explicit so subagents operate with the same framing as the parent.
      local mode_agents
      mode_agents=$(claude_modes::get_user_catalog "$yaml_file" agents 2>/dev/null || true)
      body+="When dispatching subagents via the Task tool while this mode is active:"$'\n'
      body+="  - Prepend the active mode's lens and constraints to the dispatch prompt so the subagent inherits the same framing as this conversation."$'\n'
      if [ -n "$mode_agents" ]; then
        # Names without the .md suffix — that is the subagent-type identifier.
        body+="  - Use these mode-specified agents (not generic alternatives) for in-mode work:"$'\n'
        while IFS= read -r a; do
          [ -n "$a" ] && body+="      - ${a%.md}"$'\n'
        done <<< "$mode_agents"
      fi
      body+="  - If the work being delegated falls OUTSIDE the active mode's scope (e.g., the user asks for debugging while in design mode), invoke the mode-suggester skill to surface a mode-switch suggestion before dispatching. In an autonomous context with no human present to confirm a switch, note the mismatch in your response and proceed in the current mode without blocking on AskUserQuestion."$'\n\n'

      # Trim a single trailing blank line for tidiness.
      body="${body%$'\n'}"
      [ -n "$body" ] && sections+=("$body")
    fi
  fi

  # Pending markers always emit if non-empty.
  [ -n "$install_text" ]    && sections+=("$install_text")
  [ -n "$divergence_text" ] && sections+=("$divergence_text")
  [ -n "$untagged_text" ]   && sections+=("$untagged_text")

  # If after all that we have nothing to say, exit silently.
  if [ "${#sections[@]}" -eq 0 ]; then
    exit 0
  fi

  # Join sections with a blank line separator.
  local system_message=""
  local sep=""
  local s
  for s in "${sections[@]}"; do
    system_message+="${sep}${s}"
    sep=$'\n\n'
  done

  # Best-effort audit — does NOT include prose, only event metadata.
  if [ -n "$mode_name" ]; then
    claude_modes::audit_event "prose_inject" \
      "mode=${mode_name}" \
      "first=$([ "$is_first" = "1" ] && echo Y || echo N)" \
      "session=${session_key}" >/dev/null 2>&1 || true
  fi

  # rel-001: terminal emit wrapped — never propagate non-zero up the chain.
  __emit_system_message "$system_message" || true
  exit 0
}

# Source-guard: run main only when executed, not when sourced. Tests source
# this file to exercise its helpers (__emit_system_message, __consume_marker)
# without firing main; without the guard, main's `exit 0` would terminate the
# sourcing shell before any test runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

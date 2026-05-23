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
#   - {"systemMessage": "..."} JSON object on stdout (single line, json.dumps
#     for safe escaping).
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

# ──────────────────────────────────────────────────────────────────────────
# Helpers.

# Emit {"systemMessage": "<msg>"} on stdout via Python json.dumps so we
# never hand-escape prose containing markdown, quotes, or unicode.
# ensure_ascii=False keeps emoji as valid UTF-8 (RFC 7159) — V1 had a bug
# where the default True produced lone surrogate halves on macOS Python.
__emit_system_message() {
  local msg="$1"
  "$CLAUDE_MODES_PYTHON3" -c '
import sys, json
print(json.dumps({"systemMessage": sys.argv[1]}, ensure_ascii=False))
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

# Resolve the active-mode name, returning empty string if none.
# Resolution order: per-branch (<repo>/.claude/modes/<branch-slug>.mode)
# then user-global (~/.claude/modes/.last-active-mode).
# Either source may be missing — fall through silently.
#
# Security (sec-001 P0): .mode file body is attacker-controllable via
# committed `.claude/modes/<slug>.mode` in a public repo. Body content
# is path-traversal-validated below (mirrors claude_modes::validate_name
# rules) before it leaves this function. Invalid bodies are treated as
# no-mode-active (silent rejection, no error to stderr — hooks must
# never block).
__inject_prose::validate_mode_body() {
  local name="$1"
  [ -z "$name" ] && return 1
  # "claude" is the Claude-Mode sentinel — accept as a valid marker even
  # though it's a reserved mode-name token. See _is_valid_mode_marker in
  # reconcile-symlinks.py for the same logic.
  [ "$name" = "claude" ] && return 0
  [ "${#name}" -gt 64 ] && return 1
  case "$name" in
    .|..|*..*) return 1 ;;
    [-_]*|*[-_]) return 1 ;;
  esac
  # Reserved tokens (other than the "claude" sentinel accepted above and
  # _global/_repo already caught by the underscore rule). Without this, the
  # read sites would resolve a .mode body of e.g. "setup"/"default" to a mode
  # while the canonical validator + reconcile-symlinks.py reject it — a
  # status-vs-reconcile disagreement (correctness re-review finding). Mirrors
  # CLAUDE_MODES_RESERVED_TOKENS in lib/validate-mode-name.sh (kept inline
  # for the UserPromptSubmit hot path; equivalence test guards drift).
  case "$name" in
    default|none|set|status|clear|apply|registry|adopt|setup|list|help|promote|rebuild|coverage)
      return 1 ;;
  esac
  if LC_ALL=C printf '%s' "$name" | grep -qE '[^A-Za-z0-9_-]'; then
    return 1
  fi
  return 0
}

# Read a .mode body and strip ONLY leading/trailing whitespace, mirroring
# Python's str.strip() at the reconcile-symlinks.py read site.
#
# sec-005: the old `tr -d '[:space:]'` deleted ALL whitespace including
# internal — so a body like "delivery x" became "deliveryx" (accepted)
# here while Python's .strip() kept "delivery x" (rejected by its regex).
# Two read sites resolving the same .mode file to different modes. Edge-only
# stripping lets internal whitespace reach the validator, which rejects it,
# so all read sites agree.
#
# Residual (accepted, non-security): sed strips per-LINE, and `$(...)` also
# trims trailing newlines, so a MULTI-LINE body (e.g. a leading blank line:
# "\ndelivery") may be rejected here while Python's whole-string .strip()
# would accept "delivery". This direction is safe (shell rejects MORE, never
# resolves an attacker token Python wouldn't) — at worst a malformed,
# manually-edited .mode shows "Claude Mode" here while reconcile builds the
# mode manifest. A single-line body (the only shape /mode:set ever writes)
# is handled identically by both. Not worth a whole-file normalizer for V2.0.
__inject_prose::read_mode_body() {
  local mode_file="$1"
  LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' < "$mode_file" 2>/dev/null \
    | head -c 256
}

# Synthesize the per-branch slug. Mirrors claude_modes::slugify_branch
# from lib/validate-mode-name.sh (kept inline for hot-path latency —
# inject-prose runs on every UserPromptSubmit; sourcing the shared lib
# would add subprocess + parse cost). A behavior-equivalence test under
# tests/integration/active-mode-resolver-equivalence.test.sh asserts this
# stays in sync with the canonical helper.
__inject_prose::slugify_branch() {
  local branch="$1"
  [ -z "$branch" ] && return 1
  local slug
  slug=$(LC_ALL=C printf '%s' "$branch" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')
  slug=$(printf '%s' "$slug" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
  [ -z "$slug" ] && return 1
  case "$slug" in .|..|*..*) return 1 ;; esac
  printf '%s' "$slug"
}

__resolve_active_mode() {
  local branch_slug short_sha repo_root mode_file content=""

  # Per-branch lookup: only meaningful inside a git working tree.
  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
    if branch_slug=$(git symbolic-ref --short -q HEAD 2>/dev/null) && [ -n "$branch_slug" ]; then
      branch_slug=$(__inject_prose::slugify_branch "$branch_slug") || branch_slug=""
    else
      # Detached HEAD: mirror active-mode.sh::current_branch_slug — synthesize
      # detached-<short-sha> so /mode:set writes and inject-prose reads agree.
      if short_sha=$(git rev-parse --short HEAD 2>/dev/null) && [ -n "$short_sha" ]; then
        branch_slug=$(__inject_prose::slugify_branch "detached-${short_sha}") || branch_slug=""
      fi
    fi
    if [ -n "$branch_slug" ]; then
      mode_file="${repo_root}/.claude/modes/${branch_slug}.mode"
      if [ -f "$mode_file" ]; then
        content=$(__inject_prose::read_mode_body "$mode_file")
        if __inject_prose::validate_mode_body "$content"; then
          printf '%s' "$content"
          return 0
        fi
        # Invalid body — fall through to user-global. Silent rejection: hooks
        # must never block or error-log on hostile repo content.
        content=""
      fi
    fi
  fi

  # User-global fallback.
  mode_file="${HOME}/.claude/modes/.last-active-mode"
  if [ -f "$mode_file" ]; then
    content=$(__inject_prose::read_mode_body "$mode_file")
    if __inject_prose::validate_mode_body "$content"; then
      printf '%s' "$content"
      return 0
    fi
  fi

  # No active mode.
  return 0
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

  # Resolve the active mode. Empty string ⇒ no mode set anywhere.
  local mode_name
  mode_name=$(__resolve_active_mode)

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

  # Build the systemMessage piece-by-piece.
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
# this file to reuse __inject_prose::validate_mode_body; without the guard,
# main's `exit 0` would terminate the sourcing shell before any test runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

#!/usr/bin/env bash
# claude-modes V2: append-only audit log writer.
#
# Log file: ~/.claude/modes/.audit.log
#   - Created with 0600 permissions on first write (umask 077 + : >> idiom)
#   - 0600 re-asserted on every append (V1 sec-004 carry-forward — closes
#     the case where file pre-existed with weaker perms)
#   - macOS chmod has no -h flag (rel-101 carry-forward); refuse to chmod
#     if the file is a symlink
#   - Append-only via >>; never truncated by this library
#
# V2 changes from V1:
#   - Schema generalized from (mode, tool, entity, reason) to (event, fields)
#     where event is one of: swap, install, uninstall, adopt, divergence,
#     setup_resume, mode_clear, ...
#   - Fields are key=value pairs; details serializable per event type
#   - Never records mechanism payload values (env values, mcpServer URLs,
#     hook command lines, permission grants) — only event metadata
#     (per cross-persona finding 2026-05-18 — security-lens audit-payload-scope)
#
# Line format (tab-separated):
#   <ISO-UTC-timestamp>\tevent=<event>\t<k1>=<v1>\t<k2>=<v2>...
#
# Usage:
#   . lib/audit.sh
#   claude_modes::audit_event "swap" "mode=delivery" "from_mode=claude" "branch=main"
#   claude_modes::audit_event "install" "version=0.2.0"
#   claude_modes::audit_event "uninstall" "drift_branch=Y"

# Field value maximum character length (per-value, not per-line).
set -uo pipefail

_CLAUDE_MODES_AUDIT_FIELD_MAX=200

# claude_modes::audit_event <event_name> [key=value ...]
#
# Appends one line to ~/.claude/modes/.audit.log. Each key=value pair is
# truncated to 200 characters; tabs and newlines in values are replaced
# with single spaces to keep the log line-parseable.
#
# Security: this function never logs anything from a mechanism payload
# (env values, MCP URLs, hook commands, permission grants). The caller
# is responsible for passing only metadata (event type, mode name,
# timestamps, branch slugs, outcomes). If the caller leaks a payload
# value through here, it's a bug in the caller, but the per-value
# truncation at least bounds the disclosure.
#
# Exits 0 always; audit failure is logged to stderr but NEVER propagates
# to the caller. Audit errors must never block the hook's exit path.
claude_modes::audit_event() {
  local event="${1:-unknown}"
  shift

  local audit_log="${HOME}/.claude/modes/.audit.log"

  # Ensure the log file exists with 0600 permissions (umask scope is the
  # parenthesized subshell only; doesn't leak to the calling shell).
  if ! (umask 077 && : >> "$audit_log") 2>/dev/null; then
    echo "claude-modes audit: could not create/open audit log at ${audit_log}" >&2
    return 0
  fi

  # rel-101 / sec-004: re-assert 0600 on every append; skip if symlink.
  if [ ! -L "$audit_log" ]; then
    chmod 0600 "$audit_log" 2>/dev/null || true
  fi

  # Sanitize event name.
  event="${event//$'\t'/ }"
  event="${event//$'\n'/ }"

  # Build the line: timestamp + event + sanitized k=v pairs.
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown-time")

  local line="${ts}"$'\t'"event=${event}"

  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    # Truncate value to max field length.
    if [ "${#value}" -gt "${_CLAUDE_MODES_AUDIT_FIELD_MAX}" ]; then
      value="${value:0:${_CLAUDE_MODES_AUDIT_FIELD_MAX}}..."
    fi
    # Sanitize tabs and newlines in both key and value.
    key="${key//$'\t'/ }"
    key="${key//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="${value//$'\n'/ }"
    line+=$'\t'"${key}=${value}"
  done

  printf '%s\n' "$line" >> "$audit_log" 2>/dev/null || {
    echo "claude-modes audit: could not write to audit log at ${audit_log}" >&2
  }

  return 0
}

# Allow direct invocation for testing:
#   bash lib/audit.sh <event> [key=value ...]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <event> [key=value ...]" >&2
    exit 2
  fi
  claude_modes::audit_event "$@"
fi

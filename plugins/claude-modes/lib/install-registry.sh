#!/usr/bin/env bash
# claude-modes V2 (U6): append-only repo-tracking registry.
#
# Purpose:
#   Records every repo that has had `/mode:set` run inside it on this
#   machine. Read by `scripts/unmodes.sh` (U7) to know which repos to
#   clean up at uninstall.
#
# Registry file: ~/.claude/modes/.installed-repos.txt
#   - One absolute repo path per line
#   - Created with 0600 permissions on first write (umask 077 + :>> idiom)
#   - 0600 re-asserted on every append (V1 sec-004 carry-forward —
#     closes the case where the file pre-existed with weaker perms)
#   - Append-only via >>; never truncated by this library
#   - O_APPEND writes ≤ PIPE_BUF (≥512 bytes per POSIX) are atomic — no
#     flock needed for typical repo paths (~80 bytes). The unit tests
#     verify this empirically with 5 concurrent appenders.
#
# Dedup contract:
#   - WRITE TIME: append unconditionally (no read-modify-write race window).
#     Duplicate writes are tolerated and produce duplicate lines.
#   - READ TIME: `list_registered_repos` sorts + uniqs the output. Worst
#     case the file grows with duplicates over time, but bounded by the
#     count of repos × number of `/mode:set` invocations; trivial.
#
# claude_modes::register_repo is the SINGLE canonical writer. cascade-engine.sh
# calls it directly (the prior inline grep+append duplicate was removed in the
# DRY-up; no other writer exists).

# claude_modes::registry_path
#
# Returns the canonical registry file path. Single source of truth so
# callers don't hardcode the path themselves.
set -uo pipefail

claude_modes::registry_path() {
  printf '%s' "${HOME}/.claude/modes/.installed-repos.txt"
}

# claude_modes::register_repo <repo_absolute_path>
#
# Appends one line to the registry file. Idempotent at READ time, not
# WRITE time — this lets concurrent `/mode:set` invocations append
# without coordinating via a lock. POSIX guarantees O_APPEND writes of
# ≤PIPE_BUF bytes are atomic, and a repo path line is well under that
# threshold.
#
# Born-at-0600 on first write (umask 077 + `:>>` idiom). 0600 re-asserted
# after each append (V1 sec-004 — closes the case where the file
# pre-existed with weaker perms, e.g., from a partial install).
#
# Returns 0 on success. Logs to stderr but does not propagate errors —
# audit-style ("never block the calling hook").
claude_modes::register_repo() {
  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "install-registry: register_repo called with empty repo path" >&2
    return 1
  fi

  local registry
  registry=$(claude_modes::registry_path)
  local registry_dir
  registry_dir="$(dirname "$registry")"

  # Ensure the parent dir exists at 0700 (modes are personal config).
  if [ ! -d "$registry_dir" ]; then
    mkdir -m 0700 -p "$registry_dir" 2>/dev/null || mkdir -p "$registry_dir"
  fi

  # Born-at-0600: umask scope is the parenthesized subshell only, so it
  # doesn't leak into the calling shell. The `:>>` idiom creates the file
  # if it doesn't exist without truncating it if it does.
  if ! (umask 077 && : >> "$registry") 2>/dev/null; then
    echo "install-registry: could not open ${registry} for append" >&2
    return 1
  fi

  # rel-101 / sec-004: re-assert 0600 on every append; skip if it's a
  # symlink (chmod on macOS has no -h flag — refuse rather than
  # accidentally chmod the symlink target).
  if [ ! -L "$registry" ]; then
    chmod 0600 "$registry" 2>/dev/null || true
  fi

  # Atomic append. Single printf → single write() syscall through stdio
  # → atomic per POSIX for sizes ≤ PIPE_BUF.
  if ! printf '%s\n' "$repo" >> "$registry" 2>/dev/null; then
    echo "install-registry: could not append to ${registry}" >&2
    return 1
  fi

  return 0
}

# claude_modes::list_registered_repos
#
# Emits one repo path per line, deduplicated (sort | uniq) and stripped
# of blank lines. Empty output if the registry doesn't exist yet.
#
# Caller is responsible for verifying each path still exists as a git
# work-tree root (U7's path-class verification gate).
claude_modes::list_registered_repos() {
  local registry
  registry=$(claude_modes::registry_path)
  if [ ! -f "$registry" ]; then
    return 0
  fi
  # `sort -u` does dedup + sort; grep -v '^$' strips blank lines that
  # accidental empty writes might produce.
  grep -v '^[[:space:]]*$' "$registry" 2>/dev/null | sort -u
  return 0
}

# Allow direct invocation for testing/scripting:
#   bash lib/install-registry.sh path
#   bash lib/install-registry.sh register <repo>
#   bash lib/install-registry.sh list
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    path)     claude_modes::registry_path ; echo ;;
    register) claude_modes::register_repo "${2:-}" ;;
    list)     claude_modes::list_registered_repos ;;
    *)
      echo "Usage: $0 {path | register <repo_path> | list}" >&2
      exit 2
      ;;
  esac
fi

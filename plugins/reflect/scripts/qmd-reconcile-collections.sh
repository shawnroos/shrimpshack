#!/usr/bin/env bash
#
# qmd-reconcile-collections.sh — programmatically maintain the Claude-owned QMD
# collections: one `claude-memory` for the memory dir, and one `claude-<type>`
# per doc-store sub-directory. Idempotent. Only ever touches `claude-`-prefixed
# collections, so foreign collections (openclaw, Slate, global) are never
# modified.
#
# Mechanism: `qmd collection add --name <claude-name> <dir>` creates the
# collection with an explicit name decoupled from the directory basename (the long
# `--name` flag is honored; the short `-n` is not), so foreign collections are
# never named or touched and no rename step is needed. PyYAML is not assumed and
# the config file is never hand-edited.
#
# Targets default to the real ~/.claude locations; override via env for tests:
#   QMD_RECONCILE_MEMORY_DIR   — path indexed as `claude-memory`
#   QMD_RECONCILE_DOC_STORE    — dir whose subdirs become `claude-<type>`
#   QMD_RECONCILE_NO_EMBED=1   — skip the embed step (faster tests)
#
# Isolation: qmd resolves a project-local `.qmd` from the cwd if one exists, so a
# caller that wants an isolated index (the test harness) cd's into a `qmd init`
# dir before invoking this script. This script forces nothing global.
#
# Exit non-zero on any reconcile failure.

set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
# Claude Code's project-store slug is the home path with '/' -> '-' and a leading
# '-' (e.g. /Users/jane -> -Users-jane). Derive it so the default works on any
# machine / after a home move, rather than baking in one user's slug.
_proj_slug="-${HOME#/}"; _proj_slug="${_proj_slug%/}"; _proj_slug="${_proj_slug//\//-}"
MEMORY_DIR="${QMD_RECONCILE_MEMORY_DIR:-$CLAUDE_HOME/projects/$_proj_slug/memory}"
DOC_STORE="${QMD_RECONCILE_DOC_STORE:-$CLAUDE_HOME/doc-store}"

if ! command -v qmd >/dev/null 2>&1; then
  # qmd-absent is a designed fallback, not an error: memory still works via the
  # loaded pointer index + direct file reads (the bodies are the source of truth);
  # only search-based / seeded recall is dormant until qmd is installed. Skip
  # cleanly so callers (reflect Pass 8) don't treat absence as a failure.
  echo "qmd-reconcile: qmd not installed — skipping (memory falls back to the pointer index)" >&2
  exit 0
fi

created=0
existing=0
embedded=0

# collection_exists <claude-name> -> 0 if present
collection_exists() {
  qmd collection show "$1" >/dev/null 2>&1
}

# embed_one <claude-name>
embed_one() {
  if [ "${QMD_RECONCILE_NO_EMBED:-0}" = "1" ]; then
    return 0
  fi
  # Embedding is best-effort relative to the collection-creation invariant: a
  # transient embed failure must not abort the run (under set -e) and skip the
  # remaining doc-store subdirs.
  if qmd embed -c "$1" >/dev/null 2>&1; then
    embedded=$((embedded + 1))
  else
    echo "qmd-reconcile: embed failed for $1 (non-fatal)" >&2
  fi
}

# reconcile_one <claude-name> <path>
# Ensure a `claude-`-prefixed collection for <path> exists, then embed it.
reconcile_one() {
  local name="$1" path="$2"
  case "$name" in
    claude-*) : ;;
    *) echo "qmd-reconcile: refusing non-claude- name '$name'" >&2; return 1 ;;
  esac
  if [ ! -d "$path" ]; then
    echo "qmd-reconcile: skip '$name' — path not found: $path" >&2
    return 0
  fi
  if collection_exists "$name"; then
    existing=$((existing + 1))
  else
    # Single atomic op: `qmd collection add --name <name> <dir>` creates the
    # collection with the exact `claude-`-prefixed name (the long `--name` flag;
    # the short `-n` is NOT honored). Verify and retry once — qmd writes through
    # sqlite and a write can transiently not land; silently miscounting a missing
    # collection as created is the failure mode to avoid.
    local attempt
    for attempt in 1 2 3; do
      qmd collection add --name "$name" "$path" >/dev/null 2>&1 || true
      if collection_exists "$name"; then
        break
      fi
      if [ "$attempt" -lt 3 ]; then sleep 2; fi   # no wasted sleep after the last try
    done
    if ! collection_exists "$name"; then
      echo "qmd-reconcile: FAILED to create '$name' for $path" >&2
      return 1
    fi
    created=$((created + 1))
  fi
  embed_one "$name"
  echo "  $name -> $path"
}

echo "qmd-reconcile: ensuring Claude-owned collections"
failed=0

# 1) memory collection. Per-collection failures must NOT abort the loop (set -e):
# a failed claude-memory should never starve the doc-store collections below.
reconcile_one "claude-memory" "$MEMORY_DIR" || failed=$((failed + 1))

# 2) one collection per doc-type subdirectory
if [ -d "$DOC_STORE" ]; then
  for sub in "$DOC_STORE"/*/; do
    [ -d "$sub" ] || continue
    type_name="$(basename "$sub")"
    reconcile_one "claude-${type_name}" "${sub%/}" || failed=$((failed + 1))
  done
else
  echo "qmd-reconcile: doc-store not found: $DOC_STORE" >&2
fi

echo "qmd-reconcile: done (created=$created existing=$existing embedded=$embedded failed=$failed)"
# Surface a non-zero exit if any collection couldn't be created, AFTER attempting
# all of them (next run is idempotent and recovers the rest).
[ "$failed" -eq 0 ]

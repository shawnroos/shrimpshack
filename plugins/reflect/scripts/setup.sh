#!/usr/bin/env bash
#
# setup.sh — OPT-IN one-time setup for the reflect plugin. Run it via the
# /reflect-setup command. Idempotent and safe to re-run.
#
# The plugin's hooks (seeded recall + reflect triggers) wire automatically from
# the manifest when the plugin is enabled — this script does NOT touch them. It
# performs only the invasive, opt-in live edits a plugin shouldn't do silently:
#
#   1. scaffold the doc-store (~/.claude/doc-store/{brainstorms,handoffs,solutions})
#   2. migrate an existing MEMORY.md to the budgeted pointer-index format (backs up)
#   3. patch the Memory Protocol section in your ~/.claude/CLAUDE.md (conservative,
#      backs up, skips on ambiguous structure)
#   4. create + embed the Claude-owned QMD collections (no-op without qmd)
#
# Overrides (for tests / non-default homes):
#   CLAUDE_HOME, REFLECT_MEMORY_DIR, REFLECT_DOC_STORE

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIVE="${CLAUDE_HOME:-$HOME/.claude}"
# Claude Code project-store slug, derived from $HOME (e.g. /Users/jane -> -Users-jane).
_slug="-${HOME#/}"; _slug="${_slug%/}"; _slug="${_slug//\//-}"
MEMDIR="${REFLECT_MEMORY_DIR:-$LIVE/projects/$_slug/memory}"
DOCSTORE="${REFLECT_DOC_STORE:-$LIVE/doc-store}"

echo "reflect setup: starting (idempotent)"

# 1. doc-store scaffold
mkdir -p "$DOCSTORE/brainstorms" "$DOCSTORE/handoffs" "$DOCSTORE/solutions"
echo "reflect setup: doc-store ready at $DOCSTORE"

# 2. migrate an existing MEMORY.md (idempotent; backs up to .pre-qmd-migration.bak)
if [ -f "$MEMDIR/MEMORY.md" ]; then
  if MEMORY_DIR="$MEMDIR" python3 "$PLUGIN_ROOT/scripts/migrate-memory-index.py" "$MEMDIR/MEMORY.md"; then
    :
  else
    echo "reflect setup: index migration skipped/failed (left unchanged)" >&2
  fi
else
  echo "reflect setup: no MEMORY.md at $MEMDIR — skipping migration" >&2
fi

# 3. patch the Memory Protocol in the user's CLAUDE.md (opt-in; conservative)
if [ -f "$LIVE/CLAUDE.md" ] && [ -f "$PLUGIN_ROOT/docs/memory-protocol-update.md" ]; then
  CLAUDE_MD="$LIVE/CLAUDE.md" bash "$PLUGIN_ROOT/scripts/apply-memory-protocol.sh" \
    "$PLUGIN_ROOT/docs/memory-protocol-update.md" || true
else
  echo "reflect setup: no CLAUDE.md at $LIVE — skipping protocol patch" >&2
fi

# 4. create + embed the Claude-owned QMD collections (clean no-op without qmd)
QMD_RECONCILE_MEMORY_DIR="$MEMDIR" QMD_RECONCILE_DOC_STORE="$DOCSTORE" \
  bash "$PLUGIN_ROOT/scripts/qmd-reconcile-collections.sh" || \
  echo "reflect setup: collection reconcile reported an issue (recoverable next reflect)" >&2

echo "reflect setup: done"

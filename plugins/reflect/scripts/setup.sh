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
#   5. pin Claude Code's auto-memory dir to the canonical store (autoMemoryDirectory
#      in $LIVE/settings.json; backs up, no-clobber)
#   6. ensure the repo-scope subtree (_scope/) exists + dry-run the scope backfill
#      (the backfill APPLY is a manual opt-in — it never mutates the store here)
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

# 2. render an existing MEMORY.md as the activation-ranked hot tier (idempotent;
#    backs up to .pre-render.bak). Supersedes the one-time migrate script: render
#    reads existing hooks, ranks every body by activation, and truncates at the
#    load budget — cold memories stay on disk, nothing is deleted.
if [ -f "$MEMDIR/MEMORY.md" ]; then
  if MEMORY_DIR="$MEMDIR" python3 "$PLUGIN_ROOT/scripts/memory-index-render.py" "$MEMDIR/MEMORY.md"; then
    :
  else
    echo "reflect setup: index render skipped/failed (left unchanged)" >&2
  fi
else
  echo "reflect setup: no MEMORY.md at $MEMDIR — skipping render" >&2
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

# 5. pin Claude Code's native auto-memory dir to the canonical store so a session
#    started in any project repo writes memories there, not to a git-root-derived
#    per-project store. Writes autoMemoryDirectory into $LIVE/settings.json (the
#    $LIVE var — NOT a literal $HOME/.claude — so an isolated CLAUDE_HOME redirects
#    it). Idempotent, conservative, backs up; see scripts/pin-auto-memory-dir.py.
python3 "$PLUGIN_ROOT/scripts/pin-auto-memory-dir.py" "$LIVE/settings.json" "$MEMDIR" || \
  echo "reflect setup: auto-memory pin reported an issue (recoverable next setup)" >&2

# 6. repo-scoped memory (plan 003): ensure the _scope/ subtree exists. Go-forward
#    scope backfill is NOT auto-applied — it moves bodies in the live (un-versioned)
#    store irreversibly, so it stays an explicit opt-in tool. Run a dry run to
#    surface what it WOULD tag; apply manually with:
#      python3 scripts/scoped-memory/backfill.py "$MEMDIR" "$LIVE/projects" --apply
mkdir -p "$MEMDIR/_scope"
python3 "$PLUGIN_ROOT/scripts/scoped-memory/backfill.py" "$MEMDIR" "$LIVE/projects" \
  --home-slug "$_slug" 2>/dev/null || true

echo "reflect setup: done"

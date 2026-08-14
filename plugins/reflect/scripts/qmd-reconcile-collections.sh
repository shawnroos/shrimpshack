#!/usr/bin/env bash
#
# qmd-reconcile-collections.sh — programmatically maintain the Claude-owned QMD
# collections: one `claude-memory` for the memory dir, and one `claude-<type>`
# per doc-store sub-directory. Idempotent.
#
# SCOPE, precisely — this used to claim "only ever touches `claude-`-prefixed
# collections, so foreign collections are never modified", and that is no longer
# true of the whole run:
#   * COLLECTION CREATION and EMBEDDING remain restricted to `claude-`-prefixed
#     names. Foreign collections (openclaw, Slate, global) are never created,
#     renamed, embedded, or removed here.
#   * INDEXING is global. The run performs one `qmd update`, which takes no `-c`
#     flag and therefore re-indexes every collection in the resolved qmd config,
#     foreign ones included. That is unavoidable: `qmd embed` can only vectorise
#     documents already in the index, so without it every newly saved memory
#     stays unfindable. The cost is a full re-index once per run — and note that
#     setup.sh invokes this script with embedding enabled, so `/reflect-setup` on
#     a machine with a large global index pays that cost on first run.
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
# The tally is TWO variables on purpose, and they must stay that way.
#
# `embedded_docs` is numeric and is the ONLY thing arithmetic ever touches.
# `embedded_unknown` is a flag rendered as the string `unknown` at the summary.
# Collapsing them into one mixed-type variable is fatal, not merely untidy: under
# `set -u`, `embedded=unknown` followed by any `$((embedded + n))` exits 1 with
# "unknown: unbound variable", killing the run before the summary prints AND
# before the remaining doc-store collections are traversed — the exact starvation
# the best-effort design exists to prevent.
embedded_docs=0
embedded_unknown=0

# collection_exists <claude-name> -> 0 if present
collection_exists() {
  qmd collection show "$1" >/dev/null 2>&1
}

# The exact line `qmd embed` prints when it found nothing to do. This is the ONLY
# thing that proves zero documents were embedded; anything else is unknown. If a
# qmd upgrade rewords it, the tally degrades to `unknown` (honest) rather than
# lying — and the post-merge real-qmd smoke is what catches the drift.
QMD_NO_WORK_LINE='✓ All content hashes already have embeddings.'

# embed_one <claude-name>
embed_one() {
  if [ "${QMD_RECONCILE_NO_EMBED:-0}" = "1" ]; then
    return 0
  fi
  # Embedding is best-effort relative to the collection-creation invariant: a
  # transient embed failure must not abort the run (under set -e) and skip the
  # remaining doc-store subdirs.
  #
  # The capture form is load-bearing. `if out="$(...)"; then` is the only correct
  # one: a bare `out="$(qmd embed ...)"` statement returns the command's status and
  # aborts the whole script under `set -e`, while `local out="$(...)"` returns
  # `local`'s status and silently swallows the failure so neither the warning nor
  # the unknown-tally branch below ever fires.
  local out
  if out="$(qmd embed -c "$1" 2>&1)"; then
    # Exit zero proves the command ran, never that a document was embedded — that
    # conflation is the defect this script used to ship. Only the no-work line is
    # an observed count (of zero); every other success may have embedded any
    # number of documents, and qmd reports content hashes rather than documents,
    # so there is no honest number to report.
    case "$out" in
      *"$QMD_NO_WORK_LINE"*) : ;;
      *) embedded_unknown=1 ;;
    esac
  else
    printf '%s\n' "$out" >&2
    echo "qmd-reconcile: embed failed for $1 (non-fatal)" >&2
    # A failed embed may have embedded some documents before failing, so the run's
    # total is no longer knowable — even if every other collection reported no work.
    embedded_unknown=1
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

# 0) Index the filesystem ONCE, before any embed.
#
# This is the whole bug. `qmd embed` only re-vectorises documents ALREADY in the
# index — it cannot see a file the index has never heard of. A memory saved this
# session is exactly such a file, so embed-only left every new memory unindexed,
# unembedded, and unfindable next session while the run reported a clean
# `embedded=N failed=0`.
#
# Hoisted rather than called per collection because `qmd update` takes no `-c`
# flag: it is global. One call per run; calling it inside embed_one would repeat a
# full global rescan once per collection.
#
# Best-effort for the same reason embed is: a transient update failure must not
# abort under `set -e` and starve the collections below.
if [ "${QMD_RECONCILE_NO_EMBED:-0}" != "1" ]; then
  if ! qmd update >/dev/null 2>&1; then
    echo "qmd-reconcile: qmd update failed (non-fatal; new files may not be indexed)" >&2
  fi
fi

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

# Render the tally once, here — the only place the two variables collapse into one
# field. `unknown` is deliberate and is not a failure: it means documents may have
# been embedded but qmd exposes no document count to report, and an honest
# "unknown" beats a confident number that was never measured.
if [ "$embedded_unknown" -eq 1 ]; then
  embedded_field="unknown"
else
  embedded_field="$embedded_docs"
fi
echo "qmd-reconcile: done (created=$created existing=$existing embedded=$embedded_field failed=$failed)"
# Surface a non-zero exit if any collection couldn't be created, AFTER attempting
# all of them (next run is idempotent and recovers the rest).
[ "$failed" -eq 0 ]

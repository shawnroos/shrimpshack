#!/usr/bin/env bash
# claude-modes: idempotent install of example modes.
#
# Run once after symlinking the plugin into ~/.claude/plugins/.
# Copies examples/example-discovery.yaml and example-delivery.yaml into
# ~/.claude/modes/ IFF those targets don't already exist.
#
# Why idempotent: re-running shouldn't clobber a user's edits to the
# example files (they're meant to be adapted in place).
#
# Why not auto-run from a hook: users can opt out by skipping this step
# (e.g., users who deliberately want a zero-mode start to dogfood the
# authoring flow).

# learnings-001: use `set -uo pipefail` (the documented V1 convention) — NOT
# `set -e`, which the rest of claude-modes avoids because it interacts badly
# with explicit `|| true` handling. Failure-sensitive ops below (cp/chmod)
# carry explicit `|| exit` guards instead of relying on -e.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODES_DIR="${HOME}/.claude/modes"

# Ensure target dir exists (created with restrictive perms — modes are
# personal config).
mkdir -m 0700 -p "${MODES_DIR}" 2>/dev/null || mkdir -p "${MODES_DIR}"

copied=0
skipped=0
for example in example-discovery example-delivery; do
  src="${PLUGIN_ROOT}/examples/${example}.yaml"
  dst="${MODES_DIR}/${example}.yaml"

  if [ ! -f "${src}" ]; then
    echo "claude-modes install-examples: missing source ${src}" >&2
    exit 1
  fi

  if [ -e "${dst}" ]; then
    echo "  skip: ${dst} already exists (preserving your edits)"
    skipped=$((skipped + 1))
  else
    cp "${src}" "${dst}" || {
      echo "claude-modes install-examples: cp failed ${src} → ${dst}" >&2
      exit 1
    }
    chmod 0600 "${dst}" || {
      echo "claude-modes install-examples: chmod failed ${dst}" >&2
      exit 1
    }
    echo "  copied: ${dst}"
    copied=$((copied + 1))
  fi
done

echo ""
echo "claude-modes: ${copied} example mode(s) installed, ${skipped} skipped."
echo ""
echo "Next steps:"
echo "  1. Open ~/.claude/modes/example-discovery.yaml and ~/.claude/modes/example-delivery.yaml — these are starting points to adapt or delete."
echo "  2. On a feature branch, run '/mode:set example-discovery' to try it out."
echo "  3. Author your own mode via '/mode:registry' when you're ready."

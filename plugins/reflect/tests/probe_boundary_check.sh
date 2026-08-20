#!/usr/bin/env bash
#
# probe_boundary_check.sh — KTD9, enforced rather than stated.
#
# A probe is stored agent-authored shell run with the operator's privileges. It
# runs only inside the attended `/reflect:reflect-retro` session. Nothing under
# `hooks/` and nothing in `scripts/reflect-run.sh` may reach the probe entry
# point. Without this check a later change wires probes into a hook, no test
# fails, and stored shell silently becomes unattended execution.
#
# Usage: probe_boundary_check.sh [plugin-root]   (exit 0 clean, 1 breached/broken)

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOKS="$ROOT/hooks"
RUNNER="$ROOT/scripts/reflect-run.sh"

# Asserted, never assumed: `grep` exits 2 on a missing target, and a bare
# `! grep ...` turns that into a pass forever the moment either path moves.
for target in "$HOOKS" "$RUNNER"; do
  if [ ! -e "$target" ]; then
    echo "probe_boundary_check: search target missing: $target" >&2
    exit 1
  fi
done

PATTERN='run_probes?|retro\.py"?'"'"'?[[:space:]]+probe'

hits="$(grep -rEn "$PATTERN" "$HOOKS" "$RUNNER" 2>/dev/null)"
rc=$?
case "$rc" in
  0)
    echo "probe_boundary_check: probe entry point referenced from an unattended path (KTD9):" >&2
    echo "$hits" >&2
    exit 1
    ;;
  1)
    echo "probe_boundary_check: clean — no hook and no automatic pass reaches the probe runner"
    exit 0
    ;;
  *)
    echo "probe_boundary_check: grep failed (rc=$rc); refusing to report clean" >&2
    exit 1
    ;;
esac

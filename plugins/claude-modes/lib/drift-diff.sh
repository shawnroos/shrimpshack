#!/usr/bin/env bash
# claude-modes V2 U7: bash wrapper around drift-diff.py.
#
# Purpose: emit a key-by-key structured diff between pristine and current
# settings.json (informational only — NOT a deletion gate; the sidecar
# fingerprint in <repo>/.claude/modes/.cascade-meta.json is the only
# load-bearing decision for whether to delete settings.local.json).
#
# maint-2 / STATUS: NOT YET WIRED IN. This helper has no production callers
# today — the /mode:status drift display that consumes it is deferred to
# V2.1 (see lib/status.sh "Drift detection deferred to V2.1"). It is kept
# (correct + unit-tested at tests/unit/drift-diff.test.sh) as the ready-made
# implementation for that V2.1 feature. Reintroduction point: wire into
# claude_modes::status and/or unmodes.sh forensic line. Output is line-per-key.

set -uo pipefail

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# claude_modes::drift_diff <pristine_path> <current_path>
#
# Emits one line per top-level key that differs, in deterministic order.
# Empty stdout if no differences. Exits 0 on success, 2 on missing file,
# 3 on unparseable JSON.
claude_modes::drift_diff() {
  local pristine_path="${1:-}"
  local current_path="${2:-}"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  "$CLAUDE_MODES_PYTHON3" "${script_dir}/drift-diff.py" \
    "$pristine_path" "$current_path"
}

# Allow direct invocation for testing/scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::drift_diff "${1:-}" "${2:-}"
fi

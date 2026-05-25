#!/usr/bin/env bash
# adv-006 integration: settings.local.json hand-edit detection (warn, not abort).
#
# Contract:
#   - First /mode:set on a fresh repo: NO warning (no sidecar yet).
#   - Idempotent re-set (same mode, no edits): NO warning (fingerprint matches).
#   - Hand-edit settings.local.json then re-set: warning fires AND the file is
#     still recompiled to the cascade's deterministic output (warn-and-PROCEED,
#     not warn-and-abort — cascade is idempotent/self-healing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3}"
ID="claude-modes@local-dev"

__seed_modes_dir() {
  mkdir -p "${HOME}/.claude/modes"
  cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
    "baseline@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/_global.yaml"
  cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
mechanism:
  enabledPlugins:
    "delivery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"
}

__make_repo() {
  local path="$1"
  mkdir -p "$path"
  (
    cd "$path"
    git init -q -b main >/dev/null 2>&1
    git config user.email "test@test"
    git config user.name "test"
    : > .gitkeep
    git add .gitkeep
    git commit -q -m "init" --allow-empty
  )
}

__run_set_mode_in() {
  local cwd="$1"; shift
  ( cd "$cwd" && bash "${PLUGIN_ROOT}/lib/set-mode.sh" "$@" )
}

__keys_of_settings() {
  "$PY" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
ep = d.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "$1"
}

WARN_RE="WARNING — settings.local.json"

# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO="${HOME}/repo-adv006"
__make_repo "$REPO"

SETTINGS="${REPO}/.claude/settings.local.json"

# ─── Scenario 1: first set is silent ──────────────────────────────────
claude_modes_test::it "first /mode:set delivery: no hand-edit warning"
err1=$(__run_set_mode_in "$REPO" delivery 2>&1 >/dev/null)
if printf '%s' "$err1" | grep -q "$WARN_RE"; then
  claude_modes_test::fail "first set should be silent, got: ${err1}"
else
  claude_modes_test::pass
fi

# ─── Scenario 2: idempotent re-set is silent ──────────────────────────
claude_modes_test::it "idempotent re-set (no edits): no hand-edit warning"
err2=$(__run_set_mode_in "$REPO" delivery 2>&1 >/dev/null)
if printf '%s' "$err2" | grep -q "$WARN_RE"; then
  claude_modes_test::fail "idempotent re-set should be silent, got: ${err2}"
else
  claude_modes_test::pass
fi

# ─── Scenario 3: hand-edit fires warning AND file is recompiled ───────
# Hand-edit: inject a bogus plugin into enabledPlugins.
"$PY" - "$SETTINGS" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("enabledPlugins", {})["rogue-hand-edit@market"] = True
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PYEOF

claude_modes_test::it "hand-edited settings.local.json: warning fires on next set"
err3=$(__run_set_mode_in "$REPO" delivery 2>&1 >/dev/null)
if printf '%s' "$err3" | grep -q "$WARN_RE"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected hand-edit warning, got: ${err3}"
fi

claude_modes_test::it "hand-edit is overwritten: rogue plugin gone, cascade values restored"
keys=$(__keys_of_settings "$SETTINGS")
expected="baseline@market,${ID},delivery-plugin@market"
claude_modes_test::assert_eq "$expected" "$keys"

# ─── Scenario 4: after recompile, the next set is silent again ────────
claude_modes_test::it "post-recompile re-set: warning clears (fingerprint back in sync)"
err4=$(__run_set_mode_in "$REPO" delivery 2>&1 >/dev/null)
if printf '%s' "$err4" | grep -q "$WARN_RE"; then
  claude_modes_test::fail "warning should clear after recompile re-synced sidecar, got: ${err4}"
else
  claude_modes_test::pass
fi

# ──────────────────────────────────────────────────────────────────────
claude_modes_test::teardown

echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

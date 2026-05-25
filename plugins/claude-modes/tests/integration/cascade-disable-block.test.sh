#!/usr/bin/env bash
# U4 integration: AE9 — cascade disable block end-to-end.
#
# Scenario:
#   _global.yaml mechanism.enabledPlugins = {A: true, B: true, claude-modes: true}
#   writing.yaml disable.enabledPlugins = [A]
#   /mode:set writing → settings.local.json's enabledPlugins is
#   {B: true, claude-modes: true} only — A is removed (not set false).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"

PY="${CLAUDE_MODES_PYTHON3}"
ID="claude-modes@local-dev"

# Create a fake git repo inside $HOME.
REPO="${HOME}/myrepo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" \
  && git config user.name "test" )

# Tier 2: _global.yaml carries A, B, claude-modes.
mkdir -p "${HOME}/.claude/modes"
cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "A@market": true
    "B@market": true
    "${ID}": true
EOF
chmod 0600 "${HOME}/.claude/modes/_global.yaml"

# Tier 3: writing.yaml disables A.
cat > "${HOME}/.claude/modes/writing.yaml" <<EOF
schema_version: 2
name: writing
mechanism:
  enabledPlugins: {}
disable:
  enabledPlugins:
    - "A@market"
EOF
chmod 0600 "${HOME}/.claude/modes/writing.yaml"

# ─── Run cascade ────────────────────────────────────────────────────
claude_modes_test::it "AE9: cascade disable.enabledPlugins removes A from result"
if claude_modes::cascade_compile "writing" "$REPO" >/dev/null 2>&1; then
  target="${REPO}/.claude/settings.local.json"
  if [ -f "$target" ]; then
    keys=$("$PY" -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["enabledPlugins"].keys())))' "$target")
    expected="B@market,${ID}"
    claude_modes_test::assert_eq "$expected" "$keys"
  else
    claude_modes_test::fail "settings.local.json was not created"
  fi
else
  claude_modes_test::fail "cascade_compile exited non-zero"
fi

# ─── Verify sidecar fingerprint matches written file ────────────────
claude_modes_test::it "AE9: sidecar fingerprint matches sha256 of settings.local.json"
sidecar="${REPO}/.claude/modes/.cascade-meta.json"
if [ -f "$sidecar" ]; then
  expected=$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${REPO}/.claude/settings.local.json")
  recorded=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$sidecar")
  claude_modes_test::assert_eq "$expected" "$recorded"
else
  claude_modes_test::fail "sidecar was not written"
fi

# ─── installed-repos.txt records the repo ───────────────────────────
claude_modes_test::it "AE9: cascade appends repo to .installed-repos.txt"
repos_file="${HOME}/.claude/modes/.installed-repos.txt"
if [ -f "$repos_file" ] && grep -qxF "$REPO" "$repos_file"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected $REPO in $repos_file"
fi

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

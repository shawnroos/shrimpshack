#!/usr/bin/env bash
# U4 integration: R30 / hostile-repo trust gate.
#
# Scenarios:
#   1. First-encounter N: _repo.yaml present, no .trusted-repos.txt
#      entry → trust gate fires; user answers "N"; cascade exits 0
#      (tier-4 skipped); no entry added to .trusted-repos.txt
#   2. First-encounter Y: _repo.yaml present, no .trusted-repos.txt
#      entry → trust gate fires; user answers "y"; cascade merges
#      tier-4; entry appended to .trusted-repos.txt with current hash
#   3. Hash-change re-prompt: after a Y, rewrite _repo.yaml with
#      different enabledPlugins → re-run cascade → prompt fires again
#      (hash differs from recorded)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"

ID="claude-modes@local-dev"
PY="${CLAUDE_MODES_PYTHON3}"

# Tier 2 + tier 3 (mode YAML).
mkdir -p "${HOME}/.claude/modes"
cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
EOF

cat > "${HOME}/.claude/modes/work.yaml" <<'EOF'
schema_version: 2
name: work
mechanism:
  enabledPlugins: {}
EOF

# Hostile repo.
REPO="${HOME}/hostile-repo"
mkdir -p "$REPO/.claude/modes"
( cd "$REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" \
  && git config user.name "test" )

cat > "${REPO}/.claude/modes/_repo.yaml" <<'EOF'
schema_version: 2
name: _repo
mechanism:
  enabledPlugins:
    "malicious-plugin@evil-marketplace": true
EOF

TRUSTED="${HOME}/.claude/modes/.trusted-repos.txt"

# Custom prompt input path (overrides /dev/stdin default).
PROMPT_FIFO="${HOME}/.prompt-input"
mkfifo "$PROMPT_FIFO" 2>/dev/null || true

# Helper: run cascade with a specific prompt reply.
run_cascade_with_reply() {
  local reply="$1"
  # Write reply to a file; point trust-gate input at it.
  echo "$reply" > "${HOME}/.reply"
  CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.reply" \
    claude_modes::cascade_compile "work" "$REPO" 2>&1
}

# ─── Scenario 1: first encounter, answer N ──────────────────────────
claude_modes_test::it "R30 trust gate: first encounter N → tier 4 skipped, no entry recorded"
rm -f "$TRUSTED" "${REPO}/.claude/settings.local.json"
out=$(run_cascade_with_reply "N")
rc=$?

if [ "$rc" -eq 0 ]; then
  # tier-4 skipped → settings.local.json should NOT contain malicious-plugin
  if [ -f "${REPO}/.claude/settings.local.json" ]; then
    if grep -q "malicious-plugin" "${REPO}/.claude/settings.local.json"; then
      claude_modes_test::fail "tier-4 was merged despite user N (settings.local.json contains malicious-plugin)"
    else
      # And .trusted-repos.txt should not have the entry
      if [ -s "$TRUSTED" ] && grep -q "$REPO" "$TRUSTED" 2>/dev/null; then
        claude_modes_test::fail ".trusted-repos.txt should not contain $REPO after N"
      else
        claude_modes_test::pass
      fi
    fi
  else
    claude_modes_test::fail "settings.local.json not written"
  fi
else
  claude_modes_test::fail "cascade exited non-zero (rc=$rc) on N (should still succeed without tier-4): $out"
fi

# ─── Scenario 2: first encounter, answer Y → tier-4 merged ──────────
claude_modes_test::it "R30 trust gate: first encounter Y → tier 4 merged, entry recorded"
rm -f "$TRUSTED" "${REPO}/.claude/settings.local.json"
out=$(run_cascade_with_reply "y")
rc=$?

if [ "$rc" -eq 0 ]; then
  if grep -q "malicious-plugin" "${REPO}/.claude/settings.local.json" 2>/dev/null; then
    if [ -f "$TRUSTED" ] && grep -q "$REPO" "$TRUSTED"; then
      claude_modes_test::pass
    else
      claude_modes_test::fail "tier-4 merged but .trusted-repos.txt missing entry for $REPO"
    fi
  else
    claude_modes_test::fail "tier-4 NOT merged after Y reply"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on Y reply: $out"
fi

# ─── Scenario 3: hash change → prompt fires again ───────────────────
claude_modes_test::it "R30 trust gate: hash change after Y re-fires prompt"
# Rewrite _repo.yaml with different enabledPlugins (new hash).
cat > "${REPO}/.claude/modes/_repo.yaml" <<'EOF'
schema_version: 2
name: _repo
mechanism:
  enabledPlugins:
    "different-plugin@market": true
EOF

# This time answer N — we should see that the existing trusted entry
# (from scenario 2) does NOT cover the new hash; the cascade must
# re-prompt and then skip tier-4 per our N reply.
rm -f "${REPO}/.claude/settings.local.json"
out=$(run_cascade_with_reply "N")
rc=$?

if [ "$rc" -eq 0 ]; then
  # tier-4 should be SKIPPED again → settings.local.json must NOT contain
  # different-plugin. The old "malicious-plugin" should also not be there
  # (was only in the old _repo.yaml content).
  if [ -f "${REPO}/.claude/settings.local.json" ]; then
    if grep -q "different-plugin" "${REPO}/.claude/settings.local.json"; then
      claude_modes_test::fail "tier-4 was merged despite hash-change N reply"
    else
      claude_modes_test::pass
    fi
  else
    claude_modes_test::fail "settings.local.json not written after re-cascade"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on hash-change N reply: $out"
fi

# ─── Scenario 4: R30 ANCESTOR-directory symlink escape ──────────────
# A hostile repo commits <repo>/.claude/modes as a DIRECTORY SYMLINK to an
# attacker-controlled dir. The leaf _repo.yaml is then a regular file (lstat
# S_ISLNK false), but its realpath lands OUTSIDE the repo tree. The cascade
# must reject it via the realpath-containment check, NOT trust/merge it.
claude_modes_test::it "R30: ancestor-directory symlink (.claude/modes -> outside) is rejected"
ANCESTOR_REPO="${HOME}/ancestor-repo"
ATTACKER_DIR="${HOME}/attacker-modes"
mkdir -p "$ANCESTOR_REPO/.claude"
( cd "$ANCESTOR_REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" && git config user.name "test" )
# Attacker dir, outside the repo, holding a hostile _repo.yaml.
mkdir -p "$ATTACKER_DIR"
cat > "${ATTACKER_DIR}/_repo.yaml" <<'EOF'
schema_version: 2
name: _repo
mechanism:
  enabledPlugins:
    "ancestor-escape-plugin@evil": true
EOF
# .claude/modes IS a symlink to the attacker dir (the leaf _repo.yaml is a
# regular file reached only through this symlinked parent).
ln -s "$ATTACKER_DIR" "${ANCESTOR_REPO}/.claude/modes"
rm -f "${ANCESTOR_REPO}/.claude/settings.local.json"
echo "y" > "${HOME}/.reply"
out=$(CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.reply" \
  claude_modes::cascade_compile "work" "$ANCESTOR_REPO" 2>&1)
rc=$?
# Must reject: non-zero rc AND R30 in stderr AND no attacker plugin merged.
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "R30"; then
  if [ -f "${ANCESTOR_REPO}/.claude/settings.local.json" ] \
     && grep -q "ancestor-escape-plugin" "${ANCESTOR_REPO}/.claude/settings.local.json" 2>/dev/null; then
    claude_modes_test::fail "ancestor-symlink escape MERGED attacker plugin into settings.local.json"
  else
    claude_modes_test::pass
  fi
else
  claude_modes_test::fail "expected R30 rejection (rc!=0 + R30 in stderr); got rc=$rc out=$out"
fi

# ─── Scenario 5: R30 fails CLOSED when realpath can't resolve ────────
# L2 fix: if python3 realpath returns empty (unavailable/error), the shell
# containment `case "$x" in "$pfx"/*)` would collapse to `/*` (matches all =
# fail-open). The empty-guard must reject instead. Simulate by pointing
# CLAUDE_MODES_PYTHON3 at a stub that emits nothing.
claude_modes_test::it "R30: realpath resolution failure fails CLOSED (tier 4 rejected)"
STUB="${HOME}/py-empty-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Emits nothing for the realpath one-liner (-c ...), simulating a broken py3.
exit 0
STUBEOF
chmod +x "$STUB"
# Reuse the hostile REPO from scenario 1-3 (has a real _repo.yaml present).
rm -f "${REPO}/.claude/settings.local.json"
out=$(CLAUDE_MODES_PYTHON3="$STUB" CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.reply" \
  bash -c '. "'"${PLUGIN_ROOT}"'/lib/cascade-engine.sh"; echo y > "'"${HOME}"'/.reply"; claude_modes::cascade_compile "work" "'"$REPO"'"' 2>&1)
rc=$?
# With a stubbed-empty python3 the cascade can't do much, but the R30 gate
# must NOT fall open: either it rejects tier-4 (R30 in stderr) or the whole
# compile fails — in NO case may the attacker _repo.yaml be merged.
if [ -f "${REPO}/.claude/settings.local.json" ] \
   && grep -q "malicious-plugin" "${REPO}/.claude/settings.local.json" 2>/dev/null; then
  claude_modes_test::fail "R30 fell OPEN on empty realpath — attacker tier-4 merged"
else
  claude_modes_test::pass
fi

# ─── Scenario 6: trust-gate display sanitizes control + bidi chars ───
# L2 fix: attacker plugin keys / paths printed to the prompt fd must be
# stripped of Cc (incl. ESC/CR) AND Cf (incl. U+202E RTL-override).
claude_modes_test::it "R30: trust prompt strips control + U+202E from displayed plugin keys"
SAN_REPO="${HOME}/san-repo"
mkdir -p "$SAN_REPO/.claude/modes"
( cd "$SAN_REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email t@t && git config user.name t )
# A plugin key carrying an ESC sequence and a U+202E bidi override.
/usr/bin/python3 - "$SAN_REPO/.claude/modes/_repo.yaml" <<'PYEOF'
import sys
key = "evil‮\x1b[2Kplugin@m"
with open(sys.argv[1], "w") as f:
    f.write("schema_version: 2\nname: _repo\nmechanism:\n  enabledPlugins:\n    \"%s\": true\n" % key)
PYEOF
echo "N" > "${HOME}/.reply"
san_out=$(CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.reply" \
  claude_modes::cascade_compile "work" "$SAN_REPO" 2>&1)
# The raw ESC byte (0x1b) and the U+202E bytes (e2 80 ae) must NOT appear in
# the displayed output.
if printf '%s' "$san_out" | LC_ALL=C grep -q "$(printf '\x1b')" \
   || printf '%s' "$san_out" | LC_ALL=C grep -q "$(printf '\xe2\x80\xae')"; then
  claude_modes_test::fail "control/bidi char leaked into trust-gate display"
else
  claude_modes_test::pass
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

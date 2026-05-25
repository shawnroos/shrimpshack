#!/usr/bin/env bash
# U7 integration: AE10 — multi-repo uninstall.
#
# Scenario: install in three repos (A, B, C) across time. Each repo
# gets a plugin-authored settings.local.json + matching sidecar (we
# build them directly here rather than invoking cascade-engine to keep
# the test focused on uninstall semantics — the cascade engine's own
# write path is exercised in U4's tests).
#
# Then run uninstall and verify:
#   - all three repos' settings.local.json + .cascade-meta.json deleted
#   - all three repos' <repo>/.claude/modes/ directories deleted
#   - ~/.claude/modes/ deleted
#   - ~/.claude/settings.json unchanged (never touched by plugin)
#   - preserved uninstall log carries the audit trail
#
# Asymmetric-assertion guard: we verify the pre-state (artifacts exist)
# BEFORE running uninstall, so the post-state assertions ("all gone")
# can't pass trivially just because nothing was ever there.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

_perms() {
  stat -f '%A' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

_sha() {
  shasum "$1" 2>/dev/null | awk '{print $1}'
}

# Helper: init a fake repo, return the GIT-CANONICAL path. macOS
# canonicalizes /var/folders/... → /private/var/folders/...; cascade
# engine registers the canonical form, so tests must too or the
# path-class check rejects the entry.
_init_fake_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q 2>/dev/null
  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# Helper: write a plugin-authored settings.local.json + matching sidecar
# in <repo>, then register the repo in the install registry.
_install_cascade() {
  local repo="$1"
  local content="$2"
  mkdir -p "${repo}/.claude/modes"
  printf '%s' "$content" > "${repo}/.claude/settings.local.json"
  chmod 0600 "${repo}/.claude/settings.local.json"
  local fp
  fp=$(shasum -a 256 "${repo}/.claude/settings.local.json" | awk '{print $1}')
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "${repo}/.claude/modes/.cascade-meta.json" <<EOF
{
  "tool": "claude-modes",
  "version": "2.0",
  "fingerprint": "${fp}",
  "compiled_at": "${ts}",
  "source_modes": ["_global.yaml"]
}
EOF
  chmod 0600 "${repo}/.claude/modes/.cascade-meta.json"
  printf '%s\n' "$repo" >> "${HOME}/.claude/modes/.installed-repos.txt"
}

# ═══════════════════════════════════════════════════════════════════════
# Setup: install claude-modes once.
# ═══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "claude-modes@marketplace": true,
    "compound-engineering@every-marketplace": true
  },
  "permissions": {"allow": [], "deny": []},
  "statusLine": {"type": "command", "command": "/bin/echo"}
}
EOF
PRE_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# Build three fake repos with plugin-authored cascades.
REPO_A=$(_init_fake_repo "${HOME}/repoA")
REPO_B=$(_init_fake_repo "${HOME}/repoB")
REPO_C=$(_init_fake_repo "${HOME}/repoC")

_install_cascade "$REPO_A" '{"enabledPlugins": {"claude-modes@marketplace": true, "rapid-prototyper@marketplace": true}}'
_install_cascade "$REPO_B" '{"enabledPlugins": {"claude-modes@marketplace": true}}'
_install_cascade "$REPO_C" '{"enabledPlugins": {"claude-modes@marketplace": true, "deep-research@marketplace": true}}'

# ─── Pre-state assertions (guard against asymmetric assertion trap) ───
claude_modes_test::it "PRE: repoA settings.local.json exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_A}/.claude/settings.local.json"

claude_modes_test::it "PRE: repoA sidecar exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_A}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "PRE: repoB settings.local.json exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_B}/.claude/settings.local.json"

claude_modes_test::it "PRE: repoB sidecar exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_B}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "PRE: repoC settings.local.json exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_C}/.claude/settings.local.json"

claude_modes_test::it "PRE: repoC sidecar exists before uninstall"
claude_modes_test::assert_file_exists "${REPO_C}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "PRE: registry contains all 3 repos"
# Use the canonical path list; the registry's exact representation may
# have duplicate lines (register_repo is append-only). list_registered_repos
# does sort -u for us.
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/install-registry.sh"
listed=$(claude_modes::list_registered_repos)
count=$(printf '%s\n' "$listed" | grep -c '/repo[ABC]' || true)
claude_modes_test::assert_eq "3" "$count"

# ═══════════════════════════════════════════════════════════════════════
# Run uninstall.
# ═══════════════════════════════════════════════════════════════════════
UNINSTALL_OUT=$(bash "${PLUGIN_ROOT}/scripts/unmodes.sh" 2>&1)
UNINSTALL_RC=$?

claude_modes_test::it "AE10: unmodes.sh exits 0 with 3 repos"
claude_modes_test::assert_eq "0" "$UNINSTALL_RC"

# ─── Per-repo post-state: settings.local.json removed ─────────────────
claude_modes_test::it "AE10: repoA settings.local.json removed"
claude_modes_test::assert_file_absent "${REPO_A}/.claude/settings.local.json"

claude_modes_test::it "AE10: repoB settings.local.json removed"
claude_modes_test::assert_file_absent "${REPO_B}/.claude/settings.local.json"

claude_modes_test::it "AE10: repoC settings.local.json removed"
claude_modes_test::assert_file_absent "${REPO_C}/.claude/settings.local.json"

# ─── Per-repo post-state: sidecar removed ─────────────────────────────
claude_modes_test::it "AE10: repoA sidecar removed"
claude_modes_test::assert_file_absent "${REPO_A}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "AE10: repoB sidecar removed"
claude_modes_test::assert_file_absent "${REPO_B}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "AE10: repoC sidecar removed"
claude_modes_test::assert_file_absent "${REPO_C}/.claude/modes/.cascade-meta.json"

# ─── Per-repo post-state: <repo>/.claude/modes/ tree removed ──────────
claude_modes_test::it "AE10: repoA .claude/modes/ removed"
claude_modes_test::assert_file_absent "${REPO_A}/.claude/modes"

claude_modes_test::it "AE10: repoB .claude/modes/ removed"
claude_modes_test::assert_file_absent "${REPO_B}/.claude/modes"

claude_modes_test::it "AE10: repoC .claude/modes/ removed"
claude_modes_test::assert_file_absent "${REPO_C}/.claude/modes"

# ─── ~/.claude/modes/ is gone ─────────────────────────────────────────
claude_modes_test::it "AE10: ~/.claude/modes/ removed"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes"

# ─── ~/.claude/settings.json never touched ────────────────────────────
claude_modes_test::it "AE10: ~/.claude/settings.json byte-identical to pre-install"
POST_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")
claude_modes_test::assert_eq "$PRE_SETTINGS_SHA" "$POST_SETTINGS_SHA"

# ─── Preserved log carries the audit history + final uninstall event ──
claude_modes_test::it "AE10: preserved log exists"
claude_modes_test::assert_file_exists "${HOME}/.claude/.claude-modes-uninstall.log"

claude_modes_test::it "AE10: preserved log includes the setup event"
claude_modes_test::assert_true "grep -q 'event=setup' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "AE10: preserved log includes uninstall_repo_clean events"
# Should have at least one per repo (3 total).
count=$(grep -c 'event=uninstall_repo_clean' "${HOME}/.claude/.claude-modes-uninstall.log" || true)
claude_modes_test::assert_eq "3" "$count"

claude_modes_test::it "AE10: preserved log includes the final uninstall event"
claude_modes_test::assert_true "grep -q 'event=uninstall' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "AE10: final uninstall event records repos_visited=3"
claude_modes_test::assert_true "grep -q 'repos_visited=3' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "AE10: final uninstall event records repos_deleted_full=3"
claude_modes_test::assert_true "grep -q 'repos_deleted_full=3' '${HOME}/.claude/.claude-modes-uninstall.log'"

# ─── Each repo's .git/ should be unchanged (we only touched .claude/) ─
claude_modes_test::it "AE10: repoA .git/ still exists (untouched)"
claude_modes_test::assert_true "[ -d '${REPO_A}/.git' ]"

claude_modes_test::it "AE10: repoB .git/ still exists (untouched)"
claude_modes_test::assert_true "[ -d '${REPO_B}/.git' ]"

claude_modes_test::it "AE10: repoC .git/ still exists (untouched)"
claude_modes_test::assert_true "[ -d '${REPO_C}/.git' ]"

claude_modes_test::teardown

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
printf '\n%s: %d passed, %d failed\n' \
  "multi-repo-uninstall.test.sh" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

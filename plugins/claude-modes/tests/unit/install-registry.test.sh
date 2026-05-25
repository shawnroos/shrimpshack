#!/usr/bin/env bash
# U6 unit test: lib/install-registry.sh — append-only repo registry.
#
# Scenarios:
#   1. registry_path returns ~/.claude/modes/.installed-repos.txt
#   2. register_repo creates the registry file at 0600 on first call
#   3. register_repo appends one line per call (no dedup at write time)
#   4. list_registered_repos reads + dedupes via sort -u
#   5. list_registered_repos skips empty lines
#   6. list_registered_repos returns empty when registry doesn't exist
#   7. register_repo handles concurrent writes without corruption (5
#      parallel appenders; each line lands intact, no truncation,
#      no concatenation)
#   8. register_repo re-asserts 0600 if the file pre-existed at 0644
#   9. register_repo with empty arg returns non-zero
#  10. setup-creates-registry-then-register sequence both at 0600

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/install-registry.sh"

REGISTRY="${HOME}/.claude/modes/.installed-repos.txt"

_perms() {
  stat -f '%A' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# ─── Scenario 1: registry_path constant ─────────────────────────────
claude_modes_test::it "registry_path returns ~/.claude/modes/.installed-repos.txt"
got=$(claude_modes::registry_path)
claude_modes_test::assert_eq "$REGISTRY" "$got"

# ─── Scenario 2: register_repo creates the file at 0600 ─────────────
claude_modes_test::it "register_repo creates the registry file at 0600 on first call"
claude_modes_test::assert_false "[ -f '$REGISTRY' ]"
claude_modes::register_repo "/tmp/repoA" >/dev/null 2>&1
if [ -f "$REGISTRY" ]; then
  perms=$(_perms "$REGISTRY")
  claude_modes_test::assert_eq "600" "$perms"
else
  claude_modes_test::fail "expected registry file to exist after register_repo"
fi

# ─── Scenario 3: append-only (no dedup at write time) ────────────────
claude_modes_test::it "register_repo appends one line per call (no dedup at write)"
rm -f "$REGISTRY"
claude_modes::register_repo "/tmp/repoA" >/dev/null 2>&1
claude_modes::register_repo "/tmp/repoA" >/dev/null 2>&1
claude_modes::register_repo "/tmp/repoB" >/dev/null 2>&1
lines=$(wc -l < "$REGISTRY" | tr -d '[:space:]')
claude_modes_test::assert_eq "3" "$lines"

# ─── Scenario 4: list_registered_repos dedupes ──────────────────────
claude_modes_test::it "list_registered_repos dedupes via sort -u"
listed=$(claude_modes::list_registered_repos)
expected=$'/tmp/repoA\n/tmp/repoB'
claude_modes_test::assert_eq "$expected" "$listed"

# ─── Scenario 5: skips empty lines ──────────────────────────────────
claude_modes_test::it "list_registered_repos skips empty lines"
printf '\n   \n/tmp/repoC\n\n' >> "$REGISTRY"
listed=$(claude_modes::list_registered_repos)
expected=$'/tmp/repoA\n/tmp/repoB\n/tmp/repoC'
claude_modes_test::assert_eq "$expected" "$listed"

# ─── Scenario 6: empty when registry doesn't exist ───────────────────
claude_modes_test::it "list_registered_repos returns empty when registry absent"
rm -f "$REGISTRY"
listed=$(claude_modes::list_registered_repos)
claude_modes_test::assert_eq "" "$listed"

# ─── Scenario 7: concurrent appenders don't corrupt lines ────────────
claude_modes_test::it "register_repo handles 5 concurrent appenders without corruption"
rm -f "$REGISTRY"

# Pre-create the file at 0600 so all appenders skip the umask path.
(umask 077 && : >> "$REGISTRY")

# Use distinct realistic-length repo paths so we can spot truncation
# or concatenation if it happens.
paths=(
  "/Users/test/projects/repo-alpha"
  "/Users/test/projects/repo-bravo"
  "/Users/test/projects/repo-charlie-with-longer-name"
  "/Users/test/projects/repo-delta"
  "/Users/test/projects/repo-echo-the-fifth"
)

pids=()
for p in "${paths[@]}"; do
  ( claude_modes::register_repo "$p" >/dev/null 2>&1 ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

# 5 lines should exist; each must match exactly one input path.
lines=$(wc -l < "$REGISTRY" | tr -d '[:space:]')
claude_modes_test::assert_eq "5" "$lines"

claude_modes_test::it "every concurrent appender's line is intact"
all_intact=1
while IFS= read -r line; do
  matched=0
  for p in "${paths[@]}"; do
    if [ "$line" = "$p" ]; then
      matched=1
      break
    fi
  done
  if [ "$matched" -ne 1 ]; then
    all_intact=0
    echo "      corrupted/unknown line: '$line'" >&2
    break
  fi
done < "$REGISTRY"
if [ "$all_intact" -eq 1 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "at least one line did not match a source path"
fi

# ─── Scenario 8: re-asserts 0600 even if file pre-existed weaker ─────
claude_modes_test::it "register_repo re-asserts 0600 on a pre-existing 0644 file"
rm -f "$REGISTRY"
: > "$REGISTRY"          # creates with default umask (typically 0644)
chmod 0644 "$REGISTRY"   # force weaker perms
claude_modes::register_repo "/tmp/repoX" >/dev/null 2>&1
perms=$(_perms "$REGISTRY")
claude_modes_test::assert_eq "600" "$perms"

# ─── Scenario 9: empty arg returns non-zero ─────────────────────────
claude_modes_test::it "register_repo with empty arg returns non-zero"
if claude_modes::register_repo "" >/dev/null 2>&1; then
  claude_modes_test::fail "expected non-zero exit for empty repo path"
else
  claude_modes_test::pass
fi

# ─── Scenario 10: setup-creates-registry-then-register both 0600 ────
# Mirrors the setup.sh path: setup creates the empty registry at 0600,
# then subsequent /mode:set calls register_repo. Both should yield 0600.
claude_modes_test::it "setup-precreates-then-register sequence keeps 0600"
rm -f "$REGISTRY"
(umask 077 && : > "$REGISTRY")  # setup's "born at 0600, empty" pattern
perms_after_setup=$(_perms "$REGISTRY")
claude_modes_test::assert_eq "600" "$perms_after_setup"

claude_modes_test::it "register_repo on a setup-created empty file stays 0600"
claude_modes::register_repo "/tmp/post-setup-repo" >/dev/null 2>&1
perms=$(_perms "$REGISTRY")
claude_modes_test::assert_eq "600" "$perms"

claude_modes_test::teardown

printf '\n%s: %d passed, %d failed\n' \
  "install-registry.test.sh" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

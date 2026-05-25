#!/usr/bin/env bash
# U6 integration: R26 crash-safety extension to /mode:setup.
#
# Scenarios:
#   1. Simulated SIGKILL mid-move-loop (via
#      CLAUDE_MODES_SETUP_TEST_INTERRUPT_AFTER_MOVES env var):
#      - sentinel persists across the "kill"
#      - re-running converges; end state == non-interrupted run
#   2. Already-installed (no sentinel) → second invocation exits non-zero
#      with "already installed" message, no destructive action.
#   3. Hard-linked file in ~/.claude/commands/ → hard-fail with message
#      including the path, link count, and two remediation options; no
#      files moved (atomic fail-before-mutation).
#   4. Hard-link skip-list bypass: same hard-linked file, but added to
#      .setup-skip-list → install proceeds, file is left in place.
#   5. No ~/.claude/commands or ~/.claude/agents → install succeeds and
#      creates empty staging dirs.
#   6. Alien symlink in commands/ → preserved in place; readlink target
#      matches pre-install; not moved into staging.
#   7. Cross-filesystem fallback test deferred (hard to test in CI without
#      a separate mount; documented with DEFERRED message and skipped).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

PY="${CLAUDE_MODES_PYTHON3}"

_perms() {
  stat -f '%A' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

_sha() {
  shasum "$1" 2>/dev/null | awk '{print $1}'
}

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 1: simulated crash mid-move + resume convergence.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

mkdir -p "${HOME}/.claude/commands"
mkdir -p "${HOME}/.claude/agents"
for n in alpha beta gamma delta epsilon; do
  printf '# %s\nbody-of-%s\n' "$n" "$n" > "${HOME}/.claude/commands/${n}.md"
done
for n in agentA agentB; do
  printf '# %s\nbody-of-%s\n' "$n" "$n" > "${HOME}/.claude/agents/${n}.md"
done

# Record pre-shas so we can verify content integrity after recovery.
declare -A SHA_BEFORE
for f in "${HOME}/.claude/commands"/*.md "${HOME}/.claude/agents"/*.md; do
  SHA_BEFORE["$(basename "$f")"]=$(_sha "$f")
done

# Interrupt after the 2nd move.
CLAUDE_MODES_SETUP_TEST_INTERRUPT_AFTER_MOVES=2 \
  bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
FIRST_RC=$?

claude_modes_test::it "1: interrupted setup exits 137"
claude_modes_test::assert_eq "137" "$FIRST_RC"

claude_modes_test::it "1: sentinel persists across the simulated crash"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.setup.in-progress"

# Re-run without interrupt → should resume + converge.
RESUME_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
RESUME_RC=$?

claude_modes_test::it "1: resume run exits 0"
claude_modes_test::assert_eq "0" "$RESUME_RC"

claude_modes_test::it "1: resume log mentions 'resuming previous /mode:setup'"
claude_modes_test::assert_contains "$RESUME_OUT" "resuming previous"

claude_modes_test::it "1: sentinel cleared after resume"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.setup.in-progress"

# Verify every file is now symlinked + content intact.
claude_modes_test::it "1: all 5 commands are symlinks after resume"
all_symlinks=1
for n in alpha beta gamma delta epsilon; do
  if [ ! -L "${HOME}/.claude/commands/${n}.md" ]; then
    all_symlinks=0
    break
  fi
done
claude_modes_test::assert_eq "1" "$all_symlinks"

claude_modes_test::it "1: all content sha matches pre-install"
all_ok=1
for n in alpha beta gamma delta epsilon; do
  live="${HOME}/.claude/commands/${n}.md"
  post=$(_sha "$live")
  if [ "$post" != "${SHA_BEFORE[${n}.md]}" ]; then
    all_ok=0
    break
  fi
done
for n in agentA agentB; do
  live="${HOME}/.claude/agents/${n}.md"
  post=$(_sha "$live")
  if [ "$post" != "${SHA_BEFORE[${n}.md]}" ]; then
    all_ok=0
    break
  fi
done
claude_modes_test::assert_eq "1" "$all_ok"

claude_modes_test::it "1: _global.yaml exists after resume"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/_global.yaml"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 2: already-installed (no sentinel) → refuse with message.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

# First install — clean.
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
FIRST_RC=$?

claude_modes_test::it "2: first install succeeds"
claude_modes_test::assert_eq "0" "$FIRST_RC"

# Capture state hashes to verify no destructive action on second run.
PRE_GLOBAL_SHA=$(_sha "${HOME}/.claude/modes/_global.yaml")
PRE_PRISTINE_SHA=$(_sha "${HOME}/.claude/settings.json.pristine")

# Second invocation — must refuse.
SECOND_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
SECOND_RC=$?

claude_modes_test::it "2: second invocation exits non-zero"
claude_modes_test::assert_ne "0" "$SECOND_RC"

claude_modes_test::it "2: second invocation message contains 'already installed'"
claude_modes_test::assert_contains "$SECOND_OUT" "already installed"

claude_modes_test::it "2: _global.yaml unchanged after refused second invocation"
POST_GLOBAL_SHA=$(_sha "${HOME}/.claude/modes/_global.yaml")
claude_modes_test::assert_eq "$PRE_GLOBAL_SHA" "$POST_GLOBAL_SHA"

claude_modes_test::it "2: pristine unchanged after refused second invocation"
POST_PRISTINE_SHA=$(_sha "${HOME}/.claude/settings.json.pristine")
claude_modes_test::assert_eq "$PRE_PRISTINE_SHA" "$POST_PRISTINE_SHA"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 3: hard-linked file → hard-fail before any mutation.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

mkdir -p "${HOME}/.claude/commands"
# Regular file.
printf '# safe\nbody\n' > "${HOME}/.claude/commands/safe.md"
# Hard-linked file: create the file, then ln to a second path so link
# count > 1.
printf '# linked\nbody\n' > "${HOME}/.claude/commands/linked.md"
ln "${HOME}/.claude/commands/linked.md" "${HOME}/linked-elsewhere.md"

# Sanity check link count.
LINK_COUNT=$(stat -f '%l' "${HOME}/.claude/commands/linked.md" 2>/dev/null || \
             stat -c '%h' "${HOME}/.claude/commands/linked.md" 2>/dev/null)

claude_modes_test::it "3: pre-flight: hard-link count == 2"
claude_modes_test::assert_eq "2" "$LINK_COUNT"

# Run setup → must fail.
FAIL_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
FAIL_RC=$?

claude_modes_test::it "3: setup exits non-zero on hard-linked file"
claude_modes_test::assert_ne "0" "$FAIL_RC"

claude_modes_test::it "3: error mentions the file path"
claude_modes_test::assert_contains "$FAIL_OUT" "linked.md"

claude_modes_test::it "3: error mentions link count"
claude_modes_test::assert_contains "$FAIL_OUT" "2 hard links"

claude_modes_test::it "3: error mentions remediation (a) cp/rm/mv"
claude_modes_test::assert_contains "$FAIL_OUT" ".tmp"

claude_modes_test::it "3: error mentions remediation (b) skip-list"
claude_modes_test::assert_contains "$FAIL_OUT" ".setup-skip-list"

claude_modes_test::it "3: no files moved (safe.md still a regular file)"
if [ -L "${HOME}/.claude/commands/safe.md" ]; then
  claude_modes_test::fail "safe.md became a symlink — partial mutation occurred"
else
  claude_modes_test::pass
fi

claude_modes_test::it "3: linked.md still in place (not moved)"
if [ -L "${HOME}/.claude/commands/linked.md" ] || [ ! -f "${HOME}/.claude/commands/linked.md" ]; then
  claude_modes_test::fail "linked.md was moved or removed"
else
  claude_modes_test::pass
fi

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 4: hard-link bypass via skip-list.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

mkdir -p "${HOME}/.claude/commands"
mkdir -p "${HOME}/.claude/modes"
printf '# safe\nbody\n' > "${HOME}/.claude/commands/safe.md"
printf '# linked\nbody\n' > "${HOME}/.claude/commands/linked.md"
ln "${HOME}/.claude/commands/linked.md" "${HOME}/linked-elsewhere.md"

# Skip-list the linked file (touch the modes dir first to host it).
echo "${HOME}/.claude/commands/linked.md" > "${HOME}/.claude/modes/.setup-skip-list"

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
SKIP_RC=$?

claude_modes_test::it "4: setup succeeds when hard-linked file is skip-listed"
claude_modes_test::assert_eq "0" "$SKIP_RC"

claude_modes_test::it "4: safe.md is now a symlink (moved)"
claude_modes_test::assert_true "[ -L '${HOME}/.claude/commands/safe.md' ]"

claude_modes_test::it "4: linked.md left in place (regular file, not symlink)"
if [ -L "${HOME}/.claude/commands/linked.md" ]; then
  claude_modes_test::fail "skip-listed file became a symlink"
else
  claude_modes_test::pass
fi

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 5: no ~/.claude/commands or ~/.claude/agents → succeed with
# empty staging dirs.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

# No commands/ or agents/ dirs.
rm -rf "${HOME}/.claude/commands" "${HOME}/.claude/agents"

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
EMPTY_RC=$?

claude_modes_test::it "5: setup succeeds with no commands/agents dirs"
claude_modes_test::assert_eq "0" "$EMPTY_RC"

claude_modes_test::it "5: staging commands/ exists (empty)"
claude_modes_test::assert_true "[ -d '${HOME}/.claude/modes/.user-catalog/commands' ]"

claude_modes_test::it "5: staging agents/ exists (empty)"
claude_modes_test::assert_true "[ -d '${HOME}/.claude/modes/.user-catalog/agents' ]"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 6: alien (pre-install) symlink → preserved in place.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude" "${HOME}/vault"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

mkdir -p "${HOME}/.claude/commands"
# Real file in some external location.
printf '# external command\nbody\n' > "${HOME}/vault/external.md"
# Alien symlink in commands/ pointing at the external file.
ln -s "${HOME}/vault/external.md" "${HOME}/.claude/commands/external.md"
# Also a regular file we DO want moved.
printf '# regular\nbody\n' > "${HOME}/.claude/commands/regular.md"

PRE_ALIEN_TARGET=$(readlink "${HOME}/.claude/commands/external.md")

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
ALIEN_RC=$?

claude_modes_test::it "6: setup succeeds with alien symlinks present"
claude_modes_test::assert_eq "0" "$ALIEN_RC"

claude_modes_test::it "6: alien symlink still a symlink"
claude_modes_test::assert_true "[ -L '${HOME}/.claude/commands/external.md' ]"

claude_modes_test::it "6: alien symlink target unchanged"
POST_ALIEN_TARGET=$(readlink "${HOME}/.claude/commands/external.md")
claude_modes_test::assert_eq "$PRE_ALIEN_TARGET" "$POST_ALIEN_TARGET"

claude_modes_test::it "6: alien NOT copied into staging (not moved)"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.user-catalog/commands/external.md"

claude_modes_test::it "6: regular file WAS moved (and is now a symlink)"
claude_modes_test::assert_true "[ -L '${HOME}/.claude/commands/regular.md' ]"

claude_modes_test::teardown

# Scenario 7 (cross-filesystem fallback) is DEFERRED — it needs a distinct
# mount point, impractical in CI. Removed the vacuous `it`+`pass` pair that
# inflated the count with zero assertion (testing re-review P3). The cp+verify
# +rm fallback path in _apply_category remains exercised only manually.

# ══════════════════════════════════════════════════════════════════════
# SCENARIO 8 (rel-001 regression): cross-category atomic-fail.
# A hard-linked file in AGENTS with a regular file in COMMANDS must leave
# commands UNTOUCHED — the bug was that commands' move ran (and symlinked)
# before agents' pre-flight aborted, breaking the "no files moved" promise.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "claude-modes@local-dev": true } }
EOF

# COMMANDS: a clean regular file (must NOT be moved).
mkdir -p "${HOME}/.claude/commands"
printf '# cmd\nbody\n' > "${HOME}/.claude/commands/clean-cmd.md"

# AGENTS: a hard-linked file (must trigger the abort).
mkdir -p "${HOME}/.claude/agents"
printf '# agent\nbody\n' > "${HOME}/.claude/agents/linked-agent.md"
ln "${HOME}/.claude/agents/linked-agent.md" "${HOME}/agent-elsewhere.md"

X8_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
X8_RC=$?

claude_modes_test::it "8: setup exits non-zero on hard-linked AGENTS file"
claude_modes_test::assert_ne "0" "$X8_RC"

claude_modes_test::it "8: error names the agents file"
claude_modes_test::assert_contains "$X8_OUT" "linked-agent.md"

claude_modes_test::it "8: CROSS-CATEGORY — commands file NOT moved (still regular, not symlink)"
if [ -L "${HOME}/.claude/commands/clean-cmd.md" ]; then
  claude_modes_test::fail "clean-cmd.md became a symlink — commands mutated before agents pre-flight aborted (rel-001 regression)"
else
  claude_modes_test::pass
fi

claude_modes_test::it "8: commands file NOT copied into staging"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.user-catalog/commands/clean-cmd.md"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════
printf '\n%s: %d passed, %d failed\n' \
  "mode-setup-crash-recovery.test.sh" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

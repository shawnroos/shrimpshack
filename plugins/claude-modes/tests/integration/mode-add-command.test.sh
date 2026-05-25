#!/usr/bin/env bash
# U5 integration test: /mode:add orchestrator (lib/mode-add.sh).
#
# Drives the orchestrator the way the /mode:add command body does:
#   bash lib/mode-add.sh <query-or-fqn> [<snapshot>]
# and asserts the exit-code contract + the on-disk effects.
#
# Exit-code contract under test:
#   0  applied   2  usage   1  failure (no-mode/no-candidates/drift/R22)
#   10 ambiguous (stdout: __SNAPSHOT__ line + candidate TSV rows)
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLAUDE_MODES_CANONICAL_ID="claude-modes@local-dev"

ADD_LIB="${PLUGIN_ROOT}/lib/mode-add.sh"
MODES_DIR="${HOME}/.claude/modes"
PY="$CLAUDE_MODES_PYTHON3"

# ── Fixture helpers ─────────────────────────────────────────────────────────

# Seed an active tier-3 mode (schema 2, prose layer + mechanism).
__seed_design_mode() {
  mkdir -p "$MODES_DIR"
  cat > "${MODES_DIR}/design.yaml" <<'YAML'
schema_version: 2
name: design
description: |
  Visual and UI work mode.
philosophy: |
  Optimize for design tools.
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands: []
    agents: []
YAML
  chmod 0600 "${MODES_DIR}/design.yaml"
  printf 'design' > "${MODES_DIR}/.last-active-mode"
}

# Seed installed_plugins.json (LIST-of-records shape) with one plugin.
__seed_installed() {
  mkdir -p "${HOME}/.claude/plugins"
  cat > "${HOME}/.claude/plugins/installed_plugins.json" <<JSON
{"plugins": {"$1": [{"scope": "user", "installPath": "/fake/$1"}]}}
JSON
}

# Force a GENUINE ambiguous (exit 10) resolution. The resolver matches by
# EXACT name (not substring), so ambiguity requires the SAME name to appear
# in two sources: here a cached SKILL named "figma" AND an installed PLUGIN
# named "figma". (Two plugins sharing a prefix would NOT be ambiguous —
# exact-match disambiguates them.)
__seed_two_matching() {
  mkdir -p "${HOME}/.claude/plugins"
  cat > "${HOME}/.claude/plugins/installed_plugins.json" <<'JSON'
{"plugins": {"figma@every-marketplace": [{"scope": "user", "installPath": "/fake/a"}]}}
JSON
  local skilldir="${HOME}/.claude/plugins/cache/mkt/someplugin/1.0.0/.claude/skills/figma"
  mkdir -p "$skilldir"
  printf -- '---\nname: figma\ndescription: fixture\n---\nbody\n' > "${skilldir}/SKILL.md"
}

__reset() {
  rm -rf "${HOME}/.claude"
  mkdir -m 0700 -p "$MODES_DIR"
}

# Seed a PLUGIN-SHIPPED skill in the cache (proper --- YAML frontmatter) AND
# register its parent plugin in installed_plugins.json, so the resolver emits
# parent_plugin=<plugin>@<market> and the orchestrator can route to add-plugin.
__seed_cached_skill_with_installed_parent() {
  local plugin="$1" skill="$2" market="${3:-every-marketplace}"
  local skilldir="${HOME}/.claude/plugins/cache/mkt/${plugin}/1.0.0/.claude/skills/${skill}"
  mkdir -p "$skilldir"
  printf -- '---\nname: %s\ndescription: fixture\n---\nbody\n' "$skill" > "${skilldir}/SKILL.md"
  mkdir -p "${HOME}/.claude/plugins"
  cat > "${HOME}/.claude/plugins/installed_plugins.json" <<JSON
{"plugins": {"${plugin}@${market}": [{"scope": "user", "installPath": "/fake/${plugin}"}]}}
JSON
}

# True if basename is present in mechanism.user_catalog.agents.
__in_user_catalog_agents() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
agents = ((data.get("mechanism") or {}).get("user_catalog") or {}).get("agents") or []
print("True" if sys.argv[2] in agents else "False")
PYEOF
}

__plugin_in_mechanism() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
mech = (data.get("mechanism") or {}).get("enabledPlugins") or {}
print("True" if sys.argv[2] in mech else "False")
PYEOF
}

__audit_last() { tail -n 1 "${MODES_DIR}/.audit.log" 2>/dev/null; }
# Grep the WHOLE audit log — apply_delta writes mode_edit_accept, then
# post_write_reload writes mode_reload_prompt, so mode_edit_accept is not the
# last line. Use this for assertions about apply_delta's event.
__audit_has() { grep -q "$1" "${MODES_DIR}/.audit.log" 2>/dev/null; }

# ── Scenario: happy path, single FQN candidate applies ──────────────────────
# Batch-4 Finding 3: the FQN-shortcut path is fail-CLOSED — it REQUIRES a
# non-empty snapshot (it's the re-invoke/power-user path; a re-invoke that lost
# its snapshot must not silently clobber a concurrent edit). So a direct FQN add
# passes the current YAML hash as the snapshot.
__reset; __seed_design_mode; __seed_installed "figma@every-marketplace"
snap=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" sha256 "${MODES_DIR}/design.yaml")
claude_modes_test::it "happy: add an FQN-shaped plugin (with snapshot) → exit 0"
out=$(bash "$ADD_LIB" "figma@every-marketplace" "$snap" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... plugin now in mechanism.enabledPlugins"
claude_modes_test::assert_eq "True" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "figma@every-marketplace")"
claude_modes_test::it "  ... audit records mode_edit_accept (apply_delta event)"
if __audit_has "mode_edit_accept"; then claude_modes_test::pass; else
  claude_modes_test::fail "no mode_edit_accept in audit log"; fi

# ── Scenario: Batch-4 Finding 3 (+ follow-up) — FQN-shortcut WITHOUT a snapshot ─
# A bare FQN with NO snapshot can't prove the YAML is unchanged, so it's refused
# fail-closed rather than waved through (the old fail-OPEN: empty snapshot SKIPPED
# the drift check entirely). The follow-up split distinguishes this MISSING-
# snapshot case (a one-shot FQN add, audited step=snapshot_missing, with an
# actionable "use the plugin NAME" message) from a PRESENT-but-stale snapshot
# (genuine concurrent drift, step=drift_detected) — see the drift scenario below.
__reset; __seed_design_mode; __seed_installed "figma@every-marketplace"
claude_modes_test::it "fail-closed: FQN arg with EMPTY snapshot → exit 1"
out=$(bash "$ADD_LIB" "figma@every-marketplace" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"
claude_modes_test::it "  ... refusal names the actionable workaround (use the NAME)"
claude_modes_test::assert_contains "$out" "NAME"
claude_modes_test::it "  ... YAML NOT mutated (no fail-open write)"
claude_modes_test::assert_eq "False" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "figma@every-marketplace")"
claude_modes_test::it "  ... audit records step=snapshot_missing (not drift — nothing changed)"
claude_modes_test::assert_contains "$(__audit_last)" "snapshot_missing"

# ── Scenario: happy path, single resolved candidate by bare query ───────────
__reset; __seed_design_mode; __seed_installed "slack@every-marketplace"
claude_modes_test::it "happy: bare query resolves to one candidate → exit 0"
out=$(bash "$ADD_LIB" "slack" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... resolved plugin in mechanism"
claude_modes_test::assert_eq "True" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "slack@every-marketplace")"

# ── Scenario: ambiguous → exit 10 + snapshot + candidate rows ───────────────
__reset; __seed_design_mode; __seed_two_matching
claude_modes_test::it "ambiguous: two matches → exit 10"
out=$(bash "$ADD_LIB" "figma" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "10" "$rc"
claude_modes_test::it "  ... stdout carries a __SNAPSHOT__ line"
claude_modes_test::assert_contains "$out" "__SNAPSHOT__="
claude_modes_test::it "  ... stdout carries candidate TSV rows"
claude_modes_test::assert_contains "$out" "kind="
claude_modes_test::it "  ... ambiguous run did NOT mutate the YAML"
claude_modes_test::assert_eq "False" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "figma@every-marketplace")"

# ── Scenario: re-invoke with chosen FQN + snapshot applies (disambig loop) ──
snap=$(printf '%s' "$out" | sed -n 's/^__SNAPSHOT__=//p' | head -1)
claude_modes_test::it "disambig: re-invoke with FQN + snapshot → exit 0"
out2=$(bash "$ADD_LIB" "figma@every-marketplace" "$snap" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... chosen plugin applied"
claude_modes_test::assert_eq "True" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "figma@every-marketplace")"

# ── Scenario: drift — snapshot stale → refuse ───────────────────────────────
__reset; __seed_design_mode; __seed_two_matching
out=$(bash "$ADD_LIB" "figma" 2>/dev/null)
snap=$(printf '%s' "$out" | sed -n 's/^__SNAPSHOT__=//p' | head -1)
# Mutate the YAML AFTER capturing the snapshot (simulates concurrent edit).
printf '\n# concurrent edit\n' >> "${MODES_DIR}/design.yaml"
claude_modes_test::it "drift: re-invoke with stale snapshot → exit 1"
out2=$(bash "$ADD_LIB" "figma@every-marketplace" "$snap" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"
claude_modes_test::it "  ... drift message surfaced"
claude_modes_test::assert_contains "$out2" "changed"
claude_modes_test::it "  ... audit records step=drift_detected"
claude_modes_test::assert_contains "$(__audit_last)" "drift_detected"

# ── Scenario: no candidates ─────────────────────────────────────────────────
__reset; __seed_design_mode; __seed_installed "figma@every-marketplace"
claude_modes_test::it "no-match: unknown query → exit 1"
out=$(bash "$ADD_LIB" "nonesuch-plugin-xyz" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"

# ── Scenario: no active mode ────────────────────────────────────────────────
__reset; __seed_installed "figma@every-marketplace"   # NO active mode seeded
claude_modes_test::it "no-active-mode: refuse → exit 1"
out=$(bash "$ADD_LIB" "figma@every-marketplace" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"
claude_modes_test::it "  ... message points at /mode:set"
claude_modes_test::assert_contains "$out" "mode:set"

# ── Scenario: usage (no arg) ────────────────────────────────────────────────
__reset; __seed_design_mode
claude_modes_test::it "usage: no arg → exit 2"
bash "$ADD_LIB" >/dev/null 2>&1; rc=$?
claude_modes_test::assert_eq "2" "$rc"

# ── Scenario (Batch-4 Finding 1): plugin-shipped skill enables its PARENT PLUGIN,
#    NOT a colon-FQN in user_catalog.agents. This exercises mode-add.sh's
#    verb×kind glue (the skill→parent-plugin rewrite + add-plugin op), not just
#    apply-delta. The skill resolves by bare NAME to a single candidate carrying
#    parent_plugin=iloom-lite@every-marketplace.
__reset; __seed_design_mode; __seed_cached_skill_with_installed_parent "iloom-lite" "planr"
claude_modes_test::it "skill: /mode:add a plugin-shipped skill by name → exit 0"
out=$(bash "$ADD_LIB" "planr" 2>&1); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... PARENT PLUGIN landed in mechanism.enabledPlugins"
claude_modes_test::assert_eq "True" "$(__plugin_in_mechanism "${MODES_DIR}/design.yaml" "iloom-lite@every-marketplace")"
claude_modes_test::it "  ... NO colon-FQN written into user_catalog.agents (the dangling-ref bug)"
claude_modes_test::assert_eq "False" "$(__in_user_catalog_agents "${MODES_DIR}/design.yaml" "iloom-lite:planr")"

# ── Scenario (Batch-4 Finding 1): a plugin-shipped skill whose parent plugin is
#    NOT installed → refuse (you enable it by installing the plugin).
__reset; __seed_design_mode
# Cached skill present, but NO installed_plugins.json entry for its plugin.
__skdir="${HOME}/.claude/plugins/cache/mkt/uninst-plugin/1.0.0/.claude/skills/orphan"
mkdir -p "$__skdir"
printf -- '---\nname: orphan\ndescription: fixture\n---\nbody\n' > "${__skdir}/SKILL.md"
claude_modes_test::it "skill: parent plugin NOT installed → exit 1 (refuse)"
out=$(bash "$ADD_LIB" "orphan" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"
claude_modes_test::it "  ... message points the user at /plugin install"
claude_modes_test::assert_contains "$out" "plugin install"
claude_modes_test::it "  ... nothing written to user_catalog.agents"
claude_modes_test::assert_eq "False" "$(__in_user_catalog_agents "${MODES_DIR}/design.yaml" "uninst-plugin:orphan")"

# ── Scenario (Batch-4 Finding 4): idempotent no-op → exit 0, NO reload prompt,
#    audit shows no_change (NOT a bare mode_reload_prompt for a write that
#    didn't happen). First add the plugin (real write), then add it again.
__reset; __seed_design_mode; __seed_installed "figma@every-marketplace"
snap=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" sha256 "${MODES_DIR}/design.yaml")
bash "$ADD_LIB" "figma@every-marketplace" "$snap" >/dev/null 2>&1   # real write
# Now re-add the SAME plugin via a bare query (resolve path, no snapshot needed).
claude_modes_test::it "no-op: re-add an already-present plugin → exit 0"
out=$(bash "$ADD_LIB" "figma" 2>&1); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... NO reload prompt printed (nothing was written)"
case "$out" in
  *"/reload-plugins"*) claude_modes_test::fail "reload prompt printed on a no-op: $out" ;;
  *) claude_modes_test::pass ;;
esac
claude_modes_test::it "  ... 'Mode updated' NOT printed on a no-op"
case "$out" in
  *"updated"*) claude_modes_test::fail "'updated' printed on a no-op: $out" ;;
  *) claude_modes_test::pass ;;
esac
claude_modes_test::it "  ... audit records step=no_change (not a phantom reload)"
claude_modes_test::assert_contains "$(__audit_last)" "no_change"

# ── Scenario (Batch-4 Finding 8): the catalog lock is NOT held across the
#    exit-10 human-in-the-loop dwell. The flock is acquired per-bash-process and
#    released when the process exits (exit 10 included), so BETWEEN the two
#    invocations (the AskUserQuestion dwell) the lock is free — a concurrent
#    claude-modes op must not be blocked. Observable assertion: after the exit-10
#    process returns, a NON-BLOCKING flock (LOCK_EX|LOCK_NB) on the same lock
#    file succeeds immediately (rc 0). If the lock were held across the dwell,
#    the non-blocking acquire would fail (rc 1).
__lock_is_free() {
  # Echo "free" if a non-blocking exclusive flock on $1 succeeds, "held" if it
  # would block. fcntl.flock is per-open-FD, so this fresh open() truly probes
  # whether any OTHER live process holds the lock.
  "$PY" - "$1" <<'PYEOF'
import sys, fcntl
path = sys.argv[1]
try:
    f = open(path, "a+")
except OSError:
    print("free")  # no lock file yet → nothing holds it
    sys.exit(0)
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
except OSError:
    print("held")
PYEOF
}

__reset; __seed_design_mode; __seed_two_matching
LOCK_PATH="${MODES_DIR}/.symlink-lock"
claude_modes_test::it "lock-dwell: ambiguous (exit 10) invocation → exit 10"
out=$(bash "$ADD_LIB" "figma" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "10" "$rc"
claude_modes_test::it "  ... lock is FREE after the exit-10 process exits (not held across the dwell)"
claude_modes_test::assert_eq "free" "$(__lock_is_free "$LOCK_PATH")"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]

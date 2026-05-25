#!/usr/bin/env bash
# U5 integration: /mode:set + /mode:clear + /mode:apply with R26 crash safety.
#
# Test scenarios:
#   1. Happy path /mode:set delivery — cascade runs, settings.local.json
#      written, symlink rebuild runs, per-branch state file written,
#      .last-active-mode updated, sentinel cleared, signal printed.
#   2. /mode:clear — removes per-branch pointer, re-runs cascade with no
#      tier-3, restores day-zero symlink topology, clears
#      .last-active-mode, signals user.
#   3. Detached HEAD — branch slug = detached-<short-sha>; per-branch
#      state file lives at that name.
#   4. No git repo — no per-branch state file written; .last-active-mode
#      updated; signal mentions no-git-repo.
#   5. R26 crash recovery (same target) — sentinel exists for "delivery";
#      /mode:set delivery resumes idempotently; sentinel cleared; end
#      state correct.
#   6. R26 crash recovery (different target) — sentinel exists for
#      "delivery"; /mode:set discovery replaces sentinel; ends with
#      discovery active.
#   7. /mode:set claude rejected (reserved token).
#   8. Idempotency — /mode:set delivery twice produces identical
#      settings.local.json (byte-equal).
#   9. /mode:apply re-runs the current mode's cascade.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3}"
ID="claude-modes@local-dev"

# ──────────────────────────────────────────────────────────────────────
# Per-test scaffolding.

# Re-seed the modes dir + repo for each scenario block. Some scenarios
# share state intentionally; the ones that need a fresh world call this.
__seed_modes_dir() {
  mkdir -p "${HOME}/.claude/modes"

  # Tier 2: _global.yaml carries claude-modes itself + a baseline plugin.
  cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
    "baseline@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/_global.yaml"

  # Tier 3: delivery + discovery.
  cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
philosophy: |
  Ship the slice.
mechanism:
  enabledPlugins:
    "delivery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"

  cat > "${HOME}/.claude/modes/discovery.yaml" <<EOF
schema_version: 2
name: discovery
philosophy: |
  Explore the space.
mechanism:
  enabledPlugins:
    "discovery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/discovery.yaml"
}

__make_repo() {
  local path="$1"
  local branch="${2:-main}"
  mkdir -p "$path"
  (
    cd "$path"
    git init -q -b "$branch" >/dev/null 2>&1
    git config user.email "test@test"
    git config user.name "test"
    # Need at least one commit so detached HEAD scenarios can checkout.
    : > .gitkeep
    git add .gitkeep
    git commit -q -m "init" --allow-empty
  )
}

# Run set-mode.sh from within a repo (so its git-context detection works).
__run_set_mode_in() {
  local cwd="$1"; shift
  ( cd "$cwd" && bash "${PLUGIN_ROOT}/lib/set-mode.sh" "$@" )
}

# Run apply-mode.sh from within a repo.
__run_apply_mode_in() {
  local cwd="$1"
  ( cd "$cwd" && bash "${PLUGIN_ROOT}/lib/apply-mode.sh" )
}

# Extract enabledPlugins keys from a settings.local.json.
__keys_of_settings() {
  local path="$1"
  "$PY" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
ep = d.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "$path"
}

# SHA256 of a file.
__sha256() {
  local path="$1"
  "$PY" -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())
' "$path"
}

# ──────────────────────────────────────────────────────────────────────
# Scenario 1: Happy path /mode:set delivery.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO="${HOME}/repo-delivery"
__make_repo "$REPO"

claude_modes_test::it "/mode:set delivery exits 0"
out=$(__run_set_mode_in "$REPO" delivery 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "settings.local.json was written"
claude_modes_test::assert_file_exists "${REPO}/.claude/settings.local.json"

claude_modes_test::it "settings.local.json includes delivery-plugin + baseline + claude-modes"
keys=$(__keys_of_settings "${REPO}/.claude/settings.local.json")
expected="baseline@market,${ID},delivery-plugin@market"
claude_modes_test::assert_eq "$expected" "$keys"

claude_modes_test::it "per-branch state file written at main.mode"
claude_modes_test::assert_file_exists "${REPO}/.claude/modes/main.mode"

claude_modes_test::it "per-branch state file contains 'delivery'"
content=$(tr -d '[:space:]' < "${REPO}/.claude/modes/main.mode")
claude_modes_test::assert_eq "delivery" "$content"

claude_modes_test::it ".last-active-mode contains 'delivery'"
content=$(tr -d '[:space:]' < "${HOME}/.claude/modes/.last-active-mode")
claude_modes_test::assert_eq "delivery" "$content"

claude_modes_test::it "sentinel cleared after success"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.mode-set.in-progress"

claude_modes_test::it "user-facing signal mentions /reload-plugins"
claude_modes_test::assert_contains "$out" "/reload-plugins"

claude_modes_test::it "audit log contains mode_set outcome=ok"
audit=$(cat "${HOME}/.claude/modes/.audit.log" 2>/dev/null)
case "$audit" in
  *"event=mode_set"*"outcome=ok"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "no mode_set ok audit event found in: ${audit}" ;;
esac

# ──────────────────────────────────────────────────────────────────────
# Scenario 2: /mode:clear after /mode:set delivery.
# ──────────────────────────────────────────────────────────────────────
claude_modes_test::it "/mode:clear exits 0"
out=$(__run_set_mode_in "$REPO" --clear 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "per-branch state file removed after clear"
claude_modes_test::assert_file_absent "${REPO}/.claude/modes/main.mode"

claude_modes_test::it ".last-active-mode removed after clear"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.last-active-mode"

claude_modes_test::it "settings.local.json no longer mentions delivery-plugin"
if grep -q "delivery-plugin" "${REPO}/.claude/settings.local.json"; then
  claude_modes_test::fail "settings.local.json still references delivery-plugin"
else
  claude_modes_test::pass
fi

claude_modes_test::it "settings.local.json still mentions baseline + claude-modes (tier 1+2+4)"
keys=$(__keys_of_settings "${REPO}/.claude/settings.local.json")
expected="baseline@market,${ID}"
claude_modes_test::assert_eq "$expected" "$keys"

claude_modes_test::it "clear sentinel cleared after success"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.mode-set.in-progress"

claude_modes_test::it "clear signal mentions Claude Mode"
claude_modes_test::assert_contains "$out" "Claude Mode"

claude_modes_test::it "audit log contains mode_clear outcome=ok"
audit=$(cat "${HOME}/.claude/modes/.audit.log" 2>/dev/null)
case "$audit" in
  *"event=mode_clear"*"outcome=ok"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "no mode_clear ok audit event found" ;;
esac

# ──────────────────────────────────────────────────────────────────────
# Scenario 3: Detached HEAD — slug = detached-<short-sha>.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_DET="${HOME}/repo-detached"
__make_repo "$REPO_DET"
( cd "$REPO_DET" && git checkout --detach HEAD >/dev/null 2>&1 )

claude_modes_test::it "/mode:set delivery in detached HEAD exits 0"
out=$(__run_set_mode_in "$REPO_DET" delivery 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "per-branch state file at detached-<short-sha>.mode"
short_sha=$( cd "$REPO_DET" && git rev-parse --short HEAD )
claude_modes_test::assert_file_exists "${REPO_DET}/.claude/modes/detached-${short_sha}.mode"

claude_modes_test::it "detached-mode file contains 'delivery'"
content=$(tr -d '[:space:]' < "${REPO_DET}/.claude/modes/detached-${short_sha}.mode")
claude_modes_test::assert_eq "delivery" "$content"

claude_modes_test::it "detached-HEAD signal references the slug"
claude_modes_test::assert_contains "$out" "detached-${short_sha}"

# ──────────────────────────────────────────────────────────────────────
# Scenario 4: No-repo case (/mode:set in /tmp-ish).
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
# Clear any state from prior scenarios so the user-global write is a
# fresh observable.
rm -f "${HOME}/.claude/modes/.last-active-mode"

# Use a directory inside $HOME that is NOT a git repo.
NO_REPO_DIR="${HOME}/not-a-repo"
mkdir -p "$NO_REPO_DIR"

claude_modes_test::it "/mode:set delivery in no-repo exits 0"
out=$(__run_set_mode_in "$NO_REPO_DIR" delivery 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "no-repo: .last-active-mode contains 'delivery'"
content=$(tr -d '[:space:]' < "${HOME}/.claude/modes/.last-active-mode" 2>/dev/null)
claude_modes_test::assert_eq "delivery" "$content"

claude_modes_test::it "no-repo: no per-branch .mode file created under $NO_REPO_DIR"
count=$(find "$NO_REPO_DIR" -name '*.mode' 2>/dev/null | wc -l | tr -d '[:space:]')
claude_modes_test::assert_eq "0" "$count"

claude_modes_test::it "no-repo signal mentions 'no git repo'"
claude_modes_test::assert_contains "$out" "no git repo"

# ──────────────────────────────────────────────────────────────────────
# Scenario 5: R26 crash recovery — same target resumes.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_R26A="${HOME}/repo-r26a"
__make_repo "$REPO_R26A"

# Plant a stale sentinel matching the about-to-run target.
printf 'delivery' > "${HOME}/.claude/modes/.mode-set.in-progress"
chmod 0600 "${HOME}/.claude/modes/.mode-set.in-progress"

# Crash simulation: the atomic mv inside cascade-engine.py means
# settings.local.json is either pre-write (absent) or post-write (valid
# JSON of a prior cascade run) — NEVER partial JSON. Per V2 plan
# "settings.local.json is either pre-write or post-write atomic state,
# never partial". Simulate the pre-write case by leaving the file
# absent; a real interrupted /mode:set leaves the sentinel here too.
# (No settings.local.json file written yet.)

claude_modes_test::it "R26 same-target: /mode:set delivery exits 0"
out=$(__run_set_mode_in "$REPO_R26A" delivery 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "R26 same-target: stderr mentions 'resuming previous'"
case "$out" in
  *"resuming previous"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "expected 'resuming previous' in stderr, got: $out" ;;
esac

claude_modes_test::it "R26 same-target: sentinel cleared post-success"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.mode-set.in-progress"

claude_modes_test::it "R26 same-target: end-state settings.local.json valid + has delivery"
keys=$(__keys_of_settings "${REPO_R26A}/.claude/settings.local.json")
expected="baseline@market,${ID},delivery-plugin@market"
claude_modes_test::assert_eq "$expected" "$keys"

claude_modes_test::it "R26 same-target: per-branch state file written"
claude_modes_test::assert_file_exists "${REPO_R26A}/.claude/modes/main.mode"

# ──────────────────────────────────────────────────────────────────────
# Scenario 6: R26 crash recovery — different target replaces sentinel.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_R26B="${HOME}/repo-r26b"
__make_repo "$REPO_R26B"

# Plant a stale sentinel for a DIFFERENT target.
printf 'delivery' > "${HOME}/.claude/modes/.mode-set.in-progress"
chmod 0600 "${HOME}/.claude/modes/.mode-set.in-progress"

claude_modes_test::it "R26 different-target: /mode:set discovery exits 0"
out=$(__run_set_mode_in "$REPO_R26B" discovery 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "R26 different-target: stderr mentions 'replacing'"
case "$out" in
  *"replacing with discovery"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "expected 'replacing with discovery' in stderr, got: $out" ;;
esac

claude_modes_test::it "R26 different-target: end-state contains discovery"
keys=$(__keys_of_settings "${REPO_R26B}/.claude/settings.local.json")
expected="baseline@market,${ID},discovery-plugin@market"
claude_modes_test::assert_eq "$expected" "$keys"

claude_modes_test::it "R26 different-target: per-branch file says 'discovery'"
content=$(tr -d '[:space:]' < "${REPO_R26B}/.claude/modes/main.mode")
claude_modes_test::assert_eq "discovery" "$content"

claude_modes_test::it "R26 different-target: sentinel cleared post-success"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.mode-set.in-progress"

# ──────────────────────────────────────────────────────────────────────
# Scenario 7: /mode:set claude rejected (reserved token).
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_RES="${HOME}/repo-reserved"
__make_repo "$REPO_RES"

claude_modes_test::it "/mode:set claude exits non-zero (reserved token)"
out=$(__run_set_mode_in "$REPO_RES" claude 2>&1)
rc=$?
claude_modes_test::assert_ne "0" "$rc"

claude_modes_test::it "/mode:set claude error mentions reserved"
claude_modes_test::assert_contains "$out" "reserved"

claude_modes_test::it "/mode:set claude did NOT write per-branch state"
claude_modes_test::assert_file_absent "${REPO_RES}/.claude/modes/main.mode"

# ──────────────────────────────────────────────────────────────────────
# Scenario 8: Idempotency — two runs converge to byte-identical output.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_IDEM="${HOME}/repo-idem"
__make_repo "$REPO_IDEM"

__run_set_mode_in "$REPO_IDEM" delivery >/dev/null 2>&1
hash1=$(__sha256 "${REPO_IDEM}/.claude/settings.local.json")
__run_set_mode_in "$REPO_IDEM" delivery >/dev/null 2>&1
hash2=$(__sha256 "${REPO_IDEM}/.claude/settings.local.json")

claude_modes_test::it "idempotency: two /mode:set runs produce identical settings.local.json"
claude_modes_test::assert_eq "$hash1" "$hash2"

claude_modes_test::it "idempotency: sentinel still cleared after second run"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.mode-set.in-progress"

# ──────────────────────────────────────────────────────────────────────
# Scenario 9: /mode:apply re-runs cascade for active mode.
# ──────────────────────────────────────────────────────────────────────
__seed_modes_dir
REPO_APP="${HOME}/repo-apply"
__make_repo "$REPO_APP"

__run_set_mode_in "$REPO_APP" delivery >/dev/null 2>&1
keys_pre=$(__keys_of_settings "${REPO_APP}/.claude/settings.local.json")

# Wipe the enabledPlugins slice (keep the file valid JSON so the cascade
# doesn't bail out via its preserve-user-data guard). The cascade engine
# treats enabledPlugins as the plugin-owned key — apply should restore
# it from the cascade output.
printf '{"enabledPlugins":{}}\n' > "${REPO_APP}/.claude/settings.local.json"

claude_modes_test::it "/mode:apply exits 0"
out=$(__run_apply_mode_in "$REPO_APP" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "/mode:apply restores enabledPlugins from cascade"
keys_post=$(__keys_of_settings "${REPO_APP}/.claude/settings.local.json")
claude_modes_test::assert_eq "$keys_pre" "$keys_post"

claude_modes_test::it "/mode:apply preserves non-plugin-owned keys"
# Seed a non-plugin-owned key, run apply, assert it survives.
"$PY" -c '
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d["userOwnedKey"] = "preserved"
with open(path, "w") as f:
    json.dump(d, f)
' "${REPO_APP}/.claude/settings.local.json"
__run_apply_mode_in "$REPO_APP" >/dev/null 2>&1
after=$("$PY" -c '
import json, sys
print(json.load(open(sys.argv[1])).get("userOwnedKey", ""))
' "${REPO_APP}/.claude/settings.local.json")
claude_modes_test::assert_eq "preserved" "$after"

# ──────────────────────────────────────────────────────────────────────
# Teardown + summary.

claude_modes_test::teardown

# Summary line in the format tests/run.sh expects.
echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

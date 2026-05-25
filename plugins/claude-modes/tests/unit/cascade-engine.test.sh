#!/usr/bin/env bash
# U4 unit test: cascade-engine.py merge logic + R22 + R30 + atomicity.
#
# Test scenarios:
#   1. Happy path: tier_2 {A:true,B:true,claude-modes:true} + tier_3 {D:true}
#      → result {A,B,D,claude-modes}; R22 satisfied; settings.local.json
#      and sidecar both born at 0600
#   2. Disable: tier_2 {A:true,B:true,claude-modes:true} + tier_3
#      disable.enabledPlugins: [A] → result {B,claude-modes} only
#   3. R22 satisfied by tier 2 only: mode YAML omits claude-modes but
#      _global.yaml has it → cascade proceeds successfully
#   4. R22 violation: neither tier has claude-modes → exit code 1,
#      error mentions both "claude-modes" and "every mode"
#   5. R30 symlink-safety: planted _repo.yaml symlink → exit code 4,
#      no write to settings.local.json or sidecar
#   6. Atomicity: kill mid-write (signal sent to a subshell) → no partial
#      settings.local.json, no .cascade-meta.json
#   7. Non-plugin-owned keys preserved: existing settings.local.json
#      contains "statusLine" → after compile, "statusLine" still present
#      verbatim; "enabledPlugins" overwritten with merged
#   8. Sidecar contents: fingerprint = sha256 of settings.local.json; meta
#      includes tool, version, compiled_at (ISO 8601), source_modes
#   9. Sidecar fingerprint matches re-hash of file

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3}"
CASCADE_PY="${PLUGIN_ROOT}/lib/cascade-engine.py"
ID="claude-modes@local-dev"

# Workspace inside the isolated $HOME for test artifacts.
WORK="${HOME}/work"
mkdir -p "${WORK}/repoA/.claude/modes"

write_yaml() {
  # write_yaml <path> <heredoc-style content>
  local p="$1" ; shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# ─── Scenario 1: happy path merge ──────────────────────────────────────
claude_modes_test::it "happy path: tier_2 + tier_3 union yields merged enabledPlugins"
T2="${WORK}/_global.yaml"
T3="${WORK}/writing.yaml"
T4=""
TARGET="${WORK}/repoA/.claude/settings.local.json"
SIDECAR="${WORK}/repoA/.claude/modes/.cascade-meta.json"
rm -f "$TARGET" "$SIDECAR"

write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "A@m": true' '    "B@m": true' "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "D@m": true'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "$T4" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  if [ -f "$TARGET" ] && [ -f "$SIDECAR" ]; then
    ep_keys=$("$PY" -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["enabledPlugins"].keys())))' "$TARGET")
    expected="A@m,B@m,D@m,${ID}"
    if [ "$ep_keys" = "$expected" ]; then
      perms_target=$(stat -f '%A' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET" 2>/dev/null)
      perms_side=$(stat -f '%A' "$SIDECAR" 2>/dev/null || stat -c '%a' "$SIDECAR" 2>/dev/null)
      if [ "$perms_target" = "600" ] && [ "$perms_side" = "600" ]; then
        claude_modes_test::pass
      else
        claude_modes_test::fail "perms target=$perms_target sidecar=$perms_side, expected 600 each"
      fi
    else
      claude_modes_test::fail "merged keys=$ep_keys, expected=$expected"
    fi
  else
    claude_modes_test::fail "expected both files: target=$([ -f $TARGET ] && echo yes || echo no), sidecar=$([ -f $SIDECAR ] && echo yes || echo no)"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on happy path"
fi

# ─── Scenario 2: disable block subtracts a plugin ──────────────────────
claude_modes_test::it "disable: tier_3 disable.enabledPlugins removes a key from cascade"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "A@m": true' '    "B@m": true' "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins: {}' \
  'disable:' '  enabledPlugins:' '    - "A@m"'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  ep_keys=$("$PY" -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["enabledPlugins"].keys())))' "$TARGET")
  expected="B@m,${ID}"
  claude_modes_test::assert_eq "$expected" "$ep_keys"
else
  claude_modes_test::fail "cascade exited non-zero with disable block"
fi

# ─── Scenario 2b: disable NESTED under mechanism: is the WRONG shape ────
# round-7 contract bug (api-contract/project-standards P1): the README + example
# YAMLs showed `disable:` indented under `mechanism:`, but the engine reads
# `disable` at the document ROOT (data.get("disable")). A nested disable is
# therefore SILENTLY IGNORED — the subtraction never happens. This locks the
# contract: a future doc/example regression re-nesting disable would let A@m
# survive, failing this test. (The docs are now fixed; this guards them.)
claude_modes_test::it "disable nested under mechanism: is silently ignored (A@m survives — documents the contract that disable is top-level only)"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "A@m": true' '    "B@m": true' "    \"${ID}\": true"
# WRONG shape: disable indented 2 spaces, under mechanism:
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins: {}' \
  '  disable:' '    enabledPlugins:' '      - "A@m"'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  ep_keys=$("$PY" -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["enabledPlugins"].keys())))' "$TARGET")
  # A@m is NOT subtracted because the nested disable was ignored.
  expected="A@m,B@m,${ID}"
  claude_modes_test::assert_eq "$expected" "$ep_keys"
else
  claude_modes_test::fail "cascade exited non-zero with nested-disable YAML"
fi

# ─── Scenario 3: R22 satisfied by tier 2 even when tier 3 omits it ─────
claude_modes_test::it "R22 satisfied by tier 2: tier_3 omits claude-modes but tier_2 has it"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "B@m": true' "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "X@m": true'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  claude_modes_test::pass
else
  claude_modes_test::fail "cascade should have proceeded since tier_2 carries claude-modes"
fi

# ─── Scenario 4: R22 violation (neither tier has claude-modes) ─────────
claude_modes_test::it "R22 violation: cascade total without claude-modes exits 1 with named error"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "B@m": true'
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "X@m": true'

err=$("$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" 2>&1)
rc=$?
if [ "$rc" = "1" ] && echo "$err" | grep -q "claude-modes" && echo "$err" | grep -q "every mode"; then
  if [ ! -f "$TARGET" ] && [ ! -f "$SIDECAR" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "R22 rejected but files were still written"
  fi
else
  claude_modes_test::fail "expected rc=1 + 'claude-modes' + 'every mode' in stderr; got rc=$rc, stderr=$err"
fi

# ─── Scenario 5: R30 symlink-safety ────────────────────────────────────
claude_modes_test::it "R30: planted _repo.yaml symlink exits 4 with SecurityError"
rm -f "$TARGET" "$SIDECAR"
# Re-establish a valid tier_2/tier_3 to isolate this test from prior state.
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins: {}'
PLANT="${WORK}/plant-target.yaml"
write_yaml "$PLANT" 'schema_version: 2' 'mechanism:' '  enabledPlugins: {}'
SYM_T4="${WORK}/repoA/.claude/modes/_repo.yaml"
rm -f "$SYM_T4"
ln -s "$PLANT" "$SYM_T4"

err=$("$PY" "$CASCADE_PY" "$T2" "$T3" "$SYM_T4" "$ID" "$TARGET" "$SIDECAR" 2>&1)
rc=$?
if [ "$rc" = "4" ] && echo "$err" | grep -q "R30"; then
  if [ ! -f "$TARGET" ] && [ ! -f "$SIDECAR" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "R30 rejected but a write happened"
  fi
else
  claude_modes_test::fail "expected rc=4 + 'R30'; got rc=$rc, stderr=$err"
fi
rm -f "$SYM_T4"

# ─── Scenario 6: atomicity — SIGTERM mid-write leaves no partial ───────
claude_modes_test::it "atomicity: SIGTERM during cascade leaves no partial settings.local.json"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  "    \"${ID}\": true"
# Build a tier-3 that is heavy enough to make timing realistic; we kill
# IMMEDIATELY so even fast cascades get interrupted before write.
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "X@m": true'

# Run cascade in a subshell, SIGTERM it before it can finish. We don't
# need it to ACTUALLY interrupt mid-write to verify the atomicity
# contract — the contract is: if interrupted, no partial files remain
# in target_path or sidecar_path (they only appear via mv from a
# temp file). The atomicity test passes if either:
#   - cascade completed before SIGTERM (both files present, consistent)
#   - SIGTERM interrupted before mv (neither file present, no .cascade.*
#     tmp leaked since trap-like cleanup is best-effort)
( "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1 ) &
CASCADE_PID=$!
kill -TERM "$CASCADE_PID" 2>/dev/null || true
wait "$CASCADE_PID" 2>/dev/null

# Verification: either both target+sidecar exist and target parses as
# valid JSON, OR neither exists. There is never a half-written target.
if [ -f "$TARGET" ]; then
  # Must be parseable
  if "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$TARGET" >/dev/null 2>&1; then
    # If target exists, sidecar must also exist (they're written in
    # sequence with atomic mv each)
    if [ -f "$SIDECAR" ]; then
      claude_modes_test::pass
    else
      claude_modes_test::fail "target written without sidecar"
    fi
  else
    claude_modes_test::fail "target file is not valid JSON (partial write)"
  fi
else
  # Neither should exist if target doesn't
  if [ ! -f "$SIDECAR" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "sidecar exists without target"
  fi
fi
# Cleanup any leaked .cascade.* tmp
find "${WORK}/repoA/.claude" -name '.cascade.*' -delete 2>/dev/null

# ─── Scenario 7: preserve non-plugin-owned keys verbatim ───────────────
claude_modes_test::it "preserve non-plugin-owned keys (statusLine) from existing settings.local.json"
rm -f "$TARGET" "$SIDECAR"
mkdir -p "$(dirname "$TARGET")"
cat > "$TARGET" <<'EOF'
{
  "statusLine": "my-custom-statusline",
  "enabledPlugins": {
    "Z@old-marketplace": true
  }
}
EOF
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "A@m": true' "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "D@m": true'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  status_line=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("statusLine",""))' "$TARGET")
  has_z=$("$PY" -c 'import json,sys; print("yes" if "Z@old-marketplace" in json.load(open(sys.argv[1]))["enabledPlugins"] else "no")' "$TARGET")
  has_a=$("$PY" -c 'import json,sys; print("yes" if "A@m" in json.load(open(sys.argv[1]))["enabledPlugins"] else "no")' "$TARGET")
  if [ "$status_line" = "my-custom-statusline" ] && [ "$has_z" = "no" ] && [ "$has_a" = "yes" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "statusLine=$status_line has_z=$has_z has_a=$has_a (expected: my-custom-statusline / no / yes)"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on preserve-keys scenario"
fi

# ─── Scenario 8: sidecar contents — tool, version, fingerprint, etc ────
claude_modes_test::it "sidecar contains tool, version, fingerprint, compiled_at, source_modes"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  "    \"${ID}\": true"
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    "D@m": true'

if "$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" >/dev/null 2>&1; then
  tool=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["tool"])' "$SIDECAR")
  ver=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$SIDECAR")
  has_fp=$("$PY" -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])).get("fingerprint") else "no")' "$SIDECAR")
  has_ts=$("$PY" -c 'import json,sys,re; ts=json.load(open(sys.argv[1])).get("compiled_at",""); print("yes" if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", ts) else "no")' "$SIDECAR")
  src=$("$PY" -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["source_modes"]))' "$SIDECAR")
  if [ "$tool" = "claude-modes" ] && [ "$ver" = "2.0" ] && [ "$has_fp" = "yes" ] && [ "$has_ts" = "yes" ]; then
    case "$src" in
      *_global.yaml*writing*) claude_modes_test::pass ;;
      *) claude_modes_test::fail "source_modes='$src' (expected _global.yaml + writing)" ;;
    esac
  else
    claude_modes_test::fail "tool=$tool ver=$ver fp=$has_fp ts=$has_ts (each should be: claude-modes / 2.0 / yes / yes)"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on sidecar-contents scenario"
fi

# ─── Scenario 9: sidecar fingerprint matches sha256 of settings.local ──
claude_modes_test::it "sidecar fingerprint == sha256(settings.local.json)"
expected_hash=$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$TARGET")
recorded_hash=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$SIDECAR")
claude_modes_test::assert_eq "$expected_hash" "$recorded_hash"

# ─── Scenario 10: non-dict (list-root) tier YAML exits 2, not a traceback ──
# A tier YAML whose root is a list/scalar parses without YAMLError but is not
# a mapping. _safe_load must reject it with the documented exit 2, NOT let it
# reach _extract_enabled_plugins and raise AttributeError (raw traceback + exit 1).
claude_modes_test::it "non-dict tier YAML (list root) exits 2 with 'YAML mapping' error"
rm -f "$TARGET" "$SIDECAR"
write_yaml "$T2" '- foo' '- bar'   # list root, not a mapping
write_yaml "$T3" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  "    \"${ID}\": true"
err=$("$PY" "$CASCADE_PY" "$T2" "$T3" "" "$ID" "$TARGET" "$SIDECAR" 2>&1)
rc=$?
if [ "$rc" = "2" ] && printf '%s' "$err" | grep -q "YAML mapping"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected rc=2 + 'YAML mapping' in stderr; got rc=$rc, stderr=$err"
fi

# ─── Scenario 11: resolver handles LIST-shaped installed_plugins.json ──────
# The real ~/.claude/plugins/installed_plugins.json keys each plugin to a LIST
# of install records: {"plugins": {"name@mkt": [{"scope","installPath",...}]}}.
# The resolver's registry parser must handle that list shape — an earlier
# version only accepted name→{dict}, skipped every real (list) entry, and always
# fell through to the synthetic "claude-modes@local-dev". That made a
# marketplace-installed plugin compile the WRONG identifier into _global.yaml,
# enabling a phantom @local-dev and dropping the real plugin. (Bug found on
# first contact with a real marketplace install; the suite had only ever used
# the local-dev fallback.) This test fakes a plugin root + a list-shaped
# registry pointing at it, and asserts the resolver returns the marketplace key.
claude_modes_test::it "resolve_self_identifier: list-shaped installed_plugins.json resolves the marketplace id (not the local-dev fallback)"
(
  # Fake plugin root = the real lib's parent (so SCRIPT_DIR/.. realpath matches).
  __real_plugin_root="$(cd "${PLUGIN_ROOT}" && pwd -P)"
  __reg="${HOME}/.claude/plugins/installed_plugins.json"
  mkdir -p "$(dirname "$__reg")"
  "$PY" - "$__reg" "$__real_plugin_root" <<'PYEOF'
import json, sys
reg, root = sys.argv[1], sys.argv[2]
# LIST-shaped value, exactly like the real registry.
json.dump({"version": 1, "plugins": {
    "claude-modes@shrimpshack": [{"scope": "user", "installPath": root}],
    "other@mkt": [{"scope": "user", "installPath": "/nonexistent"}],
}}, open(reg, "w"))
PYEOF
  # Source the engine and resolve. SCRIPT_DIR inside cascade-engine.sh resolves
  # to PLUGIN_ROOT/lib, so plugin_root = PLUGIN_ROOT, matching the registry.
  . "${PLUGIN_ROOT}/lib/cascade-engine.sh"
  resolved="$(__claude_modes::resolve_self_identifier 2>/dev/null)"
  if [ "$resolved" = "claude-modes@shrimpshack" ]; then
    exit 0
  else
    echo "resolver returned '$resolved', expected 'claude-modes@shrimpshack'" >&2
    exit 1
  fi
)
if [ $? -eq 0 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "resolver did not return the marketplace id from a list-shaped registry (list-vs-dict parse bug)"
fi

claude_modes_test::teardown

# Summary line in the format tests/run.sh greps for (so this file's
# assertions are counted in the suite total, not silently dropped).
echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0

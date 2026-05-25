#!/usr/bin/env bash
# sec-005 read-path equivalence: all .mode-body READ SITES must agree on the
# same file. Distinct from active-mode-resolver-equivalence.test.sh (which
# feeds STRINGS to the validators) — this feeds FILES to the resolvers, the
# layer where the tr-d-vs-strip disagreement actually lived.
#
# Read sites under test (all read <repo>/.claude/modes/<slug>.mode):
#   1. lib/active-mode.sh        claude_modes::read_active_mode_name (CANONICAL)
#   2. lib/inject-prose.sh       __resolve_active_mode
#   3. lib/status.sh             __claude_modes::status_resolve_active_mode
#   4. lib/reconcile-symlinks.py _read_per_branch_mode
#
# The gap this guards: the original sec-005 fix landed in inject-prose +
# status but missed active-mode.sh (the canonical resolver /mode:set's
# state is read back through). A malicious "delivery x" body must resolve
# to NOTHING in all four, and a clean "delivery" to "delivery" in all four.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# A git repo on branch main with a .mode file we control.
REPO="${HOME}/repo-readeq"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
MODE_FILE="${REPO}/.claude/modes/main.mode"
mkdir -p "${REPO}/.claude/modes"

# Resolve via each of the four read paths; echo the resolved value (empty if
# rejected / no mode). Each runs in a subshell cd'd into the repo so the
# git-context resolvers see branch main.
__resolve_active_mode_sh() {
  ( cd "$REPO" && bash -c '
    . "'"${PLUGIN_ROOT}"'/lib/active-mode.sh"
    claude_modes::read_active_mode_name' )
}
__resolve_inject() {
  ( cd "$REPO" && bash -c '
    . "'"${PLUGIN_ROOT}"'/lib/inject-prose.sh" >/dev/null 2>&1
    __resolve_active_mode' )
}
__resolve_status() {
  ( cd "$REPO" && bash -c '
    . "'"${PLUGIN_ROOT}"'/lib/status.sh" >/dev/null 2>&1
    __claude_modes::status_resolve_active_mode' )
}
__resolve_python() {
  "$PY" - "$REPO" "${PLUGIN_ROOT}/lib/reconcile-symlinks.py" <<'PYEOF'
import sys, importlib.util
repo, src = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("rs", src)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
r = m._read_per_branch_mode(repo, "main")
sys.stdout.write("" if r is None else r)
PYEOF
}

# Assert all four read paths resolve `mode_file` content to `$expected`.
__assert_all_four_resolve() {
  local label="$1" expected="$2"
  local a i s p
  a=$(__resolve_active_mode_sh)
  i=$(__resolve_inject)
  s=$(__resolve_status)
  p=$(__resolve_python)
  if [ "$a" = "$expected" ] && [ "$i" = "$expected" ] && [ "$s" = "$expected" ] && [ "$p" = "$expected" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "[${label}] expected='${expected}' got: active=[${a}] inject=[${i}] status=[${s}] python=[${p}]"
  fi
}

# ─── clean body resolves identically everywhere ──────────────────────
claude_modes_test::it "clean 'delivery' resolves to delivery on all 4 read paths"
printf 'delivery\n' > "$MODE_FILE"
__assert_all_four_resolve "clean" "delivery"

# ─── sec-005 attack: internal space rejected everywhere ──────────────
claude_modes_test::it "malicious 'delivery x' (internal space) resolves to NOTHING on all 4"
printf 'delivery x' > "$MODE_FILE"
__assert_all_four_resolve "internal-space" ""

# ─── path traversal rejected everywhere ──────────────────────────────
claude_modes_test::it "'../../tmp/evil' resolves to NOTHING on all 4"
printf '../../tmp/evil\n' > "$MODE_FILE"
__assert_all_four_resolve "traversal" ""

# ─── 'claude' sentinel accepted everywhere (Claude Mode marker) ──────
claude_modes_test::it "'claude' sentinel resolves to claude on all 4 read paths"
printf 'claude\n' > "$MODE_FILE"
__assert_all_four_resolve "sentinel" "claude"

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

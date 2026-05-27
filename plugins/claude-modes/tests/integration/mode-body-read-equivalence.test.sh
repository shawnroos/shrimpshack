#!/usr/bin/env bash
# sec-005 read-path equivalence: all .mode-body READ SITES must agree on the
# same file. Distinct from active-mode-resolver-equivalence.test.sh (which
# feeds STRINGS to the validators) — this feeds FILES to the resolvers, the
# layer where the tr-d-vs-strip disagreement actually lived.
#
# Read sites under test (all read <repo>/.claude/modes/<slug>.mode):
#   1. lib/active-mode.sh        claude_modes::read_active_mode_name (CANONICAL)
#   2. lib/inject-prose.sh       sources active-mode.sh → read_active_mode_name
#   3. lib/status.sh             sources active-mode.sh → read_active_mode_name
#   4. lib/reconcile-symlinks.py _read_per_branch_mode (Python mirror)
#
# Since the active-mode-resolver consolidation, inject-prose and status no
# longer carry their OWN resolver — they call the canonical one. Paths 2/3 are
# therefore resolved *through each file's loaded environment*: if a future
# change re-introduces an inline resolver that shadows the canonical name in
# either file, this test catches the divergence. Path 4 (Python) is the one
# unavoidable cross-language mirror. A malicious "delivery x" body must resolve
# to NOTHING in all four; a clean "delivery" to "delivery" in all four.

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
  # inject-prose.sh sources active-mode.sh; resolve through its environment.
  ( cd "$REPO" && bash -c '
    . "'"${PLUGIN_ROOT}"'/lib/inject-prose.sh" >/dev/null 2>&1
    claude_modes::read_active_mode_name' )
}
__resolve_status() {
  # status.sh sources active-mode.sh; resolve through its environment.
  ( cd "$REPO" && bash -c '
    . "'"${PLUGIN_ROOT}"'/lib/status.sh" >/dev/null 2>&1
    claude_modes::read_active_mode_name' )
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

# ─── LEAK REFUSAL: untracked subdir must NOT inherit the project's pin ──
# Restore a VALID pin at the project root, then resolve from an UNTRACKED
# subdir of the project. All four read paths must refuse (return empty) —
# the cross-project leak the gate closes. This is a CORRECTNESS anchor, not
# just an agreement check: it asserts the resolved value is "" specifically,
# so a co-regression where all four resolvers revert to bare --show-toplevel
# (and all four leak "delivery") FAILS here instead of passing green.
printf 'delivery\n' > "$MODE_FILE"
SCRATCH="${REPO}/scratch-untracked"
mkdir -p "$SCRATCH"  # not git-added → untracked

__resolve_from() {
  # $1 = cwd, $2 = resolver-fn-name's bash body selector
  local wd="$1" which="$2"
  case "$which" in
    active) ( cd "$wd" && bash -c '. "'"${PLUGIN_ROOT}"'/lib/active-mode.sh"; claude_modes::read_active_mode_name' ) ;;
    inject) ( cd "$wd" && bash -c '. "'"${PLUGIN_ROOT}"'/lib/inject-prose.sh" >/dev/null 2>&1; claude_modes::read_active_mode_name' ) ;;
    status) ( cd "$wd" && bash -c '. "'"${PLUGIN_ROOT}"'/lib/status.sh" >/dev/null 2>&1; claude_modes::read_active_mode_name' ) ;;
  esac
}
__resolve_python_from() {
  local wd="$1"
  "$PY" - "$wd" "${PLUGIN_ROOT}/lib/reconcile-symlinks.py" <<'PYEOF'
import sys, os, importlib.util
wd, src = sys.argv[1], sys.argv[2]
os.chdir(wd)
spec = importlib.util.spec_from_file_location("rs", src)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
# Mirror main()'s per-branch-pin decision: reconcile honors a per-branch pin
# ONLY when cwd passes the read-side gate (_gated_repo_root matches the
# working-tree toplevel). From an untracked subdir the gate returns None, so
# the pin is NOT honored even though _resolve_branch reports a real repo_root.
# This is the leak-refusal behavior the gate provides — tested at the layer
# where the gate actually lives (the pin decision), not at _resolve_branch.
branch, repo_root = m._resolve_branch(wd)
gated_root = m._gated_repo_root(wd)
if gated_root and gated_root == repo_root and branch:
    slug = m._slugify_branch(branch) or "(none)"
    pin = m._read_per_branch_mode(repo_root, slug) if slug != "(none)" else None
    sys.stdout.write(pin or "")
else:
    sys.stdout.write("")  # gated out → no per-branch pin honored
PYEOF
}

claude_modes_test::it "untracked subdir: active-mode.sh refuses the parent pin (returns empty)"
claude_modes_test::assert_eq "" "$(__resolve_from "$SCRATCH" active)"
claude_modes_test::it "untracked subdir: inject-prose.sh refuses the parent pin (returns empty)"
claude_modes_test::assert_eq "" "$(__resolve_from "$SCRATCH" inject)"
claude_modes_test::it "untracked subdir: status.sh refuses the parent pin (returns empty) — the P1 leak"
claude_modes_test::assert_eq "" "$(__resolve_from "$SCRATCH" status)"
claude_modes_test::it "untracked subdir: reconcile-symlinks.py refuses the parent pin (gate returns no root)"
claude_modes_test::assert_eq "" "$(__resolve_python_from "$SCRATCH")"

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

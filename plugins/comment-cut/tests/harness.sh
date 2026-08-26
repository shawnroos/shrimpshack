#!/usr/bin/env bash
#
# harness.sh — the comment-cut suite. Runs every *_test.sh beside it, in an
# isolated temp workspace, and exits non-zero if any assertion fails.
#
# Nothing here reads a path above plugins/comment-cut/. A test that reaches the
# repo root cannot pass from the installed plugin cache or a plugin-only export,
# where the plugin ships alone — it fails on packaging and reads as a regression.

set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN
export TOOLS="$PLUGIN/tools/comment-cut"
export CHECK="$TOOLS/check.py"

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }

# check <name> <shell-expr> — the expr is evaluated; non-zero is a failure.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# check_eq <name> <expected> <actual>
check_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

export -f ok bad check check_eq

# A floor. Two empty globs, a failed cd, or a suite that silently stopped
# collecting all produce zero assertions, and zero failures reads identical to
# a clean run. The floor is what makes "green" mean the suite actually ran.
MIN_ASSERTIONS=${MIN_ASSERTIONS:-30}

run_suite() {
  local f
  local found=0
  for f in "$PLUGIN"/tests/*_test.sh; do
    [ -e "$f" ] || continue
    found=$((found+1))
    echo
    echo "== $(basename "$f")"
    # shellcheck disable=SC1090
    source "$f"
  done
  if [ "$found" -eq 0 ]; then
    echo "no test files found beside harness.sh" >&2
    exit 1
  fi
}

run_suite

TOTAL=$((PASS+FAIL))
echo
echo "comment-cut: $PASS passed, $FAIL failed ($TOTAL assertions)"

if [ "$TOTAL" -lt "$MIN_ASSERTIONS" ]; then
  echo "FLOOR: only $TOTAL assertions ran, expected at least $MIN_ASSERTIONS" >&2
  exit 1
fi

[ "$FAIL" -eq 0 ] || exit 1

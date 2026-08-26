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

# Results cross the subshell boundary as lines in this file, not as variables.
RESULTS="$(mktemp "${TMPDIR:-/tmp}/cc-results.XXXXXX")"

ok()  { printf 'ok\t%s\n'   "$1" >> "$RESULTS"; echo "  ok   - $1"; }
bad() { printf 'FAIL\t%s\n' "$1" >> "$RESULTS"; echo "  FAIL - $1" >&2; }

check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

check_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

MIN_ASSERTIONS=${MIN_ASSERTIONS:-30}

# The suite's own file count. A test file that stops being collected -- renamed,
# deleted, or unreadable -- must fail rather than quietly shrink the run.
EXPECT_FILES=${EXPECT_FILES:-5}

# A scratch cwd for every test file. Test files create repos and cd around; a
# `cd` that leaks, or a half-parsed file whose cleanup runs against the wrong
# directory, must not be able to reach the repo this plugin lives in. A parse
# error in one test file deleted a source file before this existed.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cc-sandbox.XXXXXX")"

run_suite() {
  local f before after found=0
  for f in "$PLUGIN"/tests/*_test.sh; do
    [ -e "$f" ] || continue
    found=$((found+1))
    echo
    echo "== $(basename "$f")"
    before="$(wc -l < "$RESULTS")"
    # Subshell + pinned cwd: the file cannot change the harness's directory,
    # clobber its variables, or exit the run out from under the verdict.
    ( cd "$SANDBOX" || exit 1
      # shellcheck disable=SC1090
      source "$f" ) || bad "$(basename "$f") failed to load"
    after="$(wc -l < "$RESULTS")"
    [ "$after" -gt "$before" ] || bad "$(basename "$f") contributed no assertions"
  done
  check_eq "test files collected" "$EXPECT_FILES" "$found"
}

# The verdict lives in the trap, not at the bottom of the script, so no early
# exit inside a sourced file can bypass it.
finish() {
  # awk, not `grep -c || echo 0`: grep exits 1 on zero matches, so the fallback
  # appends a second count and the arithmetic below breaks.
  PASS="$(awk '$1=="ok"{n++} END{print n+0}'   "$RESULTS" 2>/dev/null)"
  FAIL="$(awk '$1=="FAIL"{n++} END{print n+0}' "$RESULTS" 2>/dev/null)"
  local total=$((PASS+FAIL))
  rm -rf "$SANDBOX" "$RESULTS"

  echo
  echo "comment-cut: $PASS passed, $FAIL failed ($total assertions)"

  if [ "$total" -lt "$MIN_ASSERTIONS" ]; then
    echo "FLOOR: only $total assertions ran, expected at least $MIN_ASSERTIONS" >&2
    exit 1
  fi
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}
trap finish EXIT

run_suite

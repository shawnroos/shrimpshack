#!/usr/bin/env bash
# Spinoff test runner. scripts/publish-plugin.sh reads the TOTAL line. Usage: bash tests/run.sh [all]
#
# smoke.sh stays out: it drives a real terminal backend.

set -uo pipefail

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "all" ]; }; then
  echo "usage: bash tests/run.sh [all]" >&2
  exit 2
fi

# The suite must give the same answer in any terminal, and these name the one it runs in.
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH \
      CMUX_WORKSPACE_ID CMUX_SURFACE_ID \
      REX_SESSION REX_BLOCK REX_SERVER REX_BIN_DIR \
      TERM_PROGRAM GHOSTTY_RESOURCES_DIR GHOSTTY_SURFACE_ID 2>/dev/null || true

cd "$(dirname "$0")/../skills/spinoff/scripts" || exit 1

passed=0 failed=0 skipped=0 files=0
expected=$(ls -- *.test.sh *.bats | wc -l)

record() {
  local name="$1" pass="$2" fail="$3" skip="$4" rc="$5"
  files=$((files + 1))
  # Exit 0 with no count means the file ran nothing, which must not read as a pass.
  if [ "$rc" -ne 0 ] && [ "$fail" -eq 0 ]; then fail=1; fi
  if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then fail=1; fi
  passed=$((passed + pass)); failed=$((failed + fail)); skipped=$((skipped + skip))
  if [ "$fail" -eq 0 ]; then mark="✓"; else mark="✗"; fi
  printf '  %s  %-34s (pass=%d fail=%d skip=%d)\n' "$mark" "$name" "$pass" "$fail" "$skip"
}

for f in *.test.sh; do
  out="$(bash "$f" </dev/null 2>&1)"; rc=$?
  counts="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -nE \
    -e 's/(^|.*[^0-9])([0-9]+) passed, ([0-9]+) failed(, ([0-9]+) skipped)?.*/\2 \3 \5/p' \
    -e 's/^pass: ([0-9]+) fail: ([0-9]+).*/\1 \2/p' | tail -n 1)"
  read -r pass fail skip <<<"$counts"
  record "$f" "${pass:-0}" "${fail:-0}" "${skip:-0}" "$rc"
  if [ "$rc" -ne 0 ] || [ -z "$counts" ]; then printf '%s\n' "$out" | tail -n 30; fi
done

for f in *.bats; do
  if ! command -v bats >/dev/null 2>&1; then
    record "$f" 0 1 0 1
    echo "bats is not installed, so $f did not run" >&2
    continue
  fi
  out="$(bats --tap "$f" </dev/null 2>&1)"; rc=$?
  skip="$(printf '%s\n' "$out" | grep -cE '^ok .* # skip' || true)"
  pass="$(printf '%s\n' "$out" | grep -E '^ok ' | grep -cvE ' # skip' || true)"
  fail="$(printf '%s\n' "$out" | grep -cE '^not ok ' || true)"
  plan="$(printf '%s\n' "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -n 1)"
  # A plan larger than the rows printed means bats died partway.
  if [ "${plan:-0}" -ne $((pass + fail + skip)) ]; then fail=$((fail + 1)); fi
  record "$f" "$pass" "$fail" "$skip" "$rc"
  if [ "$fail" -ne 0 ]; then printf '%s\n' "$out" | grep -E -A12 '^not ok ' | tail -n 40; fi
done

# A loop that stops early still prints a clean total for the files it reached.
if [ "$files" -ne "$expected" ]; then
  echo "ran $files of $expected test files" >&2
  failed=$((failed + 1))
fi

echo
echo "TOTAL: $passed passed, $failed failed ($files files, $skipped skipped)"
[ "$failed" -eq 0 ]

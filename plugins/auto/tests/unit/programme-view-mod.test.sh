#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "programme-view-mod.test.sh"

it "claude is on PATH to run the mod tests"
if ! command -v claude >/dev/null 2>&1; then
  fail "claude not found; the mod tests cannot run"
  echo "programme-view-mod.test.sh: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
pass

# Run from the plugin root: pointed at the mod folder, the kit finds no hooks module to load.
OUT="$(cd "$AUTO_ROOT" && claude plugin test . 2>&1)"
STATUS=$?
RAN="$(printf '%s\n' "$OUT" | sed -n 's/^Ran \([0-9][0-9]*\) tests\{0,1\} across.*/\1/p' | tail -1)"
FAILED="$(printf '%s\n' "$OUT" | sed -n 's/^ *\([0-9][0-9]*\) fail$/\1/p' | tail -1)"

it "the mod test run reports how many tests it ran"
if [ -n "$RAN" ]; then pass; else fail "no 'Ran N tests' line; output tail: $(printf '%s\n' "$OUT" | tail -5 | tr '\n' ' ')"; fi

it "the mod test run ran at least one test"
if [ "${RAN:-0}" -gt 0 ]; then pass; else fail "ran ${RAN:-0} tests"; fi

it "no mod test failed"
check "0" "${FAILED:-missing}"

it "the mod test run exited 0"
check "0" "$STATUS"

if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "$OUT" | grep -E '^\(fail\)' | sed 's/^/      /'
fi
echo "programme-view-mod.test.sh: ${PASS} passed, ${FAIL} failed (${RAN:-0} mod tests)"
[ "$FAIL" -eq 0 ]

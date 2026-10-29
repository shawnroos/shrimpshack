#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
EXPECTED="${AUTO_ROOT}/tests/helpers/fixtures/ruling-reads.jsonl"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }

echo "programme-ruling-reads.test.sh"

WORK="$(cd "$(mktemp -d -t auto-ruling-reads.XXXXXX)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal.json"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME"

ACTUAL="$("$PY" "${AUTO_ROOT}/tests/helpers/ruling_reads.py" "$AUTO_ROOT" "$WORK" 2>&1)"
it "the reads ran"
[ -n "$ACTUAL" ] && [ "$(printf '%s\n' "$ACTUAL" | wc -l)" -eq "$(wc -l < "$EXPECTED")" ] && pass \
  || fail "expected $(wc -l < "$EXPECTED") lines, got: ${ACTUAL:0:400}"

# Each line is one consumer's whole output; a change to any of them is a behaviour change, not a refactor.
while IFS= read -r want; do
  key="$("$PY" -c 'import json,sys; print(next(iter(json.loads(sys.argv[1]))))' "$want")"
  got="$(printf '%s\n' "$ACTUAL" | grep -F "{\"${key}\": " || true)"
  it "the ${key} read is unchanged"
  if [ "$got" = "$want" ]; then pass; else fail "expected ${want:0:300} got ${got:0:300}"; fi
done < "$EXPECTED"

echo
echo "programme-ruling-reads.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

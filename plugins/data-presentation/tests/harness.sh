#!/usr/bin/env bash
# The plugin's whole test surface. Runs an explicit list of files, never a glob:
# a directory scan cannot notice a file that is gone, so a deleted test would read
# as a clean pass. That false-green is the thing this harness exists to prevent.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$PLUGIN/tests"
SKILL="$PLUGIN/skills/data-presentation/SKILL.md"

EXPECTED=(
  vendor_test.py
  validate_test.py
  selection_test.py
  render_test.py
  forms_test.py
  present_test.py
)

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "data-presentation"

for name in "${EXPECTED[@]}"; do
  path="$TESTS/$name"
  if [ ! -r "$path" ]; then
    bad "$name is missing or unreadable"
    continue
  fi
  if out="$(python3 "$path" 2>&1)"; then
    tally="$(printf '%s\n' "$out" | tail -1)"
    ok "$name — $tally"
  else
    bad "$name"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
  fi
done

# The skill body carries rules no Python test can reach.
check "SKILL.md exists" "[ -r '$SKILL' ]"
check "SKILL.md declares a name" "grep -q '^name:' '$SKILL'"
check "SKILL.md declares a description" "grep -q '^description:' '$SKILL'"
check "SKILL.md pins a fence with no language tag" "grep -qE '^\`\`\`\$' '$SKILL'"
check "SKILL.md says to reproduce verbatim" "grep -qi 'verbatim' '$SKILL'"
check "SKILL.md says when not to call the skill" "grep -qi 'do not call' '$SKILL'"
check "SKILL.md tells the agent to relay a refusal" "grep -qi 'refus' '$SKILL'"
check "SKILL.md names the table fallback for unsure destinations" "grep -qi 'monospace' '$SKILL'"

echo "harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

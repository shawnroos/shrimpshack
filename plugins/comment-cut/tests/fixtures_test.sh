# fixtures_test.sh — the .ts fixture files.
#
# These duplicate the inline FIXTURES/KEEPERS lists in check.py, and they said so
# in a comment while nothing checked it. A hand-mirrored copy with no check on it
# drifts, and the copy that drifts is the one nobody runs. These assertions are
# what make the duplication safe: the fixtures also exercise the file-walking
# path, which the tempfile-based self-test never touches.

FIX="$TOOLS/fixtures"

check "known-bad fixture exists" "[ -r '$FIX/known-bad.ts' ]"
check "keepers fixture exists"   "[ -r '$FIX/keepers.ts' ]"

# --- every line of known-bad.ts must be flagged, every line of keepers.ts silent ---
_bad="$(python3 "$CHECK" --porcelain "$FIX/known-bad.ts" 2>/dev/null)"
check "known-bad.ts is flagged" "[ -n \"\$_bad\" ]"

for kind in banner ticket-label changelog commented-out restates narrates; do
  check "known-bad.ts fires $kind" "printf '%s' \"\$_bad\" | grep -q ':$kind\$'"
done

_keep="$(python3 "$CHECK" --porcelain "$FIX/keepers.ts" 2>/dev/null)"
check_eq "keepers.ts is silent" "" "$_keep"

python3 "$CHECK" --porcelain "$FIX/keepers.ts" >/dev/null 2>&1
check_eq "keepers.ts exits 0" "0" "$?"

# --- parity: the checked-in fixtures are what the inline lists render to ---
# render.py --check is the single source of truth. It exits 1 and names the file
# when a fixture and its inline list disagree.
python3 "$TOOLS/fixtures/render.py" --check >/dev/null 2>&1
check_eq "checked-in fixtures match the inline lists" "0" "$?"

_drift="$(python3 "$TOOLS/fixtures/render.py" --check 2>&1)"
check_eq "render --check is silent when they match" "" "$_drift"

# Derive the expected count from the inline list. A fixed floor equal to today's
# count cannot grow: a new inline case that never fires would keep this green.
_want="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('c', '$CHECK')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.FIXTURES))" 2>/dev/null)"
_n_bad="$(python3 "$CHECK" --porcelain "$FIX/known-bad.ts" 2>/dev/null | grep -cE '^.+:[0-9]+:[a-z-]+$')"
check_eq "every inline FIXTURES case fires in known-bad.ts" "$_want" "$_n_bad"

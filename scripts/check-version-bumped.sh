#!/usr/bin/env bash
# check-version-bumped.sh — a change to a plugin's shipped code must bump that
# plugin's version, in BOTH places that gate delivery.
#
# WHY THIS EXISTS
# ---------------
# `/plugin update` decides "is there an update?" purely by the version string.
# Merge new code under the version already published and every install reports
# "up to date" forever — the fix is in main, the user is still running the bug,
# and nothing anywhere says so. Merging is not shipping.
#
# Measured, twice, in one day (2026-08-13): the bg-agent 401 fix and the
# size-ceiling remedy fix both merged and both would have reached nobody without
# a deliberate bump. The gap was noticed by hand each time. Hands are what this
# replaces.
#
# The version lives in TWO files and both gate delivery: the plugin's own
# plugin.json, and its entry in the root marketplace.json. They must move
# together — a bump in one alone is the same silent no-op with extra steps.
#
# USAGE
#   scripts/check-version-bumped.sh [base-ref]      (default: origin/main)
#
# Exits 0 when every plugin with changed shipped code bumped both strings, or
# when no shipped code changed at all. Exits 1 naming what to bump.

set -uo pipefail

BASE="${1:-origin/main}"
ROOT="$(git rev-parse --show-toplevel)" || exit 0
cd "$ROOT" || exit 0

git rev-parse --verify "$BASE" >/dev/null 2>&1 || {
    echo "check-version-bumped: base ref '$BASE' does not resolve; skipping" >&2
    exit 0
}

# Paths that are SHIPPED — what an install actually runs. Docs and tests ride
# along in the vendored tree, so they are shipped too; a doc that lies is the
# defect this whole session was about. The exclusions are the version files
# themselves (bumping them must not require bumping them) and anything that
# never reaches an install.
changed="$(git diff --name-only "$BASE"...HEAD -- 'plugins/*' 2>/dev/null)"
[ -n "$changed" ] || exit 0

fail=0
for plugin in $(printf '%s\n' "$changed" | awk -F/ '$1=="plugins"{print $2}' | sort -u); do
    # Did anything SHIPPED change for this plugin?
    shipped="$(printf '%s\n' "$changed" \
        | grep "^plugins/$plugin/" \
        | grep -v "^plugins/$plugin/\.claude-plugin/plugin\.json$" \
        || true)"
    [ -n "$shipped" ] || continue

    pj="plugins/$plugin/.claude-plugin/plugin.json"
    [ -f "$pj" ] || continue

    now="$(python3 -c "
import json,sys
try: print(json.load(open('$pj')).get('version',''))
except Exception: print('')
" 2>/dev/null)"
    was="$(git show "$BASE:$pj" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('version',''))
except Exception: print('')
" 2>/dev/null)"

    # A brand-new plugin has no previous version to differ from.
    [ -n "$was" ] || continue

    if [ "$now" = "$was" ]; then
        echo "plugins/$plugin: shipped code changed but version is still $now"
        echo "  bump it in $pj AND in .claude-plugin/marketplace.json — /plugin update"
        echo "  gates on that string, so merging this leaves every install on the old code."
        fail=1
        continue
    fi

    # Both files or neither. A bump in plugin.json alone still ships nothing,
    # because the marketplace entry is what the store reads first.
    mp="$(python3 -c "
import json,re,sys
s=open('.claude-plugin/marketplace.json').read()
try:
    i=s.index('\"name\": \"$plugin\"'); j=s.index('./plugins/$plugin', i)
    m=re.search(r'\"version\":\s*\"([^\"]+)\"', s[i:j+200]); print(m.group(1) if m else '')
except Exception: print('')
" 2>/dev/null)"
    if [ -n "$mp" ] && [ "$mp" != "$now" ]; then
        echo "plugins/$plugin: plugin.json says $now but marketplace.json says $mp"
        echo "  both gate delivery and must match, or the store serves the old tree."
        fail=1
    fi
done

exit "$fail"

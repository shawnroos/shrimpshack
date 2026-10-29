#!/usr/bin/env bash
# publish-plugin.sh — make the `publish: <plugin> <old> → <new>` commit, but only after the plugin's
# whole suite is green. It never pushes; the push stays a deliberate step.
#
# USAGE
#   scripts/publish-plugin.sh [--dry-run] <plugin> <old-version> <new-version>
#
# Run it with the version bump already edited in the working tree: plugins/<plugin>/.claude-plugin/
# plugin.json and the plugin's entry in .claude-plugin/marketplace.json must both say <new>, and
# HEAD must still say <old>. Exits 0 after the commit (or, with --dry-run, after every check).
#
# Env: PUBLISH_BASE overrides the ref check-version-bumped.sh compares against (default origin/main).

set -uo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
if [ "$#" -ne 3 ]; then
    echo "usage: scripts/publish-plugin.sh [--dry-run] <plugin> <old-version> <new-version>" >&2
    exit 2
fi
PLUGIN="$1"; OLD="$2"; NEW="$3"

die() { echo "publish-plugin: $*" >&2; exit 1; }

printf '%s' "$PLUGIN" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || die "plugin name '$PLUGIN' is not a plain plugin directory name"
[ "$OLD" != "$NEW" ] || die "old and new version are both $OLD"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && git rev-parse --show-toplevel)" || die "not inside a git checkout"
cd "$ROOT" || exit 1

PJ="plugins/$PLUGIN/.claude-plugin/plugin.json"
MP=".claude-plugin/marketplace.json"
[ -f "$PJ" ] || die "$PJ does not exist"
[ -f "$MP" ] || die "$MP does not exist"

# Anything already staged would ride into the publish commit.
staged="$(git diff --cached --name-only)" || die "cannot read the index"
[ -z "$staged" ] || die "refusing: the index already holds staged files, unstage them first:
$staged"

BASE="${PUBLISH_BASE:-origin/main}"
bash "$ROOT/scripts/check-version-bumped.sh" "$BASE" || die "check-version-bumped.sh failed; bump the version first"

json_version() {
    python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('version',''))
except Exception: print('')
"
}

now_pj="$(json_version < "$PJ")"
was_pj="$(git show "HEAD:$PJ" 2>/dev/null | json_version)"
[ "$now_pj" = "$NEW" ] || die "$PJ says '$now_pj', expected $NEW"
[ "$was_pj" = "$OLD" ] || die "HEAD:$PJ says '$was_pj', expected $OLD"
# HEAD can lag the published ref (a branch cut before the last publish); then <old> would name a version already shipped.
if git rev-parse --verify -q "$BASE" >/dev/null; then
    base_pj="$(git show "$BASE:$PJ" 2>/dev/null | json_version)"
    [ -z "$base_pj" ] || [ "$base_pj" = "$OLD" ] || die "$BASE:$PJ says '$base_pj', expected $OLD; rebase onto $BASE first"
fi

now_mp="$(python3 -c "
import re
s=open('$MP').read()
try:
    i=s.index('\"name\": \"$PLUGIN\"'); j=s.index('./plugins/$PLUGIN', i)
    m=re.search(r'\"version\":\s*\"([^\"]+)\"', s[i:j+200]); print(m.group(1) if m else '')
except Exception: print('')
")"
[ "$now_mp" = "$NEW" ] || die "$MP says '$now_mp' for $PLUGIN, expected $NEW"

RUNNER="plugins/$PLUGIN/tests/run.sh"
[ -f "$RUNNER" ] || die "$RUNNER does not exist, so the suite cannot gate this release"

# Capture first, match second: grep -q under pipefail can kill the writer and turn a pass into a failure,
# and a run that died early prints no TOTAL line at all.
suite_out="$(bash "$RUNNER" all 2>&1)"
suite_rc=$?
total_line="$(printf '%s\n' "$suite_out" | grep -E '^TOTAL: ' | tail -n 1 || true)"
if [ -z "$total_line" ]; then
    printf '%s\n' "$suite_out" | tail -n 30 >&2
    die "the suite printed no TOTAL line, so it did not finish (exit $suite_rc)"
fi
if ! printf '%s\n' "$total_line" | grep -Eq '^TOTAL: [1-9][0-9]* passed, 0 failed( |$)'; then
    printf '%s\n' "$suite_out" | tail -n 30 >&2
    die "the suite did not pass: $total_line"
fi
[ "$suite_rc" -eq 0 ] || die "the suite printed '$total_line' but exited $suite_rc"
echo "suite: $total_line"

SUBJECT="publish: $PLUGIN $OLD → $NEW"
if [ "$DRY" -eq 1 ]; then
    echo "dry run: would commit '$SUBJECT' touching only:"
    printf '  %s\n  %s\n' "$MP" "$PJ"
    exit 0
fi

git add -- "$MP" "$PJ" || die "git add failed"
staged="$(git diff --cached --name-only | sort)"
expected="$(printf '%s\n%s\n' "$MP" "$PJ" | sort)"
if [ "$staged" != "$expected" ]; then
    git reset -q -- "$MP" "$PJ"
    die "refusing: the staged set is not exactly the two manifest files:
$staged"
fi

msg="$(mktemp)" || die "cannot make a temp file"
trap 'rm -f "$msg"' EXIT
printf '%s\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_019Hz29ksX8uTHc3wn1y9o8x\n' "$SUBJECT" > "$msg"
git commit -q -F "$msg" || die "git commit failed"
echo "committed: $SUBJECT (not pushed)"

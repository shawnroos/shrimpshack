#!/usr/bin/env bash
# auto unit test: scripts/publish-plugin.sh gates the publish commit on the version check and a green suite.
#
# Each case builds a scratch git repo holding copies of the two scripts and a fake plugin whose
# tests/run.sh prints what FAKE_MODE says, so the real suite never runs and the real repo is never touched.
# Every "no commit" case compares HEAD before and after, because a refusal that still commits is the defect.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
PUBLISH="${REPO_ROOT}/scripts/publish-plugin.sh"
CHECK="${REPO_ROOT}/scripts/check-version-bumped.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check_eq() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1], got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

MARKETPLACE_TEMPLATE='{
  "plugins": [
    {
      "name": "demo",
      "source": "./plugins/demo",
      "version": "VER",
      "description": "d"
    }
  ]
}
'

# make_repo <dir> [bump]: base commit at 1.0.0 (tagged origin/main), then a code-change commit.
# With "bump" both manifests in the working tree say 1.0.1; without it they still say 1.0.0.
make_repo() {
  local dir="$1" bump="${2:-}"
  mkdir -p "$dir/scripts" "$dir/.claude-plugin" "$dir/plugins/demo/.claude-plugin" "$dir/plugins/demo/tests"
  cp "$PUBLISH" "$CHECK" "$dir/scripts/"
  printf '%s' "${MARKETPLACE_TEMPLATE//VER/1.0.0}" > "$dir/.claude-plugin/marketplace.json"
  printf '{\n  "name": "demo",\n  "version": "1.0.0"\n}\n' > "$dir/plugins/demo/.claude-plugin/plugin.json"
  cat > "$dir/plugins/demo/tests/run.sh" <<'RUN'
#!/usr/bin/env bash
case "${FAKE_MODE:-pass}" in
  pass)      echo "TOTAL: 5 passed, 0 failed  (1 files)" ;;
  fail)      echo "TOTAL: 4 passed, 1 failed  (1 files)"; exit 1 ;;
  nototal)   echo "ran some tests" ;;
  zeroexit)  echo "TOTAL: 5 passed, 0 failed  (1 files)"; exit 3 ;;
  empty)     echo "TOTAL: 0 passed, 0 failed  (0 files)" ;;
esac
RUN
  (
    cd "$dir" || exit 1
    git init -q -b main . && git config user.email t@example.com && git config user.name t
    git add -A && git commit -q -m base
    git update-ref refs/remotes/origin/main HEAD
    echo code > plugins/demo/code.txt
    git add plugins/demo/code.txt && git commit -q -m "feat: change"
    if [ "$bump" = "bump" ]; then
      printf '%s' "${MARKETPLACE_TEMPLATE//VER/1.0.1}" > .claude-plugin/marketplace.json
      printf '{\n  "name": "demo",\n  "version": "1.0.1"\n}\n' > plugins/demo/.claude-plugin/plugin.json
    fi
  )
}

# publish <repo> <args...>: output, then the exit code on its own last line.
publish() {
  local dir="$1"; shift
  (cd "$dir" && bash scripts/publish-plugin.sh "$@" 2>&1; echo "rc=$?")
}
head_of() { git -C "$1" rev-parse HEAD; }
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -n 1; }

echo "publish-plugin: refusals commit nothing"
R="$WORK/fail"; make_repo "$R" bump; H="$(head_of "$R")"
it "a failing unit test exits non-zero and makes no commit"
OUT="$(FAKE_MODE=fail publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
check_eq "$H" "$(head_of "$R")"
has "the suite did not pass: TOTAL: 4 passed, 1 failed" "$OUT"

R="$WORK/nobump"; make_repo "$R"; H="$(head_of "$R")"
it "a missing version bump stops at check-version-bumped before the suite runs"
OUT="$(FAKE_MODE=pass publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "shipped code changed but version is still 1.0.0" "$OUT"
lacks "suite:" "$OUT"
check_eq "$H" "$(head_of "$R")"

R="$WORK/nototal"; make_repo "$R" bump; H="$(head_of "$R")"
it "a suite that prints no TOTAL line fails even though it exits 0"
OUT="$(FAKE_MODE=nototal publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "printed no TOTAL line" "$OUT"
check_eq "$H" "$(head_of "$R")"

it "a TOTAL line of 0 passed is not a pass"
OUT="$(FAKE_MODE=empty publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"

it "a green TOTAL line with a non-zero exit fails"
OUT="$(FAKE_MODE=zeroexit publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "exited 3" "$OUT"
check_eq "$H" "$(head_of "$R")"

it "a wrong old version is refused"
OUT="$(FAKE_MODE=pass publish "$R" demo 0.9.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "expected 0.9.0" "$OUT"

it "an unbumped marketplace entry is refused even when plugin.json moved"
printf '%s' "${MARKETPLACE_TEMPLATE//VER/1.0.0}" > "$R/.claude-plugin/marketplace.json"
OUT="$(FAKE_MODE=pass publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
check_eq "$H" "$(head_of "$R")"

R="$WORK/lag"; make_repo "$R" bump; H="$(head_of "$R")"
# Point the published ref at a base whose plugin.json says 0.9.0, as a branch cut before the last publish sees it.
( cd "$R" && git stash -q -u && git checkout -q origin/main 2>/dev/null && sed -i.bak 's/"version": "1.0.0"/"version": "0.9.0"/' plugins/demo/.claude-plugin/plugin.json && rm plugins/demo/.claude-plugin/plugin.json.bak \
  && git commit -q -am "published 0.9.0" && git update-ref refs/remotes/origin/main HEAD && git checkout -q main && git stash pop -q )
it "an old version that HEAD has but the published ref does not is refused"
OUT="$(FAKE_MODE=pass publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "rebase onto origin/main first" "$OUT"
check_eq "$H" "$(head_of "$R")"

R="$WORK/staged"; make_repo "$R" bump; H="$(head_of "$R")"
echo extra > "$R/extra.txt"; git -C "$R" add extra.txt
it "something already staged is refused and stays staged"
OUT="$(FAKE_MODE=pass publish "$R" demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"
has "already holds staged files" "$OUT"
check_eq "$H" "$(head_of "$R")"

echo "publish-plugin: a green, bumped plugin"
R="$WORK/ok"; make_repo "$R" bump; H="$(head_of "$R")"
echo unrelated > "$R/unrelated.txt"
it "--dry-run runs every check, prints what it would commit and commits nothing"
OUT="$(FAKE_MODE=pass publish "$R" --dry-run demo 1.0.0 1.0.1)"
check_eq "0" "$(rc_of "$OUT")"
has "would commit 'publish: demo 1.0.0 → 1.0.1'" "$OUT"
check_eq "$H" "$(head_of "$R")"

it "--dry-run still fails on a red suite"
OUT="$(FAKE_MODE=fail publish "$R" --dry-run demo 1.0.0 1.0.1)"
[ "$(rc_of "$OUT")" != "0" ] && pass || fail "exit was 0: $OUT"

it "the real run exits 0 and adds exactly one commit"
OUT="$(FAKE_MODE=pass publish "$R" demo 1.0.0 1.0.1)"
check_eq "0" "$(rc_of "$OUT")"
check_eq "1" "$(git -C "$R" rev-list --count "$H..HEAD")"

it "that commit touches only the two manifest files, not the unrelated working-tree file"
check_eq ".claude-plugin/marketplace.json plugins/demo/.claude-plugin/plugin.json" \
  "$(git -C "$R" show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"

it "its subject is the publish format and it carries no attribution trailers"
MSG="$(git -C "$R" log -1 --format=%B)"
has "publish: demo 1.0.0 → 1.0.1" "$MSG"
lacks "Co-Authored-By" "$MSG"
lacks "Claude-Session" "$MSG"

it "the unrelated file is still untracked afterwards"
has "?? unrelated.txt" "$(git -C "$R" status --porcelain)"

it "the script has no push command"
if grep -Eq '^[^#]*git[[:space:]]+push' "$PUBLISH"; then fail "publish-plugin.sh calls git push"; else pass; fi

echo ""
echo "publish-plugin.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

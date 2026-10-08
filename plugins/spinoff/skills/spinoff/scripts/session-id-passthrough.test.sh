#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SPINOFF="${SPINOFF_UNDER_TEST:-$HERE/spinoff.sh}"
PASS=0 FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
CALLS="$WORK/calls.log"

REPO="$WORK/repo"
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$REPO" 2>/dev/null
( cd "$REPO" && git config user.email s@s.s && git config user.name s \
  && git commit -q --allow-empty -m init && git branch -M main && git push -q origin main ) \
  || { echo "git setup failed"; exit 1; }
HANDOFF="$WORK/handoff.md"
printf '# Spinoff: session id\n## Source session\n<!-- SESSION -->\n' > "$HANDOFF"

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "tab create")    [ -n "${FAIL_TAB:-}" ] && exit 1; echo '{"result":{"tab":{"tab_id":"w1:t1","pane_id":"w1:p1"}}}' ;;
  "pane get")      echo '{"result":{"pane":{"workspace_id":"w1"}}}' ;;
  "pane list")     echo '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' ;;
  "pane process-info") echo '{"result":{"process_info":{"foreground_processes":[{"argv0":"zsh"},{"argv0":"claude"}]}}}' ;;
  "pane read")     printf '%s\n' '  ⏵⏵ auto mode on (shift+tab to cycle)' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export CALLS

run() {
  : > "$CALLS"
  local name="$1"; shift
  ( cd "$REPO" \
    && unset CMUX_WORKSPACE_ID HERDR_PANE_ID \
    && PATH="$BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 \
       SPINOFF_READY_TIMEOUT_MS=500 SPINOFF_RETRY_TIMEOUT_MS=100 \
       bash "$SPINOFF" --name "$name" --handoff "$HANDOFF" --target tab --base origin/main "$@" 2>&1 )
}

echo "session-id passthrough ($(basename "$SPINOFF")):"

SID="0b9f2c4e-7a1d-4e5b-9c3f-2d8e6a1b4c70"
out="$(run with-session-id --session-id "$SID")"; rc=$?
launch="$(grep -E '^pane run ' "$CALLS")"

[ "$rc" -eq 0 ] && ok "with --session-id: exited 0" || bad "with --session-id: exited $rc"
case "$launch" in
  *"claude --session-id '$SID' --name"*) ok "with --session-id: claude launched with --session-id $SID" ;;
  *) bad "with --session-id: launch line lacks the session id: $launch" ;;
esac
[ "$(grep -c -- '--session-id' <<< "$launch")" = "1" ] \
  && ok "with --session-id: exactly one launch carries it" \
  || bad "with --session-id: launch count wrong"
out="$(FAIL_TAB=1 run manual-line --session-id "$SID")"; rc=$?
case "$out" in
  *"claude --session-id '$SID' --name"*) ok "failed launch: the manual recovery line keeps the id" ;;
  *) bad "failed launch: the manual recovery line dropped the id (rc=$rc)" ;;
esac

out="$(run without-session-id)"; rc=$?
launch="$(grep -E '^pane run ' "$CALLS")"
[ "$rc" -eq 0 ] && ok "without the flag: exited 0" || bad "without the flag: exited $rc"
case "$launch" in
  *"--session-id"*) bad "without the flag: launch carries a session id: $launch" ;;
  *"cd "*" && claude --name 'Without session id' "*) ok "without the flag: launch line unchanged" ;;
  *) bad "without the flag: unexpected launch line: $launch" ;;
esac

for badid in "not-a-uuid" "0b9f2c4e-7a1d-4e5b-9c3f-2d8e6a1b4c7" "0b9f2c4e-7a1d-4e5b-9c3f-2d8e6a1b4c70; rm -rf ~" ""; do
  out="$(run "bad-id-$PASS$FAIL" --session-id "$badid")"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -qE '^pane run ' "$CALLS" && [ ! -d "$REPO/worktrees/bad-id-$PASS$FAIL" ]; then
    ok "bad --session-id [$badid]: refused before any worktree or launch"
  else
    bad "bad --session-id [$badid]: rc=$rc, launched or created a worktree"
  fi
done

out="$(run "upper-id" --session-id "0B9F2C4E-7A1D-4E5B-9C3F-2D8E6A1B4C70")"; rc=$?
[ "$rc" -ne 0 ] && ok "uppercase uuid refused (claude ids are lowercase)" || bad "uppercase uuid accepted"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

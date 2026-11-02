#!/usr/bin/env bash
# kickoff-override.test.sh: --kickoff-file swaps the first-turn text; without it the text is unchanged.
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
printf '# Spinoff: kickoff\n## Source session\n<!-- SESSION -->\n' > "$HANDOFF"

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "tab create")    echo '{"result":{"tab":{"tab_id":"w1:t1","pane_id":"w1:p1"}}}' ;;
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
  local name="$1" brief="$2"; shift 2
  ( cd "$REPO" \
    && unset CMUX_WORKSPACE_ID HERDR_PANE_ID \
    && PATH="$BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 SPINOFF_BRIEF_FILE="$brief" \
       SPINOFF_READY_TIMEOUT_MS=500 SPINOFF_RETRY_TIMEOUT_MS=100 \
       bash "$SPINOFF" --name "$name" --handoff "$HANDOFF" --target tab --base origin/main "$@" 2>&1 )
}

echo "kickoff override ($(basename "$SPINOFF")):"

DEFAULT_TEXT="Read docs/handoff.md — it's the brief for this worktree (treat it as directional: orient and validate against the code, don't execute literally). Get oriented, then recommend the next compound-engineering step (/ce-brainstorm if ambiguous, /ce-plan if clear) with a one-line rationale, and wait for my direction."

run no-override "$WORK/brief-default" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "default: exited 0" || bad "default: exited $rc"
[ "$(cat "$WORK/brief-default")" = "$DEFAULT_TEXT" ] && ok "default: first turn is the fixed kickoff text" \
  || bad "default: first turn changed: $(cat "$WORK/brief-default")"
cmp -s "$WORK/brief-default" <(printf '%s\n' "$DEFAULT_TEXT") && ok "default: bytes identical to the old output" \
  || bad "default: bytes differ from the old output"

printf '/auto docs/plans/x.md\n' > "$WORK/kick.txt"
run with-override "$WORK/brief-override" --kickoff-file "$WORK/kick.txt" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "override: exited 0" || bad "override: exited $rc"
[ "$(head -c 5 "$WORK/brief-override")" = "/auto" ] && ok "override: first turn starts with /auto" \
  || bad "override: first turn is $(cat "$WORK/brief-override")"
grep -q "wait for my direction" "$WORK/brief-override" && bad "override: default text leaked into the first turn" \
  || ok "override: default text is gone"

out="$(run empty-file "$WORK/brief-empty" --kickoff-file "$WORK/missing.txt")"; rc=$?
[ "$rc" -ne 0 ] && ok "missing kickoff file: refused (rc $rc)" || bad "missing kickoff file: exited 0"
case "$out" in *"kickoff file missing or empty"*) ok "missing kickoff file: named message" ;; *) bad "missing kickoff file: message was: $out" ;; esac
grep -qE '^pane run ' "$CALLS" && bad "missing kickoff file: a launch still ran" || ok "missing kickoff file: nothing launched"

echo "pass: $PASS fail: $FAIL"
[ "$FAIL" -eq 0 ]

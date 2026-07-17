#!/usr/bin/env bash
#
# kickoff-gate.test.sh — the readiness GATE on the kickoff (herdr path).
#
# Regression test for the "staged but unsubmitted" failure: spinoff 0.8.2 waited
# for readiness with a 30s ceiling, set LB_READY=0 on timeout, and then fired the
# kickoff ANYWAY — an Enter into a still-booting TUI is swallowed, so the new
# session sat idle holding an unsubmitted brief while the script printed
# "✓ Spinoff complete" and exited 0.
#
# Drives the real spinoff.sh against a STUB herdr on PATH, so it needs no herdr
# server, no terminal and no Claude — just git. The stub records every call, which
# is how we assert the negative: on a slow boot the kickoff must NEVER be sent.
#
# Run: bash kickoff-gate.test.sh   →   exits 0 if all checks pass, 1 otherwise.
# Point it at another copy with:  SPINOFF_UNDER_TEST=/path/to/spinoff.sh
#
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

# Isolated origin + repo so --base origin/main resolves without a network.
REPO="$WORK/repo"
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$REPO" 2>/dev/null
( cd "$REPO" && git config user.email s@s.s && git config user.name s \
  && git commit -q --allow-empty -m init && git branch -M main && git push -q origin main ) \
  || { echo "git setup failed"; exit 1; }
HANDOFF="$WORK/handoff.md"
printf '# Spinoff: gate\n## Source session\n<!-- SESSION -->\n' > "$HANDOFF"

# Stub herdr. HERDR_SCREEN picks what `pane read` shows, i.e. which boot the run sees:
#   booting → only a shell prompt; claude never draws (readiness must never pass)
#   ready   → claude's prompt footer is up
#   modal   → the first-run MCP trust modal, which flips to `ready` once an Enter
#             (or Escape) is delivered — mirroring the real dismissal.
# The stub records every call, which is how the negatives are asserted.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
SCREEN="${HERDR_SCREEN:-ready}"
# Real herdr `pane read` emits RAW TEXT (not JSON) — the stub must too, or the
# suite would go green against a script that JSON-parses it into "".
_emit() { printf '%s\n' "$1"; }
case "$1 ${2:-}" in
  "status server") echo "status: running"; exit 0 ;;
  "tab create")    echo '{"result":{"tab":{"tab_id":"w1:t1","pane_id":"w1:p1"}}}'; exit 0 ;;
  "pane run")      exit 0 ;;
  "pane get")      echo '{"result":{"pane":{"workspace_id":"w1"}}}'; exit 0 ;;
  "pane list")     echo '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}'; exit 0 ;;
  "agent send")    exit 0 ;;
  "pane send-keys")
     # An Enter/Escape against the modal dismisses it → subsequent reads are ready.
     [ "$SCREEN" = modal ] && [ -n "${MODAL_FLAG:-}" ] && touch "$MODAL_FLAG"
     exit 0 ;;
  "pane read")
     case "$SCREEN" in
       booting) _emit '~ $ cd /repo && claude
❯ ' ;;
       modal)   if [ -n "${MODAL_FLAG:-}" ] && [ -f "$MODAL_FLAG" ]; then
                  _emit '  📁 repo
  ⏵⏵ auto mode on (shift+tab to cycle)'
                else
                  _emit '  9 new MCP servers found in this project
  Select any you wish to enable.
 Space to select · Enter to confirm · Esc to reject all'
                fi ;;
       *)       _emit '  📁 repo
  ⏵⏵ auto mode on (shift+tab to cycle)' ;;
     esac
     exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export CALLS

run() {  # run <screen> <name>
  : > "$CALLS"
  export MODAL_FLAG="$WORK/modal.dismissed"; rm -f "$MODAL_FLAG"
  ( cd "$REPO" \
    && unset CMUX_WORKSPACE_ID HERDR_PANE_ID \
    && PATH="$BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HERDR_SCREEN="$1" \
       MODAL_FLAG="$MODAL_FLAG" \
       SPINOFF_READY_TIMEOUT_MS=4000 SPINOFF_RETRY_TIMEOUT_MS=100 \
       bash "$SPINOFF" --name "$2" --handoff "$HANDOFF" --target tab --base origin/main 2>&1 )
}

echo "kickoff readiness-gate checks ($(basename "$(dirname "$SPINOFF")")/$(basename "$SPINOFF")):"

# ---- 1. SLOW BOOT (claude never draws) → must WITHHOLD the kickoff ------------
out="$(run booting slow-boot)"; rc=$?

grep -q 'agent send' "$CALLS" \
  && bad "slow boot: kickoff was SENT into a non-ready session (the 0.8.2 bug)" \
  || ok  "slow boot: kickoff withheld — no 'agent send'"

echo "$out" | grep -q '✓ Spinoff complete' \
  && bad "slow boot: reported '✓ Spinoff complete' for an unbriefed session" \
  || ok  "slow boot: did not claim completion"

echo "$out" | grep -q 'Spinoff INCOMPLETE' \
  && ok  "slow boot: reported INCOMPLETE" \
  || bad "slow boot: no INCOMPLETE header"

[ "$rc" -ne 0 ] \
  && ok  "slow boot: exited non-zero (rc=$rc)" \
  || bad "slow boot: exited 0 — a caller checking status sees success"

echo "$out" | grep -q 'Read docs/handoff.md' \
  && ok  "slow boot: printed the manual recovery one-liner" \
  || bad "slow boot: no recovery instructions"

# The worktree is still real work — it must survive the failure.
[ -f "$REPO/worktrees/slow-boot/docs/handoff.md" ] \
  && ok  "slow boot: worktree + handoff preserved" \
  || bad "slow boot: worktree/handoff missing"

# The shell prompt must NOT be mistaken for readiness. `booting` shows a bare "❯",
# so if the ready-match ever regresses to matching it, check 1 goes red.
echo "$out" | grep -q 'Spinoff INCOMPLETE' \
  && ok  "slow boot: a bare shell '❯' is not treated as claude being ready" \
  || bad "slow boot: shell prompt accepted as ready (false-positive ready match)"

# ---- 2. FAST BOOT (prompt drawn) → must brief, with EXACTLY ONE submit --------
out="$(run ready fast-boot)"; rc=$?

grep -q 'agent send' "$CALLS" \
  && ok  "fast boot: kickoff sent" \
  || bad "fast boot: kickoff never sent — the gate is too strict"

[ "$(grep -c 'agent send' "$CALLS")" = "1" ] \
  && ok  "fast boot: exactly one 'agent send' (stage-once invariant held)" \
  || bad "fast boot: $(grep -c 'agent send' "$CALLS") sends — duplicate kickoff"

echo "$out" | grep -q '✓ Spinoff complete' \
  && ok  "fast boot: reported complete" \
  || bad "fast boot: did not report complete"

[ "$rc" -eq 0 ] \
  && ok  "fast boot: exited 0" \
  || bad "fast boot: exited $rc"

# ---- 3. MCP TRUST MODAL → dismiss it, THEN brief -----------------------------
# A spinoff worktree is a new project path, so a repo with .mcp.json always greets
# a fresh claude with this modal — and the agent reports "idle" behind it. This is
# the case that actually broke every real spinoff.
out="$(run modal mcp-modal)"; rc=$?

grep -q 'pane send-keys' "$CALLS" \
  && ok  "mcp modal: dismissed (send-keys issued)" \
  || bad "mcp modal: never dismissed — a real spinoff would hang here"

echo "$out" | grep -qi 'MCP trust modal' \
  && ok  "mcp modal: disclosed the auto-accept in the output" \
  || bad "mcp modal: silently accepted a trust prompt"

grep -q 'agent send' "$CALLS" \
  && ok  "mcp modal: briefed after dismissal" \
  || bad "mcp modal: kickoff never sent"

echo "$out" | grep -q '✓ Spinoff complete' && [ "$rc" -eq 0 ] \
  && ok  "mcp modal: reported complete" \
  || bad "mcp modal: did not complete (rc=$rc)"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

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

echo "brief-at-launch checks ($(basename "$(dirname "$SPINOFF")")/$(basename "$SPINOFF")):"

# The brief is now claude's positional prompt, carried by the launch command itself.
# There is no post-launch text injection, so the old "withhold the kickoff until the
# prompt is ready" gate no longer exists — a slow boot is briefed like any other.
# What readiness still buys is the trust-modal answer, which is what enables MCP
# servers for a session opened on a new project path.

# ---- 1. SLOW BOOT (claude never draws) → still briefed, MCP caveat reported ----
out="$(run booting slow-boot)"; rc=$?

grep -qE 'pane run .*\.spinoff-brief' "$CALLS" \
  && ok  "slow boot: the launch carried the brief" \
  || bad "slow boot: launch did not carry the brief"

grep -qE '^(agent send|agent prompt|pane send-text)' "$CALLS" \
  && bad "slow boot: text was injected after launch — that path should be gone" \
  || ok  "slow boot: nothing injected after launch"

echo "$out" | grep -q '✓ Spinoff complete' \
  && ok  "slow boot: reported complete — a slow boot is no longer a failure" \
  || bad "slow boot: reported incomplete for a session that WAS briefed"

[ "$rc" -eq 0 ] \
  && ok  "slow boot: exited 0" \
  || bad "slow boot: exited $rc"

echo "$out" | grep -q 'MCP servers may not be enabled' \
  && ok  "slow boot: disclosed that the prompt never confirmed" \
  || bad "slow boot: silently hid the unconfirmed prompt"

# The worktree is still real work — it must survive regardless.
[ -f "$REPO/worktrees/slow-boot/docs/handoff.md" ] \
  && ok  "slow boot: worktree + handoff preserved" \
  || bad "slow boot: worktree/handoff missing"

# A bare "❯" must still not be mistaken for claude being ready — the MCP caveat
# above is the observable proof the ready-match rejected the shell prompt.
echo "$out" | grep -q 'MCP servers may not be enabled' \
  && ok  "slow boot: a bare shell '❯' is not treated as claude being ready" \
  || bad "slow boot: shell prompt accepted as ready (false-positive ready match)"

# ---- 2. FAST BOOT (prompt drawn) → briefed, no injection, no caveat -----------
out="$(run ready fast-boot)"; rc=$?

grep -qE 'pane run .*\.spinoff-brief' "$CALLS" \
  && ok  "fast boot: the launch carried the brief" \
  || bad "fast boot: launch did not carry the brief"

[ "$(grep -cE 'pane run .*claude --name' "$CALLS")" = "1" ] \
  && ok  "fast boot: exactly one launch (no duplicate briefing)" \
  || bad "fast boot: $(grep -cE 'pane run .*claude --name' "$CALLS") launches"

echo "$out" | grep -q 'MCP servers may not be enabled' \
  && bad "fast boot: reported the MCP caveat despite a confirmed prompt" \
  || ok  "fast boot: no MCP caveat — prompt confirmed"

echo "$out" | grep -q '✓ Spinoff complete' \
  && ok  "fast boot: reported complete" \
  || bad "fast boot: did not report complete"

[ "$rc" -eq 0 ] \
  && ok  "fast boot: exited 0" \
  || bad "fast boot: exited $rc"

# ---- 3. MCP TRUST MODAL → still dismissed (this is why readiness survives) ----
# A spinoff worktree is a new project path, so a repo with .mcp.json always greets
# a fresh claude with this modal. The brief is already in by then, but the modal
# still has to be answered or the session runs without its MCP servers.
out="$(run modal mcp-modal)"; rc=$?

grep -q 'pane send-keys' "$CALLS" \
  && ok  "mcp modal: dismissed (send-keys issued)" \
  || bad "mcp modal: never dismissed — the session would run without MCP servers"

echo "$out" | grep -qi 'MCP trust modal' \
  && ok  "mcp modal: disclosed the auto-accept in the output" \
  || bad "mcp modal: silently accepted a trust prompt"

grep -qE 'pane run .*\.spinoff-brief' "$CALLS" \
  && ok  "mcp modal: brief still rode the launch" \
  || bad "mcp modal: launch did not carry the brief"

echo "$out" | grep -q '✓ Spinoff complete' && [ "$rc" -eq 0 ] \
  && ok  "mcp modal: reported complete" \
  || bad "mcp modal: did not complete (rc=$rc)"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

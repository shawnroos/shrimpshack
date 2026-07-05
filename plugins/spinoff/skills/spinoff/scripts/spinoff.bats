#!/usr/bin/env bats
#
# Tests for spinoff.sh's launch-backend seam (U2):
#   - `bash -n` validity
#   - resolve_launcher precedence / --launcher override / R8 fallback
#   - --launcher validation
#   - behavior-preservation: the cmux tab path emits the SAME CLI call shape
#     as before the seam refactor (a `cmux` stub captures argv).
#
# The herdr/cmux/sleep stubs live on a per-test PATH we control, so the "live"
# vs "dead" server probe and the captured argv are fully deterministic.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/spinoff.sh"
  STUBDIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBDIR"

  # cmux stub: logs its argv (one line per call) to $CMUX_ARGV_LOG when set, and
  # emits just enough parseable output for the script's ref-scraping + a ready
  # marker so the readiness poll breaks on the first iteration.
  cat > "$STUBDIR/cmux" <<'STUB'
#!/usr/bin/env bash
[ -n "${CMUX_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$CMUX_ARGV_LOG"
case "$1" in
  tree)          printf 'pane pane:1\n'; printf 'surface surface:9 [terminal]\n' ;;
  new-surface)   printf 'created surface:42\n' ;;
  new-workspace) printf 'created workspace:7\n' ;;
  new-pane)      printf 'created pane:5\n' ;;
  read-screen)   printf '%s\n' '❯' ;;
  *)             : ;;
esac
exit 0
STUB

  # herdr stub: `status server` reports running iff HERDR_STUB_LIVE=1 (the
  # liveness probe). The tab-path verbs (U3) consume real output, so the stub
  # emits the LIVE-VERIFIED JSON shapes from the plan's ## Spike Findings:
  #   - `agent start`  -> {"result":{"agent":{"pane_id":"wS:p2",...}}}
  #   - `agent wait`   -> success (idle event) unless HERDR_STUB_WAIT_FAIL=1
  #   - `pane read`    -> a marker line WITHOUT the kickoff text (no retry fires)
  # Every call still logs its argv to $HERDR_ARGV_LOG for capture assertions.
  cat > "$STUBDIR/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = status ] && [ "$2" = server ]; then
  if [ "${HERDR_STUB_LIVE:-0}" = 1 ]; then echo "status: running"; exit 0
  else echo "status: unreachable" >&2; exit 1; fi
fi
[ -n "${HERDR_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$HERDR_ARGV_LOG"
case "$1 $2" in
  "workspace create")
    echo '{"result":{"workspace":{"workspace_id":"wS"},"root_pane":{"pane_id":"wS:p1"},"tab":{"tab_id":"wS:t1"}}}' ;;
  "pane list")
    echo '{"result":{"panes":[{"pane_id":"wS:p1","agent_status":"unknown","workspace_id":"wS"}]}}' ;;
  "agent start")
    echo '{"result":{"agent":{"pane_id":"wS:p2","tab_id":"wS:t1","workspace_id":"wS","agent_status":"unknown"},"type":"agent_started"}}' ;;
  "agent wait")
    if [ "${HERDR_STUB_WAIT_FAIL:-0}" = 1 ]; then exit 1; fi
    echo '{"event":"pane.agent_status_changed","data":{"pane_id":"wS:p2","agent_status":"idle"}}'; exit 0 ;;
  "pane split")
    # Viewer split. Return no pane id when HERDR_STUB_SPLIT_FAIL=1 → viewer absent
    # (VIEWER_OK=0); the launch must still succeed (R5/KTD-6).
    if [ "${HERDR_STUB_SPLIT_FAIL:-0}" = 1 ]; then echo '{"result":{}}'; exit 0; fi
    echo '{"result":{"pane":{"pane_id":"wS:pB","tab_id":"wS:t1"}}}' ;;
  "pane read"|"agent read")
    echo '{"result":{"read":{"text":"❯ ready — awaiting input"}}}' ;;
  *) : ;;  # pane run / pane close / workspace focus / agent send / pane send-keys → ok
esac
exit 0
STUB

  # claude stub: makes the KTD-8 `command -v claude` probe resolve deterministically
  # so launcher_launch_agent_herdr takes the DIRECT `-- claude` exec branch under test.
  cat > "$STUBDIR/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  # sleep no-op: keeps the readiness/verify waits instant under test.
  cat > "$STUBDIR/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  # glow stub: makes the viewer's `command -v glow` probe resolve deterministically
  # (real machines vary on whether glow is installed) so the workspace viewer takes
  # the glow render branch → VIEWER_OK=1 under test.
  cat > "$STUBDIR/glow" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  chmod +x "$STUBDIR/cmux" "$STUBDIR/herdr" "$STUBDIR/claude" "$STUBDIR/sleep" "$STUBDIR/glow"
  HERDR_BIN="$STUBDIR/herdr"
  CMUX_BIN="$STUBDIR/cmux"
}

# Build a throwaway repo and run a full `--launcher herdr --target tab` spinoff
# with the stub herdr/claude on PATH. Captures herdr argv to $HERDR_ARGV_LOG and
# leaves the merged run output in $output (bats `run`). Callers may pre-`export`
# HERDR_STUB_WAIT_FAIL=1 to simulate a readiness timeout.
run_herdr_tab() {
  local repo="$BATS_TEST_TMPDIR/hrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  HREPO="$(cd "$repo" && pwd -P)"

  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  HERDR_ARGV_LOG="$BATS_TEST_TMPDIR/herdr-argv.log"
  : > "$HERDR_ARGV_LOG"

  run env PATH="$STUBDIR:$PATH" \
          HERDR_ARGV_LOG="$HERDR_ARGV_LOG" \
          HERDR_STUB_LIVE=1 \
          HERDR_ENV=1 \
          HERDR_WORKSPACE_ID=wS \
          CMUX_WORKSPACE_ID= \
      bash "$SCRIPT" --name htab --label testlabel --handoff "$handoff" \
                     --repo "$repo" --target tab --launcher herdr
}

# Same as run_herdr_tab but drives the `--target workspace` path (U4): the herdr
# backend creates a NEW workspace, briefs the agent in it via the U3 verbs, and
# opens a best-effort right-pane handoff viewer. Callers may pre-`export`
# HERDR_STUB_SPLIT_FAIL=1 to simulate an absent/failed viewer.
run_herdr_workspace() {
  local repo="$BATS_TEST_TMPDIR/wsrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  HREPO="$(cd "$repo" && pwd -P)"

  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  HERDR_ARGV_LOG="$BATS_TEST_TMPDIR/herdr-ws-argv.log"
  : > "$HERDR_ARGV_LOG"

  run env PATH="$STUBDIR:$PATH" \
          HERDR_ARGV_LOG="$HERDR_ARGV_LOG" \
          HERDR_STUB_LIVE=1 \
          HERDR_ENV=1 \
          CMUX_WORKSPACE_ID= \
      bash "$SCRIPT" --name hws --label testlabel --handoff "$handoff" \
                     --repo "$repo" --target workspace --launcher herdr
}

# Source the script for function-only use, set the resolver's inputs, run
# resolve_launcher, and echo the resolved backend. Runs in a subshell so
# `set -uo pipefail` (from the script) doesn't leak into the bats harness.
# $1 = the initial LAUNCHER value (auto|cmux|herdr).
run_resolve() {
  SPINOFF_TEST_SOURCE=1 bash -c '
    source "$1"
    HERDR="$2"; CMUX="$3"; LAUNCHER="$4"
    resolve_launcher 2>/dev/null
    echo "$LAUNCHER"
  ' _ "$SCRIPT" "$HERDR_BIN" "$CMUX_BIN" "$1"
}

@test "bash -n: spinoff.sh is syntactically valid" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "resolve: auto + HERDR_ENV + live server -> herdr" {
  export HERDR_STUB_LIVE=1 HERDR_ENV=1 CMUX_WORKSPACE_ID=
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = herdr ]
}

@test "resolve: auto + HERDR_ENV set but server dead + cmux present -> cmux (R8)" {
  export HERDR_STUB_LIVE=0 HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace:1
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = cmux ]
}

@test "resolve: both env sets present + herdr live -> herdr (precedence, R1)" {
  export HERDR_STUB_LIVE=1 HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace:1
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = herdr ]
}

@test "resolve: neither env present -> none" {
  export HERDR_STUB_LIVE=1 HERDR_ENV= CMUX_WORKSPACE_ID=
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "resolve: --launcher cmux with herdr live -> cmux (override, R2)" {
  export HERDR_STUB_LIVE=1 HERDR_ENV=1 CMUX_WORKSPACE_ID=
  run run_resolve cmux
  [ "$status" -eq 0 ]
  [ "$output" = cmux ]
}

@test "resolve: --launcher herdr with dead probe -> falls back, not hard-error (R8)" {
  export HERDR_STUB_LIVE=0 HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace:1
  run run_resolve herdr
  [ "$status" -eq 0 ]
  [ "$output" != herdr ]      # fell back rather than dying
  [ "$output" = cmux ]        # to cmux, since it's available
}

@test "--launcher bogus dies with a clear message" {
  run bash "$SCRIPT" --launcher bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --launcher"* ]]
}

@test "--label starting with '-' dies (herdr agent start bare-positional guard)" {
  run bash "$SCRIPT" --name feat --label -bad --handoff /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--label must not start with '-'"* ]]
}

@test "behavior-preservation: cmux --target tab emits the pre-seam CLI call shape" {
  # A throwaway git repo to spin off from.
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  local rrepo; rrepo="$(cd "$repo" && pwd -P)"   # symlink-resolved (matches git's toplevel)

  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  local log="$BATS_TEST_TMPDIR/cmux-argv.log"

  run env PATH="$STUBDIR:$PATH" \
          CMUX_ARGV_LOG="$log" \
          CMUX_WORKSPACE_ID=workspace:99 \
          HERDR_ENV= \
      bash "$SCRIPT" --name testx --label testlabel --handoff "$handoff" --repo "$repo" --target tab
  [ "$status" -eq 0 ]
  [ -f "$log" ]

  # 1) Exact ordered sequence of cmux subcommands (the "call shape").
  mapfile -t verbs < <(awk '{print $1}' "$log")
  local expected=(tree new-surface rename-tab send send-key read-screen send send-key read-screen)
  [ "${#verbs[@]}" -eq "${#expected[@]}" ]
  local i
  for i in "${!expected[@]}"; do
    [ "${verbs[$i]}" = "${expected[$i]}" ]
  done

  # 2) Byte-identical flag shape on the key calls.
  grep -qxF "tree --workspace workspace:99" "$log"
  grep -qxF "new-surface --type terminal --pane pane:1 --workspace workspace:99 --focus true" "$log"
  grep -qxF "rename-tab --surface surface:42 --workspace workspace:99 --title testlabel" "$log"
  # launch command carries the worktree path + label, unchanged.
  grep -qxF "send --surface surface:42 --workspace workspace:99 cd '$rrepo/worktrees/testx' && claude --name 'testlabel'" "$log"
  # kickoff is sent (pointer to the handoff), then submitted.
  grep -qE "^send --surface surface:42 --workspace workspace:99 Read docs/handoff.md" "$log"
  grep -qxF "send-key --surface surface:42 --workspace workspace:99 enter" "$log"

  # 3) Summary names the cmux backend for the tab target (R9).
  [[ "$output" == *"launcher:  cmux"* ]]
  [[ "$output" == *"cmux tab:"* ]]
}

# ---- U3: herdr tab launch path ---------------------------------------------

@test "herdr tab: launch issues 'agent start … -- claude' with --cwd \$WORKTREE and --workspace" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  [ -f "$HERDR_ARGV_LOG" ]
  # DIRECT exec form (KTD-8), worktree path + resolved workspace, `-- claude`.
  grep -qE "^agent start testlabel --cwd .*/worktrees/htab --workspace wS --no-focus -- claude --name testlabel$" "$HERDR_ARGV_LOG"
}

@test "herdr tab: readiness blocks on 'agent wait --status idle' with a timeout (KTD-3)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  grep -qxF "agent wait wS:p2 --status idle --timeout 30000" "$HERDR_ARGV_LOG"
  # the 30× read-screen poll must NOT be on the herdr path
  ! grep -q "read-screen" "$HERDR_ARGV_LOG"
}

@test "herdr tab: kickoff is EXACTLY ONE submit — one 'agent send' + one 'pane send-keys Enter' (R7)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  # exactly one stage (agent send) and exactly one submit (send-keys Enter)
  [ "$(grep -c '^agent send wS:p2 ' "$HERDR_ARGV_LOG")" -eq 1 ]
  [ "$(grep -c '^pane send-keys wS:p2 Enter$' "$HERDR_ARGV_LOG")" -eq 1 ]
  # no second send of ANY kind (auto-fire-cascade guard)
  [ "$(grep -c '^agent send ' "$HERDR_ARGV_LOG")" -eq 1 ]
  ! grep -q "^pane run " "$HERDR_ARGV_LOG"
}

@test "herdr tab: LB_READY=1 (open + briefed) when the wait succeeds" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  [[ "$output" == *"open + briefed"* ]]
}

@test "herdr tab: LB_READY=0 (readiness not confirmed) when the wait times out" {
  export HERDR_STUB_WAIT_FAIL=1
  run_herdr_tab
  [ "$status" -eq 0 ]
  [[ "$output" == *"readiness not confirmed"* ]]
  # still fires the kickoff exactly once even when readiness is unconfirmed
  [ "$(grep -c '^pane send-keys wS:p2 Enter$' "$HERDR_ARGV_LOG")" -eq 1 ]
}

@test "herdr tab: verify-submitted does not double-fire when the kickoff already landed" {
  # the pane-read stub returns a marker WITHOUT the kickoff text → no retry Enter
  run_herdr_tab
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pane send-keys wS:p2 Enter$' "$HERDR_ARGV_LOG")" -eq 1 ]
}

@test "herdr tab: summary names the herdr backend, never cmux (R9)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  # the launch line + the launcher field both report herdr…
  [[ "$output" == *"launcher:  herdr"* ]]
  [[ "$output" == *"herdr tab:"* ]]
  # …and a herdr run must never label itself cmux.
  [[ "$output" != *cmux* ]]
}

# ---- U4: herdr workspace launch + viewer fallback --------------------------

@test "herdr workspace: creates the workspace and launches the agent in it" {
  run_herdr_workspace
  [ "$status" -eq 0 ]
  [ -f "$HERDR_ARGV_LOG" ]
  # workspace create with the worktree cwd, unfocused (mirrors the cmux ordering).
  grep -qE "^workspace create --cwd .*/worktrees/hws --label testlabel --no-focus$" "$HERDR_ARGV_LOG"
  # confirms a terminal pane materialized before switching the user in.
  grep -qxF "pane list --workspace wS" "$HERDR_ARGV_LOG"
  grep -qxF "workspace focus wS" "$HERDR_ARGV_LOG"
  # the agent is launched (U3 verb reused) into the NEW workspace, direct exec.
  grep -qE "^agent start testlabel --cwd .*/worktrees/hws --workspace wS --no-focus -- claude --name testlabel$" "$HERDR_ARGV_LOG"
  # readiness still uses the blocking wait — no read-screen poll on the herdr path.
  grep -qxF "agent wait wS:p2 --status idle --timeout 30000" "$HERDR_ARGV_LOG"
  ! grep -q "read-screen" "$HERDR_ARGV_LOG"
}

@test "herdr workspace: viewer present -> VIEWER_OK=1 and a right-pane split is issued" {
  run_herdr_workspace
  [ "$status" -eq 0 ]
  # split off the agent pane, then render the handoff with a pager.
  grep -qxF "pane split wS:p2 --direction right --no-focus" "$HERDR_ARGV_LOG"
  grep -qE "^pane run wS:pB glow " "$HERDR_ARGV_LOG"
  # summary reflects the rendered viewer.
  [[ "$output" == *"handoff viewer alongside"* ]]
}

@test "herdr workspace: viewer absent -> VIEWER_OK=0 but the launch still succeeds (R5, KTD-6)" {
  export HERDR_STUB_SPLIT_FAIL=1
  run_herdr_workspace
  [ "$status" -eq 0 ]                                    # launch never depends on the viewer
  [[ "$output" != *"handoff viewer alongside"* ]]       # VIEWER_OK stayed 0
  [[ "$output" == *"open + briefed"* ]]                  # the briefed agent is the deliverable
  # no pager render was attempted (the split produced no pane).
  ! grep -q "^pane run wS:pB " "$HERDR_ARGV_LOG"
}

@test "herdr workspace: summary reports the workspace + agent refs and SESS_STATE/VIEWER_NOTE (R9)" {
  run_herdr_workspace
  [ "$status" -eq 0 ]
  # workspace ref + agent pane ref both named in the summary.
  [[ "$output" == *"workspace wS"* ]]
  [[ "$output" == *"wS:p2"* ]]
  # LB_READY=1 → "open + briefed"; VIEWER_OK=1 → the viewer note.
  [[ "$output" == *"open + briefed"* ]]
  [[ "$output" == *"handoff viewer alongside"* ]]
}

@test "herdr workspace: summary names the herdr backend, never cmux (R9)" {
  run_herdr_workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher:  herdr"* ]]
  # the workspace launch line names herdr + the workspace/agent refs.
  [[ "$output" == *"herdr:      workspace wS + agent wS:p2"* ]]
  # a herdr run must never label itself cmux.
  [[ "$output" != *cmux* ]]
}

@test "herdr workspace: readiness timeout -> launch still reports (readiness not confirmed)" {
  export HERDR_STUB_WAIT_FAIL=1
  run_herdr_workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"readiness not confirmed"* ]]
  # the agent pane still launched and the kickoff still fired exactly once.
  [ "$(grep -c '^pane send-keys wS:p2 Enter$' "$HERDR_ARGV_LOG")" -eq 1 ]
}

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
  rename-tab)
    # CMUX_STUB_RENAME_FAIL=1 rejects the way a real missing surface does.
    if [ "${CMUX_STUB_RENAME_FAIL:-0}" = 1 ]; then
      echo 'Error: surface not found' >&2; exit 1
    fi ;;
  tree)          printf 'pane pane:1\n'; printf 'surface surface:9 [terminal]\n' ;;
  new-surface)   printf 'created surface:42\n' ;;
  new-workspace) printf 'created workspace:7\n' ;;
  new-pane)      printf 'created pane:5\n' ;;
  read-screen)   printf '%s\n' '  ? for shortcuts · shift+tab to cycle' ;;
  *)             : ;;
esac
exit 0
STUB

  # herdr stub: `status server` reports running iff HERDR_STUB_LIVE=1 (the
  # liveness probe). The tab-path verbs (U3) consume real output, so the stub
  # emits the LIVE-VERIFIED JSON shapes from the plan's ## Spike Findings:
  #   - `agent start`  -> {"result":{"agent":{"pane_id":"wS:p2",...}}}
  #   - `agent wait`   -> success (idle event) unless HERDR_STUB_WAIT_FAIL=1
  #   - `pane read`    -> claude's real footer (ready) unless HERDR_STUB_NOT_READY=1,
  #                       which returns a bare shell prompt instead (never ready)
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
  "pane get")
    # live workspace resolution: report the pane's CURRENT workspace, which the
    # test controls via HERDR_STUB_LIVE_WS (defaults to wS = matches the env var).
    echo "{\"result\":{\"pane\":{\"workspace_id\":\"${HERDR_STUB_LIVE_WS:-wS}\"}}}" ;;
  "tab create")
    echo '{"result":{"tab":{"tab_id":"wS:t2","pane_id":"wS:p2"}}}' ;;
  "pane list")
    echo '{"result":{"panes":[{"pane_id":"wS:p2","tab_id":"wS:t2","agent_status":"unknown","workspace_id":"wS"}]}}' ;;
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
    # RAW TEXT, not JSON — `pane read` emits the screen verbatim (see the note in
    # launcher_wait_ready_herdr). Emit claude's actual footer, because the readiness
    # gate deliberately matches that and NOT a bare "❯" (also the shell prompt).
    # HERDR_STUB_NOT_READY=1 returns a bare shell prompt instead, i.e. never ready.
    if [ "${HERDR_STUB_NOT_READY:-0}" = 1 ]; then
      printf '%s\n' '❯ '
    else
      printf '%s\n' '╭─────────╮' '  ? for shortcuts · shift+tab to cycle'
    fi ;;
  "pane rename")
    # Echoes back what it stored, the way the real CLI does, so the caller's
    # read-back has something to compare against. HERDR_STUB_RENAME_FAIL=1 makes it
    # reject the way a real pane-not-found does: exit 1 with a JSON error payload.
    if [ "${HERDR_STUB_RENAME_FAIL:-0}" = 1 ]; then
      echo '{"error":{"code":"pane_not_found","message":"pane not found"}}'; exit 1
    fi
    shift 2   # drop "pane rename"; $1 is the pane id, $2.. the label
    pane_id="$1"; shift
    printf '{"result":{"pane":{"pane_id":"%s","label":"%s"}}}\n' "$pane_id" "$*" ;;
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

  # Cap the readiness ceiling: the 180s default means a NOT-ready case hangs three
  # minutes per test before failing, which is why this suite was unrunnable.
  run env PATH="$STUBDIR:$PATH" \
          HERDR_ARGV_LOG="$HERDR_ARGV_LOG" \
          HERDR_STUB_LIVE=1 \
          HERDR_ENV=1 \
          HERDR_WORKSPACE_ID=wS \
          HERDR_PANE_ID=wS:p1 \
          CMUX_WORKSPACE_ID= \
          SPINOFF_READY_TIMEOUT_MS=3000 \
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
          SPINOFF_READY_TIMEOUT_MS=3000 \
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
    HERDR="$2"; CMUX="$3"; LAUNCHER="$4"; FORCED_LAUNCHER="$4"
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

@test "cmux: a rejected rename warns and does not fail the run (AE5)" {
  local repo="$BATS_TEST_TMPDIR/crepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  run env PATH="$STUBDIR:$PATH" \
          CMUX_STUB_RENAME_FAIL=1 \
          CMUX_WORKSPACE_ID=workspace:99 \
          HERDR_ENV= \
      bash "$SCRIPT" --name ctestx --label testlabel --handoff "$handoff" --repo "$repo" --target tab
  # Naming is cosmetic: the worktree and the briefed session must survive it.
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be named"* ]]
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
  # The brief now rides the launch, so the trailing kickoff send/submit/verify
  # triple is gone: one send (the launch), one Enter, one readiness read.
  local expected=(tree new-surface rename-tab send send-key read-screen)
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
  # the launch command carries the brief as claude's positional prompt
  grep -qE "^send --surface surface:42 --workspace workspace:99 cd '.*/worktrees/testx' && claude --name 'testlabel' " "$log"
  grep -qxF "send-key --surface surface:42 --workspace workspace:99 enter" "$log"
  # and NO separate kickoff send exists any more
  ! grep -qE "^send --surface .* Read docs/handoff.md" "$log"

  # 3) Summary names the cmux backend for the tab target (R9).
  [[ "$output" == *"launcher:  cmux"* ]]
  [[ "$output" == *"cmux tab:"* ]]
}

# ---- U3: herdr tab launch path ---------------------------------------------

@test "herdr tab: creates a NEW named tab and runs claude into its pane (no split)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  [ -f "$HERDR_ARGV_LOG" ]
  # a real new tab, named for the session…
  grep -qxF "tab create --workspace wS --label testlabel --no-focus" "$HERDR_ARGV_LOG"
  # …and claude is RUN INTO its root pane (cd + claude), never `agent start`
  # (which splits a pane in the CURRENT tab — the bug this replaces).
  grep -qE "^pane run wS:p2 cd '.*/worktrees/htab' && claude --name 'testlabel' \"\\\$\(cat '.*\.spinoff-brief'\)\"$" "$HERDR_ARGV_LOG"
  ! grep -q "^agent start" "$HERDR_ARGV_LOG"
}

@test "herdr: names the pane, passing a two-word label as ONE argument (AE6)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  # The label is a bare variadic positional on this call, so a label that
  # word-splits would arrive as two argv items and store only the first.
  grep -qxF "pane rename wS:p2 testlabel" "$HERDR_ARGV_LOG"
}
@test "herdr: names the pane BEFORE running claude into it (KTD2)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  local rename_at run_at
  rename_at="$(grep -n '^pane rename ' "$HERDR_ARGV_LOG" | head -1 | cut -d: -f1)"
  run_at="$(grep -n '^pane run ' "$HERDR_ARGV_LOG" | head -1 | cut -d: -f1)"
  [ -n "$rename_at" ] && [ -n "$run_at" ]
  # After the launch the pane holds a live shell writing its own title; naming
  # first is what keeps the label from racing it.
  [ "$rename_at" -lt "$run_at" ]
}
@test "herdr: a rejected rename warns, keeps the session briefed, and reports the surface (AE5)" {
  export HERDR_STUB_RENAME_FAIL=1
  run_herdr_tab
  # A cosmetic failure must not cost the worktree or the briefed session.
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be named"* ]]
  # the launch still happened (the summary line for the unnamed surface is U5's)
  grep -q '^pane run ' "$HERDR_ARGV_LOG"
}

@test "herdr tab: places the tab in the LIVE workspace, not a stale HERDR_WORKSPACE_ID" {
  # the env var says wS, but the live pane reports wLIVE — the tab must follow the
  # LIVE workspace (the "spinoff spawned from space A lands in space B" fix).
  export HERDR_STUB_LIVE_WS=wLIVE
  run_herdr_tab
  [ "$status" -eq 0 ]
  grep -qxF "tab create --workspace wLIVE --label testlabel --no-focus" "$HERDR_ARGV_LOG"
  # never falls back to the stale env workspace when a live one resolved
  ! grep -qE "tab create --workspace wS " "$HERDR_ARGV_LOG"
}

@test "herdr tab: readiness is read off the SCREEN, not from an agent-status wait" {
  # 0.8.3 moved readiness from `agent wait` to reading the pane, because an agent
  # can register idle while a trust modal still blocks the prompt.
  run_herdr_tab
  [ "$status" -eq 0 ]
  grep -qE "^pane read wS:p2 --source visible$" "$HERDR_ARGV_LOG"
  # the cmux 30x read-screen poll must NOT be on the herdr path
  ! grep -q "read-screen" "$HERDR_ARGV_LOG"
}

@test "herdr tab: an unwritable brief file REFUSES to launch (R13)" {
  # Guards against the degenerate `claude ""` — a session that opens with no idea
  # why it exists, which is the exact outcome brief-at-launch is meant to remove.
  local repo="$BATS_TEST_TMPDIR/norepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"
  HERDR_ARGV_LOG="$BATS_TEST_TMPDIR/herdr-nobrief.log"
  : > "$HERDR_ARGV_LOG"

  run env PATH="$STUBDIR:$PATH" \
          HERDR_ARGV_LOG="$HERDR_ARGV_LOG" \
          HERDR_STUB_LIVE=1 HERDR_ENV=1 HERDR_WORKSPACE_ID=wS HERDR_PANE_ID=wS:p1 \
          CMUX_WORKSPACE_ID= SPINOFF_READY_TIMEOUT_MS=3000 \
          SPINOFF_BRIEF_FILE=/nonexistent-dir/brief.txt \
      bash "$SCRIPT" --name nobrief --label testlabel --handoff "$handoff" \
                     --repo "$repo" --target tab --launcher herdr

  # refused, said why, and exited non-zero
  [[ "$output" == *"refusing to launch an unbriefed session"* ]]
  [ "$status" -ne 0 ]
  # and crucially: claude was never started
  [ "$(grep -c 'claude --name' "$HERDR_ARGV_LOG")" -eq 0 ]
  # the worktree is still real work and survives
  [ -f "$repo/worktrees/nobrief/docs/handoff.md" ]
}

@test "herdr tab: the brief rides the launch — nothing is sent to the session afterward" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  # exactly one launch, and it carries the brief
  [ "$(grep -c '^pane run wS:p2 cd ' "$HERDR_ARGV_LOG")" -eq 1 ]
  grep -qF '.spinoff-brief' "$HERDR_ARGV_LOG"
  # no post-launch text injection of any kind — that whole path is gone
  [ "$(grep -c '^agent send' "$HERDR_ARGV_LOG")" -eq 0 ]
  [ "$(grep -c '^agent prompt' "$HERDR_ARGV_LOG")" -eq 0 ]
  [ "$(grep -c '^pane send-text' "$HERDR_ARGV_LOG")" -eq 0 ]
}

@test "herdr tab: LB_READY=1 (open + briefed) when the wait succeeds" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  [[ "$output" == *"open + briefed"* ]]
}

@test "herdr tab: a never-ready screen is still briefed, and says a dialog may be up" {
  # The brief is submitted BY the launch, so a session that never draws is briefed
  # regardless. What an unconfirmed prompt now costs is the trust-modal answer, so
  # the run reports that instead of withholding the brief.
  export HERDR_STUB_NOT_READY=1
  run_herdr_tab
  [ "$status" -eq 0 ]
  [[ "$output" == *"open + briefed"* ]]
  [[ "$output" == *"a dialog may still be up"* ]]
}

@test "herdr tab: no Enter is sent to submit the brief (the launch already did)" {
  run_herdr_tab
  [ "$status" -eq 0 ]
  # the only send-keys allowed on a ready screen is none: readiness confirmed
  # without a modal, so nothing needs dismissing and nothing needs submitting.
  [ "$(grep -c '^pane send-keys wS:p2 Enter$' "$HERDR_ARGV_LOG")" -eq 0 ]
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
  # claude is RUN INTO the workspace's root pane (shared verb), never `agent start`.
  grep -qE "^pane run wS:p2 cd '.*/worktrees/hws' && claude --name 'testlabel' " "$HERDR_ARGV_LOG"
  ! grep -q "^agent start" "$HERDR_ARGV_LOG"
  # readiness is read off the screen — no cmux read-screen poll on the herdr path.
  grep -qE "^pane read wS:p2 --source visible$" "$HERDR_ARGV_LOG"
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

@test "herdr workspace: a never-ready screen is still briefed by the launch" {
  export HERDR_STUB_NOT_READY=1
  run_herdr_workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"open + briefed"* ]]
  [[ "$output" == *"a dialog may still be up"* ]]
}

# ---- U2: the loud path for an announced-but-unresolvable backend ------------
#
# These runs deliberately keep herdr and cmux OFF the PATH. The bug they pin: a
# background agent's PATH does not hold the login shell's, so an environment that
# announced herdr (HERDR_ENV=1) resolved LAUNCHER=none and the run printed
# "skipping launch automation" at exit 0 — a silent skip the relaying agent read as
# success.
#
# Two knobs make that reachable under test at all:
#   * $SPINOFF_BIN_PATHS points at an EMPTY dir, so the standard-install scan can't
#     find this machine's real /opt/homebrew/bin/herdr and pass for the wrong reason.
#   * PATH keeps /usr/bin:/bin. A PATH of only the stub dir dies at `git rev-parse`
#     in the --repo region, long before the launch gate — which would look like the
#     bug and prove nothing.
# HERDR_BIN / CMUX_BIN are explicitly `env -u`'d: setup() sets them without
# exporting, and a future change that exports them would otherwise silently disarm
# every test in this section by resolving the very binary they need missing.
run_unresolvable() {
  local repo="$BATS_TEST_TMPDIR/urepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  UREPO="$(cd "$repo" && pwd -P)"

  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  # A launcher-free stub dir: claude/sleep/glow only. $LOUD_STUBS adds back exactly
  # the launcher binaries a given case wants resolvable (e.g. "cmux" for the KTD-8
  # proof, "herdr" for the server-down case).
  NOSTUB="$BATS_TEST_TMPDIR/nostubs"
  EMPTYBIN="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$NOSTUB" "$EMPTYBIN"
  cp "$STUBDIR/claude" "$STUBDIR/sleep" "$STUBDIR/glow" "$NOSTUB/"
  local s
  for s in ${LOUD_STUBS:-}; do cp "$STUBDIR/$s" "$NOSTUB/"; done

  # Also scrub the host's GHOSTTY identity. Those vars are exported by every real
  # Ghostty window, so an unannounced-session test run from one inherits them, the
  # ghostty branch wins (its .app and /usr/bin/osascript both resolve), and the case
  # under test never happens — it drives a REAL AppleScript launch instead. A test
  # that wants ghostty passes the vars back explicitly (they follow "$@", so they win).
  run env -u HERDR_BIN -u CMUX_BIN \
          -u TERM_PROGRAM -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_SURFACE_ID \
          PATH="$NOSTUB:/usr/bin:/bin" \
          SPINOFF_BIN_PATHS="$EMPTYBIN" \
          SPINOFF_READY_TIMEOUT_MS=3000 \
          "$@" \
      bash "$SCRIPT" --name uh --label testlabel --handoff "$handoff" \
                     --repo "$repo" --target tab ${LOUD_ARGS:-}
}

@test "loud: announced herdr that cannot be resolved warns and exits 4 (R5, R6)" {
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID=

  # names the binary, every place it looked, and the override that fixes it
  [[ "$output" == *"could not resolve"* ]]
  [[ "$output" == *"herdr"* ]]
  [[ "$output" == *"HERDR_BIN"* ]]
  [[ "$output" == *"$EMPTYBIN"* ]]
  # incomplete, with the code reserved for this cause
  [ "$status" -eq 4 ]
  # …and the real work survives: branch, worktree, handoff
  [ -f "$UREPO/worktrees/uh/docs/handoff.md" ]
  git -C "$UREPO" rev-parse --verify feature/uh
  git -C "$UREPO" worktree list | grep -q "worktrees/uh"
}

@test "override: a valid HERDR_BIN launches with no herdr on PATH at all (R2)" {
  # The main session resolves the binary and passes it down (SKILL.md Step 4), so a
  # SET, VALID override is the PRIMARY path now, not a break-glass knob — and the whole
  # point is that it works when PATH cannot answer. run_unresolvable's stub dir holds
  # no herdr, so PATH resolution genuinely cannot succeed here; only the override can.
  LOUD_STUBS=
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=1 \
                   HERDR_BIN="$STUBDIR/herdr"

  [ "$status" -eq 0 ]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" != *"INCOMPLETE"* ]]
  [[ "$output" == *"launcher:  herdr"* ]]
  # and it really launched rather than falling back to a quiet none
  [[ "$output" == *"✓ Spinoff complete"* ]]
  [ -f "$UREPO/worktrees/uh/docs/handoff.md" ]
}

@test "loud: announced cmux that cannot be resolved warns and exits 4 (R5, R6)" {
  # cmux is made unresolvable through a SET-but-invalid CMUX_BIN rather than a bare
  # empty PATH, and that is deliberate: resolve_bin's extra candidate for cmux is
  # /Applications/cmux.app/Contents/Resources/bin/cmux, which EXISTS on a developer
  # machine that has cmux installed — so "cmux is not on PATH" resolves anyway there
  # and the test would pass or fail depending on whose laptop ran it. A set override
  # that fails the R15 file+executable test resolves to empty on every machine, and
  # deliberately does not fall through, which is exactly the state the record reads.
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID=workspace:1 \
                   CMUX_BIN=/nonexistent/dir/cmux

  [[ "$output" == *"could not resolve"* ]]
  [[ "$output" == *"cmux"* ]]
  [[ "$output" == *"CMUX_WORKSPACE_ID"* ]]
  # the rejected-override branch diagnoses the value that was thrown out, and does NOT
  # tell someone to set a variable they already set
  [[ "$output" == *"CMUX_BIN is set to '/nonexistent/dir/cmux'"* ]]
  [[ "$output" != *"fix: set CMUX_BIN"* ]]
  [ "$status" -eq 4 ]
  [ -f "$UREPO/worktrees/uh/docs/handoff.md" ]
}

@test "loud: exit 4 warns that re-running the same --name will die, like exit 5 does" {
  # Both loud codes leave a worktree and branch behind and both tell the user to
  # re-run. Exit 5 says re-run with a NEW --name; exit 4 used to just say "re-run",
  # sending the user into `worktree path already exists` at exit 1 — a named,
  # recoverable failure turned into a confusing unrelated one. Held to the same
  # message contract here so the two blocks cannot drift apart again.
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID=
  [ "$status" -eq 4 ]
  [[ "$output" == *"NEW --name"* ]]
}

@test "loud: the summary block says INCOMPLETE and never prints a tick (KTD-5)" {
  # Teaching only the tail exit would print "✓ Spinoff complete" alongside exit 4, and
  # the skill relays this block verbatim — so the header has to learn the flag too.
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID=
  [ "$status" -eq 4 ]
  [[ "$output" == *"Spinoff INCOMPLETE"* ]]
  [[ "$output" != *"✓ Spinoff complete"* ]]
  # and the launch line names the real cause, not "not inside cmux/herdr"
  [[ "$output" != *"not automated (not inside cmux/herdr)"* ]]
}

@test "silent: another announced backend launches -> exit 0, no warning (R17, KTD-8)" {
  # THE KTD-8 proof. herdr is announced and unresolvable, cmux is announced and
  # resolvable: recording happens, acting must not, because resolution settled on cmux.
  LOUD_STUBS=cmux
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace:1
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" == *"launcher:  cmux"* ]]
  [[ "$output" == *"✓ Spinoff complete"* ]]
}

@test "silent: no announcement at all -> exit 0, LAUNCHER=none, worktree made (R7)" {
  # OSASCRIPT_BIN is deliberately bogus so this machine's real Ghostty.app +
  # /usr/bin/osascript can't resolve the ghostty backend and steal the case.
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID= OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" == *"launcher:  none"* ]]
  [[ "$output" == *"no multiplexer announced this session"* ]]
  [ -f "$UREPO/worktrees/uh/docs/handoff.md" ]
}

@test "silent: HERDR_ENV=0 keeps its existing quiet fallback to none (R8)" {
  run_unresolvable HERDR_ENV=0 CMUX_WORKSPACE_ID=
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" == *"launcher:  none"* ]]
}

@test "loud: resolvable herdr whose server is down exits 5, not a silent 0 (R9)" {
  # This test used to assert exit 0. That silence was the defect: a dead herdr server
  # looked exactly like a session that isn't in a multiplexer, and the background agent
  # that relays this script reads the status, not the prose. The binary resolves here,
  # so $LOUD_BIN is empty and the gate selects 5 rather than 4.
  LOUD_STUBS=herdr
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=0
  [ "$status" -eq 5 ]
  [[ "$output" == *"launcher:  none"* ]]
  # Assert the NEW wording specifically. Bare "herdr" and "HERDR_ENV=1" would be
  # useless here — the old step line this diff removed contained both, so asserting
  # them would pass against the very implementation this test exists to reject.
  [[ "$output" == *'`herdr` announced this session (HERDR_ENV=1) but would not take the launch'* ]]
  # The remedy is starting the server — NOT setting a binary path. Borrowing exit 4's
  # diagnosis here would send the user to fix a $PATH that is already correct.
  [[ "$output" == *"herdr status server"* ]]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" != *"SPINOFF_BIN_PATHS"* ]]
  # A retrying caller must be told the worktree is already there; re-running the same
  # --name dies at exit 1 on "worktree path already exists", turning a recoverable
  # failure into a confusing one.
  [[ "$output" == *"NEW --name"* ]]
  # ...and the failure must still hand over a working recovery command. Assert the
  # MANUAL_CMD the exit-5 tail prints, not the worktree path on its own: the summary
  # block prints that path unconditionally on every run, so a path-only assertion
  # holds even if the recovery paragraph is deleted entirely.
  [[ "$output" == *"cd '$UREPO/worktrees/uh' && claude"* ]]
  # A single occurrence proves nothing — the LAUNCHER=none summary branch prints
  # MANUAL_CMD too, so deleting it from the failure paragraph still leaves one. Require
  # BOTH: the summary's copy and the exit-5 tail's. That paragraph is the part relayed
  # outside the summary block, so losing its recovery line is the regression that matters.
  [ "$(grep -cF "cd '$UREPO/worktrees/uh' && claude" <<<"$output")" -ge 2 ]
  [[ "$output" == *"or just start the session by hand in the worktree that is already there:"* ]]
  # It must not read as a skip, and it must not lie about what announced.
  [[ "$output" != *"no multiplexer announced"* ]]
  [[ "$output" != *"skipping launch automation"* ]]
  # The artifacts survive — this is a failed launch, not a failed spinoff.
  [ -f "$UREPO/worktrees/uh/docs/handoff.md" ]
}

@test "loud: the probe-failed summary says INCOMPLETE and never prints a tick" {
  # Same regression KTD-5 pinned for exit 4: teaching the tail exit but not the header
  # prints "✓ Spinoff complete" above a failing status, in the block the skill relays
  # verbatim. The header reads the generalized flag, so this covers exit 5 too.
  LOUD_STUBS=herdr
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=0
  [ "$status" -eq 5 ]
  [[ "$output" == *"Spinoff INCOMPLETE"* ]]
  [[ "$output" != *"✓ Spinoff complete"* ]]
}

@test "loud: forced --launcher herdr with nothing announced exits 4, not a silent 0" {
  LOUD_ARGS="--launcher herdr"
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID= OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 4 ]
  [[ "$output" == *"falling back to auto-detection"* ]]
  [[ "$output" == *"could not resolve"* ]]
  # The diagnosis must name the FLAG the user passed, not an env var they never set.
  # Assert the announce text from the record — a bare "--launcher herdr" is printed by
  # the falling-back warning above and would hold against the old code too.
  [[ "$output" == *"announced it (--launcher herdr)"* ]]
  [[ "$output" != *"no multiplexer announced this session"* ]]
  [[ "$output" != *"✓ Spinoff complete"* ]]
}

@test "loud: forced ghostty must not erase a live herdr's diagnosis" {
  # SKILL.md points you at `--launcher ghostty` precisely when herdr's server is dead,
  # so that run has BOTH a forced ghostty and HERDR_ENV=1 with a resolvable herdr. The
  # message has to keep herdr's cause: `herdr status server` is the only thing here that
  # separates a stopped server from a socket this process cannot reach. Naming ghostty
  # instead would swap an actionable diagnosis for one with no remedy — at the same
  # exit code, so no status check would notice.
  LOUD_STUBS=herdr
  LOUD_ARGS="--launcher ghostty"
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=0 \
                   OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 5 ]
  [[ "$output" == *"announced this session (HERDR_ENV=1)"* ]]
  [[ "$output" == *"herdr status server"* ]]
  [[ "$output" != *"announced this session (--launcher ghostty)"* ]]
  [[ "$output" != *"osascript was not found"* ]]
}

@test "loud: forced --launcher ghostty that can't run exits 5 (KTD-9 flag vs env)" {
  # Ghostty's ENV vars stay excluded from the loud path — they are set for every
  # Ghostty window and announce nothing. The FLAG is a deliberate request, so it does
  # count. This is also the only reachable exercise of the non-herdr exit-5 wording.
  LOUD_ARGS="--launcher ghostty"
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID= OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 5 ]
  [[ "$output" == *"announced this session (--launcher ghostty)"* ]]
  # It must name what is ACTUALLY missing. osascript is pinned at a nonexistent path
  # here, so that is the piece to report. Ghostty's probe only ever fails because
  # something did not resolve — there is no ghostty server — so a message claiming
  # "the binary resolved fine" would be false, which is the class of defect this whole
  # change removes. Assert the true cause, not just the harmless tail of the sentence.
  [[ "$output" == *"osascript was not found"* ]]
  [[ "$output" != *"the binary resolved fine"* ]]
  [[ "$output" != *"resolved; the backend did not pass"* ]]
  # and it must not borrow the other backends' remedies
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" != *"herdr status server"* ]]
}

@test "silent: ghostty ENV identity alone still announces nothing (R14, KTD-9)" {
  # The counterpart to the test above, and the line the flag change must not cross:
  # being IN a Ghostty window is not a launch request. Without the flag this stays a
  # quiet exit 0 even though the exact same probe fails.
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID= \
                   TERM_PROGRAM=ghostty OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 0 ]
  [[ "$output" == *"no multiplexer announced this session"* ]]
  # Not `!= *"--launcher"*` — no flag is passed here, so nothing could print it and the
  # check cannot fail. Deny the ANNOUNCE-TEXT form instead: a real announcement always
  # renders as "<backend> announced this session (<what announced it>)", and the benign
  # line above is "no multiplexer announced this session" with no parenthetical. So the
  # trailing " (" is what separates them — this breaks the moment ghostty's env vars are
  # promoted to an announcement, which is the distinction the test is named for.
  [[ "$output" != *"announced this session ("* ]]
}

@test "loud: two announced backends failing differently report ONE cause (exit 4)" {
  # The only reachable run where the two records disagree: $ANNOUNCED_* is
  # first-announced-wins (herdr, resolved, server dead), $LOUD_* is
  # first-unresolved-wins (cmux, missing). The gate fires on the announcement but the
  # branch selects on $LOUD_BIN, so this run must diagnose cmux ONLY — fixing CMUX_BIN
  # genuinely restores a launch, and naming herdr's dead server alongside it would put
  # two backends in one diagnosis. Without this test, a later edit that keys any loud
  # wording off $ANNOUNCED_BIN produces exactly that and every other test stays green.
  LOUD_STUBS=herdr
  run_unresolvable HERDR_ENV=1 HERDR_STUB_LIVE=0 CMUX_WORKSPACE_ID=workspace:1 \
                   CMUX_BIN=/nonexistent/cmux
  [ "$status" -eq 4 ]
  # Assert the diagnosis line VERBATIM, and deny the other backend by name. A bare
  # *cmux* substring cannot tell which backend was named — "cmux" also appears in the
  # searched-locations list (/Applications/cmux.app/...) — so it holds even if the
  # wording is repointed at $ANNOUNCED_BIN and reports herdr's dead server instead.
  # That repointing is the exact drift this test exists to stop.
  [[ "$output" == *'could not resolve `cmux`'* ]]
  [[ "$output" != *'could not resolve `herdr`'* ]]
  [[ "$output" != *"would not take it"* ]]
}

@test "loud: a forced launcher can also reach the exit-5 gate (second entry path)" {
  # Regression coverage for the OTHER route into the gate: a forced --launcher whose
  # probe fails falls through to detection instead of returning early, so an announced
  # session can land on `none` this way too. Note this does NOT prove the gate is
  # default-deny — herdr is still the announced backend and its probe still failed, so
  # an enumerating gate would pass this as well. The source-level test below is what
  # separates those two implementations.
  #
  # Forced herdr, binary present, server dead: the flag's probe fails, the run falls
  # through to detection, detection also lands on none, and the gate fires. $LOUD_BIN
  # is empty because the binary resolved, so this is the exit-5 shape.
  LOUD_STUBS=herdr
  LOUD_ARGS="--launcher herdr"
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=0
  [ "$status" -eq 5 ]
  [[ "$output" == *"falling back to auto-detection"* ]]
  # The flag outranks the env var for the diagnosis: HERDR_ENV=1 is also set here, and
  # the message must still name the flag the user typed. Assert the announce text in
  # the failure itself — a bare "--launcher herdr" would be satisfied by the
  # falling-back warning above and would hold against the old code too.
  [[ "$output" == *"announced this session (--launcher herdr)"* ]]
  [[ "$output" != *"announced this session (HERDR_ENV=1)"* ]]
}

@test "loud: a forced backend whose BINARY is missing is exit 4, not exit 5" {
  # The sibling of the test above, and the reason the flag is recorded through the same
  # two-record split as an env announcement rather than always meaning "backend
  # refused". Forcing cmux with no cmux installed is a resolution failure, and the
  # actionable answer is CMUX_BIN — not "start the server".
  #
  # CMUX_BIN is pinned at a nonexistent path on purpose. Emptying $PATH is NOT enough
  # to make cmux unresolvable: resolve_bin also tries the app's own install location
  # (/Applications/cmux.app/...), so on a machine with cmux installed the forced probe
  # SUCCEEDS, returns early, and the run drives a real cmux socket instead of the case
  # under test — passing or failing according to what the developer happens to have
  # installed. A set-but-invalid override resolves to empty (R15), which is deterministic.
  LOUD_STUBS=herdr
  LOUD_ARGS="--launcher cmux"
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID= HERDR_STUB_LIVE=0 \
                   CMUX_BIN=/nonexistent/cmux
  [ "$status" -eq 4 ]
  # Verbatim, and deny herdr by name — same reason as the two-backend test below: a
  # bare *cmux* substring also matches the searched-locations list, so it cannot tell
  # which backend the diagnosis actually named.
  [[ "$output" == *'could not resolve `cmux`'* ]]
  [[ "$output" != *'could not resolve `herdr`'* ]]
  [[ "$output" != *"would not take the launch"* ]]
}

@test "the loud gate keys on the ANNOUNCEMENT, not on any one backend's probe (KTD1)" {
  # KTD1 requires the gate to be default-deny: ANY announced backend that did not
  # launch is a failure, whatever the reason. End-to-end runs cannot prove that today —
  # `_cmux_probe` is binary-only, so herdr is the only backend that can reach
  # "announced, resolved, probe failed", and an implementation keyed on "herdr
  # announced and _herdr_probe failed" would pass every behavioural test in this file
  # including the flipped one above, while being exactly what KTD1 forbids.
  #
  # So drive the decision directly with a backend name that DOES NOT EXIST. Nothing
  # keyed on herdr, on cmux, or on any probe can return true for `futurebackend`;
  # only a gate that reads the announcement itself can. That is the invariant, tested
  # rather than the source text spelling it — this survives renames and reflows.
  run bash -c '
    SPINOFF_TEST_SOURCE=1 . "$1" || exit 9
    LAUNCHER=none ANNOUNCED_BIN=futurebackend LOUD_BIN=""
    _announced_unlaunched || exit 1
    # and it must stay quiet when nothing announced, or when something DID launch
    ANNOUNCED_BIN="" ;                 _announced_unlaunched && exit 2
    LAUNCHER=herdr ANNOUNCED_BIN=herdr; _announced_unlaunched && exit 3
    exit 0
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "silent: unannounced session says nothing announced, not a backend name (R7)" {
  # The counterpart to the R9 test above: with nothing announced, the benign wording is
  # the correct one. Pinning both directions is what stops the two from re-collapsing.
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID=
  [ "$status" -eq 0 ]
  [[ "$output" == *"no multiplexer announced"* ]]
  [[ "$output" != *"announced this session ("* ]]
}

@test "silent: ghostty vars + unresolvable osascript stay quiet (R14, KTD-9)" {
  # Ghostty's vars are passive terminal identity, set for every window. Keying the
  # loud path on them would turn ordinary sessions into exit-4 failures.
  run_unresolvable HERDR_ENV= CMUX_WORKSPACE_ID= \
                   TERM_PROGRAM=ghostty OSASCRIPT_BIN=/nonexistent/osascript
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not resolve"* ]]
  [[ "$output" != *osascript* ]]
  [[ "$output" == *"launcher:  none"* ]]
}

@test "forced --launcher herdr with the binary missing still falls back, not dies (R10)" {
  LOUD_STUBS=cmux
  LOUD_ARGS="--launcher herdr"
  run_unresolvable HERDR_ENV=1 CMUX_WORKSPACE_ID=workspace:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to auto-detection"* ]]
  [[ "$output" == *"launcher:  cmux"* ]]
  [[ "$output" != *"could not resolve"* ]]
}

@test "exit codes stay distinct: the unbriefed-session path still exits 3 (KTD-4)" {
  # 3 and 4 are mutually exclusive by construction: 3 needs BRIEF_ATTEMPTED=1 (so
  # LAUNCHER != none), 4 needs LAUNCHER = none. This pins 3 against a drift to 4.
  local repo="$BATS_TEST_TMPDIR/e3repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  local handoff="$repo/handoff.md"
  printf '# Handoff\n\nbrief body\n' > "$handoff"

  # -u HERDR_BIN -u CMUX_BIN for the same reason the loud tests do it: setup() assigns
  # those names as stub pointers, and the moment one is exported this test would honor
  # it as a production override instead of exercising PATH resolution.
  run env -u HERDR_BIN -u CMUX_BIN PATH="$STUBDIR:$PATH" \
          HERDR_STUB_LIVE=1 HERDR_ENV=1 HERDR_WORKSPACE_ID=wS HERDR_PANE_ID=wS:p1 \
          CMUX_WORKSPACE_ID= SPINOFF_READY_TIMEOUT_MS=3000 \
          SPINOFF_BRIEF_FILE=/nonexistent-dir/brief.txt \
      bash "$SCRIPT" --name e3 --label testlabel --handoff "$handoff" \
                     --repo "$repo" --target tab --launcher herdr

  [ "$status" -eq 3 ]
  [[ "$output" == *"THE NEW SESSION WAS NOT BRIEFED"* ]]
  [[ "$output" != *"could not resolve"* ]]
}

# ---- resolver-level coverage (U3): resolve_bin precedence + the R15 rejections ----
#
# The six `resolve_launcher` tests above enter one layer too high (they inject $HERDR /
# $CMUX by hand), and the loud/silent tests one layer too low (they assert on a whole
# run's output). Neither pins resolve_bin's OWN contract, so "simplify" `-f && -x` to a
# bare `-x`, or let a set-but-invalid override fall through to $PATH, and the suite
# stays green. These tests call resolve_bin directly through the SPINOFF_TEST_SOURCE
# hook (R12) and assert on its echoed path.
#
# Every test sets BOTH search inputs explicitly — $RB_PATH and $RB_BIN_PATHS — so no
# real install location on the host can satisfy a lookup and make a test pass for the
# wrong reason. Note $SPINOFF_BIN_PATHS is read with `:-`, so an EMPTY string means
# "use the built-in defaults": "nothing in the known locations" has to be spelled as a
# real but empty DIRECTORY, never as "".

# A tiny executable at $1.
mkbin() { mkdir -p "${1%/*}"; printf '#!/usr/bin/env bash\nexit 0\n' > "$1"; chmod +x "$1"; }

# resolve_bin <name> <override> [extra-candidates], echoed for assertion on $output.
# PATH is assigned INSIDE the spawned shell rather than through `env`, because
# `env PATH=... bash` resolves `bash` itself through the PATH it is setting — an empty
# one means env cannot find bash at all and the test dies before reaching the resolver.
run_resolve_bin() {
  run env SPINOFF_TEST_SOURCE=1 SPINOFF_BIN_PATHS="${RB_BIN_PATHS-}" \
      bash -c 'PATH="$5"; source "$1"; resolve_bin "$2" "$3" "$4"' \
      _ "$SCRIPT" "$1" "${2-}" "${3-}" "${RB_PATH-}"
}

# Same seam, but echoes resolve_bin_rejected's verdict for the same inputs.
run_resolve_bin_rejected() {
  run env SPINOFF_TEST_SOURCE=1 SPINOFF_BIN_PATHS="${RB_BIN_PATHS-}" \
      bash -c 'PATH="$4"; source "$1"
               r="$(resolve_bin "$2" "$3")"
               resolve_bin_rejected "$r" "$3"' \
      _ "$SCRIPT" "$1" "${2-}" "${RB_PATH-}"
}

@test "resolve_bin: an explicit override wins over a different binary on \$PATH (R2, R3)" {
  local pathdir="$BATS_TEST_TMPDIR/rb-ovr/path" ovrdir="$BATS_TEST_TMPDIR/rb-ovr/ovr"
  mkbin "$pathdir/tool"
  mkbin "$ovrdir/tool"
  RB_PATH="$pathdir" RB_BIN_PATHS="$BATS_TEST_TMPDIR/rb-ovr/empty"
  mkdir -p "$RB_BIN_PATHS"

  run_resolve_bin tool "$ovrdir/tool"
  [ "$status" -eq 0 ]
  [ "$output" = "$ovrdir/tool" ]
}

@test "resolve_bin: the override wins even when \$PATH holds no candidate (R2)" {
  local ovrdir="$BATS_TEST_TMPDIR/rb-ovr2/ovr" empty="$BATS_TEST_TMPDIR/rb-ovr2/empty"
  mkbin "$ovrdir/tool"
  mkdir -p "$empty"
  RB_PATH="$empty" RB_BIN_PATHS="$empty"

  run_resolve_bin tool "$ovrdir/tool"
  [ "$status" -eq 0 ]
  [ "$output" = "$ovrdir/tool" ]
}

@test "resolve_bin: no override -> a stub on \$PATH resolves to its absolute path (R1, R3)" {
  local pathdir="$BATS_TEST_TMPDIR/rb-path/bin" empty="$BATS_TEST_TMPDIR/rb-path/empty"
  mkbin "$pathdir/tool"
  mkdir -p "$empty"
  RB_PATH="$pathdir" RB_BIN_PATHS="$empty"

  run_resolve_bin tool ""
  [ "$status" -eq 0 ]
  [ "$output" = "$pathdir/tool" ]
}

@test "resolve_bin: nothing on \$PATH -> a stub in \$SPINOFF_BIN_PATHS resolves (R3, R16)" {
  local known="$BATS_TEST_TMPDIR/rb-known/known" empty="$BATS_TEST_TMPDIR/rb-known/empty"
  mkbin "$known/tool"
  mkdir -p "$empty"
  RB_PATH="$empty" RB_BIN_PATHS="$empty:$known"

  run_resolve_bin tool ""
  [ "$status" -eq 0 ]
  [ "$output" = "$known/tool" ]
}

@test "resolve_bin: nothing anywhere -> empty, no error, exit 0 (R3)" {
  # resolve_bin never fails and never writes to stderr: deciding what an empty result
  # MEANS belongs to the caller, which is what the loud/silent split above depends on.
  local empty="$BATS_TEST_TMPDIR/rb-none/empty"
  mkdir -p "$empty"
  RB_PATH="$empty" RB_BIN_PATHS="$empty"

  run_resolve_bin tool ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_bin: an override pointing at a DIRECTORY is empty and does NOT fall through to \$PATH (R15)" {
  # The highest-value test in this file. `-x` alone is TRUE of a directory, so a bare
  # `-x` check "resolves" HERDR_BIN=/opt/homebrew/bin and reproduces the original bug
  # one layer down with a launch that execs a directory — this pins the `-f` half.
  # The usable stub on $PATH is the second half: a SET override that fails the test
  # resolves to EMPTY on purpose. Someone who named a binary meant THAT binary, and
  # quietly driving a different one is worse than not launching at all.
  local pathdir="$BATS_TEST_TMPDIR/rb-dir/bin" dir="$BATS_TEST_TMPDIR/rb-dir/adir"
  local empty="$BATS_TEST_TMPDIR/rb-dir/empty"
  mkbin "$pathdir/tool"
  mkdir -p "$dir" "$empty"
  RB_PATH="$pathdir" RB_BIN_PATHS="$empty"

  run_resolve_bin tool "$dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]                    # the directory was rejected…
  [ "$output" != "$pathdir/tool" ]    # …and did not silently become the PATH stub
}

@test "resolve_bin: an override pointing at a nonexistent path is empty (R15)" {
  local pathdir="$BATS_TEST_TMPDIR/rb-missing/bin" empty="$BATS_TEST_TMPDIR/rb-missing/empty"
  mkbin "$pathdir/tool"
  mkdir -p "$empty"
  RB_PATH="$pathdir" RB_BIN_PATHS="$empty"

  run_resolve_bin tool "$BATS_TEST_TMPDIR/rb-missing/nope/tool"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_bin: an override pointing at a non-executable regular file is empty (R15)" {
  local pathdir="$BATS_TEST_TMPDIR/rb-noexec/bin" empty="$BATS_TEST_TMPDIR/rb-noexec/empty"
  local plain="$BATS_TEST_TMPDIR/rb-noexec/plain-file"
  mkbin "$pathdir/tool"
  mkdir -p "$empty"
  printf 'not a program\n' > "$plain"
  chmod 644 "$plain"
  RB_PATH="$pathdir" RB_BIN_PATHS="$empty"

  run_resolve_bin tool "$plain"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_bin_rejected: names the thrown-out override for each rejection shape, and nothing on success (R15)" {
  # This is what lets the ⚠ say "CMUX_BIN is set to '…'" instead of telling someone to
  # set a variable they already set — so all three rejection shapes must report, and a
  # successful resolution must report nothing.
  local base="$BATS_TEST_TMPDIR/rb-rej"
  local pathdir="$base/bin" dir="$base/adir" empty="$base/empty" plain="$base/plain-file"
  mkbin "$pathdir/tool"
  mkdir -p "$dir" "$empty"
  printf 'not a program\n' > "$plain"
  chmod 644 "$plain"
  RB_PATH="$pathdir" RB_BIN_PATHS="$empty"

  run_resolve_bin_rejected tool "$dir"
  [ "$output" = "$dir" ]

  run_resolve_bin_rejected tool "$base/nope/tool"
  [ "$output" = "$base/nope/tool" ]

  run_resolve_bin_rejected tool "$plain"
  [ "$output" = "$plain" ]

  # resolved via the override -> nothing was rejected
  run_resolve_bin_rejected tool "$pathdir/tool"
  [ -z "$output" ]

  # resolved via PATH with no override at all -> likewise nothing
  run_resolve_bin_rejected tool ""
  [ -z "$output" ]
}

@test "resolve_bin: a full path passed as an extra candidate resolves last (R3)" {
  # The non-PATH installs: the cmux app bundle and /usr/bin/osascript.
  local extra="$BATS_TEST_TMPDIR/rb-extra/App.app/Contents/Resources/bin/tool"
  local empty="$BATS_TEST_TMPDIR/rb-extra/empty"
  mkbin "$extra"
  mkdir -p "$empty"
  RB_PATH="$empty" RB_BIN_PATHS="$empty"

  run_resolve_bin tool "" "$extra"
  [ "$status" -eq 0 ]
  [ "$output" = "$extra" ]
}

@test "resolve_bin: a RELATIVE override resolves to an ABSOLUTE path (R1)" {
  # Resolution runs BEFORE the `--repo` cd, so a relative result silently stops
  # resolving the moment the cwd moves — abspath() is what prevents that.
  local dir="$BATS_TEST_TMPDIR/rb-rel" empty="$BATS_TEST_TMPDIR/rb-rel/empty"
  mkbin "$dir/tool"
  mkdir -p "$empty"
  # abspath() PREFIXES `pwd -P` — it does not normalize, so "./tool" comes back as
  # "<physical-cwd>/./tool". That is fine and is what the test asserts: the leading
  # slash (the property that survives a cd) plus the same file on disk. `pwd -P` also
  # means the prefix is symlink-resolved, and $BATS_TEST_TMPDIR sits under
  # /var -> /private/var on macOS, so the physical dir is what to compare against.
  local dirp
  dirp="$(cd "$dir" && pwd -P)"

  run env SPINOFF_TEST_SOURCE=1 SPINOFF_BIN_PATHS="$empty" \
      bash -c 'cd "$3"; PATH="$4"; source "$1"; resolve_bin tool "$2"' \
      _ "$SCRIPT" ./tool "$dir" "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]                 # absolute, not "./tool"
  [[ "$output" == "$dirp"/* ]]          # anchored at the physical cwd
  [ "$output" -ef "$dir/tool" ]         # and still the same file on disk
}

@test "resolve_bin: resolution does not depend on \$PATH for its own internals (R1)" {
  # U1's first draft split $SPINOFF_BIN_PATHS with `tr`, and under a scrubbed PATH it
  # died with "tr: command not found" and resolved nothing — the exact failure the
  # resolver exists to prevent, one level down. The split is now pure parameter
  # expansion, and this is what stops that regression coming back.
  local known="$BATS_TEST_TMPDIR/rb-nopath/known"
  mkbin "$known/tool"
  RB_PATH="" RB_BIN_PATHS="$known"

  run_resolve_bin tool ""
  [ "$status" -eq 0 ]
  [ "$output" = "$known/tool" ]
}


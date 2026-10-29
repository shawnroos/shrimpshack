#!/usr/bin/env bats
#
# Tests for spinoff.sh's REX backend. REX is never installed for these: `rex` is a stub
# on a per-test PATH that logs its argv to $REX_ARGV_LOG and prints the JSON shapes the
# real CLI printed in the live probes recorded in the REX plan.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/spinoff.sh"
  STUBDIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBDIR"
  REX_ARGV_LOG="$BATS_TEST_TMPDIR/rex-argv.log"
  : > "$REX_ARGV_LOG"

  cat > "$STUBDIR/rex" <<'STUB'
#!/usr/bin/env bash
[ -n "${REX_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$REX_ARGV_LOG"
# drop the global flag every rexc call carries
[ "$1" = "--autostart=false" ] && shift
case "$1 $2" in
  "whoami --json")
    if [ "${REX_STUB_WHOAMI_FAIL:-0}" = 1 ]; then echo "connection refused" >&2; exit 1; fi
    if [ "${REX_STUB_IMPOSTOR:-0}" = 1 ]; then echo "Rex 2.0 deployment tool"; exit 0; fi
    printf '{"account":"t","rex_version":"0.0.1-stub","session_count":1}\n' ;;
  "window new")
    [ "${REX_STUB_CREATE_FAIL:-0}" = 1 ] && { echo "Error: session target not found" >&2; exit 1; }
    printf '{"window_id":"window:w9","block_ids":["block:bTAB"],"revision":2}\n' ;;
  "block inspect")
    printf '{"session_id":"session:sFROMBLOCK","block":{"block_id":"%s"}}\n' "$3" ;;
  "client ls")
    if [ "${REX_STUB_NO_APP:-0}" = 1 ]; then printf '{"clients":[]}\n'
    else printf '{"clients":[{"client_id":"client:cAPP","info":{"kind":"app"}}]}\n'; fi ;;
  "capture -s"|"capture -b")
    case "${REX_STUB_SCREEN:-ready}" in
      ready)  printf '%s\n' '╭─────────╮' '  ? for shortcuts · shift+tab to cycle' ;;
      mcp)    printf '%s\n' '3 new MCP servers found in this project' 'Select any you wish to enable' ;;
      trustno) printf '%s\n' 'Do you trust the files in this folder?' '❯ 1. No, exit' '  2. Yes, I trust this folder' ;;
      trustyes) printf '%s\n' 'Do you trust the files in this folder?' '❯ 1. Yes, I trust this folder' '  2. No, exit' ;;
      shell)  printf '%s\n' '❯ ' ;;
    esac ;;
  "wait block:"*|"wait "*)
    if [ "${REX_STUB_CHILD_EXITED:-0}" = 1 ]; then
      printf '{"exit_code":1,"error":"exit status 1"}\n'; exit 1
    fi
    echo "Error: wait timed out after 1s: context deadline exceeded" >&2; exit 1 ;;
  *) : ;;
esac
case "$1" in
  split)
    [ "${REX_STUB_CREATE_FAIL:-0}" = 1 ] && { echo "Error: block not found" >&2; exit 1; }
    printf '{"anchor_id":"x","block_ids":["block:bSPLIT"],"split_ids":["split:p"]}\n' ;;
  new)
    printf '{"session_id":"session:sNEW","initial_windows":[{"window_id":"window:w1","block_ids":["block:bNEW"]}]}\n' ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/sleep"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/glow"
  cat > "$STUBDIR/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = status ] && [ "$2" = server ]; then
  printf '%s\n' "status: running" "version: 0.8.2"; exit 0
fi
exit 0
STUB
  chmod +x "$STUBDIR"/*
  REX_BIN_STUB="$STUBDIR/rex"
}

run_resolve() {
  SPINOFF_TEST_SOURCE=1 bash -c '
    source "$1"
    REX="$2"; HERDR="$3"; CMUX=""; GHOSTTY_APP="/x"; OSASCRIPT="/x"; LAUNCHER="$4"; FORCED_LAUNCHER="$4"
    resolve_launcher 2>/dev/null
    echo "$LAUNCHER"
  ' _ "$SCRIPT" "$REX_BIN_STUB" "${HERDR_STUB_BIN:-}" "${1:-auto}"
}

# Full run of the script on a throwaway repo, REX forced. Every other backend's
# announcement is scrubbed so the host terminal cannot decide the route.
run_rex() {
  local target="$1"; shift
  local repo="$BATS_TEST_TMPDIR/rrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  echo hi > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  RREPO="$(cd "$repo" && pwd -P)"
  printf '# Handoff\n\nbrief body\n' > "$repo/handoff.md"
  run env -u HERDR_ENV -u CMUX_WORKSPACE_ID -u TERM_PROGRAM -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_SURFACE_ID \
          PATH="${RPATH:-$STUBDIR:/usr/bin:/bin}" \
          SPINOFF_BIN_PATHS="$BATS_TEST_TMPDIR/emptybin" \
          REX_BIN="$REX_BIN_STUB" REX_SESSION=sENV REX_ARGV_LOG="$REX_ARGV_LOG" \
          SPINOFF_READY_TIMEOUT_MS=3000 \
          "$@" \
      bash "$SCRIPT" --name rtest --label "Test Label" --handoff "$repo/handoff.md" \
                     --repo "$repo" --target "$target" --launcher rex ${RARGS:-}
}

# ---- detection ---------------------------------------------------------------

@test "resolve: REX_SESSION + live rex -> rex, even with Ghostty identity present" {
  export REX_SESSION=sENV TERM_PROGRAM=ghostty GHOSTTY_SURFACE_ID=abc HERDR_ENV= CMUX_WORKSPACE_ID=
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = rex ]
}

@test "resolve: REX_SESSION + HERDR_ENV + live herdr -> herdr (existing precedence kept)" {
  export REX_SESSION=sENV HERDR_ENV=1 CMUX_WORKSPACE_ID=
  HERDR_STUB_BIN="$STUBDIR/herdr" run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = herdr ]
}

@test "resolve: live rex but no REX_SESSION -> not rex (no unannounced arm)" {
  export REX_SESSION= HERDR_ENV= CMUX_WORKSPACE_ID= TERM_PROGRAM= GHOSTTY_RESOURCES_DIR= GHOSTTY_SURFACE_ID=
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "resolve: REX_SESSION but rex whoami fails -> none, and never ghostty" {
  export REX_SESSION=sENV REX_STUB_WHOAMI_FAIL=1 TERM_PROGRAM=ghostty HERDR_ENV= CMUX_WORKSPACE_ID=
  run run_resolve auto
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "resolve: a different tool named rex (exit 0, no rex_version) is not live" {
  export REX_SESSION=sENV REX_STUB_IMPOSTOR=1 HERDR_ENV= CMUX_WORKSPACE_ID=
  run run_resolve auto
  [ "$output" = none ]
}

@test "resolve: --launcher rex with a dead probe falls back instead of erroring" {
  export REX_STUB_WHOAMI_FAIL=1 REX_SESSION= HERDR_ENV= CMUX_WORKSPACE_ID= TERM_PROGRAM= GHOSTTY_RESOURCES_DIR= GHOSTTY_SURFACE_ID=
  run run_resolve rex
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "probe: every rex call carries --autostart=false" {
  run_rex tab
  [ "$status" -eq 0 ]
  ! grep -qv -- '--autostart=false' "$REX_ARGV_LOG"
}

# ---- failure reporting -------------------------------------------------------

@test "loud: REX_SESSION set and rex unresolvable exits 4 and names REX_BIN" {
  RPATH="/usr/bin:/bin" run_rex tab REX_BIN=/nonexistent/rex REX_BIN_DIR=
  [ "$status" -eq 4 ]
  [[ "$output" == *"announced it (--launcher rex)"* ]]
  [[ "$output" == *"REX_BIN"* ]]
}

@test "loud: rex resolves but whoami fails exits 5 and quotes what rex said" {
  run_rex tab REX_STUB_WHOAMI_FAIL=1
  [ "$status" -eq 5 ]
  [[ "$output" == *"connection refused"* ]]
  [[ "$output" == *"never starts the REX server"* ]]
}

# ---- launch shapes -----------------------------------------------------------

@test "tab: opens a labelled tab in REX_SESSION, rooted at the worktree, running the brief" {
  run_rex tab
  [ "$status" -eq 0 ]
  grep -qE '^--autostart=false window new -s sENV Test Label -c .*/worktrees/rtest --keep-open --focus=false --json -- sh -c cd .* && claude' "$REX_ARGV_LOG"
  [[ "$output" == *"rex tab:"* ]]
  [[ "$output" == *"open + briefed"* ]]
}

@test "split right: splits the --from-surface block, unfocused, in that block's own session" {
  RARGS="--from-surface block:bFROM --split-direction right" run_rex split
  [ "$status" -eq 0 ]
  grep -qE '^--autostart=false block inspect block:bFROM --json' "$REX_ARGV_LOG"
  grep -qE 'split -s session:sFROMBLOCK -b block:bFROM --split=right --label Test Label .* --focus=false' "$REX_ARGV_LOG"
}

@test "split left: uses the native --split=left, with no swap step" {
  RARGS="--from-surface block:bFROM --split-direction left" run_rex split
  [ "$status" -eq 0 ]
  grep -q -- '--split=left' "$REX_ARGV_LOG"
  ! grep -q 'swap' "$REX_ARGV_LOG"
}

@test "split with no --from-surface: downgrades to a tab and says so" {
  run_rex split
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT what was asked for"* ]]
  grep -q 'window new' "$REX_ARGV_LOG"
}

@test "workspace: creates a session, shows it in the app, opens a right-hand viewer" {
  run_rex workspace
  [ "$status" -eq 0 ]
  grep -qE 'new Test Label --window Test Label -c .*/worktrees/rtest --keep-open --json -- sh -c' "$REX_ARGV_LOG"
  grep -q -- '-C client:cAPP do session.select session_id=session:sNEW' "$REX_ARGV_LOG"
  grep -qE 'split -s session:sNEW -b block:bNEW --split=right --label Handoff' "$REX_ARGV_LOG"
  [[ "$output" == *"handoff viewer alongside"* ]]
}

@test "workspace: no app client connected is a visible note, not a failure" {
  run_rex workspace REX_STUB_NO_APP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not shown"* ]]
}

@test "viewer: no glow or bat means a warning and no viewer, launch still succeeds" {
  mkdir -p "$BATS_TEST_TMPDIR/nostubs"
  cp "$STUBDIR/rex" "$STUBDIR/claude" "$STUBDIR/sleep" "$BATS_TEST_TMPDIR/nostubs/"
  RPATH="$BATS_TEST_TMPDIR/nostubs:/usr/bin:/bin" REX_BIN_STUB="$BATS_TEST_TMPDIR/nostubs/rex" run_rex workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"no markdown pager"* ]]
  [[ "$output" != *"handoff viewer alongside"* ]]
}

@test "launch failure: a rex window-new error exits 3 and prints the error" {
  run_rex tab REX_STUB_CREATE_FAIL=1
  [ "$status" -eq 3 ]
  [[ "$output" == *"session target not found"* ]]
  [[ "$output" == *"NOT BRIEFED"* ]]
}

@test "launch failure: REX_SESSION unset and no --from-surface exits 3 without calling rex create" {
  run_rex tab REX_SESSION=
  [ "$status" -eq 3 ]
  ! grep -q 'window new' "$REX_ARGV_LOG"
}

# ---- readiness ---------------------------------------------------------------

@test "ready: the claude footer on the first capture is ready, nothing is sent" {
  run_rex tab
  [ "$status" -eq 0 ]
  ! grep -q 'send-key' "$REX_ARGV_LOG"
}

@test "ready: the MCP modal is answered with enter" {
  run_rex tab REX_STUB_SCREEN=mcp SPINOFF_READY_TIMEOUT_MS=1000
  grep -qE 'send-key -s sENV -b block:bTAB enter' "$REX_ARGV_LOG"
  [[ "$output" == *"MCP trust modal: accepted"* ]]
}

@test "ready: SPINOFF_MCP_MODAL=reject sends escape" {
  run_rex tab REX_STUB_SCREEN=mcp SPINOFF_MCP_MODAL=reject SPINOFF_READY_TIMEOUT_MS=1000
  grep -qE 'send-key .* escape' "$REX_ARGV_LOG"
}

@test "ready: SPINOFF_MCP_MODAL=abort sends nothing" {
  run_rex tab REX_STUB_SCREEN=mcp SPINOFF_MCP_MODAL=abort SPINOFF_READY_TIMEOUT_MS=1000
  ! grep -q 'send-key' "$REX_ARGV_LOG"
}

@test "ready: folder-trust with the cursor on 'No, exit' sends down+enter, never a bare enter" {
  run_rex tab REX_STUB_SCREEN=trustno SPINOFF_READY_TIMEOUT_MS=1000
  grep -qE 'send-key .* down enter' "$REX_ARGV_LOG"
  ! grep -qE 'send-key .* -b block:bTAB enter$' "$REX_ARGV_LOG"
}

@test "ready: folder-trust with the cursor on 'Yes' sends enter" {
  run_rex tab REX_STUB_SCREEN=trustyes SPINOFF_READY_TIMEOUT_MS=1000
  grep -qE 'send-key .* enter$' "$REX_ARGV_LOG"
}

@test "ready: a never-ready screen is a warning, not a failure, while claude is still running" {
  run_rex tab REX_STUB_SCREEN=shell SPINOFF_READY_TIMEOUT_MS=1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"a dialog may still be up"* ]]
}

@test "gone: not ready and rex reports the block's child exited -> exit 3" {
  run_rex tab REX_STUB_SCREEN=shell REX_STUB_CHILD_EXITED=1 SPINOFF_READY_TIMEOUT_MS=1000
  [ "$status" -eq 3 ]
  [[ "$output" == *"claude is not running in block:bTAB"* ]]
}

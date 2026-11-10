#!/usr/bin/env bash
# Every session auto launches must reach claude with --settings '{"remoteControlAtStartup":false}'
# as two exact argv entries. Each case runs the real launch string through sh against a fake
# claude and reads back its argv, so the check covers the shell quoting, not only the text.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
SOCKET="$ROOT/lib/cmux-socket.sh"
WS="$ROOT/lib/auto-workspace.py"
SPAWN="$ROOT/lib/auto-spawn.py"
WANT='{"remoteControlAtStartup":false}'

SANDBOX="$(mktemp -d -t rc-off.XXXXXX)"
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
export HOME="$SANDBOX"
trap 'export HOME="$ORIG_HOME" PATH="$ORIG_PATH"; rm -rf "$SANDBOX"' EXIT

FAKE_BIN="$SANDBOX/fake"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$CLAUDE_ARGV_OUT"\n' > "$FAKE_BIN/claude"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/sleep"

# cmux stub: one argv entry per line, each call opened by a "--call--" line.
STUB_BIN="$SANDBOX/bin"
CMUX_LOG="$SANDBOX/cmux.log"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/cmux" <<EOF
#!/usr/bin/env bash
{ printf -- '--call--\n'; for a in "\$@"; do printf '%s\n' "\$a"; done; } >> "$CMUX_LOG"
case "\$1" in
  new-surface) echo "surface:stub-surface-id" ;;
  list-workspaces) echo "\${CLAUDE_AUTO_TEST_WS_LIST:-}" ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/cmux"
export PATH="$STUB_BIN:$PATH"

# $1 = a shell command string. Prints the argv the fake claude received, one per line.
launch_argv() {
  local out="$SANDBOX/claude-argv"
  rm -f "$out"
  CLAUDE_ARGV_OUT="$out" PATH="$FAKE_BIN:/usr/bin:/bin" sh -c "$1" >/dev/null 2>&1
  cat "$out" 2>/dev/null
}

# $1 = verb, $2 = argv entry that precedes the wanted one. Prints the entry after it in the
# first logged call of that verb.
logged_after() {
  awk -v verb="$1" -v key="$2" '
    /^--call--$/ { n = 0; inside = 0; next }
    { n++ }
    n == 1 { inside = ($0 == verb) }
    inside && grab { print; exit }
    inside && $0 == key { grab = 1 }
  ' "$CMUX_LOG"
}

make_host_repo() {
  local repo; repo="$(mktemp -d "$SANDBOX/host.XXXXXX")"
  (
    cd "$repo"
    git init -q
    git config user.email t@t
    git config user.name t
    printf '.claude/\nworktrees/\n' > .gitignore
    mkdir -p docs/plans
    printf '# p1\n' > docs/plans/p1.md
    git add .gitignore docs
    git -c commit.gpgsign=false commit -q -m init
  )
  echo "$repo"
}

auto_test::it "bash and Python copies of the settings JSON are the same exact value"
bash_val="$(bash -c '. "$1"; printf "%s" "$AUTO_CLAUDE_SETTINGS"' _ "$SOCKET")"
py_val="$("$PY" - "$WS" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("auto_workspace", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.CLAUDE_LAUNCH_SETTINGS, end="")
PYEOF
)"
auto_test::assert_eq "$WANT|$WANT" "$bash_val|$py_val"

auto_test::it "auto-resume workspace command reaches claude with Remote Control off"
cmd="$(bash -c '. "$1"; auto::resume_command r1' _ "$SOCKET")"
auto_test::assert_eq "$(printf '%s\n' --settings "$WANT" '/auto:auto-resume r1')" "$(launch_argv "$cmd")"

auto_test::it "project workspace's claude pane reaches claude with Remote Control off"
R1="$(make_host_repo)"
: > "$CMUX_LOG"
"$PY" "$WS" create "$R1" >/dev/null 2>&1
layout="$(logged_after new-workspace --layout)"
cmd="$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["children"][0]["pane"]["surfaces"][0]["command"])' "$layout" 2>/dev/null)"
auto_test::assert_eq "$(printf '%s\n' --settings "$WANT")" "$(launch_argv "$cmd")"

auto_test::it "fanout in workspace mode reaches claude with Remote Control off"
R2="$(make_host_repo)"
: > "$CMUX_LOG"
unset CMUX_WORKSPACE_ID
(cd "$R2" && "$PY" "$SPAWN" fanout docs/plans/p1.md >/dev/null 2>&1)
cmd="$(logged_after new-workspace --command)"
auto_test::assert_eq "$(printf '%s\n' --settings "$WANT" '/auto:auto docs/plans/p1.md')" "$(launch_argv "$cmd")"

auto_test::it "fanout in tab mode reaches claude with Remote Control off"
R3="$(make_host_repo)"
mkdir -p "$R3/.claude/auto"
printf '{"workspace_id":"workspace:proj-rc","left_pane_id":"pane:left-1","created_at":"2026-05-27T00:00:00Z"}\n' \
  > "$R3/.claude/auto/workspace.json"
: > "$CMUX_LOG"
(cd "$R3" && CMUX_WORKSPACE_ID=workspace:proj-rc CLAUDE_AUTO_TEST_WS_LIST=workspace:proj-rc \
   "$PY" "$SPAWN" fanout docs/plans/p1.md >/dev/null 2>&1)
cmd="$(logged_after send surface:stub-surface-id)"
auto_test::assert_eq "$(printf '%s\n' --settings "$WANT" '/auto:auto docs/plans/p1.md')" "$(launch_argv "$cmd")"

auto_test::summary

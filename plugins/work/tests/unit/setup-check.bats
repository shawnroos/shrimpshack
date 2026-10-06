#!/usr/bin/env bats

load setup_common

# bin/setup-check.sh reports every prerequisite of the work plugin as one JSON
# object. Every external command it runs is a fake here: board answers from a
# directory of per-verb files, herdr and security are the shared fixtures, and
# claude is a stub written below. HOME is a fresh directory per test, so the
# "writes nothing" claim is checked against a HOME nothing else touches; every
# fixture keeps its own records outside it.

bats_require_minimum_version 1.5.0

KEYS="git cargo python3 herdr path board daemon herdr_plugin board_mcp duplicate_hook import linear_key in_herdr space_binding worktree_binding"
INSTALL='herdr plugin install shawnroos/herdr-linear-board --ref v0.18.0 --yes'

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    SCRIPT="$ROOT/bin/setup-check.sh"
    ROOT_ABS="$(cd "$ROOT" && pwd -P)"
    SB="$BATS_TEST_TMPDIR/sc"
    WORK="$SB/work"
    ANS="$WORK/answers"
    export HOME="$SB/home"
    mkdir -p "$HOME" "$WORK/bin" "$WORK/rec" "$WORK/project" "$ANS"

    ln -s "$(command -v python3)" "$WORK/bin/python3"
    ln -s "$(command -v git)" "$WORK/bin/git"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/cargo"
    cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"
if [ "${FAKE_CLAUDE_MCP:-present}" = present ] && [ "$*" = "mcp get board" ]; then
    printf 'board:\n  Status: connected\n'
    exit 0
fi
printf 'No MCP server named "board".\n'
exit 1
SH
    chmod +x "$WORK/bin/cargo" "$WORK/bin/claude"

    export HERDR_LINEAR_CLAUDE_BIN="$WORK/bin/claude"
    export FAKE_CLAUDE_LOG="$WORK/rec/claude.log"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_RECORD_DIR="$WORK/rec/herdr"
    export FAKE_HERDR_VERSION=0.9.3
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/keychain"
    export FAKE_SECURITY_RECORD_DIR="$WORK/rec/security"
    export FAKE_BOARD_RESPONSE_DIR="$ANS"
    export FAKE_BOARD_LOG="$WORK/rec/board.log"
    export CLAUDE_PROJECT_DIR="$WORK/project"
    TPATH="$HOME/.local/bin:$WORK/bin:/usr/bin:/bin"
    cd "$WORK/project" || return 1
}

# Runs the script, which must exit 0 and print one JSON object holding every
# check. An empty or partial answer fails here, so no test below can pass
# against a script that printed nothing.
check() {
    run -0 --separate-stderr env PATH="$TPATH" bash "$SCRIPT"
    printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
missing = [k for k in sys.argv[1:] if k not in d]
assert not missing, "missing checks: %s" % missing
for k, v in d.items():
    assert v["state"] in ("ok", "missing", "old", "unknown", "needs_import"), (k, v)
    assert v["fix_kind"] in ("command", "instruction", None), (k, v)
    assert isinstance(v["detail"], str) and v["detail"], (k, v)
    assert (v["fix"] is None) == (v["fix_kind"] is None), (k, v)
' $KEYS
}

# field <check> <key>: one value from the last check, `null` for JSON null.
field() {
    printf '%s' "$output" | python3 -c '
import json, sys
v = json.load(sys.stdin)[sys.argv[1]][sys.argv[2]]
print("null" if v is None else v)' "$1" "$2"
}

answer() { printf '%s\n' "$2" > "$ANS/$1"; }

# one_token <command> <word>: the shell splits the command into words, and
# <word> is exactly one of them.
one_token() {
    python3 -c '
import shlex, sys
words = shlex.split(sys.argv[1])
assert sys.argv[2] in words, words' "$1" "$2"
}

versions() { answer version "{\"cli_version\":\"$1\",\"daemon_version\":${2:-null}}"; }

managed_board() {
    mkdir -p "$HOME/.local/bin"
    cp "$FIX/fake-board.sh" "$HOME/.local/bin/board"
    printf 'herdr-board install-cli.sh managed board sha256:00\n' > "$HOME/.local/bin/.herdr-board-cli-managed"
    versions "$1" "\"$1\""
}

# A development checkout whose build ~/.local/bin/board points into.
symlinked_board() {
    CHK="${2:-$SB/checkout}"
    mkdir -p "$CHK/target/release" "$HOME/.local/bin"
    printf 'id = "herdr-board"\n' > "$CHK/herdr-plugin.toml"
    cp "$FIX/fake-board.sh" "$CHK/target/release/board"
    ln -s "$CHK/target/release/board" "$HOME/.local/bin/board"
    CHK="$(cd "$CHK" && pwd -P)"
    versions "$1" "\"$1\""
}

store_key() {
    printf 'k\nk\n' | "$FIX/fake-security.sh" add-generic-password -a linear-api-key -s work-linear -w >/dev/null
}

in_herdr() { export HERDR_WORKSPACE_ID=w1 HERDR_PANE_ID=w1:p1; }

healthy() {
    managed_board 0.18.0
    export FAKE_HERDR_PLUGINS="herdr-board=$SB/plugin"
    store_key
    answer linear_project_list '{"status":"ok","message":null,"rows":[]}'
    answer import_work-store '{"store_dir":"/x","present":false,"dry_run":true,"imported":[],"skipped":[],"ignored":[]}'
    answer linear_session '{"space":"w1","space_bound":true,"binding":{"worktree_path":"/w","issue":"ABC-1"},"column":null,"marks":[],"pending_requests":0}'
    in_herdr
}

# A recursive listing of HOME with sizes and modification times.
home_listing() {
    python3 -c '
import os, sys
for d, dirs, files in os.walk(sys.argv[1]):
    for n in sorted(dirs + files):
        p = os.path.join(d, n)
        st = os.lstat(p)
        print(p, st.st_size, st.st_mtime_ns)' "$HOME" | sort
}

@test "a fresh machine reports the board, plugin, daemon and mcp missing, and offers the fork install" {
    export FAKE_CLAUDE_MCP=absent
    check
    for k in board herdr_plugin daemon board_mcp; do
        [ "$(field "$k" state)" = missing ] || { echo "$k: $(field "$k" state)"; return 1; }
    done
    [ "$(field board fix)" = "$INSTALL" ]
    [ "$(field board fix_kind)" = command ]
    [ "$(field board_mcp fix)" = "claude mcp add --scope user board -- board mcp" ]
    [ "$(field linear_key state)" = unknown ]
    [[ "$(field linear_key detail)" == *"start the daemon first"* ]]
}

@test "a managed board older than 0.18.0 is old, with the fork install" {
    managed_board 0.17.0
    check
    [ "$(field board state)" = old ]
    [ "$(field board fix)" = "$INSTALL" ]
}

@test "a managed board that is new enough with no herdr plugin offers the fork install on the plugin entry" {
    managed_board 0.18.0
    check
    [ "$(field board state)" = ok ]
    [ "$(field herdr_plugin state)" = missing ]
    [ "$(field herdr_plugin fix)" = "$INSTALL" ]
}

@test "a new enough board symlinked into a checkout is linked, not reinstalled" {
    symlinked_board 0.18.0
    check
    [ "$(field board state)" = ok ]
    [ "$(field herdr_plugin state)" = missing ]
    [ "$(field herdr_plugin fix)" = "herdr plugin link $CHK" ]
    [ "$(field herdr_plugin fix_kind)" = command ]
}

@test "an old board symlinked into a checkout is rebuilt at the tag, never installed over" {
    symlinked_board 0.17.0
    check
    [ "$(field board state)" = old ]
    fix="$(field board fix)"
    [ "$fix" = "git -C $CHK fetch --tags && git -C $CHK checkout v0.18.0 && cargo build --release -p board-cli --manifest-path $CHK/Cargo.toml" ]
    [[ "$fix" != *"plugin install"* ]]
    [[ "$(field board detail)" == *"move it aside"* ]]
}

@test "an unmanaged board that is not a symlink is left to the person to move aside" {
    mkdir -p "$HOME/.local/bin"
    cp "$FIX/fake-board.sh" "$HOME/.local/bin/board"
    versions 0.18.0 '"0.18.0"'
    check
    [ "$(field herdr_plugin state)" = missing ]
    [ "$(field herdr_plugin fix_kind)" = instruction ]
    [[ "$(field herdr_plugin fix)" == "Move "*" aside"* ]]
}

@test "herdr 0.8 is old, and no board install is offered" {
    export FAKE_HERDR_VERSION=0.8.2
    check
    [ "$(field herdr state)" = old ]
    [ "$(field board state)" = missing ]
    [ "$(field board fix)" = null ]
    [ "$(field herdr_plugin fix)" = null ]
}

@test "herdr on protocol 21 is old, and no board install is offered" {
    export FAKE_HERDR_PROTOCOL=21
    check
    [ "$(field herdr state)" = old ]
    [ "$(field board fix)" = null ]
}

@test "a board linear report hook in settings is a duplicate, fixed by an instruction" {
    healthy
    mkdir -p "$HOME/.claude"
    printf '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"board linear report"}]}]}}\n' \
        > "$HOME/.claude/settings.json"
    check
    [ "$(field duplicate_hook state)" = missing ]
    [ "$(field duplicate_hook fix_kind)" = instruction ]
    [[ "$(field duplicate_hook fix)" == *"$HOME/.claude/settings.json"* ]]
    [[ "$(field duplicate_hook fix)" == *Remove* ]]
}

@test "a hook in the project's local settings is found too" {
    healthy
    mkdir -p "$WORK/project/.claude"
    printf '{"hooks":{"x":"board linear report"}}\n' > "$WORK/project/.claude/settings.local.json"
    check
    [ "$(field duplicate_hook state)" = missing ]
    [[ "$(field duplicate_hook fix)" == *"$WORK/project/.claude/settings.local.json"* ]]
}

@test "an old store with nothing on the board yet needs importing" {
    healthy
    answer import_work-store '{"store_dir":"/x","present":true,"dry_run":true,"imported":[{"kind":"space_binding","key":"w1","source":"a","dropped":[]},{"kind":"grouping","key":"g","source":"b","dropped":[]}],"skipped":[],"ignored":[]}'
    check
    [ "$(field import state)" = needs_import ]
    [[ "$(field import detail)" == *docs/cutover.md* ]]
}

@test "a completed cut-over is ok, naming the old rows that would still import" {
    healthy
    answer import_work-store '{"store_dir":"/x","present":true,"dry_run":true,"imported":[{"kind":"worktree_binding","key":"/a","source":"a","dropped":[]},{"kind":"worktree_binding","key":"/b","source":"b","dropped":[]},{"kind":"worktree_binding","key":"/c","source":"c","dropped":[]}],"skipped":[{"kind":"grouping","key":"global","source":"board.json","reason":"already in the board; the import never overwrites a row"},{"kind":"space_binding","key":"w1","source":"s","reason":"already in the board; the import never overwrites a row","dropped":[]}],"ignored":[]}'
    check
    [ "$(field import state)" = ok ]
    [[ "$(field import detail)" == *3* ]]
    [[ "$(field import detail)" == *docs/cutover.md* ]]
}

# The import writes board.json's global grouping and nothing else does, so one
# row someone bound by hand before importing is not a finished cut-over.
@test "one row already in the board without the import's marker still needs importing" {
    healthy
    answer import_work-store '{"store_dir":"/x","present":true,"dry_run":true,"imported":[{"kind":"grouping","key":"global","source":"board.json","dropped":[]},{"kind":"worktree_binding","key":"/a","source":"a","dropped":[]}],"skipped":[{"kind":"space_binding","key":"w1","source":"s","reason":"already in the board; the import never overwrites a row","dropped":[]}],"ignored":[]}'
    check
    [ "$(field import state)" = needs_import ]
}

@test "an old store with no board.json falls back to any row already in the board" {
    healthy
    answer import_work-store '{"store_dir":"/x","present":true,"dry_run":true,"imported":[{"kind":"worktree_binding","key":"/a","source":"a","dropped":[]}],"skipped":[{"kind":"space_binding","key":"w1","source":"s","reason":"already in the board; the import never overwrites a row","dropped":[]}],"ignored":[]}'
    check
    [ "$(field import state)" = ok ]
    [[ "$(field import detail)" == *board.json* ]]
}

@test "with the daemon down the import and key probes are never run" {
    healthy
    versions 0.18.0 null
    check
    [ "$(field daemon state)" = missing ]
    [ "$(field daemon fix)" = "$HOME/.local/bin/board daemon status" ]
    for k in import linear_key space_binding worktree_binding; do
        [ "$(field "$k" state)" = unknown ] || { echo "$k: $(field "$k" state)"; return 1; }
        [[ "$(field "$k" detail)" == *"start the daemon first"* ]]
    done
    run ! grep -E 'argv: (import|linear project)' "$FAKE_BOARD_LOG"
}

@test "a daemon on another version than the CLI is old" {
    healthy
    versions 0.18.0 '"0.17.0"'
    check
    [ "$(field daemon state)" = old ]
    [ "$(field daemon fix)" = "$HOME/.local/bin/board daemon stop && $HOME/.local/bin/board daemon status" ]
}

@test "a key the board refuses is missing, with the store fix" {
    healthy
    answer linear_project_list '{"status":"unavailable","message":"Linear refused the API key","rows":[]}'
    check
    [ "$(field linear_key state)" = missing ]
    [[ "$(field linear_key detail)" == *"Linear refused the API key"* ]]
    [[ "$(field linear_key fix)" == *"migrate-credential.sh store" ]]
}

@test "a Linear that does not answer leaves the key unknown, never missing" {
    healthy
    for msg in "Linear is unavailable: timeout" "Linear rate limited the request"; do
        answer linear_project_list "{\"status\":\"unavailable\",\"message\":\"$msg\",\"rows\":[]}"
        check
        [ "$(field linear_key state)" = unknown ] || { echo "$msg: $(field linear_key state)"; return 1; }
        [ "$(field linear_key fix)" = null ]
        [[ "$(field linear_key detail)" == "The board could not reach Linear: $msg" ]]
    done
}

@test "a key the board accepts with no Keychain item is ok, with advice to move it" {
    healthy
    rm -rf "$FAKE_SECURITY_STORE_DIR"
    check
    [ "$(field linear_key state)" = ok ]
    [ "$(field linear_key fix)" = null ]
    [ "$(field linear_key fix_kind)" = null ]
    [[ "$(field linear_key detail)" == *"the board is using a fallback key; \`bash $ROOT_ABS/bin/migrate-credential.sh store\` moves it to the Keychain"* ]]
}

@test "a key the board refuses with no Keychain item is missing, with the store fix" {
    healthy
    rm -rf "$FAKE_SECURITY_STORE_DIR"
    answer linear_project_list '{"status":"unavailable","message":"no Linear API key: none in the keychain, LINEAR_API_KEY or ~/.secrets","rows":[]}'
    check
    [ "$(field linear_key state)" = missing ]
    [ "$(field linear_key fix)" = "bash $ROOT_ABS/bin/migrate-credential.sh store" ]
    [ "$(field linear_key fix_kind)" = command ]
}

@test "with the daemon down and no Keychain item the key is unknown and the board is not asked" {
    healthy
    rm -rf "$FAKE_SECURITY_STORE_DIR"
    versions 0.18.0 null
    check
    [ "$(field linear_key state)" = unknown ]
    [[ "$(field linear_key detail)" == *"start the daemon first"* ]]
    run ! grep -E 'argv: linear project' "$FAKE_BOARD_LOG"
}

@test "outside herdr both bindings are unknown and say to run in herdr" {
    healthy
    unset HERDR_WORKSPACE_ID HERDR_PANE_ID
    check
    [ "$(field in_herdr state)" = missing ]
    for k in space_binding worktree_binding; do
        [ "$(field "$k" state)" = unknown ]
        [[ "$(field "$k" detail)" == *"run in herdr"* ]]
    done
}

@test "an unbound space is missing, and the worktree waits for it" {
    healthy
    answer linear_session '{"space":"w1","space_bound":false,"binding":null,"column":null,"marks":[],"pending_requests":0}'
    check
    [ "$(field space_binding state)" = missing ]
    [ "$(field worktree_binding state)" = unknown ]
}

@test "a bound space with an unbound worktree reports the worktree missing" {
    healthy
    answer linear_session '{"space":"w1","space_bound":true,"binding":null,"column":null,"marks":[],"pending_requests":0}'
    check
    [ "$(field space_binding state)" = ok ]
    [ "$(field worktree_binding state)" = missing ]
}

@test "a healthy machine is all ok, and a second run answers the same" {
    healthy
    check
    first="$output"
    printf '%s' "$output" | python3 -c '
import json, sys
bad = {k: v for k, v in json.load(sys.stdin).items() if v["state"] != "ok"}
assert not bad, bad'
    [ "$(field path state)" = ok ]
    check
    [ "$output" = "$first" ]
}

@test "the script writes nothing under HOME" {
    healthy
    mkdir -p "$HOME/.claude"
    printf '{"hooks":{"x":"board linear report"}}\n' > "$HOME/.claude/settings.json"
    before="$(home_listing)"
    [ -n "$before" ]
    check
    [ "$(field duplicate_hook state)" = missing ]
    [ "$(home_listing)" = "$before" ]
}

@test "without python3 it still exits 0 and reports python3 missing, with every check" {
    mkdir -p "$WORK/nopy"
    run -0 --separate-stderr env PATH="$WORK/nopy" "$BASH" "$SCRIPT"
    printf '%s' "$output" | /usr/bin/env PATH="$WORK/bin" python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["python3"]["state"] == "missing", d
assert sorted(d) == sorted(sys.argv[1:]), sorted(set(d) ^ set(sys.argv[1:]))' $KEYS
}

@test "a checkout path with a space stays one word in every fix that names it" {
    symlinked_board 0.17.0 "$SB/my checkout"
    check
    fix="$(field board fix)"
    one_token "$fix" "$CHK"
    one_token "$fix" "$CHK/Cargo.toml"
    versions 0.18.0 '"0.18.0"'
    check
    one_token "$(field herdr_plugin fix)" "$CHK"
    [ "$(field herdr_plugin fix)" = "herdr plugin link '$CHK'" ]
}

@test "a plugin path with a space stays one word in the key store fix" {
    healthy
    answer linear_project_list '{"status":"unavailable","message":"Linear refused the API key","rows":[]}'
    mkdir -p "$SB/my plugin/bin"
    cp "$SCRIPT" "$SB/my plugin/bin/setup-check.sh"
    SCRIPT="$SB/my plugin/bin/setup-check.sh"
    check
    plugin="$(cd "$SB/my plugin" && pwd -P)"
    one_token "$(field linear_key fix)" "$plugin/bin/migrate-credential.sh"
}

@test "a board path with a space stays one word in the move-aside instruction" {
    mkdir -p "$SB/odd home/.local/bin"
    export HOME="$SB/odd home"
    cp "$FIX/fake-board.sh" "$HOME/.local/bin/board"
    versions 0.17.0 '"0.17.0"'
    TPATH="$HOME/.local/bin:$WORK/bin:/usr/bin:/bin"
    check
    [[ "$(field board fix)" == *"mv '$HOME/.local/bin/board' '$HOME/.local/bin/board.old'"* ]]
}

# The path fix needs a new shell, which this session never gets, so every fix
# run in it has to name the board it found.
@test "a board found only in ~/.local/bin is named by its path in the fixes, and path is missing" {
    managed_board 0.18.0
    versions 0.18.0 null
    export FAKE_CLAUDE_MCP=absent
    TPATH="$WORK/bin:/usr/bin:/bin"
    check
    [ "$(field path state)" = missing ]
    [ "$(field path fix_kind)" = instruction ]
    [[ "$(field path fix)" == *'export PATH="$HOME/.local/bin:$PATH"'* ]]
    [ "$(field daemon fix)" = "$HOME/.local/bin/board daemon status" ]
    [ "$(field board_mcp fix)" = "claude mcp add --scope user board -- $HOME/.local/bin/board mcp" ]
    versions 0.18.0 '"0.17.0"'
    check
    [ "$(field daemon fix)" = "$HOME/.local/bin/board daemon stop && $HOME/.local/bin/board daemon status" ]
}

@test "a board on PATH registers as the bare name" {
    managed_board 0.18.0
    export FAKE_CLAUDE_MCP=absent
    check
    [ "$(field path state)" = ok ]
    [ "$(field board_mcp fix)" = "claude mcp add --scope user board -- board mcp" ]
}

@test "without cargo no board install is offered, and the detail says to fix cargo" {
    export HERDR_LINEAR_CARGO_BIN="$WORK/absent/cargo"
    check
    [ "$(field cargo state)" = missing ]
    [ "$(field board state)" = missing ]
    [ "$(field board fix)" = null ]
    [[ "$(field board detail)" == *"Fix cargo first"* ]]
}

@test "without git no board install is offered, and the detail says to fix git" {
    export HERDR_LINEAR_GIT_BIN="$WORK/absent/git"
    check
    [ "$(field git state)" = missing ]
    [ "$(field board fix)" = null ]
    [[ "$(field board detail)" == *"Fix git first"* ]]
}

# A wedged probe and the grandchild it started must both be ended: the
# grandchild holds the output pipe open. perl's alarm bounds this test, so a
# regression fails instead of hanging the suite.
@test "a claude probe that hangs, with a child of its own, is unknown and the check still returns" {
    healthy
    cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
sleep 60 &
sleep 60
SH
    export HERDR_LINEAR_SETUP_NETWORK_TIMEOUT_SECONDS=1
    start=$SECONDS
    run -0 --separate-stderr env PATH="$TPATH" perl -e 'alarm 20; exec @ARGV' bash "$SCRIPT"
    [ $((SECONDS - start)) -lt 8 ] || { echo "took $((SECONDS - start))s"; return 1; }
    [ "$(field board_mcp state)" = unknown ]
}

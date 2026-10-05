#!/usr/bin/env bats

load setup_common

# The report hook hands each Linear MCP write to `board linear report` (KTD2).
# It exits 0 on every path, so each test also checks what the fake board saw.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    HOOK="$ROOT/hooks/board-behind.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/bin" "$HERDR_LINEAR_PROJECTS_ROOT/wt" "$HERDR_LINEAR_STORE_DIR"
    ln -s "${BATS_TEST_DIRNAME}/../fixtures/fake-board.sh" "$WORK/bin/board"
    BASE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    export PATH="$WORK/bin:$BASE_PATH"
    export FAKE_BOARD_LOG="$WORK/board.log"
    INSIDE="$HERDR_LINEAR_PROJECTS_ROOT/wt"
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"mcp__linear__save_issue","tool_input":{"id":"WEB-1","title":"t"},"tool_response":{"identifier":"WEB-1"}}' \
        "$INSIDE" > "$WORK/payload.json"
}

calls() { grep -c '^argv: ' "$FAKE_BOARD_LOG" 2>/dev/null || printf '0\n'; }

@test "a save_issue payload reaches board linear report once, byte for byte" {
    run --separate-stderr bash "$HOOK" < "$WORK/payload.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(calls)" = "1" ]
    [ "$(grep '^argv: ' "$FAKE_BOARD_LOG")" = "argv: linear report" ]
    cmp "$WORK/payload.json" "$FAKE_BOARD_LOG.stdin"
}

@test "a payload larger than 64 KB passes every byte and exits 0" {
    python3 -c '
import json, sys
print(json.dumps({"session_id": "s1", "cwd": sys.argv[1], "hook_event_name": "PostToolUse",
    "tool_name": "mcp__linear__save_issue", "tool_input": {},
    "tool_response": {"description": "x" * 200000}}), end="")
' "$INSIDE" > "$WORK/big.json"
    [ "$(wc -c < "$WORK/big.json")" -gt 65536 ]
    run --separate-stderr bash "$HOOK" < "$WORK/big.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(calls)" = "1" ]
    cmp "$WORK/big.json" "$FAKE_BOARD_LOG.stdin"
}

@test "with board absent from PATH the hook exits 0 with no output at all" {
    export PATH="$BASE_PATH"
    run command -v board
    [ "$status" -ne 0 ]
    run --separate-stderr bash "$HOOK" < "$WORK/payload.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "an old board that exits 64 is called, and the hook still exits 0 silently" {
    export FAKE_BOARD_EXIT=64
    run --separate-stderr bash "$HOOK" < "$WORK/payload.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ "$(calls)" = "1" ]
}

@test "a board that prints is not heard on the hook's stdout" {
    printf 'noise\n' > "$WORK/noise"
    export FAKE_BOARD_RESPONSE="$WORK/noise"
    run --separate-stderr bash "$HOOK" < "$WORK/payload.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(calls)" = "1" ]
}

@test "the hook writes nothing under the plugin store" {
    printf 'keep\n' > "$HERDR_LINEAR_STORE_DIR/existing"
    before="$(cd "$HERDR_LINEAR_STORE_DIR" && find . | sort)"
    run --separate-stderr bash "$HOOK" < "$WORK/payload.json"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "1" ]
    after="$(cd "$HERDR_LINEAR_STORE_DIR" && find . | sort)"
    [ "$before" = "$after" ]
}

@test "the hook sources no library at all" {
    run grep -nE '^[[:space:]]*(\.|source)[[:space:]]|\$LIB|lib/' "$HOOK"
    [ "$status" -eq 1 ]
}

# bats cannot run the harness timeout, so a hanging board is covered by the
# value Claude Code enforces.
@test "hooks.json parses, has no SessionEnd, keeps the Linear matcher and times out above 5 s" {
    run python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
assert "SessionEnd" not in h, "SessionEnd still registered"
post = h["PostToolUse"]
assert len(post) == 1, post
assert post[0]["matcher"] == "mcp__.*[Ll][Ii][Nn][Ee][Aa][Rr].*__.*", post[0]["matcher"]
for event in ("PostToolUse", "SessionStart"):
    for group in h[event]:
        for cmd in group["hooks"]:
            t = cmd.get("timeout")
            assert isinstance(t, (int, float)) and t > 5, "%s timeout is %r" % (event, t)
print("ok")
' "$ROOT/hooks/hooks.json"
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

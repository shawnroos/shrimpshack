#!/usr/bin/env bats

load setup_common

# U14 — an agent's own Linear write marks the board behind (KTD15). The hook
# records and advises; it never syncs, reads Linear or touches a pane (KTD2).

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    HOOK="$ROOT/hooks/board-behind.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/bin" "$HERDR_LINEAR_PROJECTS_ROOT/wt" "$HERDR_LINEAR_STORE_DIR"

    # Any herdr or network call leaves a trace a test can refuse.
    for b in herdr curl; do
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/%s.calls"\nexit 1\n' "$WORK" "$b" > "$WORK/bin/$b"
        chmod +x "$WORK/bin/$b"
    done
    export HERDR_BIN="$WORK/bin/herdr" HERDR_LINEAR_CURL_BIN="$WORK/bin/curl"
    export HERDR_LINEAR_BIN_PATHS="$WORK/bin"

    SYNC="$HERDR_LINEAR_STORE_DIR/board/sync-state.json"
    INSIDE="$HERDR_LINEAR_PROJECTS_ROOT/wt"
}

board_config() {
    printf '{"version":1,"global":{"levels":{"column":"state"},"filter":{"team":["WEB"]}},"spaces":{}}\n' \
        > "$HERDR_LINEAR_STORE_DIR/board.json"
    chmod 600 "$HERDR_LINEAR_STORE_DIR/board.json"
}

payload() { printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{},"tool_response":{}}' "${2:-$INSIDE}" "$1"; }

fire() { run --separate-stderr bash -c "printf '%s' '$(payload "$@")' | bash '$HOOK'"; }

marked_behind() {
    python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1])).get("behind_marked_at")))' "$SYNC" 2>/dev/null \
        || printf 'False\n'
}

context_of() { python3 -c 'import sys,json;d=json.load(sys.stdin)["hookSpecificOutput"];print(d["hookEventName"]);print(d["additionalContext"])'; }

no_side_calls() {
    [ ! -e "$WORK/herdr.calls" ] && [ ! -e "$WORK/curl.calls" ]
}

@test "a Linear write tool call marks the board behind and names the unattended sync" {
    board_config
    fire mcp__linear__save_issue
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$(marked_behind)" = "True" ]
    ctx="$(printf '%s' "$output" | context_of)"
    [[ "$ctx" == PostToolUse* ]]
    [[ "$ctx" == *"bash \""*"/lib/board-sync.sh\""* ]]
}

@test "a Linear write creates or moves no pane and calls no Linear API" {
    board_config
    fire mcp__linear__save_issue
    [ "$status" -eq 0 ]
    no_side_calls
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/sync.lock" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/journal.json" ]
}

@test "a write through a second Linear server prefix marks the board behind too" {
    board_config
    fire mcp__claude_ai_Linear__save_comment
    [ "$status" -eq 0 ]
    [ "$(marked_behind)" = "True" ]
    [[ "$(printf '%s' "$output" | context_of)" == *"/lib/board-sync.sh"* ]]
}

@test "a write tool Linear adds later still marks the board behind" {
    board_config
    fire mcp__linear__archive_issue
    [ "$(marked_behind)" = "True" ]
}

@test "a Linear read does not mark the board behind" {
    board_config
    for t in mcp__linear__get_issue mcp__linear__list_issues mcp__claude_ai_Linear__search_documentation mcp__linear__extract_images; do
        fire "$t"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -e "$SYNC" ]
}

@test "a write through a server that is not Linear does not mark the board behind" {
    board_config
    fire mcp__github__create_issue
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$SYNC" ]
}

@test "with no board configured nothing is recorded and nothing is said" {
    fire mcp__linear__save_issue
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$SYNC" ]
}

@test "a write from outside the project roots marks the board behind and says nothing" {
    board_config
    mkdir -p "$WORK/elsewhere"
    fire mcp__linear__save_issue "$WORK/elsewhere"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(marked_behind)" = "True" ]
}

@test "a hook with an unreadable store still exits 0" {
    board_config
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board"
    printf '{}' > "$SYNC"
    chmod 000 "$SYNC" "$HERDR_LINEAR_STORE_DIR/board" 2>/dev/null || skip "cannot remove read permission here"
    fire mcp__linear__save_issue
    chmod 700 "$HERDR_LINEAR_STORE_DIR/board"; chmod 600 "$SYNC"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "a malformed or empty payload exits 0 and says nothing" {
    board_config
    run --separate-stderr bash -c "printf 'not json' | bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run --separate-stderr bash -c "bash '$HOOK' </dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$SYNC" ]
}

@test "the hook is registered on PostToolUse with a matcher that takes every Linear server" {
    run python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
groups = [g for g in h.get("PostToolUse", []) if any("board-behind.sh" in x.get("command", "") for x in g["hooks"])]
assert len(groups) == 1, groups
m = groups[0]["matcher"]
for name in ("mcp__linear__save_issue", "mcp__claude_ai_Linear__save_issue", "mcp__linear-eu__save_issue"):
    assert re.search(m, name), name
for name in ("mcp__github__create_issue", "Bash", "Edit"):
    assert not re.search(m, name), name
for event, groups in h.items():
    if event != "PostToolUse":
        assert not any("board-behind.sh" in x.get("command", "") for g in groups for x in g["hooks"]), event
print("ok")
PY
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

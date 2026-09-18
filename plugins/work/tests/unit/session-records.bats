#!/usr/bin/env bats

load setup_common

# Records keyed by a herdr id are kept per session (R15, R16). herdr ids are
# scoped to one server, so without this a workspace `w1` bound in one session
# is read as bound in every other session that also has a `w1`. The default
# session keeps today's flat paths, so records written before sessions existed
# keep applying there (R17).

bats_require_minimum_version 1.5.0

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hl-srec.XXXXXX")" && pwd -P)"
    DEFAULT_SOCK="/h/.config/herdr/herdr.sock"
    WEB_SOCK="/h/.config/herdr/sessions/web/herdr.sock"
    export HERDR_SOCKET_PATH="$DEFAULT_SOCK"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export HERDR_LINEAR_BIN_PATHS=""
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_WORKSPACES="w1=Plugins"
    for f in sanitize.sh herdr-read.sh session.sh binding.sh board-store.sh board-sync.sh states.sh herdr-write.sh board-herdr.sh; do
        . "$LIB/$f"
    done
    REPO="$WORK/repo"
    git init -q "$REPO"
    git -C "$REPO" commit -q --allow-empty -m init
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }

in_default() { export HERDR_SOCKET_PATH="$DEFAULT_SOCK"; }
in_web()     { export HERDR_SOCKET_PATH="$WEB_SOCK"; }
no_session() { export HERDR_SOCKET_PATH="/tmp/elsewhere.sock"; }

bind_space() {   # bind_space <ws> <project>
    local nonce
    nonce="$(herdr_linear::workspace_propose "$1" "$2")"
    herdr_linear::workspace_confirm "$1" "$2" "$nonce"
}

@test "AE1: a workspace bound in the default session reads unbound in session web" {
    in_default
    bind_space w1 proj-a
    [ "$(herdr_linear::workspace_project w1)" = proj-a ]
    in_web
    run herdr_linear::workspace_project w1
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::workspace_state w1)" = unbound ]
    bind_space w1 proj-b
    [ "$(herdr_linear::workspace_project w1)" = proj-b ]
    in_default
    [ "$(herdr_linear::workspace_project w1)" = proj-a ]
}

@test "records written before this change are read unchanged in the default session" {
    in_default
    bind_space w1 proj-a
    [ -f "$HERDR_LINEAR_STORE_DIR/workspaces/w1.json" ]
    herdr_linear::board_reserve iss-1 WEB-1 web-1 web-1 false
    [ -f "$HERDR_LINEAR_STORE_DIR/board/reservations/iss-1.json" ]
    [ "$(herdr_linear::board_reservation_field iss-1 identifier)" = WEB-1 ]
}

@test "a named session keeps its records under sessions/<name>" {
    in_web
    bind_space w1 proj-b
    herdr_linear::board_reserve iss-1 WEB-1 web-1 web-1 false
    [ -f "$HERDR_LINEAR_STORE_DIR/sessions/web/workspaces/w1.json" ]
    [ -f "$HERDR_LINEAR_STORE_DIR/sessions/web/board/reservations/iss-1.json" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/workspaces/w1.json" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/reservations/iss-1.json" ]
}

@test "the board ledger, questions and reservations of one session are not read in another" {
    in_default
    herdr_linear::board_ledger_put Plugins iss-1 w1:p1 home '{}' true
    herdr_linear::board_reserve iss-1 WEB-1 web-1 web-1 false
    herdr_linear::board_question_propose q-1 close '{"issue":"iss-1"}' >/dev/null
    [ -n "$(herdr_linear::board_questions_pending)" ]
    in_web
    run herdr_linear::board_ledger_entry Plugins iss-1
    [ "$status" -ne 0 ]
    run herdr_linear::board_reservation iss-1
    [ "$status" -ne 0 ]
    [ -z "$(herdr_linear::board_questions_pending)" ]
}

@test "a board sync in session web ignores the default session's lock" {
    in_default
    herdr_linear::_board_sync_lock "$$"
    [ -d "$HERDR_LINEAR_STORE_DIR/board/sync.lock" ]
    in_web
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=1
    run herdr_linear::_board_sync_lock "$$"
    [ "$status" -eq 0 ]
    [ -d "$HERDR_LINEAR_STORE_DIR/sessions/web/board/sync.lock" ]
}

@test "a home pane recorded in the default session's ledger is not found from session web" {
    in_default
    herdr_linear::board_ledger_put Plugins iss-1 w1:p1 home '{}' true
    [ "$(herdr_linear::board_home_space iss-1)" = Plugins ]
    in_web
    run herdr_linear::board_home_space iss-1
    [ "$status" -ne 0 ]
    no_session
    run herdr_linear::board_home_space iss-1
    [ "$status" -ne 0 ]
}

@test "the space lookup in session web ignores a default-session record with the same id" {
    in_default
    bind_space w1 proj-a
    [ "$(herdr_linear::project_spaces proj-a)" = w1 ]
    in_web
    [ -z "$(herdr_linear::project_spaces proj-a)" ]
}

@test "a tab saved for a worktree in the default session is not reused in session web" {
    in_default
    herdr_linear::binding_propose "$REPO" WEB-1 >/dev/null
    herdr_linear::binding_set_tab "$REPO" w1:t3
    [ "$(herdr_linear::binding_tab "$REPO")" = w1:t3 ]
    in_web
    run herdr_linear::binding_tab "$REPO"
    [ -z "$output" ]
    herdr_linear::binding_set_tab "$REPO" w1:t9
    [ "$(herdr_linear::binding_tab "$REPO")" = w1:t9 ]
    in_default
    [ "$(herdr_linear::binding_tab "$REPO")" = w1:t3 ]
}

@test "a tab recorded before sessions existed applies to the default session" {
    in_default
    herdr_linear::binding_propose "$REPO" WEB-1 >/dev/null
    f="$(herdr_linear::_record_path "$REPO")"
    python3 - "$f" <<'EOF'
import json, sys
p = sys.argv[1]; r = json.load(open(p)); r["tab"] = "w1:t5"; r.pop("tabs", None)
json.dump(r, open(p, "w"))
EOF
    [ "$(herdr_linear::binding_tab "$REPO")" = w1:t5 ]
    in_web
    [ -z "$(herdr_linear::binding_tab "$REPO")" ]
}

@test "with no session, workspace records and board state are neither read nor written" {
    in_default
    bind_space w1 proj-a
    herdr_linear::board_reserve iss-1 WEB-1 web-1 web-1 false
    before="$(cd "$HERDR_LINEAR_STORE_DIR" && find . -type f | sort)"
    no_session
    run herdr_linear::workspace_project w1
    [ "$status" -ne 0 ]
    run herdr_linear::workspace_propose w2 proj-a
    [ "$status" -ne 0 ]
    run herdr_linear::board_reservation iss-1
    [ "$status" -ne 0 ]
    run herdr_linear::board_reserve iss-2 WEB-2 web-2 web-2 false
    [ "$status" -ne 0 ]
    run herdr_linear::board_mark_behind
    [ "$status" -ne 0 ]
    run herdr_linear::_board_sync_lock "$$"
    [ "$status" -ne 0 ]
    run herdr_linear::binding_tab "$REPO"
    [ -z "$output" ]
    [ "$(cd "$HERDR_LINEAR_STORE_DIR" && find . -type f | sort)" = "$before" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/sessions" ]
}

@test "with no session a worktree binding keeps working" {
    no_session
    run herdr_linear::binding_propose "$REPO" WEB-1
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$REPO")" = proposed ]
}

@test "the layout journal is kept per session" {
    in_default
    [ "$(herdr_linear::_journal WEB-1)" = "$HERDR_LINEAR_JOURNAL_DIR/WEB-1.journal" ]
    in_web
    [ "$(herdr_linear::_journal WEB-1)" = "$HERDR_LINEAR_JOURNAL_DIR/sessions/web/WEB-1.journal" ]
    [ "$(herdr_linear::_board_placeholders)" = "$HERDR_LINEAR_JOURNAL_DIR/sessions/web/board-placeholders" ]
    no_session
    run herdr_linear::_journal WEB-1
    [ "$status" -ne 0 ]
}

@test "a Linear write from session web marks the default session's board behind too" {
    in_default
    herdr_linear::board_sync_complete '{"observed":{},"unknown":{},"pending_questions":0,"members":[],"rendered":{}}'
    in_web
    herdr_linear::board_sync_complete '{"observed":{},"unknown":{},"pending_questions":0,"members":[],"rendered":{}}'
    in_default
    run herdr_linear::board_behind
    [ "$status" -ne 0 ]
    in_web
    herdr_linear::board_mark_behind_all
    run herdr_linear::board_behind
    [ "$status" -eq 0 ]
    in_default
    run herdr_linear::board_behind
    [ "$status" -eq 0 ]
}

@test "marking every board behind creates no board for a session that has none" {
    in_web
    herdr_linear::board_mark_behind_all
    [ ! -e "$HERDR_LINEAR_STORE_DIR/sessions" ]
    [ -f "$HERDR_LINEAR_STORE_DIR/board/sync-state.json" ]
}

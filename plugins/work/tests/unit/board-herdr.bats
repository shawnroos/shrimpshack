#!/usr/bin/env bats

load setup_common

# U7 — the herdr board writer: create, move, close and label board panes, and
# nothing else.
#
# No test reaches a live herdr. HERDR_BIN is the fake, its socket is a fake
# server under this test's directory, and the board state both transports edit
# is one JSON file there. A move goes over the socket with focus:false because
# the CLI verb steals focus (docs/board-spikes.md step 2); every move test
# checks the socket log AND that the argv record holds no `pane move`.

bats_require_minimum_version 1.5.0

A=aaaaaaaa-0000-4000-8000-00000000000a
B=bbbbbbbb-0000-4000-8000-00000000000b
C=cccccccc-0000-4000-8000-00000000000c
D=dddddddd-0000-4000-8000-00000000000d
E=eeeeeeee-0000-4000-8000-00000000000e
SPACE="In Progress"

refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    # Short on purpose: a Unix socket path over 104 bytes cannot be bound on macOS.
    WORK="$(mktemp -d /tmp/bh.XXXXXX)"
    WORK="$(cd "$WORK" && pwd -P)"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_BOARD_STATE="$WORK/state.json"
    export FAKE_HERDR_SOCKET_PATH="$WORK/h.sock"
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=5
    mkdir -p "$WORK/rec" "$HERDR_LINEAR_WORKTREES_ROOT"
    for f in herdr-read.sh board-store.sh board-herdr.sh; do
        # shellcheck source=/dev/null
        . "$LIB/$f"
    done
    SERVER_PID=""
}

teardown() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}

label() { herdr_linear::board_pane_label "$1" "${2:-home}" "${3:-$SPACE}"; }

# seed <spec-json>: the fake board state. Tabs carry a compact tree: a pane id,
# or [direction, first, second].
seed() {
    python3 "$FIX/fake-herdr-socket.py" seed "$1"
}

serve() {
    python3 "$FIX/fake-herdr-socket.py" serve 3>&- &
    SERVER_PID=$!
    local i=0
    until [ -S "$FAKE_HERDR_SOCKET_PATH" ]; do
        i=$((i + 1))
        [ "$i" -lt 200 ] || { echo "fake socket server never bound" >&2; return 1; }
        perl -e 'select undef, undef, undef, 0.02'
    done
}

snap() { "$HERDR_BIN" api snapshot; }

field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

tree_of() { python3 "$FIX/fake-herdr-socket.py" tree "$1"; }

own() { herdr_linear::board_ledger_put "$SPACE" "$1" "$2" "${3:-home}" '{}' "${4:-true}"; }

# A board of two tabs in w1 and one in w2. A sits alone in t1; B and C share t2;
# D is in another workspace.
standard_board() {
    seed "$(printf '{"focused":"w1:p9","workspaces":[{"workspace_id":"w1","label":"Board"},{"workspace_id":"w2","label":"Other"}],
      "tabs":[{"tab_id":"w1:t1","label":"Todo","tree":"w1:p1"},
              {"tab_id":"w1:t2","label":"Doing","tree":["right","w1:p2","w1:p3"]},
              {"tab_id":"w1:t9","label":"Mine","tree":"w1:p9"},
              {"tab_id":"w2:t1","label":"Else","tree":"w2:p1"}],
      "panes":{"w1:p1":{"label":"%s"},"w1:p2":{"label":"%s"},"w1:p3":{"label":"%s"},"w2:p1":{"label":"%s"}}}' \
      "$(label "$A")" "$(label "$B")" "$(label "$C")" "$(label "$D")")"
    own "$A" w1:p1; own "$B" w1:p2; own "$C" w1:p3; own "$D" w2:p1
}

assert_moves_went_over_the_socket() {
    grep -q '"method": "pane.move"' "$FAKE_HERDR_RECORD_DIR/socket"
    refute_match -q '"focus": true' "$FAKE_HERDR_RECORD_DIR/socket"
    refute_match -q '"method": "layout.apply"' "$FAKE_HERDR_RECORD_DIR/socket"
    refute_match -qE '^pane (move|swap)' "$FAKE_HERDR_RECORD_DIR/argv"
}

# ---------------------------------------------------------------- layout

@test "a desired two-column, two-row tree produces that geometry in the fake snapshot" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$B\"],[\"$C\",\"$D\"]]"
    # D came from another workspace, so herdr renamed it; the tree holds the new id.
    d_now="$(printf '%s\n' "$output" | awk -F '\t' -v i="$D" '$1 == i { print $2 }')"
    [ -n "$d_now" ]
    [ "$d_now" != "w2:p1" ]
    [ "$(tree_of w1:t1)" = "right(down(w1:p1,w1:p2),down(w1:p3,$d_now))" ]
    run -0 herdr_linear::board_tab_columns w1:t1
    [ "$output" = "[[\"w1:p1\",\"w1:p2\"],[\"w1:p3\",\"$d_now\"]]" ]
    # The person's focus never moved.
    [ "$(snap | field 'd["result"]["snapshot"]["focused_pane_id"]')" = "w1:p9" ]
    assert_moves_went_over_the_socket
}

@test "every pane is reported with both its pane id and its terminal id" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\"],[\"$D\"]]"
    line="$(printf '%s\n' "$output" | awk -F '\t' -v i="$D" '$1 == i')"
    [ "$(printf '%s' "$line" | cut -f3)" = "term-w2-p1" ]
    [ "$(printf '%s' "$line" | cut -f4)" = "w1:t1" ]
    [ "$(printf '%s' "$line" | cut -f5)" = "w1" ]
}

@test "a tab is reordered through a scratch tab, because a same-tab move does nothing" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t2 "[[\"$C\"],[\"$B\"]]"
    [ "$(tree_of w1:t2)" = "right(w1:p3,w1:p2)" ]
    # The scratch tab closed itself when its last pane went back.
    [ "$(snap | field 'len(d["result"]["snapshot"]["tabs"])')" = "4" ]
    assert_moves_went_over_the_socket
}

@test "a tab already in the desired shape is left alone" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t2 "[[\"$B\"],[\"$C\"]]"
    [ ! -e "$FAKE_HERDR_RECORD_DIR/socket" ] || refute_match -q 'pane.move' "$FAKE_HERDR_RECORD_DIR/socket"
}

@test "a same-tab move is a no-op, reported as same_tab" {
    standard_board; serve
    run -0 herdr_linear::board_move_pane "$SPACE" "$B" w1:t2 down w1:p3
    [ "$(printf '%s' "$output" | cut -f6)" = "same_tab" ]
    [ "$(tree_of w1:t2)" = "right(w1:p2,w1:p3)" ]
    assert_moves_went_over_the_socket
}

@test "a cross-workspace move renames the pane and the ledger still finds it by label" {
    standard_board; serve
    run -0 herdr_linear::board_move_pane "$SPACE" "$D" w1:t1 right w1:p1
    new_id="$(printf '%s' "$output" | cut -f2)"
    [ "$new_id" != "w2:p1" ]
    # The ledger still holds the old id. The label is what finds the pane now.
    [ "$(herdr_linear::board_ledger_entry "$SPACE" "$D" | field 'd["pane_id"]')" = "w2:p1" ]
    run -0 herdr_linear::board_locate "$SPACE" "$D"
    [ "$(printf '%s' "$output" | cut -f1)" = "$new_id" ]
    [ "$(printf '%s' "$output" | cut -f2)" = "term-w2-p1" ]
    [ "$(printf '%s' "$output" | cut -f3)" = "w1:t1" ]
}

@test "moving the last pane out of a tab the board still needs keeps that tab" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$D\"]]" w2:t1
    [ "$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"]].count("w2:t1")')" = "1" ]
    # The tab held a placeholder until its own apply brought its pane in, and a
    # restart in between renews its terminal id without making it foreign.
    python3 "$FIX/fake-herdr-socket.py" restart
    run -0 herdr_linear::board_apply_tab "$SPACE" w2:t1 "[[\"$C\"]]"
    c_now="$(printf '%s\n' "$output" | awk -F '\t' -v i="$C" '$1 == i { print $2 }')"
    [ "$(tree_of w2:t1)" = "$c_now" ]
}

@test "a tab the board does not name loses its last pane and closes, as herdr does" {
    standard_board; serve
    run -0 herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$D\"]]"
    [ "$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"]].count("w2:t1")')" = "0" ]
}

@test "a desired tree naming a pane the board did not create is refused and nothing moves" {
    standard_board; serve
    own "$B" w1:p2 home false
    run -2 herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$B\"]]"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    [[ "$output" == *"did not create"* ]]
    [ ! -e "$FAKE_HERDR_RECORD_DIR/socket" ] || refute_match -q 'pane.move' "$FAKE_HERDR_RECORD_DIR/socket"
}

@test "a tab holding a pane the board does not own is refused rather than rebuilt around it" {
    standard_board; serve
    herdr_linear::board_ledger_remove "$SPACE" "$C"
    run -2 herdr_linear::board_apply_tab "$SPACE" w1:t2 "[[\"$A\"],[\"$B\"]]"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    [[ "$output" == *"w1:p3"* ]]
}

@test "a kept tab needs an existing directory for its placeholder" {
    standard_board; serve
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/absent"
    run herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$D\"]]" w2:t1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    [ ! -e "$FAKE_HERDR_RECORD_DIR/socket" ] || refute_match -q 'pane.move' "$FAKE_HERDR_RECORD_DIR/socket"
}

@test "a tree over the pane cap is refused" {
    standard_board; serve
    many="$(python3 -c 'import json; print(json.dumps([["a%02d-x" % i] for i in range(17)]))')"
    run -2 herdr_linear::board_apply_tab "$SPACE" w1:t1 "$many"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
}

@test "a move whose effect cannot be read back is reported unknown" {
    # Before the server starts: the move is applied inside it.
    export FAKE_HERDR_SNAPSHOT_FAILS_AFTER_MOVE=1
    standard_board; serve
    run herdr_linear::board_move_pane "$SPACE" "$D" w1:t1 right w1:p1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
    [[ "$output" == *"unknown"* ]]
}

@test "an apply whose tree cannot be read back is reported unknown" {
    # Before the server starts: the move is applied inside it.
    export FAKE_HERDR_SNAPSHOT_FAILS_AFTER_MOVE=1
    standard_board; serve
    run herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\"],[\"$D\"]]"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

@test "a canonical tree reads as columns of rows; an off-grid drop does not" {
    seed '{"focused":"w1:p1","workspaces":[{"workspace_id":"w1","label":"B"}],
      "tabs":[{"tab_id":"w1:t1","label":"x","tree":["right","w1:p1",["down",["right","w1:p2","w1:p4"],"w1:p3"]]}],"panes":{}}'
    serve
    run herdr_linear::board_tab_columns w1:t1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run herdr_linear::board_tab_columns w1:t404
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_GONE" ]
}

@test "no socket server is unknown for a layout read, not an empty tab" {
    standard_board
    run herdr_linear::board_tab_columns w1:t1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

# ---------------------------------------------------------------- in use

@test "the invoking, focused, working-agent and idle-agent panes are in use; a quiet pane is not" {
    seed '{"focused":"w1:p2","workspaces":[{"workspace_id":"w1","label":"B"}],
      "tabs":[{"tab_id":"w1:t1","label":"x","tree":["right","w1:p1",["right","w1:p2",["right","w1:p3",["right","w1:p4","w1:p5"]]]]}],
      "panes":{"w1:p3":{"agent":"claude","agent_status":"working"},"w1:p4":{"agent":"codex","agent_status":"idle"},
               "w1:p5":{"agent":null,"agent_status":"unknown"}}}'
    export HERDR_PANE_ID=w1:p1
    run -0 herdr_linear::board_in_use w1:p1
    [[ "$output" == *invoking* ]]
    run -0 herdr_linear::board_in_use w1:p2
    [[ "$output" == *focused* ]]
    run -0 herdr_linear::board_in_use w1:p3
    [[ "$output" == *agent* ]]
    run -0 herdr_linear::board_in_use w1:p4
    [[ "$output" == *agent* ]]
    # agent_status "unknown" with no agent is a pane with no agent (spike step 4).
    run -1 herdr_linear::board_in_use w1:p5
}

@test "in use is unknown when the snapshot cannot be read" {
    export FAKE_HERDR_SNAPSHOT_FAILS=1
    seed '{"focused":"w1:p1","workspaces":[{"workspace_id":"w1","label":"B"}],"tabs":[{"tab_id":"w1:t1","label":"x","tree":"w1:p1"}],"panes":{}}'
    run herdr_linear::board_in_use w1:p1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

@test "the invoking pane is in use even after a workspace move made its env id stale" {
    standard_board; serve
    herdr_linear::board_move_pane "$SPACE" "$D" w1:t1 right w1:p1 >/dev/null
    new_id="$(snap | field '[p["pane_id"] for p in d["result"]["snapshot"]["panes"] if p["terminal_id"] == "term-w2-p1"][0]')"
    export HERDR_PANE_ID=w2:p1
    run -0 herdr_linear::board_in_use "$new_id"
    [[ "$output" == *invoking* ]]
}

@test "a move of a pane in use is refused and nothing moves; the in-use verb moves it" {
    standard_board
    python3 "$FIX/fake-herdr-socket.py" set-agent w2:p1 claude working
    serve
    run herdr_linear::board_move_pane "$SPACE" "$D" w1:t1 right w1:p1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_IN_USE" ]
    [ ! -e "$FAKE_HERDR_RECORD_DIR/socket" ] || refute_match -q 'pane.move' "$FAKE_HERDR_RECORD_DIR/socket"
    [ "$(tree_of w2:t1)" = "w2:p1" ]
    run -0 herdr_linear::board_move_in_use "$SPACE" "$D" w1:t1 right w1:p1
    [ "$(printf '%s' "$output" | cut -f4)" = "w1:t1" ]
    assert_moves_went_over_the_socket
}

@test "an apply that would move a pane in use is refused whole" {
    standard_board
    python3 "$FIX/fake-herdr-socket.py" set-agent w2:p1 claude idle
    serve
    run herdr_linear::board_apply_tab "$SPACE" w1:t1 "[[\"$A\",\"$D\"]]"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_IN_USE" ]
    [[ "$output" == *"$D"* ]]
    [ ! -e "$FAKE_HERDR_RECORD_DIR/socket" ] || refute_match -q 'pane.move' "$FAKE_HERDR_RECORD_DIR/socket"
    run -0 herdr_linear::board_apply_tab_in_use "$SPACE" w1:t1 "[[\"$A\",\"$D\"]]"
}

# ---------------------------------------------------------------- close

@test "a close on a pane the ledger does not own is refused" {
    standard_board; serve
    own "$B" w1:p2 home false
    run herdr_linear::board_close_pane "$SPACE" "$B"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    [[ "$output" == *"did not create"* ]]
    run herdr_linear::board_close_pane "$SPACE" "$E"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    refute_match -q '^pane close' "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$(tree_of w1:t2)" = "right(w1:p2,w1:p3)" ]
}

@test "a close on a board pane closes it and is observed gone" {
    standard_board; serve
    run -0 herdr_linear::board_close_pane "$SPACE" "$C"
    [ "$(tree_of w1:t2)" = "w1:p2" ]
    run herdr_linear::board_locate "$SPACE" "$C"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_GONE" ]
}

@test "a close whose effect cannot be read back is unknown" {
    standard_board; serve
    export FAKE_HERDR_SNAPSHOT_FAILS_AFTER_CLOSE=1
    run herdr_linear::board_close_pane "$SPACE" "$C"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

# ---------------------------------------------------------------- creation and labels

@test "a reserved pane opens in a neutral directory, labelled, without taking focus" {
    standard_board; serve
    run -0 herdr_linear::board_create_pane "$SPACE" "$E" home "$HERDR_LINEAR_WORKTREES_ROOT" split:w1:p1:down
    pane="$(printf '%s' "$output" | cut -f1)"
    [ -n "$(printf '%s' "$output" | cut -f2)" ]
    [ "$(snap | field "[p['label'] for p in d['result']['snapshot']['panes'] if p['pane_id'] == '$pane'][0]")" = "$(label "$E")" ]
    [ "$(snap | field "[p['cwd'] for p in d['result']['snapshot']['panes'] if p['pane_id'] == '$pane'][0]")" = "$HERDR_LINEAR_WORKTREES_ROOT" ]
    [ "$(snap | field 'd["result"]["snapshot"]["focused_pane_id"]')" = "w1:p9" ]
    grep -q -- '--no-focus' "$FAKE_HERDR_RECORD_DIR/argv"
}

@test "a reserved pane in a new tab lands in the workspace asked for" {
    standard_board; serve
    run -0 herdr_linear::board_create_pane "$SPACE" "$E" home "$HERDR_LINEAR_WORKTREES_ROOT" tab:w2:Review
    [ "$(printf '%s' "$output" | cut -f4)" = "w2" ]
}

@test "a second pane for a ticket that already has one is refused" {
    standard_board; serve
    run herdr_linear::board_create_pane "$SPACE" "$C" home "$HERDR_LINEAR_WORKTREES_ROOT" split:w1:p1:down
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    refute_match -q '^pane split' "$FAKE_HERDR_RECORD_DIR/argv"
}

@test "a reserved pane is refused a directory that is missing or inside a git worktree" {
    standard_board; serve
    run herdr_linear::board_create_pane "$SPACE" "$E" home "$WORK/nope" split:w1:p1:down
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    git -C "$WORK" init -q "$WORK/repo"
    run herdr_linear::board_create_pane "$SPACE" "$E" home "$WORK/repo" split:w1:p1:down
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_REFUSED" ]
    refute_match -q '^pane split' "$FAKE_HERDR_RECORD_DIR/argv"
}

@test "a pane that registers late is still labelled" {
    export FAKE_HERDR_SLOW_PANE=3
    standard_board; serve
    run -0 herdr_linear::board_create_pane "$SPACE" "$E" home "$HERDR_LINEAR_WORKTREES_ROOT" split:w1:p1:down
    pane="$(printf '%s' "$output" | cut -f1)"
    [ "$(snap | field "[p['label'] for p in d['result']['snapshot']['panes'] if p['pane_id'] == '$pane'][0]")" = "$(label "$E")" ]
}

@test "a pane that never registers is unknown" {
    export FAKE_HERDR_SLOW_PANE=50
    standard_board; serve
    run herdr_linear::board_create_pane "$SPACE" "$E" home "$HERDR_LINEAR_WORKTREES_ROOT" split:w1:p1:down
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

@test "a pane whose label cannot be read back is unknown" {
    standard_board; serve
    export FAKE_HERDR_RENAME_IGNORED=1
    run herdr_linear::board_create_pane "$SPACE" "$E" home "$HERDR_LINEAR_WORKTREES_ROOT" split:w1:p1:down
    [ "$status" -eq "$HERDR_LINEAR_BOARD_PANE_UNKNOWN" ]
}

@test "pointer panes in two spaces get distinct labels and focus their home pane" {
    standard_board; serve
    [ "$(label "$A" pointer "Space One")" != "$(label "$A" pointer "Space Two")" ]
    [ "$(label "$A" pointer "Space One")" != "$(label "$A" home)" ]
    run -0 herdr_linear::board_create_pane "Space One" "$A" pointer "$HERDR_LINEAR_WORKTREES_ROOT" tab:w2:Pointers
    grep -q "HERDR_LINEAR_BOARD_HOME=$A" "$FAKE_HERDR_RECORD_DIR/argv"
    run -0 herdr_linear::board_focus_home "$A"
    [ "$(snap | field 'd["result"]["snapshot"]["focused_pane_id"]')" = "w1:p1" ]
    grep -q '"method": "pane.focus"' "$FAKE_HERDR_RECORD_DIR/socket"
}

# ---------------------------------------------------------------- sync state

@test "sync state is shown on every board pane with report-metadata and read back" {
    standard_board; serve
    herdr_linear::board_sync_complete '{"observed":{"tickets":4},"unknown":{"panes":0},"pending_questions":2,"members":[],"rendered":{}}'
    run -0 herdr_linear::board_show_sync_state "$SPACE"
    grep -q '^pane report-metadata' "$FAKE_HERDR_RECORD_DIR/argv"
    for p in w1:p1 w1:p2 w1:p3 w2:p1; do
        t="$(snap | field "[p['title'] for p in d['result']['snapshot']['panes'] if p['pane_id'] == '$p'][0]")"
        [[ "$t" == *"2 questions"* ]]
    done
    title="$(snap | field "[p['title'] for p in d['result']['snapshot']['panes'] if p['pane_id'] == 'w1:p9'][0]")"
    [ "$title" = "None" ]
}

@test "a failed sync is shown as a failure, never as nothing to do" {
    run -0 herdr_linear::board_sync_title '{"last_failure":{"stage":"linear read","message":"x","at":"t"},"behind":true}'
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"linear read"* ]]
}

# ---------------------------------------------------------------- socket

@test "the socket path comes from the probe, and an empty one is refused" {
    standard_board; serve
    run -0 herdr_linear::board_socket_path
    [ "$output" = "$FAKE_HERDR_SOCKET_PATH" ]
    export FAKE_HERDR_SOCKET_PATH=""
    export HERDR_LINEAR_SOCKET_PATH=""
    export FAKE_HERDR_STATUS_NO_SOCKET=1
    run herdr_linear::board_socket_path
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

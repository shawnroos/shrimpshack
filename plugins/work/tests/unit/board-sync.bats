#!/usr/bin/env bats

load setup_common

# U8 — the unattended sync. herdr is the fake board (a state file edited by the
# fake CLI and a fake socket server under this test's directory); Linear is a
# curl stub that answers the board read from a ticket file and records every
# request body, so "no issueUpdate was sent" is read from what reached curl.

bats_require_minimum_version 1.5.0

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    # Short on purpose: a Unix socket path over 104 bytes cannot be bound on macOS.
    WORK="$(mktemp -d /tmp/bs.XXXXXX)"
    WORK="$(cd "$WORK" && pwd -P)"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_BOARD_STATE="$WORK/state.json"
    export FAKE_HERDR_SOCKET_PATH="$WORK/h.sock"
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=5
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=20
    mkdir -p "$WORK/rec" "$WORK/linear" "$HERDR_LINEAR_WORKTREES_ROOT" "$HERDR_LINEAR_STORE_DIR"

    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export HERDR_LINEAR_RETRY_MAX=1
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_SYNCSYNCSYNCSYNC" > "$LINEAR_SECRETS_FILE"
    export FAKE_BOARD_LINEAR_DIR="$WORK/linear"
    export HERDR_LINEAR_CURL_BIN="$WORK/curl.sh"
    cat > "$HERDR_LINEAR_CURL_BIN" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
body="" want=0
for a in "$@"; do
    [ "$want" = 1 ] && { body="$a"; want=0; }
    [ "$a" = -d ] && want=1
done
printf '%s\n' "$body" >> "$FAKE_BOARD_LINEAR_DIR/bodies"
case "$body" in
    *BoardIssues\(*)
        python3 -c '
import json, os, sys
d = os.environ["FAKE_BOARD_LINEAR_DIR"]
nodes = json.load(open(os.path.join(d, "tickets.json")))
more = os.path.exists(os.path.join(d, "incomplete"))
print(json.dumps({"data": {"issues": {"nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": None}}}}))' ;;
    *) printf '{"errors":[{"message":"not a board read","extensions":{"code":"INPUT_ERROR"}}]}\n' ;;
esac
SH
    chmod +x "$HERDR_LINEAR_CURL_BIN"

    for f in herdr-read.sh board-store.sh board-herdr.sh board-sync.sh; do
        # shellcheck source=/dev/null
        . "$LIB/$f"
    done
    mkdir -p "$WORK/repo"
    herdr_linear::record_scope_repo "$WORK/repo" team-team-web
    SERVER_PID=""
    BG_PIDS=""
}

teardown() {
    local p
    for p in $BG_PIDS $SERVER_PID; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
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

# config <global-levels-json> [extra top-level spaces json]
config() {
    printf '{"version":1,"global":{"levels":%s,"filter":{"team":["WEB"]}},"spaces":%s}\n' "$1" "${2:-{\}}" \
        > "$HERDR_LINEAR_STORE_DIR/board.json"
    chmod 600 "$HERDR_LINEAR_STORE_DIR/board.json"
}

# An empty board workspace, and a scratch workspace holding the person's focus.
empty_board() {
    python3 "$FIX/fake-herdr-socket.py" seed '{"focused":"w9:p9",
      "workspaces":[{"workspace_id":"w1","label":"Board"},{"workspace_id":"w9","label":"Scratch"}],
      "tabs":[{"tab_id":"w9:t1","label":"shell","tree":"w9:p9"}],"panes":{}}'
}

# tickets "iss-1:todo iss-2:doing ..." -- states todo, doing, review, done-ish
# columns, each ticket in team WEB and project alpha unless it says :<project>.
tickets() {
    python3 - "$FAKE_BOARD_LINEAR_DIR/tickets.json" "$*" <<'PY'
import json, sys
states = {"todo": ("st-todo", "Todo", "unstarted"), "doing": ("st-doing", "Doing", "started"),
          "review": ("st-review", "Review", "started"), "qa": ("st-qa", "QA", "started"),
          "ship": ("st-ship", "Ship", "started"), "wait": ("st-wait", "Wait", "started")}
out = []
for spec in sys.argv[2].split():
    parts = spec.split(":")
    issue, state = parts[0], parts[1]
    project = parts[2] if len(parts) > 2 else "alpha"
    n = issue.split("-")[-1]
    sid, sname, stype = states[state]
    out.append({"id": issue, "identifier": "WEB-%s" % n, "title": "Ticket %s" % n,
                "updatedAt": "2026-09-14T10:00:00.000Z",
                "state": {"id": sid, "name": sname, "type": stype},
                "team": {"id": "team-web", "key": "WEB"},
                "project": {"id": "prj-" + project, "name": project.title()},
                "projectMilestone": None, "cycle": None, "assignee": None, "priority": 0,
                "parent": None, "labels": {"nodes": []}})
json.dump(out, open(sys.argv[1], "w"))
PY
}

snap() { "$HERDR_BIN" api snapshot; }

field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

tree_of() { python3 "$FIX/fake-herdr-socket.py" tree "$1"; }

board_panes() { snap | field 'sorted(p["label"] for p in d["result"]["snapshot"]["panes"] if (p.get("label") or "").startswith("work:"))'; }

tab_of_issue() {
    snap | field "[t['label'] for t in d['result']['snapshot']['tabs'] for p in d['result']['snapshot']['panes'] if p.get('label') == 'work:$1' and p['tab_id'] == t['tab_id']][0]"
}

pane_of_issue() {
    snap | field "[p['pane_id'] for p in d['result']['snapshot']['panes'] if p.get('label') == 'work:$1'][0]"
}

# The ledger as JSON with only what a sync decides: no file timestamps.
ledger_json() {
    python3 - "$HERDR_LINEAR_STORE_DIR/board/ledger" <<'PY'
import json, os, sys
d = sys.argv[1]
out = {}
for n in sorted(os.listdir(d)):
    rec = json.load(open(os.path.join(d, n)))
    out[rec["space"]] = rec["panes"]
print(json.dumps(out, sort_keys=True))
PY
}

questions() { herdr_linear::board_questions_pending | field 'd["kind"] + ":" + d["key"]' 2>/dev/null; }

question_kinds() {
    herdr_linear::board_questions_pending | python3 -c 'import sys,json; print(" ".join(sorted(json.loads(l)["kind"] for l in sys.stdin if l.strip())))'
}

issue_updates() { grep -c 'issueUpdate' "$FAKE_BOARD_LINEAR_DIR/bodies" 2>/dev/null || true; }

plan_actions() {
    python3 -c 'import sys,json; p=json.load(open(sys.argv[1])); print(" ".join(sorted("%s:%s" % (a["kind"], a["issue_id"]) for a in p["actions"])))' \
        "$HERDR_LINEAR_STORE_DIR/board/last-plan.json"
}

consent() {
    local nonce
    nonce="$(herdr_linear::board_consent_propose Board state)"
    herdr_linear::board_consent_confirm Board state "$nonce"
}

# A sync in its own process group, so the fake server can kill all of it --
# bash, python driver and every verb it is waiting on -- the way a crash would.
sync_in_own_group() {
    printf '' > "$WORK/pgid"
    perl -e 'setpgrp(0, 0); exec @ARGV' bash -c '
        printf "%s\n" "$$" > "$1"
        for f in herdr-read.sh board-store.sh board-herdr.sh board-sync.sh; do . "$2/$f"; done
        herdr_linear::board_sync' _ "$WORK/pgid" "$LIB"
}

five_on_the_board() {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo iss-5:todo"
    run -0 herdr_linear::board_sync
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4,work:iss-5" ]
}

# ---------------------------------------------------------------- interruption

@test "a sync killed after the second of five moves is re-run into the board and ledger of a clean run" {
    five_on_the_board
    cp -R "$HERDR_LINEAR_STORE_DIR" "$WORK/store-before"
    cp "$FAKE_HERDR_BOARD_STATE" "$WORK/state-before.json"

    # Five tickets each move to their own state: five tabs, one socket move each.
    tickets "iss-1:doing iss-2:review iss-3:qa iss-4:ship iss-5:wait"
    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    FAKE_HERDR_KILL_AFTER_MOVES=2 FAKE_HERDR_KILL_PGID_FILE="$WORK/pgid" serve
    run sync_in_own_group
    [ "$status" -eq 137 ]
    [ "$(cat "$FAKE_HERDR_RECORD_DIR/moves-applied")" = 2 ]
    # Killed mid-apply: the intent is still journalled and the lock names a dead holder.
    [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["intents"]))' "$HERDR_LINEAR_STORE_DIR/board/journal.json")" = 1 ]
    [ -e "$HERDR_LINEAR_STORE_DIR/board/sync.lock/pid" ]

    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    serve
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"resumed 1"* ]]
    interrupted_ledger="$(ledger_json)"
    interrupted_panes="$(board_panes)"
    for i in 1 2 3 4 5; do printf '%s ' "$(tab_of_issue "iss-$i")"; done > "$WORK/tabs-interrupted"

    # The same second sync, uninterrupted, from the same starting point.
    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    rm -rf "$HERDR_LINEAR_STORE_DIR" "$FAKE_HERDR_RECORD_DIR"; mkdir -p "$FAKE_HERDR_RECORD_DIR"
    cp -R "$WORK/store-before" "$HERDR_LINEAR_STORE_DIR"
    cp "$WORK/state-before.json" "$FAKE_HERDR_BOARD_STATE"
    serve
    run -0 herdr_linear::board_sync
    for i in 1 2 3 4 5; do printf '%s ' "$(tab_of_issue "iss-$i")"; done > "$WORK/tabs-clean"

    [ "$interrupted_panes" = "$(board_panes)" ]
    [ "$interrupted_ledger" = "$(ledger_json)" ]
    [ "$(cat "$WORK/tabs-clean")" = "Doing Review QA Ship Wait " ]
    cmp "$WORK/tabs-interrupted" "$WORK/tabs-clean"
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/journal.json" ] \
        || [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["intents"]))' "$HERDR_LINEAR_STORE_DIR/board/journal.json")" = 0 ]
}

@test "a journal entry left by a crash in the middle of a tab rebuild is finished, not hidden, and never written back" {
    config '{"column":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo"
    run -0 herdr_linear::board_sync
    consent
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Board"][0]')"
    p1="$(pane_of_issue iss-1)"; p2="$(pane_of_issue iss-2)"
    [ "$(tree_of "$tab")" = "down($p1,$p2)" ]

    # iss-1 goes to Doing: the rebuild parks iss-1 in a scratch tab (move one)
    # and is killed before bringing it back (move two).
    tickets "iss-1:doing iss-2:todo"
    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    FAKE_HERDR_KILL_AFTER_MOVES=1 FAKE_HERDR_KILL_PGID_FILE="$WORK/pgid" serve
    run sync_in_own_group
    [ "$status" -eq 137 ]
    [ "$(tab_of_issue iss-1)" = "work:scratch" ]

    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    serve
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    [ "$(tree_of "$tab")" = "right($p2,$p1)" ]
    [[ "$(plan_actions)" != *hide* ]]
    [[ "$(plan_actions)" != *write-back* ]]
    [ "$(issue_updates)" = 0 ]
    run -0 herdr_linear::board_ledger_entry Board iss-1
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["hidden"]')" = "('st-doing', False)" ]
}

# ---------------------------------------------------------------- questions, never asks

@test "AE14: a sync from an agent's shell with one leaving ticket leaves the pane open, records one close question, and exits questions-waiting" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [[ "$output" == *"1 question waiting"* ]]
    [[ "$(board_panes)" == *"work:iss-5"* ]]
    [ "$(question_kinds)" = "close" ]
    refute_close="$(grep -c '^pane close' "$FAKE_HERDR_RECORD_DIR/argv" || true)"
    [ "$refute_close" = 0 ]
    run -0 herdr_linear::board_sync_state
    [ "$(printf '%s' "$output" | field 'd["pending_questions"]')" = 1 ]
}

@test "AE5: the agent's own pane is not moved; the other affected panes are" {
    five_on_the_board
    export HERDR_PANE_ID="$(pane_of_issue iss-1)"
    tickets "iss-1:doing iss-2:review iss-3:todo iss-4:todo iss-5:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(tab_of_issue iss-1)" = "Todo" ]
    [ "$(tab_of_issue iss-2)" = "Review" ]
    [ "$(question_kinds)" = "move" ]
    run -0 herdr_linear::board_ledger_entry Board iss-1
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-todo', True)" ]
}

@test "AE5: an in-use pane and two movable panes bound for one tab: the two move, the in-use pane stays, one question" {
    config '{"tab":"project","column":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing iss-3:todo iss-4:todo iss-9:doing:beta"
    run -0 herdr_linear::board_sync
    consent
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Alpha"][0]')"
    p1="$(pane_of_issue iss-1)"; p2="$(pane_of_issue iss-2)"; p3="$(pane_of_issue iss-3)"; p4="$(pane_of_issue iss-4)"
    export HERDR_PANE_ID="$p2"
    seen="$(wc -l < "$FAKE_HERDR_RECORD_DIR/socket")"
    tickets "iss-1:review iss-2:qa iss-3:todo iss-4:review iss-9:doing:beta"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(question_kinds)" = "move" ]
    [ "$(tree_of "$tab")" = "right($p2,$p3,down($p1,$p4))" ]
    [ "$(tail -n +"$((seen + 1))" "$FAKE_HERDR_RECORD_DIR/socket" | grep -c "\"pane_id\": \"$p2\"")" = 0 ]
    [ "$(tail -n +"$((seen + 1))" "$FAKE_HERDR_RECORD_DIR/socket" | grep -c '"method": "pane.move"')" -gt 0 ]
    for i in 1 4; do
        run -0 herdr_linear::board_ledger_entry Board "iss-$i"
        [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-review', False)" ]
    done
    run -0 herdr_linear::board_ledger_entry Board iss-2
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-doing', True)" ]

    # Beta keeps Doing among the rendered columns, so the tab built around the
    # in-use pane has exactly the columns its ledger values name, in an order
    # that reads Todo as Review and Review as Doing. None of it is a move.
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(plan_actions)" = "move-question:iss-2" ]
    [ "$(issue_updates)" = 0 ]
}

@test "a pane in use whose column is unchanged stays put while another pane moves into its column, and the tab is rebuilt once it is free" {
    config '{"column":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:doing"
    run -0 herdr_linear::board_sync
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Board"][0]')"
    p1="$(pane_of_issue iss-1)"; p2="$(pane_of_issue iss-2)"; p3="$(pane_of_issue iss-3)"
    python3 "$FIX/fake-herdr-socket.py" set-agent "$p2" claude idle
    seen="$(wc -l < "$FAKE_HERDR_RECORD_DIR/socket")"
    tickets "iss-1:todo iss-2:todo iss-3:todo"
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    [[ "$output" != *unknown* ]]
    [ "$(tree_of "$tab")" = "right($p2,down($p1,$p3))" ]
    [ "$(tail -n +"$((seen + 1))" "$FAKE_HERDR_RECORD_DIR/socket" | grep -c "\"pane_id\": \"$p2\"")" = 0 ]
    [ "$(tail -n +"$((seen + 1))" "$FAKE_HERDR_RECORD_DIR/socket" | grep -c '"method": "pane.move"')" -gt 0 ]
    [ -z "$(question_kinds)" ]
    run -0 herdr_linear::board_ledger_entry Board iss-3
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-todo', False)" ]

    python3 "$FIX/fake-herdr-socket.py" set-agent "$p2" none
    run -0 herdr_linear::board_sync
    [ "$(tree_of "$tab")" = "down($p1,$p2,$p3)" ]
    run -0 herdr_linear::board_sync
    [ "$(plan_actions)" = "" ]
}

@test "a pane leaving a tab that also gains a pane is moved out before that tab is rebuilt" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo"
    run -0 herdr_linear::board_sync
    tickets "iss-1:doing iss-2:todo iss-3:todo"
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    [ "$(tab_of_issue iss-1)" = "Doing" ]
    [ "$(tab_of_issue iss-2)" = "Todo" ]
    [ "$(tab_of_issue iss-3)" = "Todo" ]
}

@test "two panes in use stacked in the column a pane moves into leave no room to build: the tab waits and the move is a question" {
    config '{"column":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:doing"
    run -0 herdr_linear::board_sync
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Board"][0]')"
    before="$(tree_of "$tab")"
    python3 "$FIX/fake-herdr-socket.py" set-agent "$(pane_of_issue iss-1)" claude idle
    python3 "$FIX/fake-herdr-socket.py" set-agent "$(pane_of_issue iss-2)" claude working
    tickets "iss-1:todo iss-2:todo iss-3:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [[ "$output" != *unknown* ]]
    [ "$(tree_of "$tab")" = "$before" ]
    [ "$(questions)" = "move:move-iss-3-$(printf '%s' Board | shasum | cut -c1-16)" ]
    run -0 herdr_linear::board_ledger_entry Board iss-3
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-doing', True)" ]
}

parking_tabs() { snap | field 'len([t for t in d["result"]["snapshot"]["tabs"] if t["label"] == "work:parking"])'; }

@test "two tabs that swap panes: each pane ends in the other tab, the ledger follows, and nothing is asked" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing"
    run -0 herdr_linear::board_sync
    tickets "iss-1:doing iss-2:todo"
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    [ "$(tab_of_issue iss-1)" = "Doing" ]
    [ "$(tab_of_issue iss-2)" = "Todo" ]
    [ -z "$(question_kinds)" ]
    [ "$(parking_tabs)" = 0 ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2" ]
    [ "$(ledger_json | field 'd["Board"]["iss-1"]["groups"]["state"], d["Board"]["iss-2"]["groups"]["state"]')" = "('st-doing', 'st-todo')" ]
    [ "$(ledger_json | field 'd["Board"]["iss-1"]["pane_id"]')" = "$(pane_of_issue iss-1)" ]
    run -0 herdr_linear::board_sync
    [ "$(plan_actions)" = "" ]
}

@test "a pane in use in a tab caught in a swap is never parked: the others swap and its move waits as a question" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing iss-3:todo"
    run -0 herdr_linear::board_sync
    p1="$(pane_of_issue iss-1)"
    export HERDR_PANE_ID="$p1"
    seen="$(wc -l < "$FAKE_HERDR_RECORD_DIR/socket")"
    tickets "iss-1:doing iss-2:todo iss-3:doing"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [[ "$output" != *unknown* ]]
    [ "$(question_kinds)" = "move" ]
    [ "$(tab_of_issue iss-1) $(tab_of_issue iss-2) $(tab_of_issue iss-3)" = "Todo Todo Doing" ]
    [ "$(tail -n +"$((seen + 1))" "$FAKE_HERDR_RECORD_DIR/socket" | grep -c "\"pane_id\": \"$p1\"")" = 0 ]
    [ "$(parking_tabs)" = 0 ]
}

@test "a sync killed right after parking the panes of a swap is re-run into the board and ledger of a clean run" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing"
    run -0 herdr_linear::board_sync
    cp -R "$HERDR_LINEAR_STORE_DIR" "$WORK/store-before"
    cp "$FAKE_HERDR_BOARD_STATE" "$WORK/state-before.json"
    tickets "iss-1:doing iss-2:todo"

    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    FAKE_HERDR_KILL_AFTER_MOVES=2 FAKE_HERDR_KILL_PGID_FILE="$WORK/pgid" serve
    run sync_in_own_group
    [ "$status" -eq 137 ]
    [ "$(parking_tabs)" = 1 ]

    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    serve
    run herdr_linear::board_sync
    [ "$status" -eq 0 ]
    interrupted_ledger="$(ledger_json)"
    interrupted_panes="$(board_panes)"
    [ "$(parking_tabs)" = 0 ]
    [ "$(tab_of_issue iss-1) $(tab_of_issue iss-2)" = "Doing Todo" ]
    [ -z "$(question_kinds)" ]

    kill "$SERVER_PID"; rm -f "$FAKE_HERDR_SOCKET_PATH"
    rm -rf "$HERDR_LINEAR_STORE_DIR" "$FAKE_HERDR_RECORD_DIR"; mkdir -p "$FAKE_HERDR_RECORD_DIR"
    cp -R "$WORK/store-before" "$HERDR_LINEAR_STORE_DIR"
    cp "$WORK/state-before.json" "$FAKE_HERDR_BOARD_STATE"
    serve
    run -0 herdr_linear::board_sync
    [ "$interrupted_panes" = "$(board_panes)" ]
    [ "$interrupted_ledger" = "$(ledger_json)" ]
}

@test "a tab build herdr still refuses becomes a layout question" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing"
    run -0 herdr_linear::board_sync
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Todo"][0]')"
    p1="$(pane_of_issue iss-1)"
    "$HERDR_BIN" pane split "$p1" --direction right --cwd "$WORK" --no-focus >/dev/null
    tickets "iss-1:todo iss-2:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(question_kinds)" = "layout" ]
    [ "$(tab_of_issue iss-2)" = "Doing" ]
}

@test "a tab a person rearranged off the grid is a layout question, and none of its panes is read as moved" {
    config '{"column":"state"}'
    empty_board; serve
    consent
    tickets "iss-1:todo iss-2:todo iss-3:doing"
    run -0 herdr_linear::board_sync
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Board"][0]')"
    p1="$(pane_of_issue iss-1)"; p2="$(pane_of_issue iss-2)"; p3="$(pane_of_issue iss-3)"
    python3 - "$FAKE_HERDR_BOARD_STATE" "$tab" "$p1" "$p2" "$p3" <<'PY2'
import json, sys
path, tab, p1, p2, p3 = sys.argv[1:]
st = json.load(open(path))
leaf = lambda p: {"type": "pane", "pane_id": p}
split = lambda d, a, b: {"type": "split", "direction": d, "ratio": 0.5, "first": a, "second": b}
st["trees"][tab] = split("down", split("right", leaf(p1), leaf(p3)), leaf(p2))
json.dump(st, open(path, "w"))
PY2
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(question_kinds)" = "layout" ]
    [[ "$(plan_actions)" != *write-back* ]]
    [[ "$(plan_actions)" != *move* ]]
    [ "$(issue_updates)" = 0 ]
}

@test "after an in-use move is deferred, a second sync with writes enabled sends no issueUpdate and plans no write-back for it" {
    config '{"column":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:doing iss-3:review iss-4:todo"
    run -0 herdr_linear::board_sync
    consent
    tab="$(snap | field '[t["tab_id"] for t in d["result"]["snapshot"]["tabs"] if t["label"] == "Board"][0]')"
    export HERDR_PANE_ID="$(pane_of_issue iss-1)"
    tickets "iss-1:doing iss-2:doing iss-3:review iss-4:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    # Linear goes back, and a person drags the pane into Review. Ledger and
    # Linear agree while herdr differs: without the pending change this is a
    # person's move and a write-back.
    tickets "iss-1:todo iss-2:doing iss-3:review iss-4:todo"
    unset HERDR_PANE_ID
    p1="$(pane_of_issue iss-1)"; p2="$(pane_of_issue iss-2)"; p3="$(pane_of_issue iss-3)"; p4="$(pane_of_issue iss-4)"
    [ "$(tree_of "$tab")" = "right(down($p1,$p4),$p2,$p3)" ]
    python3 - "$FAKE_HERDR_BOARD_STATE" "$tab" "$p4" "$p2" "$p3" "$p1" <<'PY'
import json, sys
path, tab, p4, p2, p3, p1 = sys.argv[1:]
st = json.load(open(path))
leaf = lambda p: {"type": "pane", "pane_id": p}
split = lambda d, a, b: {"type": "split", "direction": d, "ratio": 0.5, "first": a, "second": b}
st["trees"][tab] = split("right", leaf(p4), split("right", leaf(p2), split("down", leaf(p3), leaf(p1))))
json.dump(st, open(path, "w"))
PY
    herdr_linear::board_sync >/dev/null || true
    [[ "$(plan_actions)" == *"move:iss-1"* ]]
    [[ "$(plan_actions)" != *"write-back-candidate:iss-1"* ]]
    [ "$(issue_updates)" = 0 ]
}

# ---------------------------------------------------------------- refusals and limits

@test "a refused configuration exits with its own code and a sync state that names the refusal, not zero changes" {
    config '{"tab":"state"}'
    empty_board; serve
    chmod 666 "$HERDR_LINEAR_STORE_DIR/board.json"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_REFUSED" ]
    run -0 herdr_linear::board_sync_state
    [ "$(printf '%s' "$output" | field 'd["last_failure"]["stage"]')" = "configuration" ]
    [ "$(printf '%s' "$output" | field '"observed" in d')" = "False" ]
    [[ "$(herdr_linear::board_sync_title "$output")" == *"failed at configuration"* ]]
    [ ! -e "$FAKE_BOARD_LINEAR_DIR/bodies" ]
}

@test "no board configuration is a no-op that writes nothing" {
    empty_board; serve
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_NO_BOARD" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board" ]
    [ ! -e "$FAKE_BOARD_LINEAR_DIR/bodies" ]
}

@test "a filter matching more tickets than the cap places the cap and records one question for the rest" {
    export HERDR_LINEAR_BOARD_PANE_CAP=3
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo iss-5:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3" ]
    [ "$(question_kinds)" = "cap" ]
    run -0 herdr_linear::board_question cap-surplus
    [[ "$(printf '%s' "$output" | field 'd["preconditions"]')" == *'"issues":["iss-4","iss-5"]'* ]]
}

@test "an incomplete read closes nothing, asks nothing about leaving, and says so in the sync state" {
    five_on_the_board
    tickets "iss-1:todo iss-2:todo"
    touch "$FAKE_BOARD_LINEAR_DIR/incomplete"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_INCOMPLETE" ]
    [[ "$(question_kinds)" != *close* ]]
    [[ "$(plan_actions)" != *forget* ]]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4,work:iss-5" ]
    run -0 herdr_linear::board_sync_state
    [ "$(printf '%s' "$output" | field 'd["last_failure"]["stage"]')" = "linear read" ]
}

@test "right after a herdr restart every pane is in use: a Linear change becomes a question, not a move" {
    five_on_the_board
    python3 "$FIX/fake-herdr-socket.py" restart
    tickets "iss-1:doing iss-2:todo iss-3:todo iss-4:todo iss-5:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(tab_of_issue iss-1)" = "Todo" ]
    [ "$(question_kinds)" = "move" ]
    run -0 herdr_linear::board_ledger_entry Board iss-1
    [[ "$(printf '%s' "$output" | field 'd["terminal_id"]')" == term-r* ]]
}

@test "a pane herdr knows by neither its id nor its terminal is found by its label: relinked, not hidden, not placed again" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo"
    run -0 herdr_linear::board_sync
    p1="$(pane_of_issue iss-1)"
    python3 - "$FAKE_HERDR_BOARD_STATE" "$p1" <<'PY2'
import json, sys
path, old = sys.argv[1:]
st = json.load(open(path))
def rename(n):
    if n.get("type") == "pane" and n["pane_id"] == old:
        n["pane_id"] = "w1:p77"
    for k in ("first", "second"):
        if k in n:
            rename(n[k])
for t in st["trees"].values():
    rename(t)
for p in st["panes"]:
    if p["pane_id"] == old:
        p["pane_id"], p["terminal_id"] = "w1:p77", "term-new"
json.dump(st, open(path, "w"))
PY2
    run -0 herdr_linear::board_sync
    [ "$(plan_actions)" = "relink:iss-1" ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2" ]
    run -0 herdr_linear::board_ledger_entry Board iss-1
    [ "$(printf '%s' "$output" | field 'd["pane_id"], d["terminal_id"], d["hidden"]')" = "('w1:p77', 'term-new', False)" ]
    run -0 herdr_linear::board_sync
    [ "$(plan_actions)" = "" ]
}

@test "AE8: a Linear project change moves the pane to the project's space and records no misplaced state" {
    config '{"space":"project"}'
    python3 "$FIX/fake-herdr-socket.py" seed '{"focused":"w9:p9",
      "workspaces":[{"workspace_id":"w1","label":"Alpha"},{"workspace_id":"w2","label":"Beta"},{"workspace_id":"w9","label":"Scratch"}],
      "tabs":[{"tab_id":"w9:t1","label":"shell","tree":"w9:p9"}],"panes":{}}'
    serve
    tickets "iss-1:todo:alpha iss-2:todo:alpha iss-3:todo:beta"
    run -0 herdr_linear::board_sync
    tickets "iss-1:todo:beta iss-2:todo:alpha iss-3:todo:beta"
    run -0 herdr_linear::board_sync
    ws_of() { snap | field "[p['workspace_id'] for p in d['result']['snapshot']['panes'] if p.get('label') == 'work:$1'][0]"; }
    [ "$(ws_of iss-1)" = w2 ]
    [ "$(ws_of iss-2)" = w1 ]
    ledger="$(ledger_json)"
    [ "$(printf '%s' "$ledger" | field 'sorted(d["Beta"]), sorted(d["Alpha"])')" = "(['iss-1', 'iss-3'], ['iss-2'])" ]
    [ "$(printf '%s' "$ledger" | field 'd["Beta"]["iss-1"]["pane_id"]')" = "$(pane_of_issue iss-1)" ]
    [ "$(printf '%s' "$ledger" | field 'd["Beta"]["iss-1"]["pending_linear_change"]')" = "False" ]
    run grep -rl misplaced "$HERDR_LINEAR_STORE_DIR"
    [ -z "$output" ]
    run -0 herdr_linear::board_sync
    [[ "$(plan_actions)" == "" ]]
}

# ---------------------------------------------------------------- the lock

@test "two syncs started together: one waits for the other, and the board and ledger come out as one sync's" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:todo"
    herdr_linear::board_sync > "$WORK/a.out" 2>&1 & a=$!
    herdr_linear::board_sync > "$WORK/b.out" 2>&1 & b=$!
    BG_PIDS="$a $b"
    wait "$a"; ra=$?
    wait "$b"; rb=$?
    [ "$ra" -eq 0 ]
    [ "$rb" -eq 0 ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3" ]
    [ "$(ledger_json | field 'sorted(d["Board"])')" = "['iss-1', 'iss-2', 'iss-3']" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/sync.lock" ]
}

@test "a lock held by a live process is refused however old, and nothing is read" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    sleep 60 & holder=$!
    BG_PIDS="$holder"
    printf '%s\n' "$holder" > "$HERDR_LINEAR_STORE_DIR/board/sync.lock/pid"
    touch -t 202001010000 "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=1
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_LOCKED" ]
    [ ! -e "$FAKE_BOARD_LINEAR_DIR/bodies" ]
    [ "$(cat "$HERDR_LINEAR_STORE_DIR/board/sync.lock/pid")" = "$holder" ]
}

@test "a lock left by a process that is no longer running is taken by the next sync" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    sh -c ':' & gone=$!
    wait "$gone"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    printf '%s\n' "$gone" > "$HERDR_LINEAR_STORE_DIR/board/sync.lock/pid"
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=1
    run -0 herdr_linear::board_sync
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/sync.lock" ]
}

@test "a lock with no holder recorded is waited for while it is fresh, and taken once it is old" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=1
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_LOCKED" ]
    touch -t 202001010000 "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    run -0 herdr_linear::board_sync
    [ ! -e "$HERDR_LINEAR_STORE_DIR/board/sync.lock" ]
}

@test "a journal another user could have written is refused before anything is read or moved" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board"
    printf '{"version":1,"intents":{}}' > "$HERDR_LINEAR_STORE_DIR/board/journal.json"
    chmod 666 "$HERDR_LINEAR_STORE_DIR/board/journal.json"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_FAILED" ]
    run -0 herdr_linear::board_sync_state
    [ "$(printf '%s' "$output" | field 'd["last_failure"]["stage"]')" = "journal" ]
    [ -z "$(board_panes | tr -d "[]' ")" ]
    [ ! -e "$FAKE_BOARD_LINEAR_DIR/bodies" ]
}

@test "a held-tab record another user could have written is refused, not read" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board"
    printf '{"version":1,"tabs":[]}' > "$HERDR_LINEAR_STORE_DIR/board/held-tabs.json"
    chmod 666 "$HERDR_LINEAR_STORE_DIR/board/held-tabs.json"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_FAILED" ]
    run -0 herdr_linear::board_sync_state
    [ "$(printf '%s' "$output" | field 'd["last_failure"]["stage"]')" = "held tabs" ]
}

# ---------------------------------------------------------------- boundaries

@test "the sync never calls a verb that asks or closes" {
    run grep -nE 'board_(close_pane|move_in_use|apply_tab_in_use)|board_config_set' "$LIB/board-sync.sh"
    [ "$status" -eq 1 ]
}

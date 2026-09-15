#!/usr/bin/env bats

load setup_common

# U10 — the attended half: the fence every /work skill runs first, and the
# answer verb that applies a person's answer to a board question. As U8: herdr is the fake board (a state file edited by the
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
    # Most scenarios stack more than the default soft limit in one tab.
    export HERDR_LINEAR_BOARD_TAB_LIMIT=16
    # A loaded machine runs an answer's sync slowly; only the time-bound test lowers it.
    export HERDR_LINEAR_BOARD_FENCE_SECONDS=300
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

    for f in herdr-read.sh board-store.sh board-herdr.sh board-sync.sh board-attended.sh; do
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


q_of_kind() {
    herdr_linear::board_questions_pending | python3 -c 'import sys,json
for l in sys.stdin:
    d = json.loads(l)
    if d["kind"] == sys.argv[1]: print(d["key"], d["nonce"])' "$1"
}

# ---------------------------------------------------------------- the fence

@test "R8: with no board configured the fence prints nothing and reads nothing" {
    run herdr_linear::board_fence
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_BOARD_LINEAR_DIR/bodies" ]
}

@test "the fence syncs, reports the outcome, and lists each waiting question" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_fence
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "board: board sync:"*"1 question waiting"* ]]
    [[ "$output" == *'board question: {'*'"kind": "close"'* ]]
}

@test "a sync past the fence's time bound is stopped and reported, and the fence still returns 0" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    export HERDR_LINEAR_BOARD_FENCE_SECONDS=1 FAKE_HERDR_SLOW_PANE=5
    run herdr_linear::board_fence
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"did not finish within 1s"* ]]
}

@test "a sync held off by another sync's lock is reported, and the fence still returns 0" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=1
    sleep 60 & BG_PIDS="$BG_PIDS $!"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/board/sync.lock"
    printf '%s' "${BG_PIDS##* }" > "$HERDR_LINEAR_STORE_DIR/board/sync.lock/pid"
    run herdr_linear::board_fence
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "board: another sync is running"* ]]
}

# ---------------------------------------------------------------- answers

@test "an answer without the question's nonce changes nothing" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    read -r key nonce < <(q_of_kind close)
    run herdr_linear::board_answer "$key" wrong-nonce yes
    [ "$status" -eq 2 ]
    [[ "$(board_panes)" == *"work:iss-5"* ]]
    [ "$(question_kinds)" = "close" ]
}

@test "AE7: a close answered yes closes the pane and forgets the ticket" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    read -r key nonce < <(q_of_kind close)
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 0 ]
    [[ "$(board_panes)" != *"work:iss-5"* ]]
    run herdr_linear::board_ledger_entry Board iss-5
    [ "$status" -ne 0 ]
    [ -z "$(question_kinds)" ]
}

@test "AE7: a close whose ticket has a worktree records the removal question and removes nothing" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    wt="$HERDR_LINEAR_WORKTREES_ROOT/web/$(herdr_linear::board_reservation_field iss-5 worktree_name)"
    git -C "$WORK/repo" init -q -b main
    git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    mkdir -p "${wt%/*}"
    git -C "$WORK/repo" worktree add -q -b "$(herdr_linear::board_reservation_field iss-5 branch)" "$wt"
    n="$(herdr_linear::binding_propose "$wt" WEB-5)"; herdr_linear::binding_confirm "$wt" WEB-5 "$n"
    herdr_linear::board_reservation_start iss-5
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    read -r key nonce < <(q_of_kind close)
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 0 ]
    [[ "$output" == 'board question: {'*'"kind": "remove-worktree"'* ]]
    [ -d "$wt" ]
    [ "$(question_kinds)" = "remove-worktree" ]
}

@test "a close whose pane changed since it was asked is refused and closes nothing" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    read -r key nonce < <(q_of_kind close)
    herdr_linear::board_ledger_set_pane Board iss-5 "$(pane_of_issue iss-4)"
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 2 ]
    [[ "$output" == *"no longer the one asked about"* ]]
    [[ "$(board_panes)" == *"work:iss-5"* ]]
}

@test "a close declined is not asked again and the pane stays" {
    five_on_the_board
    export HERDR_PANE_ID=w9:p9
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo"
    run herdr_linear::board_sync
    read -r key nonce < <(q_of_kind close)
    run herdr_linear::board_answer "$key" "$nonce" no
    [ "$status" -eq 0 ]
    run herdr_linear::board_sync
    [ -z "$(question_kinds)" ]
    [[ "$(board_panes)" == *"work:iss-5"* ]]
}

@test "a move in use answered yes moves that pane and no other pane in use" {
    five_on_the_board
    export HERDR_PANE_ID="$(pane_of_issue iss-1)"
    python3 "$FIX/fake-herdr-socket.py" set-agent "$(pane_of_issue iss-1)" claude working
    python3 "$FIX/fake-herdr-socket.py" set-agent "$(pane_of_issue iss-3)" claude working
    tickets "iss-1:doing iss-2:todo iss-3:doing iss-4:todo iss-5:todo"
    run herdr_linear::board_sync
    [ "$(tab_of_issue iss-1)" = "Todo" ]
    read -r key nonce < <(herdr_linear::board_questions_pending | python3 -c 'import sys,json
for l in sys.stdin:
    d = json.loads(l)
    if d["kind"] == "move" and json.loads(d["preconditions"])["issue"] == "iss-1": print(d["key"], d["nonce"])')
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 0 ]
    [ "$(tab_of_issue iss-1)" = "Doing" ]
    [ "$(tab_of_issue iss-3)" = "Todo" ]
    run herdr_linear::board_ledger_entry Board iss-1
    [ "$(printf '%s' "$output" | field 'd["groups"]["state"], d["pending_linear_change"]')" = "('st-doing', False)" ]
}

@test "the first write-back of a field answered yes records consent for that field only" {
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo"
    herdr_linear::board_question_propose "write-consent-x" write-consent '{"field":"state","space":"Board"}' >/dev/null
    read -r key nonce < <(q_of_kind write-consent)
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 0 ]
    herdr_linear::board_consent_covers Board state
    run herdr_linear::board_consent_covers Board assignee
    [ "$status" -ne 0 ]
    [ -z "$(question_kinds)" ]
}

@test "AE4: a repository answer is recorded for the scope, and a repository answer with no path is refused" {
    config '{"tab":"state"}'
    herdr_linear::board_question_propose "repository-project-prj-beta" repository '{"scope":"project-prj-beta"}' >/dev/null
    read -r key nonce < <(q_of_kind repository)
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 2 ]
    mkdir -p "$WORK/beta"
    run herdr_linear::board_answer "$key" "$nonce" yes "$WORK/beta"
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::scope_repo project-prj-beta)" = "$WORK/beta" ]
}

@test "a tab holds four panes until more are asked for; placing more adds exactly those, and they stay" {
    export HERDR_LINEAR_BOARD_TAB_LIMIT=4
    config '{"tab":"state"}'
    empty_board; serve
    tickets "iss-1:todo iss-2:todo iss-3:todo iss-4:todo iss-5:todo iss-6:todo"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4" ]
    run herdr_linear::board_sync
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4" ]
    read -r key nonce < <(q_of_kind cap)
    run herdr_linear::board_answer "$key" "$nonce" yes
    [ "$status" -eq 0 ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4,work:iss-5,work:iss-6" ]
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_CLEAN" ]
    [ "$(board_panes | tr -d "[]' ")" = "work:iss-1,work:iss-2,work:iss-3,work:iss-4,work:iss-5,work:iss-6" ]
}

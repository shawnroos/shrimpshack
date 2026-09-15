#!/usr/bin/env bats

load setup_common

# U9 — write-back from herdr moves. herdr is the fake board; Linear is a curl
# stub that answers the board read from a ticket file, records every request
# body, and applies an issueUpdate to that file only when the test permits a
# mutation, so "the next sync confirms placement" reads a Linear that changed.

bats_require_minimum_version 1.5.0

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    # Short on purpose: a Unix socket path over 104 bytes cannot be bound on macOS.
    WORK="$(mktemp -d /tmp/bw.XXXXXX)"
    WORK="$(cd "$WORK" && pwd -P)"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_BOARD_STATE="$WORK/state.json"
    export FAKE_HERDR_SOCKET_PATH="$WORK/h.sock"
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=5
    export HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS=20
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/rec" "$WORK/linear" "$HERDR_LINEAR_WORKTREES_ROOT" "$HERDR_LINEAR_STORE_DIR"

    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export HERDR_LINEAR_RETRY_MAX=1
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_WRITEWRITEWRITEWRITE" > "$LINEAR_SECRETS_FILE"
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
import json, os
d = os.environ["FAKE_BOARD_LINEAR_DIR"]
nodes = json.load(open(os.path.join(d, "tickets.json")))
more = os.path.exists(os.path.join(d, "incomplete"))
print(json.dumps({"data": {"issues": {"nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": None}}}}))' ;;
    *mutation*issueUpdate*)
        [ "${FAKE_LINEAR_ALLOW_MUTATION:-0}" = 1 ] || { printf 'unpermitted mutation\n' >&2; exit 97; }
        if [ "${FAKE_LINEAR_MUTATION_RESULT:-ok}" = fail ]; then
            printf '{"data":{"issueUpdate":{"success":false}}}\n'; exit 0
        fi
        [ "${FAKE_LINEAR_MUTATION_RESULT:-ok}" = down ] && exit 7
        python3 -c '
import json, os, sys
d = os.environ["FAKE_BOARD_LINEAR_DIR"]
v = json.loads(sys.argv[1])["variables"]
path = os.path.join(d, "tickets.json")
nodes = json.load(open(path))
people = {"u-ann": "Ann", "u-bob": "Bob"}
for t in nodes:
    if t["id"] != v["id"]:
        continue
    inp = v["input"]
    if "assigneeId" in inp:
        t["assignee"] = None if inp["assigneeId"] is None else {"id": inp["assigneeId"], "name": people[inp["assigneeId"]]}
    if "parentId" in inp:
        t["parent"] = None if inp["parentId"] is None else {"id": inp["parentId"], "identifier": "WEB-" + inp["parentId"].split("-")[-1]}
    labels = [l for l in t["labels"]["nodes"] if l["id"] not in inp.get("removedLabelIds", [])]
    for l in inp.get("addedLabelIds", []):
        labels.append({"id": l, "name": l.split("-")[-1].title(), "parent": {"id": "lg-kind", "name": "Kind"}})
    t["labels"]["nodes"] = labels
json.dump(nodes, open(path, "w"))
print(json.dumps({"data": {"issueUpdate": {"success": True}}}))' "$body" ;;
    *) printf '{"errors":[{"message":"not a board call","extensions":{"code":"INPUT_ERROR"}}]}\n' ;;
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
}

teardown() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
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

# config <global-levels-json> [spaces-json]
config() {
    printf '{"version":1,"global":{"levels":%s,"filter":{"team":["WEB"]}},"spaces":%s}\n' "$1" "${2:-{\}}" \
        > "$HERDR_LINEAR_STORE_DIR/board.json"
    chmod 600 "$HERDR_LINEAR_STORE_DIR/board.json"
}

board() {
    python3 "$FIX/fake-herdr-socket.py" seed '{"focused":"w9:p9",
      "workspaces":[{"workspace_id":"w1","label":"Board"},{"workspace_id":"w2","label":"Mine"},
                    {"workspace_id":"w9","label":"Scratch"}],
      "tabs":[{"tab_id":"w9:t1","label":"shell","tree":"w9:p9"}],"panes":{}}'
    serve
}

# tickets "iss-1:a=u-ann:p=iss-9:l=lb-bug ..." -- a assignee, p parent, l a label
# in the Kind group. Every ticket is in team WEB, state Todo.
tickets() {
    python3 - "$FAKE_BOARD_LINEAR_DIR/tickets.json" "$*" <<'PY'
import json, sys
people = {"u-ann": "Ann", "u-bob": "Bob"}
out = []
for spec in sys.argv[2].split():
    parts = spec.split(":")
    issue, attrs = parts[0], dict(p.split("=", 1) for p in parts[1:])
    t = {"id": issue, "identifier": "WEB-%s" % issue.split("-")[-1], "title": "Ticket %s" % issue,
         "updatedAt": "2026-09-15T10:00:00.000Z",
         "state": {"id": "st-todo", "name": "Todo", "type": "unstarted"},
         "team": {"id": "team-web", "key": "WEB"}, "project": None,
         "projectMilestone": None, "cycle": None, "assignee": None, "priority": 0,
         "parent": None, "labels": {"nodes": []}}
    if "a" in attrs:
        t["assignee"] = {"id": attrs["a"], "name": people[attrs["a"]]}
    if "p" in attrs:
        t["parent"] = {"id": attrs["p"], "identifier": "WEB-%s" % attrs["p"].split("-")[-1]}
    if "l" in attrs:
        t["labels"]["nodes"].append({"id": attrs["l"], "name": attrs["l"].split("-")[-1].title(),
                                     "parent": {"id": "lg-kind", "name": "Kind"}})
    out.append(t)
json.dump(out, open(sys.argv[1], "w"))
PY
}

snap() { "$HERDR_BIN" api snapshot; }

field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

pane_of() {
    snap | field "[p['pane_id'] for p in d['result']['snapshot']['panes'] if p.get('label') == '$1'][0]"
}

tab_id() {
    snap | field "[t['tab_id'] for t in d['result']['snapshot']['tabs'] if t['label'] == '$1' and t['workspace_id'] == '${2:-w1}'][0]"
}

tab_of() {
    snap | field "[t['label'] for t in d['result']['snapshot']['tabs'] for p in d['result']['snapshot']['panes'] if p.get('label') == '$1' and p['tab_id'] == t['tab_id']][0]"
}

# columns <tab-id>: the tab's columns as pane labels, "a b | c".
columns() {
    local ids
    ids="$(herdr_linear::board_tab_columns "$1")" || return 1
    printf '%s' "$ids" | python3 -c '
import json, subprocess, sys, os
snap = json.loads(subprocess.run([os.environ["HERDR_BIN"], "api", "snapshot"], capture_output=True, text=True).stdout)
label = {p["pane_id"]: p.get("label") for p in snap["result"]["snapshot"]["panes"]}
print(" | ".join(" ".join(sorted(label[p] for p in col)) for col in json.load(sys.stdin)))'
}

# rearrange <tab-id> "<label> <label>" "<label>" ...: a person drags the panes
# into these columns.
rearrange() {
    local tab="$1"; shift
    python3 - "$FAKE_HERDR_BOARD_STATE" "$tab" "$@" <<'PY'
import json, sys
path, tab, cols = sys.argv[1], sys.argv[2], sys.argv[3:]
st = json.load(open(path))
ids = {p.get("label"): p["pane_id"] for p in st["panes"]}
leaf = lambda p: {"type": "pane", "pane_id": p}
def chain(nodes, d):
    return nodes[0] if len(nodes) == 1 else {"type": "split", "direction": d, "ratio": 0.5,
                                               "first": nodes[0], "second": chain(nodes[1:], d)}
st["trees"][tab] = chain([chain([leaf(ids[l]) for l in c.split()], "down") for c in cols], "right")
json.dump(st, open(path, "w"))
PY
}

consent() {
    local nonce
    nonce="$(herdr_linear::board_consent_propose "$1" "$2")"
    herdr_linear::board_consent_confirm "$1" "$2" "$nonce"
}

issue_updates() { cat "$FAKE_BOARD_LINEAR_DIR/bodies" 2>/dev/null | grep -c 'issueUpdate' || true; }

update_input() { grep 'issueUpdate' "$FAKE_BOARD_LINEAR_DIR/bodies" | field 'json.dumps(d["variables"], sort_keys=True)'; }

plan_actions() {
    python3 -c 'import sys,json; p=json.load(open(sys.argv[1])); print(" ".join(sorted("%s:%s" % (a["kind"], a["issue_id"]) for a in p["actions"])))' \
        "$HERDR_LINEAR_STORE_DIR/board/last-plan.json"
}

groups() { herdr_linear::board_ledger_entry "$1" "$2" | field "d['groups'].get('$3'), d['pending_linear_change']"; }

shadow_lines() { cat "$HERDR_LINEAR_SHADOW_LOG" 2>/dev/null | grep -c 'SHADOW' || true; }

question_keys() {
    herdr_linear::board_questions_pending | python3 -c 'import sys,json; print(" ".join(sorted(json.loads(l)["kind"] for l in sys.stdin if l.strip())))'
}

# Rewrites the last complete sync's record through the store verb, as a sync
# that saw another read would have left it.
record_sync() {
    local doc
    doc="$(herdr_linear::board_sync_state | python3 -c '
import json, sys
rec, drop_member, space, fld, drop_value = json.load(sys.stdin), sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rendered = rec["rendered"]
if fld:
    rendered[space][fld] = [v for v in rendered[space][fld] if v != drop_value]
print(json.dumps({"observed": {}, "unknown": {}, "pending_questions": 0,
                  "members": [m for m in rec["members"] if m != drop_member], "rendered": rendered}))' "$@")"
    herdr_linear::board_sync_complete "$doc"
}

# Ann's column holds iss-1 and iss-2, Bob's holds iss-3.
two_assignees() {
    config '{"column":"assignee"}'
    board
    tickets "iss-1:a=u-ann iss-2:a=u-ann iss-3:a=u-bob"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
}

# ---------------------------------------------------------------- shadow mode

@test "AE6: in shadow mode a moved pane sends no issueUpdate and is restored" {
    two_assignees
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    [ "$(groups Board iss-2 assignee)" = "('u-ann', False)" ]
    [ "$(shadow_lines)" = 1 ]
    grep -q 'SHADOW board would set "assignee" to "u-bob" on "iss-2" in "Board": no consent for this field in this space$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(question_keys)" = "write-consent" ]

    # Consent given later does not replay the move.
    consent Board assignee
    herdr_linear::board_question_drop "$(herdr_linear::board_questions_pending | field 'd["key"]')"
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
}

@test "moves of two tickets across one unconsented field record one consent question" {
    config '{"column":"assignee"}'
    board
    tickets "iss-1:a=u-ann iss-2:a=u-ann iss-3:a=u-bob iss-4:a=u-bob"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    rearrange "$TAB" "work:iss-1 work:iss-4" "work:iss-3 work:iss-2"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(question_keys)" = "write-consent" ]
    run -0 herdr_linear::board_questions_pending
    [ "$(printf '%s' "$output" | field 'json.loads(d["preconditions"])')" = "{'field': 'assignee', 'space': 'Board'}" ]
    [ "$(shadow_lines)" = 2 ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3 work:iss-4" ]
}

# ---------------------------------------------------------------- consented writes

@test "with space consent, a move into another assignee's column writes assigneeId and the next sync confirms placement" {
    two_assignees
    consent Board assignee
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(update_input)" = '{"id": "iss-2", "input": {"assigneeId": "u-bob"}}' ]
    [ "$(columns "$TAB")" = "work:iss-1 | work:iss-2 work:iss-3" ]
    [ "$(groups Board iss-2 assignee)" = "('u-bob', False)" ]
    [ "$(shadow_lines)" = 0 ]
    run -0 herdr_linear::board_sync_state
    [ -n "$(printf '%s' "$output" | field 'd["last_plugin_write_at"]')" ]

    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(plan_actions)" = "" ]
    [ "$(columns "$TAB")" = "work:iss-1 | work:iss-2 work:iss-3" ]
}

@test "a move into No assignee sends a null assignee, and the next sync confirms placement" {
    config '{"column":"assignee"}'
    board
    tickets "iss-1:a=u-ann iss-2:a=u-ann iss-3"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    consent Board assignee
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run -0 herdr_linear::board_sync
    [ "$(update_input)" = '{"id": "iss-2", "input": {"assigneeId": null}}' ]
    [ "$(groups Board iss-2 assignee)" = "(None, False)" ]
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(plan_actions)" = "" ]
    [ "$(columns "$TAB")" = "work:iss-1 | work:iss-2 work:iss-3" ]
}

@test "a move across label groups adds the new label and removes the old one" {
    config '{"column":"label-group:Kind"}'
    board
    tickets "iss-1:l=lb-bug iss-2:l=lb-bug iss-3:l=lb-chore"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    consent Board label-group:Kind
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run -0 herdr_linear::board_sync
    [ "$(update_input)" = '{"id": "iss-2", "input": {"addedLabelIds": ["lb-chore"], "removedLabelIds": ["lb-bug"]}}' ]
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(plan_actions)" = "" ]
}

@test "a write Linear rejects restores the pane, records one question, and is never sent again" {
    two_assignees
    consent Board assignee
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    FAKE_LINEAR_MUTATION_RESULT=fail run herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    [ "$(groups Board iss-2 assignee)" = "('u-ann', False)" ]
    [ "$(shadow_lines)" = 1 ]
    grep -q 'SHADOW board did not set "assignee" to "u-bob" on "iss-2" in "Board": Linear rejected the write$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(question_keys)" = "write-rejected" ]
    run -0 herdr_linear::board_questions_pending
    [ "$(printf '%s' "$output" | field 'json.loads(d["preconditions"])')" = "{'field': 'assignee', 'issue': 'iss-2', 'space': 'Board', 'target': 'u-bob'}" ]

    FAKE_LINEAR_MUTATION_RESULT=fail run herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    [ "$(shadow_lines)" = 1 ]
}

@test "a write that cannot reach Linear restores the pane, records one question, and is never sent again" {
    two_assignees
    consent Board assignee
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    FAKE_LINEAR_MUTATION_RESULT=down run herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_QUESTIONS" ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    grep -q 'SHADOW board did not set "assignee" to "u-bob" on "iss-2" in "Board": the Linear request failed with code [0-9]*$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(question_keys)" = "write-rejected" ]

    run herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(groups Board iss-2 assignee)" = "('u-ann', False)" ]
}

@test "an incomplete Linear read writes nothing and moves nothing back" {
    two_assignees
    consent Board assignee
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    touch "$FAKE_BOARD_LINEAR_DIR/incomplete"
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_INCOMPLETE" ]
    [ "$(issue_updates)" = 0 ]
    [ "$(columns "$TAB")" = "work:iss-1 | work:iss-2 work:iss-3" ]
    [ "$(groups Board iss-2 assignee)" = "('u-ann', False)" ]
}

@test "an unconsented move on an incomplete Linear read is still restored and asked about" {
    two_assignees
    rearrange "$TAB" "work:iss-1" "work:iss-3 work:iss-2"
    touch "$FAKE_BOARD_LINEAR_DIR/incomplete"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::board_sync
    [ "$status" -eq "$HERDR_LINEAR_BOARD_SYNC_INCOMPLETE" ]
    [ "$(issue_updates)" = 0 ]
    [ "$(columns "$TAB")" = "work:iss-1 work:iss-2 | work:iss-3" ]
    [ "$(shadow_lines)" = 1 ]
    [ "$(question_keys)" = "write-consent" ]
}

# ---------------------------------------------------------------- the write bound

three_parents() {
    config '{"column":"parent"}'
    board
    # Columns: WEB-1 (iss-3 iss-4), WEB-2 (iss-5), No parent (iss-1 iss-2).
    tickets "iss-1 iss-2 iss-3:p=iss-1 iss-4:p=iss-1 iss-5:p=iss-2"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    [ "$(columns "$TAB")" = "work:iss-3 work:iss-4 | work:iss-5 | work:iss-1 work:iss-2" ]
    consent Board parent
    rearrange "$TAB" "work:iss-3" "work:iss-5 work:iss-4" "work:iss-1 work:iss-2"
    export FAKE_LINEAR_ALLOW_MUTATION=1
}

@test "a move into a parent ticket's column writes parentId for a ticket in the last complete read" {
    three_parents
    run -0 herdr_linear::board_sync
    [ "$(update_input)" = '{"id": "iss-4", "input": {"parentId": "iss-2"}}' ]
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 1 ]
    [ "$(columns "$TAB")" = "work:iss-3 | work:iss-4 work:iss-5 | work:iss-1 work:iss-2" ]
}

@test "a move into a parent ticket's column is refused for a ticket outside the last complete read" {
    three_parents
    record_sync iss-4 "" "" ""
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    grep -q '"iss-4" in "Board": ticket is not in the last complete filter read$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(columns "$TAB")" = "work:iss-3 work:iss-4 | work:iss-5 | work:iss-1 work:iss-2" ]
}

@test "a move into a group the board did not render is refused" {
    config '{"tab":"assignee"}'
    board
    tickets "iss-1:a=u-ann iss-2:a=u-ann iss-3:a=u-bob"
    run -0 herdr_linear::board_sync
    consent Board assignee
    # The last complete sync rendered no Bob tab; this one does.
    record_sync "" Board assignee u-bob
    "$HERDR_BIN" pane move "$(pane_of work:iss-2)" --tab "$(tab_id Bob)" --no-focus >/dev/null
    [ "$(tab_of work:iss-2)" = Bob ]
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    grep -q 'SHADOW board would set "assignee" to "u-bob" on "iss-2" in "Board": target group was not rendered by the board$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(tab_of work:iss-2)" = Ann ]
    [ "$(groups Board iss-2 assignee)" = "('u-ann', False)" ]
}

sub_tickets() {
    config '{"column":"parent"}'
    board
    # Columns: WEB-1 (iss-2), WEB-2 (iss-3), WEB-3 (iss-4), WEB-9 (iss-8), No parent (iss-1 iss-9).
    tickets "iss-1 iss-2:p=iss-1 iss-3:p=iss-2 iss-4:p=iss-3 iss-9 iss-8:p=iss-9"
    run -0 herdr_linear::board_sync
    TAB="$(tab_id Board)"
    [ "$(columns "$TAB")" = "work:iss-2 | work:iss-3 | work:iss-4 | work:iss-8 | work:iss-1 work:iss-9" ]
    consent Board parent
    export FAKE_LINEAR_ALLOW_MUTATION=1
}

@test "a move under one of the ticket's own sub-tickets writes nothing and is refused" {
    sub_tickets
    rearrange "$TAB" "work:iss-2" "work:iss-3" "work:iss-4 work:iss-1" "work:iss-8" "work:iss-9"
    run herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    grep -q 'SHADOW board would set "parent" to "iss-3" on "iss-1" in "Board": the target is the ticket itself or one of its sub-tickets$' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(shadow_lines)" = 1 ]
    [ "$(columns "$TAB")" = "work:iss-2 | work:iss-3 | work:iss-4 | work:iss-8 | work:iss-1 work:iss-9" ]
}

@test "a move under the ticket's own column writes nothing and is refused" {
    sub_tickets
    rearrange "$TAB" "work:iss-2 work:iss-1" "work:iss-3" "work:iss-4" "work:iss-8" "work:iss-9"
    run herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    grep -q 'SHADOW board would set "parent" to "iss-1" on "iss-1" in "Board": the target is the ticket itself' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$(columns "$TAB")" = "work:iss-2 | work:iss-3 | work:iss-4 | work:iss-8 | work:iss-1 work:iss-9" ]
}

@test "a move of a pointer pane writes nothing" {
    config '{"column":"assignee"}' '{"Mine":{"levels":{"column":"assignee"},"filter":{"assignee":"me"}}}'
    board
    tickets "iss-1:a=u-ann iss-2:a=u-ann iss-3:a=u-bob"
    run -0 herdr_linear::board_sync
    MINE="$(tab_id Board w2)"
    key="$(printf 'Mine' | shasum | cut -c1-16)"
    [ "$(columns "$MINE")" = "work:iss-1:pointer:$key work:iss-2:pointer:$key | work:iss-3:pointer:$key" ]
    consent Mine assignee
    consent Board assignee
    rearrange "$MINE" "work:iss-1:pointer:$key" "work:iss-3:pointer:$key work:iss-2:pointer:$key"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run -0 herdr_linear::board_sync
    [ "$(issue_updates)" = 0 ]
    [ "$(columns "$MINE")" = "work:iss-1:pointer:$key work:iss-2:pointer:$key | work:iss-3:pointer:$key" ]
}

# ---------------------------------------------------------------- the verb

@test "a write-back names no field for a ticket level and sends nothing" {
    # Consent and a sync record that would allow it, were a ticket a field.
    consent Board ticket
    herdr_linear::board_sync_complete '{"observed":{},"unknown":{},"pending_questions":0,"members":["iss-1","iss-2"],"rendered":{"Board":{"ticket":["iss-1","iss-2"]}}}'
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::board_write_back Board iss-1 ticket iss-2 iss-1
    [ "$status" -eq "$HERDR_LINEAR_BOARD_WRITE_SHADOW" ]
    [ "$(issue_updates)" = 0 ]
    [ "$(shadow_lines)" = 1 ]
}

@test "the sync reaches Linear's field write only through the write-back gate" {
    run grep -c 'board_write_field' "$LIB/board-sync.sh"
    [ "$output" = 1 ]
    run grep -n 'call("board_write_field"\|call("board_consent_gate"' "$LIB/board-sync.sh"
    [ "$status" -eq 1 ]
}

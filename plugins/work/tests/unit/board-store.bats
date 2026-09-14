#!/usr/bin/env bats

load setup_common

# U5 — board records: reservations, the pane ledger, pending questions, space
# consent, the sync-state record, and the board consent gate.

bats_require_minimum_version 1.5.0

ISSUE=9f1c2b7e-0d4a-4c1e-9a55-3b1f0c2d8e71
OTHER=1a2b3c4d-0000-4000-8000-000000000002

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    # shellcheck source=/dev/null
    . "$LIB_DIR/board-store.sh"
    BOARD="$HERDR_LINEAR_STORE_DIR/board"
}

reservation_file() { printf '%s/reservations/%s.json' "$BOARD" "$1"; }

only_file_in() { find "$BOARD/$1" -name '*.json' -type f | head -1; }

shadow_lines() {
    if [ -e "$HERDR_LINEAR_SHADOW_LOG" ]; then grep -c . "$HERDR_LINEAR_SHADOW_LOG" || true; else echo 0; fi
}

complete_sync() {
    herdr_linear::board_sync_complete "$(printf '{"observed":{"tickets":2},"unknown":{"panes":0},"pending_questions":0,"members":["%s","%s"],"rendered":{"In Progress":{"state":["Todo","In Review"]}}}' "$ISSUE" "$OTHER")"
}

# ---------------------------------------------------------------- versioning

@test "the binding record version constant is unchanged" {
    [ "$HERDR_LINEAR_RECORD_VERSION" = "1" ]
    run grep -c '^HERDR_LINEAR_RECORD_VERSION=1$' "$LIB_DIR/binding.sh"
    [ "$output" = "1" ]
    [ -n "$HERDR_LINEAR_BOARD_RECORD_VERSION" ]
    [ "$HERDR_LINEAR_BOARD_RECORD_VERSION" -eq 1 ]
}

@test "a record with a future version reads as absent and is not overwritten" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    printf '{"version":99,"issue_id":"%s","worktree_name":"from-the-future"}\n' "$ISSUE" > "$(reservation_file "$ISSUE")"

    run herdr_linear::board_reservation "$ISSUE"
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    run herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the record was written by a newer version"* ]]
    run grep -c '"version":99' "$(reservation_file "$ISSUE")"
    [ "$output" = "1" ]

    run herdr_linear::board_reservation_start "$ISSUE"
    [ "$status" -eq 2 ]
    run grep -c 'from-the-future' "$(reservation_file "$ISSUE")"
    [ "$output" = "1" ]
}

@test "a future-version sync-state record is not overwritten by a complete sync" {
    mkdir -p "$BOARD"
    printf '{"version":42}\n' > "$BOARD/sync-state.json"
    chmod 600 "$BOARD/sync-state.json"
    run complete_sync
    [ "$status" -eq 2 ]
    run grep -c '"version":42' "$BOARD/sync-state.json"
    [ "$output" = "1" ]
}

# ---------------------------------------------------------------- identifiers

@test "an unsafe issue id is refused before any file is opened" {
    for bad in "../outside" ".." "-D" ".git" "a/b" 'a$b' ""; do
        run herdr_linear::board_reserve "$bad" WEB-12 web-12 feature/web-12 false
        [ "$status" -eq 2 ]
        [[ "$output" == *"refused: that issue id is not a safe identifier"* ]]
        run herdr_linear::board_reservation "$bad"
        [ "$status" -eq 2 ]
        run herdr_linear::board_ledger_put "In Progress" "$bad" "w1:p1" home '{}' true
        [ "$status" -eq 2 ]
        run herdr_linear::board_question_propose "$bad" move '{}'
        [ "$status" -eq 2 ]
    done
    [ ! -e "$BOARD" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/outside.json" ]

    run herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    [ "$status" -eq 0 ]
    [ -f "$(reservation_file "$ISSUE")" ]
}

@test "an unsafe worktree name or branch segment is refused and nothing is written" {
    run herdr_linear::board_reserve "$ISSUE" WEB-12 "../escape" feature/web-12 false
    [ "$status" -eq 2 ]
    run herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 "feature/../main" false
    [ "$status" -eq 2 ]
    run herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 "-D" false
    [ "$status" -eq 2 ]
    [ ! -e "$(reservation_file "$ISSUE")" ]
}

# ---------------------------------------------------------------- reservations

@test "a reservation records identifier, frozen name and branch, repository flag and state" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 true
    run herdr_linear::board_reservation_field "$ISSUE" worktree_name
    [ "$output" = "web-12" ]
    run herdr_linear::board_reservation_field "$ISSUE" branch
    [ "$output" = "feature/web-12" ]
    run herdr_linear::board_reservation_field "$ISSUE" repository_unknown
    [ "$output" = "true" ]
    run herdr_linear::board_reservation_field "$ISSUE" state
    [ "$output" = "reserved" ]
    run herdr_linear::board_reservation_field "$ISSUE" identifier
    [ "$output" = "WEB-12" ]
    run stat -f %Lp "$(reservation_file "$ISSUE")"
    [ "$output" = "600" ]
}

@test "a reservation survives a title change: the stored name does not change" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12-fix-login feature/web-12-fix-login false
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12-new-title feature/web-12-new-title false
    run herdr_linear::board_reservation_field "$ISSUE" worktree_name
    [ "$output" = "web-12-fix-login" ]
    run herdr_linear::board_reservation_field "$ISSUE" branch
    [ "$output" = "feature/web-12-fix-login" ]
}

@test "a team move that renumbers the ticket updates the identifier and keeps the worktree" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    herdr_linear::board_reserve "$ISSUE" OPS-7 ops-7 feature/ops-7 false
    run herdr_linear::board_reservation_field "$ISSUE" identifier
    [ "$output" = "OPS-7" ]
    run herdr_linear::board_reservation_field "$ISSUE" worktree_name
    [ "$output" = "web-12" ]
}

@test "starting a reservation marks it started, and a started one cannot be re-reserved back" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    herdr_linear::board_reservation_start "$ISSUE"
    run herdr_linear::board_reservation_field "$ISSUE" state
    [ "$output" = "started" ]
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    run herdr_linear::board_reservation_field "$ISSUE" state
    [ "$output" = "started" ]
}

@test "starting a ticket that has no reservation is absent, not created" {
    run herdr_linear::board_reservation_start "$ISSUE"
    [ "$status" -eq 1 ]
    [ ! -e "$(reservation_file "$ISSUE")" ]
}

@test "the repository-unknown flag is cleared once an answer is recorded" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 true
    herdr_linear::board_reservation_set_repo_unknown "$ISSUE" false
    run herdr_linear::board_reservation_field "$ISSUE" repository_unknown
    [ "$output" = "false" ]
    run herdr_linear::board_reservation_set_repo_unknown "$ISSUE" maybe
    [ "$status" -eq 2 ]
}

@test "a group- or world-writable record reads as absent and is not written through" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    chmod 660 "$(reservation_file "$ISSUE")"
    run herdr_linear::board_reservation "$ISSUE"
    [ "$status" -eq 1 ]
    run herdr_linear::board_reservation_start "$ISSUE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the record's owner or mode is wrong"* ]]
    run stat -f %Lp "$(reservation_file "$ISSUE")"
    [ "$output" = "660" ]
}

@test "an unreadable record is reported as unreadable, not absent" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    chmod 000 "$(reservation_file "$ISSUE")"
    run herdr_linear::board_reservation "$ISSUE"
    chmod 600 "$(reservation_file "$ISSUE")"
    [ "$status" -eq 4 ]
}

@test "a truncated record reads as absent" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 false
    printf '{"version":1,"issue' > "$(reservation_file "$ISSUE")"
    run herdr_linear::board_reservation "$ISSUE"
    [ "$status" -eq 1 ]
}

@test "a held lock makes a mutation report locked and leaves the record unchanged" {
    herdr_linear::board_reserve "$ISSUE" WEB-12 web-12 feature/web-12 true
    mkdir "$(reservation_file "$ISSUE").lock"
    HERDR_LINEAR_LOCK_WAIT_SECONDS=0 run herdr_linear::board_reservation_set_repo_unknown "$ISSUE" false
    rmdir "$(reservation_file "$ISSUE").lock"
    [ "$status" -eq 3 ]
    run herdr_linear::board_reservation_field "$ISSUE" repository_unknown
    [ "$output" = "true" ]
}

# ---------------------------------------------------------------- pane ledger

@test "a ledger entry records pane, role, groups and board-created per space" {
    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{"state":"Todo","project":null}' true
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; e=json.loads(sys.argv[1]); print(e["pane_id"], e["role"], e["groups"]["state"], e["groups"]["project"], e["board_created"], e["hidden"], e["pending_linear_change"])' "$output"
    [ "$output" = "w1:p3 home Todo None True False False" ]

    run herdr_linear::board_ledger_entry "Backlog" "$ISSUE"
    [ "$status" -eq 1 ]
}

@test "a space name with a space in it is a ledger key, and the name is kept in the record" {
    herdr_linear::board_ledger_put "No project" "$ISSUE" "w1:p3" pointer '{}' true
    run grep -c '"space": "No project"' "$(only_file_in ledger)"
    [ "$output" = "1" ]
    run herdr_linear::board_ledger_entries "No project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ISSUE"* ]]
}

@test "a ledger file whose stored space name differs is not read or written as the space asked for" {
    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{}' true
    f="$(only_file_in ledger)"
    sed -i '' 's/"space": "In Progress"/"space": "Somewhere Else"/' "$f"
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    [ "$status" -eq 1 ]
    run herdr_linear::board_ledger_put "In Progress" "$OTHER" "w1:p4" home '{}' true
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the ledger file on disk belongs to another space name"* ]]
    run grep -c '"space": "Somewhere Else"' "$f"
    [ "$output" = "1" ]
}

@test "a ledger role outside home and pointer is refused" {
    run herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" owner '{}' true
    [ "$status" -eq 2 ]
    run herdr_linear::board_ledger_put "In Progress" "$ISSUE" 'w1;p3' home '{}' true
    [ "$status" -eq 2 ]
    run herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '["Todo"]' true
    [ "$status" -eq 2 ]
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    [ "$status" -eq 1 ]
}

@test "a pending Linear change keeps the old group values until the pane is observed in the new group" {
    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{"state":"Todo"}' true
    herdr_linear::board_ledger_mark_linear_change "In Progress" "$ISSUE"
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    run python3 -c 'import json,sys; e=json.loads(sys.argv[1]); print(e["groups"]["state"], e["pending_linear_change"])' "$output"
    [ "$output" = "Todo True" ]

    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{"state":"In Review"}' true
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    run python3 -c 'import json,sys; e=json.loads(sys.argv[1]); print(e["groups"]["state"], e["pending_linear_change"])' "$output"
    [ "$output" = "In Review False" ]
}

@test "a hidden ticket stays hidden until its fingerprint changes" {
    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{}' true
    herdr_linear::board_ledger_hide "In Progress" "$ISSUE" "2026-09-14T10:00:00Z"
    run herdr_linear::board_ledger_hidden "In Progress" "$ISSUE" "2026-09-14T10:00:00Z"
    [ "$status" -eq 0 ]
    run herdr_linear::board_ledger_hidden "In Progress" "$ISSUE" "2026-09-14T11:30:00Z"
    [ "$status" -eq 1 ]

    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p4" home '{}' true
    run herdr_linear::board_ledger_hidden "In Progress" "$ISSUE" "2026-09-14T10:00:00Z"
    [ "$status" -eq 0 ]

    herdr_linear::board_ledger_unhide "In Progress" "$ISSUE"
    run herdr_linear::board_ledger_hidden "In Progress" "$ISSUE" "2026-09-14T10:00:00Z"
    [ "$status" -eq 1 ]
}

@test "removing a ledger entry leaves the other tickets in that space" {
    herdr_linear::board_ledger_put "In Progress" "$ISSUE" "w1:p3" home '{}' true
    herdr_linear::board_ledger_put "In Progress" "$OTHER" "w1:p4" home '{}' false
    herdr_linear::board_ledger_remove "In Progress" "$ISSUE"
    run herdr_linear::board_ledger_entry "In Progress" "$ISSUE"
    [ "$status" -eq 1 ]
    run herdr_linear::board_ledger_entry "In Progress" "$OTHER"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- questions

@test "answering a question with a stale nonce is refused and the question stays" {
    nonce="$(herdr_linear::board_question_propose "move-$ISSUE" move '{"from":"Todo","to":"In Review"}')"
    [ "${#nonce}" -eq 32 ]

    run herdr_linear::board_question_answer "move-$ISSUE" "0000000000000000000000000000dead" '{"from":"Todo","to":"In Review"}'
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the nonce does not match the question as recorded"* ]]

    run herdr_linear::board_questions_pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"move-$ISSUE"* ]]
    [[ "$output" == *"$nonce"* ]]
}

@test "answering a question whose preconditions no longer hold is refused" {
    nonce="$(herdr_linear::board_question_propose "move-$ISSUE" move '{"from":"Todo","to":"In Review"}')"
    run herdr_linear::board_question_answer "move-$ISSUE" "$nonce" '{"from":"Done","to":"In Review"}'
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the question's preconditions no longer hold"* ]]
    run herdr_linear::board_questions_pending
    [[ "$output" == *"move-$ISSUE"* ]]
}

@test "answering with the current nonce and preconditions clears the question" {
    nonce="$(herdr_linear::board_question_propose "move-$ISSUE" move '{"from":"Todo","to":"In Review"}')"
    run herdr_linear::board_question_answer "move-$ISSUE" "$nonce" '{"to":"In Review","from":"Todo"}'
    [ "$status" -eq 0 ]
    run herdr_linear::board_questions_pending
    [ -z "$output" ]
    run herdr_linear::board_question_answer "move-$ISSUE" "$nonce" '{"from":"Todo","to":"In Review"}'
    [ "$status" -eq 1 ]
}

@test "a declined question is not returned again until its preconditions change" {
    nonce="$(herdr_linear::board_question_propose "close-$ISSUE" close '{"left_view":true}')"
    herdr_linear::board_question_decline "close-$ISSUE" "$nonce"

    run herdr_linear::board_questions_pending
    [ -z "$output" ]

    run herdr_linear::board_question_propose "close-$ISSUE" close '{"left_view":true}'
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: this question was declined and its preconditions have not changed"* ]]
    run herdr_linear::board_questions_pending
    [ -z "$output" ]

    run herdr_linear::board_question_propose "close-$ISSUE" close '{"left_view":true,"updated":"2026-09-14T12:00:00Z"}'
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
    [ "$output" != "$nonce" ]
    run herdr_linear::board_questions_pending
    [[ "$output" == *"close-$ISSUE"* ]]
}

@test "a decline with a stale nonce is refused and the question stays open" {
    herdr_linear::board_question_propose "close-$ISSUE" close '{"left_view":true}' >/dev/null
    run herdr_linear::board_question_decline "close-$ISSUE" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    run herdr_linear::board_questions_pending
    [[ "$output" == *"close-$ISSUE"* ]]
}

@test "re-recording an open question with the same preconditions keeps its nonce" {
    first="$(herdr_linear::board_question_propose "move-$ISSUE" move '{"to":"In Review"}')"
    second="$(herdr_linear::board_question_propose "move-$ISSUE" move '{"to":"In Review"}')"
    [ "$first" = "$second" ]
}

# ---------------------------------------------------------------- space consent

@test "space consent is recorded per space name and field through a nonce" {
    run herdr_linear::board_consent_covers "In Progress" state
    [ "$status" -eq 1 ]

    nonce="$(herdr_linear::board_consent_propose "In Progress" state)"
    run herdr_linear::board_consent_confirm "In Progress" state "wrong"
    [ "$status" -eq 2 ]
    run herdr_linear::board_consent_covers "In Progress" state
    [ "$status" -eq 1 ]

    herdr_linear::board_consent_confirm "In Progress" state "$nonce"
    run herdr_linear::board_consent_covers "In Progress" state
    [ "$status" -eq 0 ]
    run herdr_linear::board_consent_covers "In Progress" project
    [ "$status" -eq 1 ]
    run herdr_linear::board_consent_covers "Backlog" state
    [ "$status" -eq 1 ]
}

@test "a consent nonce issued for one field does not confirm another" {
    nonce="$(herdr_linear::board_consent_propose "In Progress" state)"
    run herdr_linear::board_consent_confirm "In Progress" project "$nonce"
    [ "$status" -eq 2 ]
    run herdr_linear::board_consent_covers "In Progress" project
    [ "$status" -eq 1 ]
}

@test "declining consent clears the proposal and records nothing" {
    nonce="$(herdr_linear::board_consent_propose "In Progress" state)"
    herdr_linear::board_consent_decline "In Progress" state "$nonce"
    run herdr_linear::board_consent_confirm "In Progress" state "$nonce"
    [ "$status" -eq 2 ]
    run herdr_linear::board_consent_covers "In Progress" state
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------- sync state

@test "a complete sync records its time, counts and pending question count" {
    complete_sync
    run herdr_linear::board_sync_state
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print(s["observed"]["tickets"], s["unknown"]["panes"], s["pending_questions"], bool(s["last_complete_sync_at"]), s["behind"])' "$output"
    [ "$output" = "2 0 0 True False" ]
}

@test "with no complete sync the board reads as behind" {
    run herdr_linear::board_behind
    [ "$status" -eq 0 ]
}

@test "a plugin Linear write after the last complete sync marks the board behind with its time" {
    complete_sync
    run herdr_linear::board_behind
    [ "$status" -eq 1 ]
    herdr_linear::board_record_linear_write
    run herdr_linear::board_behind
    [ "$status" -eq 0 ]
    run herdr_linear::board_sync_state
    run python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print(s["behind"], bool(s["last_plugin_write_at"]))' "$output"
    [ "$output" = "True True" ]

    complete_sync
    run herdr_linear::board_behind
    [ "$status" -eq 1 ]
}

@test "a behind mark from a hook reads as behind until the next complete sync" {
    complete_sync
    herdr_linear::board_mark_behind
    run herdr_linear::board_behind
    [ "$status" -eq 0 ]
    complete_sync
    run herdr_linear::board_behind
    [ "$status" -eq 1 ]
}

@test "a failed sync stage is recorded and keeps the last complete counts" {
    complete_sync
    herdr_linear::board_sync_failed filter-read "page 3 timed out"
    run herdr_linear::board_sync_state
    run python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print(s["last_failure"]["stage"], s["last_failure"]["message"], s["observed"]["tickets"])' "$output"
    [ "$output" = "filter-read page 3 timed out 2" ]
}

@test "a malformed complete-sync document is refused and nothing is recorded" {
    run herdr_linear::board_sync_complete '{"observed":{"tickets":"two"},"unknown":{},"pending_questions":0,"members":[],"rendered":{}}'
    [ "$status" -eq 2 ]
    run herdr_linear::board_sync_complete '{"observed":{},"unknown":{},"pending_questions":0,"members":["../x"],"rendered":{}}'
    [ "$status" -eq 2 ]
    run herdr_linear::board_sync_complete '{"observed":{},"unknown":{},"pending_questions":0,"members":[],"rendered":{},"extra":1}'
    [ "$status" -eq 2 ]
    [ ! -e "$BOARD/sync-state.json" ]
}

# ---------------------------------------------------------------- board consent gate

consent_for() {
    local n
    n="$(herdr_linear::board_consent_propose "$1" "$2")"
    herdr_linear::board_consent_confirm "$1" "$2" "$n"
}

@test "the board consent gate refuses a field its space has not consented to and writes one shadow log line" {
    complete_sync
    consent_for "In Progress" project
    run herdr_linear::board_consent_gate "In Progress" state "$ISSUE" "In Review"
    [ "$status" -eq 1 ]
    [ "$(shadow_lines)" = "1" ]
    run grep -c "SHADOW board would set \"state\" to \"In Review\" on \"$ISSUE\" in \"In Progress\": no consent for this field in this space$" "$HERDR_LINEAR_SHADOW_LOG"
    [ "$output" = "1" ]
    run grep -c 'no consent for this field in this space' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$output" = "1" ]
}

@test "the board consent gate allows a consented field for a ticket in the last complete read moving into a rendered group" {
    complete_sync
    consent_for "In Progress" state
    run herdr_linear::board_consent_gate "In Progress" state "$ISSUE" "In Review"
    [ "$status" -eq 0 ]
    [ "$(shadow_lines)" = "0" ]
}

@test "the board consent gate refuses a ticket outside the last complete read" {
    complete_sync
    consent_for "In Progress" state
    run herdr_linear::board_consent_gate "In Progress" state 77777777-0000-4000-8000-000000000007 "In Review"
    [ "$status" -eq 1 ]
    [ "$(shadow_lines)" = "1" ]
    run grep -c 'not in the last complete filter read' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$output" = "1" ]
}

@test "the board consent gate refuses a target group the board did not render" {
    complete_sync
    consent_for "In Progress" state
    run herdr_linear::board_consent_gate "In Progress" state "$ISSUE" "Cancelled"
    [ "$status" -eq 1 ]
    run grep -c 'target group was not rendered by the board' "$HERDR_LINEAR_SHADOW_LOG"
    [ "$output" = "1" ]
}

@test "the board consent gate refuses with no complete sync, logging once even when every fact fails" {
    run herdr_linear::board_consent_gate "In Progress" state "$ISSUE" "In Review"
    [ "$status" -eq 1 ]
    [ "$(shadow_lines)" = "1" ]
}

@test "the board consent gate refuses an unsafe issue id and still logs one line" {
    complete_sync
    consent_for "In Progress" state
    run herdr_linear::board_consent_gate "In Progress" state "../x" "In Review"
    [ "$status" -eq 1 ]
    [ "$(shadow_lines)" = "1" ]
}

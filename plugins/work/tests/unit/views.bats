#!/usr/bin/env bats

load setup_common

# U6 — the bind skill's view step: choose a view for a space, or create one
# through the consent gate.
#
# Nothing here reaches Linear. The curl stand-in records what would have been
# sent and refuses any mutation a test did not permit.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    export HERDR_LINEAR_RETRY_BASE_MS=1
    mkdir -p "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_VIEWSVIEWSVIEWSVIEWS" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in secrets.sh binding.sh linear.sh views.sh; do . "$ROOT/lib/$f"; done

    TEAM=55555555-5555-4555-8555-555555555555
    PROJECT=44444444-4444-4444-8444-444444444444
    VIEW=cccccccc-cccc-4ccc-8ccc-cccccccccccc

    WT="$WORK/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    local n
    n="$(herdr_linear::workspace_propose wA "$PROJECT")"
    herdr_linear::workspace_confirm wA "$PROJECT" "$n"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
}

ws_file() { printf '%s/workspaces/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }
ws_field() { python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))' "$(ws_file wA)" "$1"; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
grant_consent() {
    local n
    n="$(herdr_linear::consent_propose "$WT" "$TEAM" "$PROJECT")"
    herdr_linear::consent_confirm "$WT" "$TEAM" "$PROJECT" "$n"
}

# ------------------------------------------------------------- choosing (AE7)

@test "AE7: views_for_space lists every view whose filter names the project, and choosing the second records it without a Linear write" {
    export FAKE_LINEAR_VIEWS=many
    run --separate-stderr herdr_linear::views_for_space wA
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | grep -c .)" -eq 3 ]
    [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f1)" = "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2" ]
    refute_match -F "A different project" <<< "$output"
    refute_match -F "Old canvas board" <<< "$output"

    run --separate-stderr herdr_linear::view_choose wA c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2
    [ "$status" -eq 0 ]
    [ "$(ws_field 'd["view"]["id"]')" = "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2" ]
    [ "$(ws_field 'd["view"]["name"]')" = "Canvas board" ]
    [ "$(ws_field 'd["view"]["layout"]["grouping"]')" = "workflowState" ]
    [ "$(ws_field 'd["version"]')" = "1" ]
    [ "$(ws_field 'd["created_views"]')" = "[]" ]
    [ "$(sent mutation)" = "0" ]
}

@test "views_for_space refuses a space that is not bound" {
    rm -f "$(ws_file wA)"
    run --separate-stderr herdr_linear::views_for_space wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    [ -z "$output" ]
    [ ! -f "$FAKE_LINEAR_RECORD_DIR/bodies" ]
}

@test "view_choose on an id Linear does not know records nothing" {
    export FAKE_LINEAR_VIEW_MISSING=1
    run --separate-stderr herdr_linear::view_choose wA "$VIEW"
    [ "$status" -eq "$HERDR_LINEAR_VIEW_FAILED" ]
    [ "$(ws_field 'd["view"]')" = "None" ]
}

@test "view_choose on a view whose filter names another project is refused and records nothing" {
    export FAKE_LINEAR_VIEW_PROJECT=99999999-9999-4999-8999-999999999999
    run --separate-stderr herdr_linear::view_choose wA c4c4c4c4-c4c4-4c4c-8c4c-c4c4c4c4c4c4
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    [ -z "$output" ]
    [ "$(ws_field 'd["view"]')" = "None" ]
    # The positive control: the same id with the canned filter is recorded.
    unset FAKE_LINEAR_VIEW_PROJECT
    run --separate-stderr herdr_linear::view_choose wA c4c4c4c4-c4c4-4c4c-8c4c-c4c4c4c4c4c4
    [ "$status" -eq 0 ]
    [ "$(ws_field 'd["view"]["id"]')" = "c4c4c4c4-c4c4-4c4c-8c4c-c4c4c4c4c4c4" ]
}

@test "view_none clears the recorded view and keeps the record bound" {
    herdr_linear::view_choose wA "$VIEW" >/dev/null
    [ "$(ws_field 'd["view"]["id"]')" = "$VIEW" ]
    run herdr_linear::view_none wA
    [ "$status" -eq 0 ]
    [ "$(ws_field 'd["view"]')" = "None" ]
    [ "$(ws_field 'd["state"]')" = "bound" ]
}

# ------------------------------------------------------------- creating (AE8)

@test "a view is not created when nobody has answered" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 1 ]
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_SHADOW" ]
    [ "$(sent customViewCreate)" = "0" ]
    [ "$(sent mutation)" = "0" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create view \"AI Canvas Tools board\" on project $PROJECT"* ]]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"create view"* ]]
    [ "$(ws_field 'd["view"]')" = "None" ]
    [ "$(ws_field 'd["created_views"]')" = "[]" ]
}

@test "with consent recorded both mutations are sent in order, the id joins created_views and becomes the view" {
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq 0 ]
    [ "$output" = "$VIEW" ]
    [ "$(sent mutation)" = "2" ]
    [ "$(sed -n 1p "$FAKE_LINEAR_RECORD_DIR/bodies" | grep -c customViewCreate)" = "1" ]
    [ "$(sed -n 2p "$FAKE_LINEAR_RECORD_DIR/bodies" | grep -c viewPreferencesCreate)" = "1" ]
    [ "$(ws_field 'd["created_views"]')" = "['$VIEW']" ]
    [ "$(ws_field 'd["view"]["id"]')" = "$VIEW" ]
    [ "$(ws_field 'd["view"]["name"]')" = "AI Canvas Tools board" ]
    [ "$(ws_field 'd["view"]["layout"]["grouping"]')" = "workflowState" ]
    run herdr_linear::workspace_owns_view wA "$VIEW"
    [ "$status" -eq 0 ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"CREATED view \"AI Canvas Tools board\" ($VIEW)"* ]]
}

@test "when the board preferences fail the view is still recorded, with layout list and a reason" {
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=prefs_fail
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_PREFS_FAILED" ]
    [ "$output" = "$VIEW" ]
    [[ "$stderr" == *"board preferences were not"* ]]
    [ "$(sent mutation)" = "2" ]
    [ "$(ws_field 'd["created_views"]')" = "['$VIEW']" ]
    [ "$(ws_field 'd["view"]["id"]')" = "$VIEW" ]
    [ "$(ws_field 'd["view"]["layout"]["layout"]')" = "list" ]
    [ "$(ws_field 'd["view"]["layout"]["grouping"]')" = "None" ]
}

@test "a failed create records nothing" {
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=fail
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_FAILED" ]
    [ "$(ws_field 'd["created_views"]')" = "[]" ]
    [ "$(ws_field 'd["view"]')" = "None" ]
}

@test "a create whose record write fails after Linear answered still prints and logs the id" {
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1 HERDR_LINEAR_LOCK_WAIT_SECONDS=1
    # A held record lock: the view is created at Linear, then workspace_add_view
    # cannot write.
    mkdir "$(ws_file wA).lock"
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_FAILED" ]
    [ "$output" = "$VIEW" ]
    [[ "$stderr" == *"$VIEW"* ]]
    [ "$(sent customViewCreate)" = "1" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"CREATED view \"AI Canvas Tools board\" ($VIEW)"* ]]
    [ "$(ws_field 'd["created_views"]')" = "[]" ]
    [ "$(ws_field 'd["view"]')" = "None" ]
}

@test "a create with no team is refused before the gate: no shadow line, no pending notice" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::view_create_gated "$WT" "" "$PROJECT" "AI Canvas Tools board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    [ -z "$output" ]
    [ "$(sent mutation)" = "0" ]
    [ ! -f "$HERDR_LINEAR_SHADOW_LOG" ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -ne 0 ]
}

@test "a create naming a project the space is not bound to is refused before the gate" {
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::view_create_gated "$WT" "$TEAM" 99999999-9999-4999-8999-999999999999 "Other board" wA
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    [ "$(sent mutation)" = "0" ]
    [ ! -f "$HERDR_LINEAR_SHADOW_LOG" ]
}

# ------------------------------------------------------ the write bound (KTD11)

@test "write_allowed refuses customViewUpdate-shaped targets, including a view in created_views" {
    local n
    n="$(herdr_linear::binding_propose "$WT" WEB-2870)"
    herdr_linear::binding_confirm "$WT" WEB-2870 "$n"
    grant_consent
    export FAKE_LINEAR_ALLOW_MUTATION=1
    herdr_linear::view_create_gated "$WT" "$TEAM" "$PROJECT" "AI Canvas Tools board" wA >/dev/null
    run herdr_linear::workspace_owns_view wA "$VIEW"
    [ "$status" -eq 0 ]
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 0 ]
    local target
    for target in "$VIEW" "customViewUpdate:$VIEW" "customView:$VIEW" "view:$VIEW"; do
        run herdr_linear::write_allowed "$WT" "$target"
        [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    done
}

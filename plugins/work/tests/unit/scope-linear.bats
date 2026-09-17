#!/usr/bin/env bats

load setup_common

# Whether a project or an issue lies inside a session's scope, read from
# Linear's relations (KTD4). An answer Linear could not give is unknown, and
# unknown never counts as outside: a session must not report work as misplaced
# because a read failed.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_RETRY_MAX=1
    mkdir -p "$WORK/rec"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_SCOPESCOPESCOPESCOPE" > "$LINEAR_SECRETS_FILE"
    export FAKE_LINEAR_SCOPE_WORLD="$WORK/world.json"
    cat > "$FAKE_LINEAR_SCOPE_WORLD" <<'JSON'
{"teams": [{"id": "t-web", "key": "WEB", "name": "Web"}, {"id": "t-ops", "key": "OPS", "name": "Ops"}],
 "initiatives": [{"id": "i-media", "name": "Media Hub"}, {"id": "i-ai", "name": "Slate AI"}],
 "projects": {"p-canvas": {"name": "AI Canvas Tools", "teams": ["t-web"], "initiatives": ["i-media", "i-ai"]},
              "p-infra": {"name": "Infra", "teams": ["t-ops", "t-web"], "initiatives": []},
              "p-ops": {"name": "Ops Only", "teams": ["t-ops"], "initiatives": []}},
 "issues": {"WEB-1": {"team": "t-web", "project": "p-canvas"},
            "WEB-2": {"team": "t-web", "project": null},
            "OPS-7": {"team": "t-ops", "project": "p-ops"}}}
JSON
    for f in sanitize.sh secrets.sh linear.sh scope-linear.sh; do . "$ROOT/lib/$f"; done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bodies() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }

@test "a project of team WEB is inside a WEB session and outside an OPS session" {
    run herdr_linear::scope_contains_project team t-web p-canvas
    [ "$status" -eq 0 ]; [ "$output" = inside ]
    run herdr_linear::scope_contains_project team t-ops p-canvas
    [ "$status" -eq 1 ]; [ "$output" = outside ]
}

@test "a project shared by two teams is inside either team's session" {
    run herdr_linear::scope_contains_project team t-ops p-infra
    [ "$output" = inside ]
    run herdr_linear::scope_contains_project team t-web p-infra
    [ "$output" = inside ]
}

@test "a project with two initiatives is inside a session bound to either" {
    run herdr_linear::scope_contains_project initiative i-media p-canvas
    [ "$output" = inside ]
    run herdr_linear::scope_contains_project initiative i-ai p-canvas
    [ "$output" = inside ]
    run herdr_linear::scope_contains_project initiative i-ai p-infra
    [ "$status" -eq 1 ]; [ "$output" = outside ]
}

@test "a project session contains only that project, without a read" {
    run herdr_linear::scope_contains_project project p-canvas p-canvas
    [ "$output" = inside ]
    run herdr_linear::scope_contains_project project p-canvas p-infra
    [ "$output" = outside ]
    [ "$(bodies ScopeProject)" = 0 ]
}

@test "an issue with no project is outside an initiative session and inside its team's session" {
    run herdr_linear::scope_contains_issue initiative i-media WEB-2
    [ "$status" -eq 1 ]; [ "$output" = outside ]
    run herdr_linear::scope_contains_issue team t-web WEB-2
    [ "$status" -eq 0 ]; [ "$output" = inside ]
    run herdr_linear::scope_contains_issue project p-canvas WEB-2
    [ "$output" = outside ]
}

@test "an issue belongs by its team, its project and that project's initiatives" {
    run herdr_linear::scope_contains_issue team t-ops WEB-1
    [ "$output" = outside ]
    run herdr_linear::scope_contains_issue project p-canvas WEB-1
    [ "$output" = inside ]
    run herdr_linear::scope_contains_issue initiative i-ai WEB-1
    [ "$output" = inside ]
    run herdr_linear::scope_contains_issue initiative i-ai OPS-7
    [ "$output" = outside ]
}

@test "everything is inside an organization session, and nothing is read" {
    run herdr_linear::scope_contains_project organization org-1 p-ops
    [ "$output" = inside ]
    run herdr_linear::scope_contains_issue organization org-1 OPS-7
    [ "$output" = inside ]
    [ "$(bodies Scope)" = 0 ]
}

@test "a rate-limited read answers unknown and marks nothing outside" {
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    run herdr_linear::scope_contains_project team t-ops p-canvas
    [ "$status" -eq 2 ]; [ "$output" = unknown ]
    run herdr_linear::scope_contains_issue initiative i-ai OPS-7
    [ "$status" -eq 2 ]; [ "$output" = unknown ]
}

@test "a refused credential and a missing entity answer unknown" {
    export FAKE_LINEAR_SCOPE_FAIL=auth_error
    run herdr_linear::scope_contains_issue team t-web WEB-1
    [ "$output" = unknown ]
    unset FAKE_LINEAR_SCOPE_FAIL
    run herdr_linear::scope_contains_project team t-web p-missing
    [ "$output" = unknown ]
    run herdr_linear::scope_contains_issue team t-web WEB-404
    [ "$output" = unknown ]
}

@test "an unknown kind or an unsafe id answers unknown without a read" {
    run herdr_linear::scope_contains_project milestone m-1 p-canvas
    [ "$status" -eq 2 ]; [ "$output" = unknown ]
    run herdr_linear::scope_contains_issue team t-web '../WEB-1'
    [ "$status" -eq 2 ]
    [ "$(bodies Scope)" = 0 ]
}

@test "within one sync, a repeated membership question reads Linear once" {
    export HERDR_LINEAR_SCOPE_CACHE_DIR="$WORK/scope-cache"
    herdr_linear::scope_contains_project team t-web p-canvas >/dev/null
    herdr_linear::scope_contains_project initiative i-ai p-canvas >/dev/null
    herdr_linear::scope_contains_issue team t-web WEB-1 >/dev/null
    herdr_linear::scope_contains_issue initiative i-ai WEB-1 >/dev/null
    [ "$(bodies ScopeProject)" = 1 ]
    [ "$(bodies ScopeIssue)" = 1 ]
}

@test "a failed read is not cached" {
    export HERDR_LINEAR_SCOPE_CACHE_DIR="$WORK/scope-cache"
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    herdr_linear::scope_contains_project team t-web p-canvas >/dev/null || true
    unset FAKE_LINEAR_SCOPE_FAIL
    run herdr_linear::scope_contains_project team t-web p-canvas
    [ "$output" = inside ]
}

@test "candidates are listed per kind, one tab-separated line each" {
    run herdr_linear::scope_candidates team
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" = 2 ]
    printf '%s\n' "$output" | grep -qx "$(printf 'team\tt-web\tWEB Web')"
    run herdr_linear::scope_candidates initiative
    printf '%s\n' "$output" | grep -qx "$(printf 'initiative\ti-media\tMedia Hub')"
    run herdr_linear::scope_candidates project
    printf '%s\n' "$output" | grep -qx "$(printf 'project\tp-canvas\tAI Canvas Tools')"
    run herdr_linear::scope_candidates organization
    printf '%s\n' "$output" | grep -q "^organization	"
}

@test "a candidate name cannot break the line format" {
    python3 - "$FAKE_LINEAR_SCOPE_WORLD" <<'EOF'
import json, sys
w = json.load(open(sys.argv[1]))
w["initiatives"].append({"id": "i-bad", "name": "Tab\there\nnew\x1b[31mline"})
json.dump(w, open(sys.argv[1], "w"))
EOF
    run herdr_linear::scope_candidates initiative
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" = 3 ]
    [[ "$output" != *$'\033'* ]]
}

@test "a failed candidate read fails rather than listing nothing" {
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    run herdr_linear::scope_candidates team
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a 200 whose list is null fails rather than listing nothing" {
    export FAKE_LINEAR_SCOPE_FAIL=null_connection
    run herdr_linear::scope_candidates initiative
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run herdr_linear::scope_contains_project team t-web p-canvas
    [ "$output" = unknown ]
}

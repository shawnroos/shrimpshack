#!/usr/bin/env bats

load setup_common

# The session record, the resolver and the guard.
#
# The fixture's own ids are the whole point of the guard tests: WEB-3308 and
# BRAND-1200 sit in the SAME project and belong to DIFFERENT teams, which is the
# case a project-only test cannot see.

bats_require_minimum_version 1.5.0

WEB_TEAM=55555555-5555-4555-8555-555555555555
BRAND_TEAM=66666666-6666-4666-8666-666666666666
PROJECT=44444444-4444-4444-8444-444444444444
OTHER_PROJECT=99999999-9999-4999-8999-999999999999

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(cd "$(mktemp -d)" && pwd -P)"

    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    mkdir -p "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_CTXFILTERCTXFILTERCT" > "$LINEAR_SECRETS_FILE"

    # A named session, as herdr exports it into every pane it owns.
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/alpha/herdr.sock"

    WT="$WORK/wt"
    mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-3308-panel
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    # shellcheck source=/dev/null
    for f in sanitize.sh secrets.sh contain.sh herdr-read.sh binding.sh linear.sh context.sh context-filter.sh; do
        . "$ROOT/lib/$f"
    done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

declare_team() {   # declare_team <team-id> [team-key]
    local n
    n="$(herdr_linear::session_propose "$1")" || return 1
    herdr_linear::session_confirm "$1" "$n" "${2:-}"
}

bind_space() {     # bind_space <space> <project> [team-id...]
    local ws="$1" project="$2" n
    shift 2
    n="$(herdr_linear::workspace_propose "$ws" "$project")" || return 1
    herdr_linear::workspace_confirm "$ws" "$project" "$n" "$@"
}

bind_wt() {
    local n
    n="$(herdr_linear::binding_propose "$WT" "$1")"
    herdr_linear::binding_confirm "$WT" "$1" "$n"
}

field() { printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }

# ------------------------------------------------------------ the session record

@test "a session with no record has no team and is unbound" {
    run herdr_linear::session_state
    [ "$output" = "unbound" ]
    run herdr_linear::session_team
    [ -z "$output" ]
}

@test "a declared team is readable, with its key in the display field" {
    declare_team "$WEB_TEAM" WEB
    [ "$(herdr_linear::session_state)" = "bound" ]
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
    [ "$(herdr_linear::session_team_key)" = "WEB" ]
}

@test "a proposed team is not yet the session's team" {
    herdr_linear::session_propose "$WEB_TEAM" > /dev/null
    [ "$(herdr_linear::session_state)" = "proposed" ]
    [ -z "$(herdr_linear::session_team)" ]
}

@test "confirming without the proposal's nonce records nothing" {
    herdr_linear::session_propose "$WEB_TEAM" > /dev/null
    run herdr_linear::session_confirm "$WEB_TEAM" not-the-nonce
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_state)" = "proposed" ]
}

@test "the default session gets a record of its own, and the resolver reports it" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    export HERDR_SOCKET_PATH="$WORK/herdr/herdr.sock"
    declare_team "$WEB_TEAM" WEB
    [ -f "$HERDR_LINEAR_STORE_DIR/contexts/session-default.json" ]
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" team_source)" = "session" ]
}

@test "a session marked misplaced stops answering with its team" {
    declare_team "$WEB_TEAM" WEB
    herdr_linear::session_set_state misplaced
    [ "$(herdr_linear::session_state)" = "misplaced" ]
    [ -z "$(herdr_linear::session_team)" ]
}

@test "two sessions do not share a team" {
    declare_team "$WEB_TEAM" WEB
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/beta/herdr.sock"
    [ "$(herdr_linear::session_state)" = "unbound" ]
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/alpha/herdr.sock"
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
}

@test "a pane with no herdr socket has no session level to declare" {
    unset HERDR_SOCKET_PATH
    run herdr_linear::session_propose "$WEB_TEAM"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_state)" = "unbound" ]
}

@test "the space record carries the project's team ids" {
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::workspace_team_ids wA
    [ "$status" -eq 0 ]
    [ "$output" = "$WEB_TEAM
$BRAND_TEAM" ]
}

@test "binding a space to another project drops the previous team ids" {
    bind_space wA "$PROJECT" "$WEB_TEAM"
    bind_space wA "$OTHER_PROJECT"
    run herdr_linear::workspace_team_ids wA
    [ -z "$output" ]
}

# ---------------------------------------------------------------- the resolver

@test "with nothing declared the resolver answers what the worktree derives" {
    export FAKE_LINEAR_MODE=found_child
    bind_wt WEB-3308
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ "$(field "$ctx" identifier)" = "WEB-3308" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" team_source)" = "derived" ]
    [ "$(field "$ctx" project_source)" = "derived" ]
    [ "$(field "$ctx" issue_source)" = "tab" ]
}

@test "a declared team is the resolver's team, and the session is named as the level" {
    declare_team "$BRAND_TEAM" BRAND
    bind_space wA "$PROJECT" "$BRAND_TEAM"
    local ctx; ctx="$(herdr_linear::context "$WT" wA)"
    [ "$(field "$ctx" team_id)" = "$BRAND_TEAM" ]
    [ "$(field "$ctx" team_key)" = "BRAND" ]
    [ "$(field "$ctx" team_source)" = "session" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
    [ "$(field "$ctx" project_source)" = "space" ]
}

@test "a resolved session and space make no Linear call" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    local ctx; ctx="$(herdr_linear::context "$WT" wA)"
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
}

@test "nothing declared and nothing bound leaves every level absent" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ -z "$(field "$ctx" team_id)" ]
    [ -z "$(field "$ctx" project_id)" ]
    [ "$(field "$ctx" team_source)" = "none" ]
    [ "$(field "$ctx" project_source)" = "none" ]
    [ "$(field "$ctx" issue_source)" = "none" ]
}

# ------------------------------------------------------------------- the guard

@test "no declared level filters nothing" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows team "$BRAND_TEAM"
    [ "$status" -eq 0 ]
    run herdr_linear::context_allows project "$OTHER_PROJECT"
    [ "$status" -eq 0 ]
}

@test "the session's own team is inside and another team is outside" {
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows team "$WEB_TEAM"
    [ "$status" -eq 0 ]
    run herdr_linear::context_allows team "$BRAND_TEAM"
    [ "$status" -eq 1 ]
}

@test "the space's own project is inside on the recorded team ids alone" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows project "$PROJECT" wA
    [ "$status" -eq 0 ]
}

@test "a space bound to a project without the session's team is outside, locally" {
    declare_team "$BRAND_TEAM" BRAND
    bind_space wA "$PROJECT" "$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows project "$PROJECT" wA
    [ "$status" -eq 1 ]
}

@test "a project spanning the session's team is inside" {
    export FAKE_LINEAR_PROJECT_TEAMS=many
    declare_team "$BRAND_TEAM" BRAND
    run herdr_linear::context_allows project "$PROJECT"
    [ "$status" -eq 0 ]
}

@test "a project without the session's team is outside" {
    export FAKE_LINEAR_PROJECT_TEAMS=one
    declare_team "$BRAND_TEAM" BRAND
    run herdr_linear::context_allows project "$PROJECT"
    [ "$status" -eq 1 ]
}

@test "an issue of the session's team in the space's project is inside" {
    export FAKE_LINEAR_MODE=found_child
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 0 ]
}

@test "another team's issue in the space's own project is outside" {
    export FAKE_LINEAR_MODE=found_other_team
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::context_allows issue BRAND-1200 wA
    [ "$status" -eq 1 ]
}

@test "an issue outside the space's project is outside" {
    export FAKE_LINEAR_MODE=found_child
    bind_space wA "$OTHER_PROJECT"
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 1 ]
}

@test "an issue is inside when only its team is declared and it matches" {
    export FAKE_LINEAR_MODE=found_child
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows issue WEB-3308
    [ "$status" -eq 0 ]
}

@test "an unreachable Linear is unknown, never outside" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 3 ]
    run herdr_linear::context_allows project "$OTHER_PROJECT"
    [ "$status" -eq 3 ]
}

@test "a kind the guard does not know is refused rather than allowed" {
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows cycle something
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------ the tab on a bind

@test "the bind skill records the tab it confirmed in" {
    local fences
    fences="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
sys.stdout.write("\n".join(re.findall(r"```bash\n(.*?)```", text, re.S)))
' "$ROOT/skills/bind/SKILL.md")"
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::binding_confirm')" -eq 2 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::binding_set_tab')" -eq 2 ]
}

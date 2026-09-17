#!/usr/bin/env bats

load setup_common

# U9 — the untidy states.
#
# Both states exist to STOP the plugin doing something, so every test here
# checks that nothing was changed. A plugin that moved a worktree's issue to
# match whatever workspace it happens to be sitting in, or that reopened a
# ticket someone had just closed, would be undoing decisions a person made
# deliberately.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/root" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_STATESSTATESSTATES1" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh states.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/root/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    CANVAS="44444444-4444-4444-8444-444444444444"
    OTHER="99999999-9999-4999-8999-999999999999"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
# The ids the fake tracker puts on every issue in these fixtures.
grant_consent() {
    local dir="$1" team="${2:-55555555-5555-4555-8555-555555555555}"
    local project="${3-44444444-4444-4444-8444-444444444444}" n
    n="$(herdr_linear::consent_propose "$dir" "$team" "$project")"
    herdr_linear::consent_confirm "$dir" "$team" "$project" "$n"
}
# classify RETURNS the state as its exit code, so every call goes through `run`.
# A bare call trips errexit on a perfectly normal "this is misplaced" answer.
bind_ws() { local n; n="$(herdr_linear::workspace_propose "$1" "$2")"; herdr_linear::workspace_confirm "$1" "$2" "$n"; }
mutations_sent() { local n; n="$(grep -c 'issueUpdate' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------- misplaced (R22)

# AE5. Both sides are named, and NEITHER remedy is applied -- moving the issue
# or moving the workspace are both decisions a person makes.
@test "a worktree in a workspace bound to another project reports the mismatch and applies neither remedy" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
    [[ "$output" == *"WEB-2870"* ]]
    [[ "$output" == *"$OTHER"* ]]
    [[ "$output" == *"$CANVAS"* ]]
    [[ "$output" == *"writes are suspended"* ]]
    [[ "$output" == *"/work:bind"* ]]
    [ "$(mutations_sent)" = "0" ]
}

# KTD14. The board put this worktree where its mapping says, so the workspace's
# project binding is not a judgement on it.
@test "a board-owned worktree in a workspace bound to another project reports ok, not misplaced" {
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::board_reserve issue-2870 WEB-2870 wt feature/web-2870-detach false
    herdr_linear::board_reservation_start issue-2870
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(mutations_sent)" = "0" ]
}

@test "a reserved but unstarted ticket does not make its namesake worktree board-owned" {
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::board_reserve issue-2870 WEB-2870 wt feature/web-2870-detach false
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
}

@test "a started reservation for another ticket leaves a boardless worktree misplaced" {
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::board_reserve issue-9999 WEB-9999 wt feature/web-9999-other false
    herdr_linear::board_reservation_start issue-9999
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
    [[ "$output" == *"writes are suspended"* ]]
}

@test "a binding stored as misplaced before the board still reads as a valid record" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
    run herdr_linear::binding_identifier "$WT"
    [ "$status" -eq 0 ]
    [ "$output" = "WEB-2870" ]
}

@test "matching projects are not a mismatch" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Most workspaces are unbound and always will be. Reporting every worktree in
# one as misplaced makes the state meaningless within a day, and a warning
# nobody can clear is one everybody learns to ignore.
@test "a workspace with no binding does not make every worktree in it misplaced" {
    bind_wt
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "a merely proposed workspace binding is not enough to judge a mismatch" {
    bind_wt
    herdr_linear::workspace_propose w1 "$CANVAS" >/dev/null
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
}

@test "an unbound worktree is never misplaced" {
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
}

# Comparing on names would let a rename silently clear a real mismatch, and two
# projects can share a name.
@test "the comparison is on the project id, not its name" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
    # The report names ids, so a reader can act on it without guessing.
    [[ "$output" == *"$OTHER"* ]]
}

# ----------------------------------------------------------------- stale (R23)

# AE6. Reported, and nothing is reopened. Someone closed that ticket on purpose.
@test "a completed issue with a live worktree is reported and not reopened" {
    bind_wt
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WEB-2870 is completed in Linear"* ]]
    [[ "$output" == *"Nothing has been changed"* ]]
    [ "$(mutations_sent)" = "0" ]
}

@test "a canceled issue is treated the same as a completed one" {
    bind_wt
    export FAKE_LINEAR_MODE=canceled_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"canceled"* ]]
    [ "$(mutations_sent)" = "0" ]
}

@test "an open issue is not stale" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------- suspending writes

@test "a misplaced binding suspends the reconciliation write until it is resolved" {
    bind_wt
    bind_ws w1 "$CANVAS"
    grant_consent "$WT"
    export FAKE_LINEAR_MODE=other_project_issue FAKE_LINEAR_ALLOW_MUTATION=1

    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]

    # And the bound itself refuses, not only reconcile's own state check.
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

@test "a stale binding suspends the reconciliation write too" {
    bind_wt
    grant_consent "$WT"
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

# ---------------------------------------------------------------- clearing

@test "the misplaced state clears when the mismatch is gone, and writes resume" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    # The remedy Shawn chose: the issue now sits in the workspace's project.
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 0 ]
}

# The FIXTURE IS HELD CONSTANT ACROSS BOTH CALLS. The test above flips it
# between them, which is why it missed this: both checks used to refuse to run
# unless the state was exactly `bound`, so once misplaced was set neither could
# run again and the next pass cleared it with the mismatch untouched. The
# suspension lasted exactly one pass.
@test "a mismatch that is still there stays misplaced on the next pass" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

@test "an issue that is still closed stays stale on the next pass" {
    bind_wt
    export FAKE_LINEAR_MODE=completed_issue
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]

    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

# UNKNOWN is not OK. The SessionEnd hook passes no workspace id it can trust, so
# placement is unjudgeable there -- and a pass that could not look must not
# clear a suspension somebody else's pass raised.
@test "a pass that cannot judge placement does not clear a misplaced binding" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
}

# THE case the narrow clearing exists for. An unbound worktree -- one whose
# candidate was declined -- must stay unbound. Making the clear unconditional
# turns classify into something that BINDS a worktree nobody bound, which is the
# one thing the whole propose-and-confirm design exists to prevent.
@test "classify never binds a worktree that was never bound" {
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
}

@test "classify never binds a worktree whose candidate was declined" {
    herdr_linear::binding_propose "$WT" WEB-2870 >/dev/null
    herdr_linear::binding_decline "$WT" WEB-2870
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
}

# The branch-downgrade case is covered by the read path rather than by clearing:
# the downgrade is computed on every read, so even a blanket write could not
# resurrect it. Kept because it pins that interaction.
@test "clearing does not resurrect a binding downgraded by a branch change" {
    bind_wt
    git -C "$WT" checkout -q -b somewhere-else
    [ "$(herdr_linear::binding_state "$WT")" = "proposed" ]
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "proposed" ]
}

# ------------------------------------------------------------- the skill

@test "the bind skill documents both remedies for a misplaced binding" {
    body="$(cat "$ROOT/skills/bind/SKILL.md")"
    [[ "$body" == *"misplaced"* ]]
}

# ------------------------------------------------------ session scope (R10-R13)

# The session binding and the scope world the fake tracker answers membership
# from. The fake's issue reads still answer by mode; only Scope* reads use this.
scope_world() {
    export FAKE_LINEAR_SCOPE_WORLD="$WORK/world.json"
    cat > "$FAKE_LINEAR_SCOPE_WORLD" <<'JSON'
{"teams": [{"id": "t-web", "key": "WEB", "name": "Web"}, {"id": "t-ops", "key": "OPS", "name": "Ops"}],
 "initiatives": [{"id": "i-media", "name": "Media Hub"}],
 "projects": {"44444444-4444-4444-8444-444444444444": {"name": "AI Canvas Tools", "teams": ["t-web"], "initiatives": ["i-media"]},
              "99999999-9999-4999-8999-999999999999": {"name": "Ops Work", "teams": ["t-ops"], "initiatives": []}},
 "milestones": {"m-canvas-1": "44444444-4444-4444-8444-444444444444", "m-ops-1": "99999999-9999-4999-8999-999999999999"},
 "issues": {"WEB-2870": {"team": "t-web", "project": "44444444-4444-4444-8444-444444444444"},
            "WEB-2871": {"team": "t-web", "project": "44444444-4444-4444-8444-444444444444"},
            "OPS-7": {"team": "t-ops", "project": "99999999-9999-4999-8999-999999999999"}}}
JSON
}

bind_session() {   # bind_session <kind> <id> <name>
    . "$ROOT/lib/session-binding.sh"
    local n
    n="$(herdr_linear::session_binding_propose default "$1" "$2" "$3")"
    herdr_linear::session_binding_confirm default "$n"
}

bind_wt_to() {   # bind_wt_to <identifier>
    local n; n="$(herdr_linear::binding_propose "$WT" "$1")"; herdr_linear::binding_confirm "$WT" "$1" "$n"
}

@test "AE3: a worktree bound to an OPS issue in a WEB session is reported outside the session, and its binding is unchanged" {
    scope_world
    bind_session team t-web "WEB Web"
    bind_wt_to OPS-7
    before="$(herdr_linear::binding_read "$WT")"
    run herdr_linear::check_session_scope "$WT"
    [ "$status" -eq "$HERDR_LINEAR_STATE_OUTSIDE_SESSION" ]
    [[ "$output" == *"OPS-7"* ]]
    [[ "$output" == *"WEB Web"* ]]
    run herdr_linear::classify "$WT" ""
    [[ "$output" == *"outside"* ]]
    [ "$(herdr_linear::binding_state "$WT")" = bound ]
    [ "$(herdr_linear::binding_identifier "$WT")" = OPS-7 ]
    [ "$(mutations_sent)" = "0" ]
}

@test "an issue inside the session's scope is not reported" {
    scope_world
    bind_session team t-web "WEB Web"
    bind_wt_to WEB-2870
    run herdr_linear::check_session_scope "$WT"
    [ "$status" -eq "$HERDR_LINEAR_STATE_OK" ]
    [ -z "$output" ]
}

@test "in an unbound or organization session nothing is reported and nothing is read" {
    scope_world
    bind_wt_to OPS-7
    run herdr_linear::check_session_scope "$WT"
    [ "$status" -eq "$HERDR_LINEAR_STATE_OK" ]; [ -z "$output" ]
    bind_session organization org-1 "Acme"
    run herdr_linear::check_session_scope "$WT"
    [ "$status" -eq "$HERDR_LINEAR_STATE_OK" ]; [ -z "$output" ]
    local n; n="$(grep -c 'Scope' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0
    [ "${n:-0}" = 0 ]
}

@test "an unknown membership answer reports nothing and refuses nothing" {
    scope_world
    bind_session team t-web "WEB Web"
    bind_wt_to OPS-7
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    run herdr_linear::check_session_scope "$WT"
    [ "$status" -eq "$HERDR_LINEAR_STATE_UNKNOWN" ]
    [ -z "$output" ]
    run bind_ws w1 "$OTHER"
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::workspace_project w1)" = "$OTHER" ]
}

@test "in an unbound session every existing placement answer is unchanged" {
    scope_world
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq "$HERDR_LINEAR_STATE_MISPLACED" ]
    bind_ws w2 "$OTHER"
    [ "$(herdr_linear::workspace_project w2)" = "$OTHER" ]
}

@test "in a team session a workspace binds to that team's project, and another team's project is refused" {
    scope_world
    bind_session team t-web "WEB Web"
    bind_ws w1 "$CANVAS"
    [ "$(herdr_linear::workspace_project w1)" = "$CANVAS" ]
    run herdr_linear::workspace_propose w2 "$OTHER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside"* ]]
    [ "$(herdr_linear::workspace_state w2)" = unbound ]
}

@test "in an initiative session a project outside the initiative is refused" {
    scope_world
    bind_session initiative i-media "Media Hub"
    bind_ws w1 "$CANVAS"
    run herdr_linear::workspace_propose w2 "$OTHER"
    [ "$status" -ne 0 ]
}

@test "a confirmation cannot bind a project the session's scope refuses" {
    scope_world
    n="$(herdr_linear::workspace_propose w2 "$OTHER")"
    bind_session team t-web "WEB Web"
    run herdr_linear::workspace_confirm w2 "$OTHER" "$n"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::workspace_state w2)" != bound ]
}

@test "AE4: in a project session a workspace binds to a milestone of that project, and a project is refused" {
    scope_world
    bind_session project "$CANVAS" "AI Canvas Tools"
    run herdr_linear::workspace_propose w1 "$CANVAS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"milestone or issue"* ]]
    run herdr_linear::workspace_propose w1 "$OTHER"
    [ "$status" -ne 0 ]
    n="$(herdr_linear::workspace_propose_part w1 milestone m-canvas-1)"
    herdr_linear::workspace_confirm_part w1 milestone m-canvas-1 "$n"
    [ "$(herdr_linear::workspace_state w1)" = bound ]
    [ "$(herdr_linear::workspace_project w1)" = "$CANVAS" ]
    [ "$(herdr_linear::workspace_read w1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["part_kind"], d["part_id"])')" = "milestone m-canvas-1" ]
}

@test "in a project session a milestone or issue of another project is refused" {
    scope_world
    bind_session project "$CANVAS" "AI Canvas Tools"
    run herdr_linear::workspace_propose_part w1 milestone m-ops-1
    [ "$status" -ne 0 ]
    run herdr_linear::workspace_propose_part w1 issue OPS-7
    [ "$status" -ne 0 ]
    n="$(herdr_linear::workspace_propose_part w1 issue WEB-2871)"
    herdr_linear::workspace_confirm_part w1 issue WEB-2871 "$n"
    [ "$(herdr_linear::workspace_state w1)" = bound ]
}

@test "a part binding needs a project session, a known kind, and a matching confirmation" {
    scope_world
    run herdr_linear::workspace_propose_part w1 milestone m-canvas-1
    [ "$status" -ne 0 ]
    bind_session project "$CANVAS" "AI Canvas Tools"
    run herdr_linear::workspace_propose_part w1 cycle c-1
    [ "$status" -ne 0 ]
    n="$(herdr_linear::workspace_propose_part w1 milestone m-canvas-1)"
    run herdr_linear::workspace_confirm_part w1 issue WEB-2871 "$n"
    [ "$status" -ne 0 ]
    run herdr_linear::workspace_confirm w1 "$CANVAS" "$n"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::workspace_state w1)" != bound ]
}

@test "in a team session a part binding is refused even when Linear cannot answer membership" {
    scope_world
    bind_session team t-web "WEB Web"
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    run herdr_linear::workspace_propose_part w1 milestone m-canvas-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"only a session bound to a project"* ]]
    [ "$(herdr_linear::workspace_state w1)" = unbound ]
}

@test "in a project session, a worktree on an issue of the project in a milestone workspace is not misplaced, and start finds that workspace" {
    scope_world
    bind_session project "$CANVAS" "AI Canvas Tools"
    bind_wt
    n="$(herdr_linear::workspace_propose_part w1 milestone m-canvas-1)"
    herdr_linear::workspace_confirm_part w1 milestone m-canvas-1 "$n"
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq "$HERDR_LINEAR_STATE_OK" ]
    . "$ROOT/lib/herdr-read.sh"; . "$ROOT/lib/herdr-write.sh"
    export HERDR_BIN="$FIX/fake-herdr.sh" FAKE_HERDR_RECORD_DIR="$WORK/hrec" FAKE_HERDR_WORKSPACES="w1=Canvas"
    [ "$(herdr_linear::project_space "$CANVAS")" = w1 ]
}

@test "a workspace rebound from a milestone to a project in an unbound session loses its part" {
    scope_world
    bind_session project "$CANVAS" "AI Canvas Tools"
    n="$(herdr_linear::workspace_propose_part w1 milestone m-canvas-1)"
    herdr_linear::workspace_confirm_part w1 milestone m-canvas-1 "$n"
    herdr_linear::session_binding_unbind default
    bind_ws w1 "$OTHER"
    [ "$(herdr_linear::workspace_read w1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print(repr(d["part_kind"]), repr(d["part_id"]))')" = "'' ''" ]
}

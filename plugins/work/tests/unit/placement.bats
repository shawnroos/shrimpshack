#!/usr/bin/env bats

load setup_common

# U7 — where a session opens.
#
# A space is a project, a tab is a piece of work, a pane is a session. So a
# session for an issue opens in the space bound to the issue's project, in the
# tab that ticket owns or a new one -- never beside whatever pane has focus.
#
# Every herdr call goes to tests/fixtures/fake-herdr.sh. This suite runs inside
# the user's real terminal, and nothing here may split, create or move anything
# in it.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    WORK="$(cd "$WORK" && pwd -P)"

    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/wt"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export FAKE_LINEAR_MODE=found_child
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_RECORD_DIR="$WORK/hrec"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=10
    # Three live spaces. wG's LABEL names the issue's project; only a record
    # can say it is that project's space.
    export FAKE_HERDR_WORKSPACES='wA=Plugins,wG=AI Canvas Tools,wR=AI-Editor'
    # The space this session is working from. No pane id, so the reader takes
    # the environment's word for it.
    export HERDR_WORKSPACE_ID=wA
    mkdir -p "$WORK/root/alpha" "$WORK/rec" "$WORK/cache" "$WORK/hrec"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_PLACEPLACEPLACEPLAC" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh herdr-read.sh repos.sh start.sh states.sh herdr-write.sh; do
        . "$ROOT/lib/$f"
    done

    PROJECT="$WORK/root/alpha"
    git -C "$PROJECT" init -q -b main
    git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    WT="$WORK/wt/acme/ai-canvas-tools/WEB-3318-ai-tools-drawer-is-blank-when-a-still"
    mkdir -p "${WT%/*}"
    git -C "$PROJECT" worktree add -q -b feature/WEB-3318-x "$WT" >/dev/null 2>&1
    n="$(herdr_linear::binding_propose "$WT" WEB-3318)"
    herdr_linear::binding_confirm "$WT" WEB-3318 "$n"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

PID=44444444-4444-4444-8444-444444444444

# A person's answer to "bind this space to that project", recorded the only way
# the store accepts one.
bind_space() {
    local n
    n="$(herdr_linear::workspace_propose "$1" "$2")"
    herdr_linear::workspace_confirm "$1" "$2" "$n"
}

herdr_calls() { local n; n="$(grep -c -- "$1" "$FAKE_HERDR_RECORD_DIR/argv" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
creations() { local n; n="$(grep -cE '^(tab create|pane split|workspace create)' "$FAKE_HERDR_RECORD_DIR/argv" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------ the space (R17)

# THE property. The focused space is wA; the issue's project is bound to wG.
@test "a bound space receives the session and the focused space does not" {
    bind_space wG "$PID"
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
    [ "$(herdr_calls '--workspace wA')" = "0" ]
    # Never an untargeted split: herdr splits the focused pane when given none.
    [ "$(herdr_calls '^pane split --')" = "0" ]
    [[ "$stderr" == *"wG"* ]]
}

# The session pane is opened in the worktree, and the tab carries the ticket.
@test "a new tab opens in the worktree and is labelled with the identifier" {
    bind_space wG "$PID"
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    [ "$(herdr_calls "tab create --workspace wG --cwd $WT --label WEB-3318")" = "1" ]
}

# ------------------------------------------------------------- the tab (R20)

@test "the tab a session opened in is recorded on the ticket's binding" {
    bind_space wG "$PID"
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    run herdr_linear::binding_tab "$WT"
    [[ "$output" == wG:t* ]]
}

@test "a ticket that has a tab gets a pane inside it, not a second tab" {
    bind_space wG "$PID"
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    tab="$(herdr_linear::binding_tab "$WT")"
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'tab create')" = "1" ]
    [ "$(herdr_calls "pane split wG:")" = "1" ]
    [ "$(herdr_linear::tab_of_pane "$output")" = "$tab" ]
}

# The record is only an authority while the tab it names is still there.
@test "a recorded tab that herdr no longer has is replaced, and the record follows" {
    bind_space wG "$PID"
    herdr_linear::binding_set_tab "$WT" wG:t999
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
    [ "$(herdr_linear::binding_tab "$WT")" != "wG:t999" ]
}

# A ticket's tab that sits in another space is not in the project's space.
@test "a recorded tab in another space is not reused" {
    bind_space wG "$PID"
    herdr_linear::binding_set_tab "$WT" wA:t1
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
    [ "$(herdr_calls 'pane split wA:')" = "0" ]
}

# -------------------------------------------------- the question (R18, R19)

# R18. The pairing is already in hand: the space this session works from and the
# issue's project. The verb proposes it; only a person's answer records it.
@test "an unbound space proposes binding it to the project and records nothing" {
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [ -z "$output" ]
    [[ "$stderr" == *"wA"* ]]
    [[ "$stderr" == *"$PID"* ]]
    [ "$(herdr_linear::workspace_state wA)" = "unbound" ]
    [ "$(creations)" = "0" ]
}

# R19. Both sides are known and disagree. Report, offer both moves, pick none.
@test "a space bound to a different project reports misplaced and moves nothing" {
    bind_space wA proj-other
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [[ "$stderr" == *"proj-other"* ]]
    [[ "$stderr" == *"$PID"* ]]
    [[ "$stderr" == *"either"* ]]
    [ "$(herdr_linear::workspace_project wA)" = "proj-other" ]
    [ "$(creations)" = "0" ]
}

# KTD13. On the machine this was written for, the one bound space's label names
# a different project than its record. A label is prose.
@test "a space whose label names the project but whose record does not is unbound" {
    export HERDR_WORKSPACE_ID=wG
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [[ "$stderr" == *"wG"* ]]
    [ "$(creations)" = "0" ]
}

@test "several spaces bound to the project are a question naming each" {
    bind_space wG "$PID"
    bind_space wR "$PID"
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [[ "$stderr" == *"wG"* ]]
    [[ "$stderr" == *"wR"* ]]
    [ "$(creations)" = "0" ]
}

# A record outlives the space it names. Offering a closed space as the answer
# would fail inside `tab create`, after the question could have been asked.
@test "a bound space herdr no longer reports is not a candidate" {
    bind_space wZ "$PID"
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [ "$(creations)" = "0" ]
}

# ---------------------------------------------------- nobody to ask (R21)

# The verb cannot tell whether a person is watching, so the question is kept
# where the next session start will show it, as a skipped write is.
@test "an unanswered placement is recorded on the binding, and a placed session clears it" {
    run herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    run herdr_linear::binding_pending_placement "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$PID"* ]]

    bind_space wG "$PID"
    run herdr_linear::open_session "$WT"
    [ "$status" -eq 0 ]
    run herdr_linear::binding_pending_placement "$WT"
    [ "$status" -ne 0 ]
}

# An issue with no project has no space to be bound to. Asked, not guessed.
@test "an issue with no project is a question, not a placement" {
    export FAKE_LINEAR_MODE=traversal_identifier
    bind_space wG "$PID"
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [[ "$stderr" == *"no project"* ]]
    [ "$(creations)" = "0" ]
}

@test "a worktree bound to nothing opens no session" {
    unbound="$WORK/wt/acme/ai-canvas-tools/loose"
    git -C "$PROJECT" worktree add -q -b f/loose "$unbound" >/dev/null 2>&1
    bind_space wG "$PID"
    run herdr_linear::open_session "$unbound"
    [ "$status" -ne 0 ]
    [ "$status" -ne "$HERDR_LINEAR_SESSION_ASK" ]
    [ "$(creations)" = "0" ]
}

# A proposal nobody confirmed is not a binding, so it offers no space.
@test "a merely proposed space is not a candidate" {
    herdr_linear::workspace_propose wG "$PID" >/dev/null
    run --separate-stderr herdr_linear::open_session "$WT"
    [ "$status" -eq "$HERDR_LINEAR_SESSION_ASK" ]
    [ "$(creations)" = "0" ]
}

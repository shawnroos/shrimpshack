#!/usr/bin/env bats
# Creating work — an issue, a sub-issue, or a project.
#
# Every verb here writes to Linear, so every one is shadow-gated, and in shadow
# mode NOTHING local is created either. A worktree bound to an issue that was
# never filed is a dangling reference; a herdr space bound to a project that
# does not exist is worse, because it looks like a place to work.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_RECORD_DIR="$WORK/hrec"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_WRITE_ALLOWLIST="$WORK/write-enabled"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    export HERDR_LINEAR_PANE_POLL_MS=5
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/hrec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_CREATECREATECREATE1" > "$LINEAR_SECRETS_FILE"

    git -C "$WORK/Slate" init -q -b main
    git -C "$WORK/Slate" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh \
             herdr-read.sh herdr-write.sh start.sh create.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/worktrees/current"
    git -C "$WORK/Slate" worktree add -q -b feature/web-2870-detach "$WT" >/dev/null 2>&1

    DESC="$WORK/d.md"
    printf '## Problem\n\nA real problem for the actor, at length.\n\n## Solution\n\nThe world without it.\n\n## Proposal\n\nWhat we build.\n' > "$DESC"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
enable_writes() { printf '%s\n' "$(cd "$WT" && pwd -P)" > "$HERDR_LINEAR_WRITE_ALLOWLIST"; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------------ context

# "In the current project" means derived, not asked for. Asking which team and
# which project every time is how a command stops being worth typing.
@test "the current project and team come from the bound issue" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::current_context "$WT"
    [[ "$output" == *"project=44444444-4444-4444-8444-444444444444"* ]]
    [[ "$output" == *"team=55555555-5555-4555-8555-555555555555"* ]]
    [[ "$output" == *"issue=WEB-2870"* ]]
}

# The first issue in a new space has no bound worktree to ask.
@test "a bound workspace supplies the project when the worktree cannot" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::current_context "$WT" w1
    [[ "$output" == *"project=proj-abc"* ]]
}

@test "a merely proposed workspace supplies nothing" {
    herdr_linear::workspace_propose w1 proj-abc >/dev/null
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::current_context "$WT" w1
    [[ "$output" == *"project="$'\n'* ]] || [[ "$output" != *"proj-abc"* ]]
}

# --------------------------------------------------------------- new issue

@test "a new issue is created in the current project, with a session" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" "" newthing
    [ "$status" -eq 0 ]
    ident="$(printf '%s' "$output" | cut -f1)"
    path="$(printf '%s' "$output" | cut -f2)"
    [ "$ident" = "WEB-4001" ]
    [ -d "$path" ]
    [ "$(herdr_linear::binding_identifier "$path")" = "WEB-4001" ]
    # Filed into the project it was derived from.
    run grep -c '44444444-4444-4444-8444-444444444444' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" -ge 1 ]
}

@test "a new issue opens a pane in its own worktree" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" "" newthing
    [ "$status" -eq 0 ]
    pane="$(printf '%s' "$output" | cut -f3)"
    [ -n "$pane" ]
    run grep -c -- "--cwd $HERDR_LINEAR_SLATE_ROOT/worktrees/newthing" "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$output" = "1" ]
}

@test "with no team derivable, nothing is created and the reason is given" {
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"cannot tell which team"* ]]
    [ "$(sent issueCreate)" = "0" ]
}

@test "a description that fails validation stops before anything is filed" {
    bind_wt; enable_writes
    printf '## Why\n\nreal\n\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n' > "$WORK/bad.md"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::new_issue "$WT" "A new thing" "$WORK/bad.md"
    [ "$status" -eq 1 ]
    [ "$(sent issueCreate)" = "0" ]
}

# ----------------------------------------------------------- new sub-issue

@test "a sub-issue is parented to the issue this worktree is bound to" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4002
    run herdr_linear::new_sub_issue "$WT" "A smaller thing" "$DESC" "" smaller
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | cut -f1)" = "WEB-4002" ]
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *"parentId"* ]]
}

# A sub-issue with no parent is just an issue, and silently filing one is not
# what was asked for.
@test "a sub-issue is refused when the worktree is not bound" {
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::new_sub_issue "$WT" "A smaller thing" "$DESC"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"not bound"* ]]
    [ "$(sent issueCreate)" = "0" ]
}

# -------------------------------------------------------------- new project

@test "a new project creates the herdr space and binds the two" {
    enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_PROJECT_ID=proj-new
    printf '# A New Project\n\nWhat it is for.\n' > "$WORK/p.md"
    run herdr_linear::new_project "A New Project" "$WORK/p.md" team-web
    [ "$status" -eq 0 ]
    pid="$(printf '%s' "$output" | cut -f1)"
    ws="$(printf '%s' "$output" | cut -f2)"
    [ "$pid" = "proj-new" ]
    [ -n "$ws" ]
    [ "$(herdr_linear::workspace_state "$ws")" = "bound" ]
    [ "$(herdr_linear::workspace_project "$ws")" = "proj-new" ]
}

@test "a project is created on the team it was given" {
    enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "P" "$WORK/p.md" team-web
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *'"teamIds": ["team-web"]'* ]] || [[ "$body" == *'team-web'* ]]
}

# Without herdr the project still exists and is usable, so this reports rather
# than failing silently.
@test "an unreachable herdr server leaves the project made and says so" {
    enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_HERDR_MODE=not_running
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run --separate-stderr herdr_linear::new_project "P" "$WORK/p.md" team-web
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"no space was made"* ]]
    [ "$(sent projectCreate)" = "1" ]
}

# ------------------------------------------------------------- shadow mode

# NOTHING local is created either. A worktree bound to an issue that was never
# filed is a dangling reference.
@test "shadow mode creates no issue, no worktree and no pane" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" "" newthing
    [ "$status" -eq 3 ]
    [ "$(sent issueCreate)" = "0" ]
    [ ! -e "$HERDR_LINEAR_SLATE_ROOT/worktrees/newthing" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create issue"* ]]
}

@test "shadow mode creates no project and no space" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "P" "$WORK/p.md" team-web
    [ "$status" -eq 3 ]
    [ "$(sent projectCreate)" = "0" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create project"* ]]
}

@test "a sub-issue in shadow mode names its parent and creates nothing" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::new_sub_issue "$WT" "A smaller thing" "$DESC"
    [ "$status" -eq 3 ]
    [[ "$output" == *"under WEB-2870"* ]]
    [ "$(sent issueCreate)" = "0" ]
}

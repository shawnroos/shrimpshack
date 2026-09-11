#!/usr/bin/env bats

load setup_common

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
    # Resolved: the readers derive with `pwd -P`, so an unresolved fixture path
    # compares unequal to every answer they give.
    WORK="$(cd "$WORK" && pwd -P)"
    # The containment boundary is a plain directory holding projects, as
    # ~/projects is; the repository is the project inside it.
    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    PROJECT="$WORK/root/alpha"
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/wt"
    WT_ROOT="$WORK/wt"
    # found_parent answers every fetch with WEB-2870 in AI Canvas Tools, so a
    # filed issue's worktree derives this path whatever identifier was filed.
    NEW_WT="$WT_ROOT/acme/ai-canvas-tools/WEB-2870-tool-detach-foreground"
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
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    export HERDR_LINEAR_PANE_POLL_MS=5
    mkdir -p "$PROJECT" "$WORK/rec" "$WORK/hrec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_CREATECREATECREATE1" > "$LINEAR_SECRETS_FILE"

    git -C "$PROJECT" init -q -b main
    git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh \
             herdr-read.sh herdr-write.sh repos.sh start.sh context.sh create.sh; do . "$ROOT/lib/$f"; done

    WT="$PROJECT/worktrees/current"
    git -C "$PROJECT" worktree add -q -b feature/web-2870-detach "$WT" >/dev/null 2>&1

    DESC="$WORK/d.md"
    printf '## Problem\n\nA real problem for the actor, at length.\n\n## Solution\n\nThe world without it.\n\n## Proposal\n\nWhat we build.\n' > "$DESC"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
# The answer a person would have given, recorded the only way the store accepts
# one: propose, then confirm with the nonce it returned. Scoped to the team and
# project the question named, and to the branch it was answered on.
grant_consent() {
    local dir="$1" team="$2" project="${3:-}" n
    n="$(herdr_linear::consent_propose "$dir" "$team" "$project")"
    herdr_linear::consent_confirm "$dir" "$team" "$project" "$n"
}
TEAM_ID=55555555-5555-4555-8555-555555555555
PROJECT_ID=44444444-4444-4444-8444-444444444444
enable_writes() { grant_consent "$WT" "${1:-$TEAM_ID}" "${2-$PROJECT_ID}"; }
# The repository question answered for the scope a filed issue lands in. Only
# the tests whose intent is a worktree need it: a scope with no recorded
# repository asks rather than creates, which is its own test below.
record_repo() { herdr_linear::record_scope_repo "$PROJECT" "project-$PROJECT_ID" "team-$TEAM_ID"; }
# new_project names a team and no project, and is answered for the directory it
# is run from -- which needs no binding of its own.
enable_root_writes() { grant_consent "${1:-$PWD}" team-web ""; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------------ context

# "In the current project" means derived, not asked for. Asking which team and
# which project every time is how a command stops being worth typing.
@test "the current project and team come from the bound issue" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::current_context "$WT"
    [ "$(herdr_linear::context_fields "$output" project_id team_id identifier)" \
      = "$PROJECT_ID"$'\t'"$TEAM_ID"$'\t'"WEB-2870" ]
}

# The first issue in a new space has no bound worktree to ask.
@test "a bound workspace supplies the project when the worktree cannot" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::current_context "$WT" w1
    [ "$(herdr_linear::context_fields "$output" project_id)" = "proj-abc" ]
}

# The other half of the same case. A project answers the TEAM too, or the first
# issue in a new space is unfileable: `_create_issue` refuses on an empty team,
# and before this the workspace filled project and left team blank forever.
# Covers AE1.
@test "a bound workspace supplies the team when its project has one team" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_PROJECT_TEAMS=one
    run --separate-stderr herdr_linear::current_context "$WT" w1
    [ "$(herdr_linear::context_fields "$output" project_id team_id)" \
      = "proj-abc"$'\t'"$TEAM_ID" ]
}

# AE1's second half: "states which team it resolved" needs the NAME, and R4
# wants the fact and its source together. The id alone reads as an opaque uuid
# in the session output, which is the gap this closes.
@test "a team resolved from the project is named, not just identified" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_PROJECT_TEAMS=one
    run --separate-stderr herdr_linear::current_context "$WT" w1
    [ "$(herdr_linear::context_fields "$output" project_id team_name)" \
      = "proj-abc"$'\t'"Web" ]
}

# The other arm. A bound issue already carries its team's name in the fetch, so
# the name must come from that response rather than a second project query.
@test "a team resolved from the bound issue is named too" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::current_context "$WT"
    [ "$(herdr_linear::context_fields "$output" team_id team_name)" \
      = "$TEAM_ID"$'\t'"Web Creation" ]
    [ "$(sent 'project(id:')" -eq 0 ]
}

# Picking one of several is how work is filed into a team nobody chose.
@test "a project spanning several teams supplies no team" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_PROJECT_TEAMS=many
    run --separate-stderr herdr_linear::current_context "$WT" w1
    # Without this the test passes on code that never looked at all:
    # a hardcoded empty team satisfies the assertion below.
    [ "$(sent 'project(id:')" -ge 1 ]
    # The whole line, not the two empty fields alone: a reader that returns
    # nothing at all -- unparseable output, a crash -- gives an empty string
    # here, and an emptiness assertion would call that the right answer. The
    # `many` fixture's first team is the pair the bound issue carries, so this
    # is also what stays red on a resolver that picks the first of several.
    [ "$(herdr_linear::context_fields "$output" project_id team_id team_name)" \
      = "proj-abc"$'\t'$'\t' ]
}

@test "a project with no team supplies no team" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_PROJECT_TEAMS=none
    run --separate-stderr herdr_linear::current_context "$WT" w1
    # Without this the test passes on code that never looked at all:
    # a hardcoded empty team satisfies the assertion below.
    [ "$(sent 'project(id:')" -ge 1 ]
    [ "$(herdr_linear::context_fields "$output" project_id team_id team_name)" \
      = "proj-abc"$'\t'$'\t' ]
}

# The bound issue still wins: it is the more specific fact, and a project lookup
# must not override the team the issue itself names. The lookup must not even
# fire -- without that count, dropping the `[ -z "$team" ]` guard stays green
# here whenever the project happens to answer the same id.
@test "a bound issue's team is not replaced by its project's" {
    bind_wt
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_PROJECT_TEAMS=many
    run --separate-stderr herdr_linear::current_context "$WT" w1
    [ "$(sent 'project(id:')" -eq 0 ]
    [ "$(herdr_linear::context_fields "$output" team_id)" = "$TEAM_ID" ]
}

# The whole point of the fix, at the verb that was refusing.
@test "an issue can be filed from a workspace-bound worktree with no binding" {
    record_repo
    enable_writes "$TEAM_ID" proj-abc
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_NEW_IDENT=WEB-4002 FAKE_LINEAR_PROJECT_TEAMS=one
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" w1
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | cut -f1)" = "WEB-4002" ]
}

# Covers AE2. Naming the candidates is the whole of the ask half of act-or-ask:
# "cannot tell which team" leaves the reader to go find out which teams exist.
# Writes are ENABLED and mutation is permitted here on purpose -- otherwise the
# fixture's own 97 gate, not the refusal, is what kept issueCreate unsent.
@test "a project spanning three teams names all three and files nothing" {
    enable_writes
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_PROJECT_TEAMS=many
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" w1
    [ "$status" -eq "$HERDR_LINEAR_CREATE_NO_CONTEXT" ]
    [[ "$output" == *"Web"* ]]
    [[ "$output" == *"Brand"* ]]
    [[ "$output" == *"Platform"* ]]
    [ "$(sent issueCreate)" -eq 0 ]
}

@test "a merely proposed workspace supplies nothing" {
    herdr_linear::workspace_propose w1 proj-abc >/dev/null
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::current_context "$WT" w1
    [ "$(herdr_linear::context_fields "$output" project_id team_id identifier)" \
      = $'\t'$'\t' ]
}

# --------------------------------------------------------------- new issue

# The shared body's whole output contract: an identifier, and nothing else. A
# progress line on stdout prepends a sentence to what every tail reads back as
# the identifier, which is the defect start.sh records having had once with
# `git worktree add`.
@test "the shared filing body prints the identifier and nothing else" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::_file_issue "$WT" "A new thing" "$DESC" "" ""
    [ "$status" -eq 0 ]
    [ "$output" = "WEB-4001" ]
}

# A field nobody reads is a field nobody should ask for: the fixture prunes its
# answer to the selection it was sent, so asking for more is asking the tracker
# for data this plugin then drops. Scoped to the mutation's own selection --
# fetch_issue selects branchName for a reason.
@test "the issue-create request asks for no field the caller never reads" {
    record_repo
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 0 ]
    [ "$(sent issueCreate)" -eq 1 ]
    [ "$(sent 'issueCreate.*branchName')" -eq 0 ]
    [ "$(sent 'issueCreate.*identifier')" -eq 1 ]
}

@test "a new issue is created in the current project, with a session" {
    record_repo
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
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
    record_repo
    # R17. The session opens in the space bound to the issue's project.
    export FAKE_HERDR_WORKSPACES='wG=AI Canvas Tools'
    n="$(herdr_linear::workspace_propose wG "$PROJECT_ID")"
    herdr_linear::workspace_confirm wG "$PROJECT_ID" "$n"
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 0 ]
    pane="$(printf '%s' "$output" | cut -f3)"
    [ -n "$pane" ]
    run grep -c -- "--cwd $NEW_WT" "$FAKE_HERDR_RECORD_DIR/argv"
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

# AE6. The create path composes a description FRESH from the template, so the
# spine is what was asked for and its absence means the template was abandoned
# halfway. Lenient mode -- right for a description that earned its own headings
# -- would file this with only a note. Strict refuses it.
#
# CREATE_REFUSED is shared with a missing title, so the exit code alone proves
# nothing. The stderr line is what says WHICH refusal this was, and it is the
# unprefixed form: lenient writes "description: note: not using ...".
@test "a description with no template headings is refused before anything is filed" {
    bind_wt; enable_writes
    printf '## Why\n\nA real reason, stated at length for whoever reads it.\n\n## The shape of this work\n\nWhat we do about it.\n' > "$WORK/headingless.md"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$WORK/headingless.md"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"description: not using the Problem/Solution/Proposal shape"* ]]
    [ "$(sent issueCreate)" = "0" ]
}

# The same bar on the sub-issue path, which reaches the same validate call.
@test "a sub-issue with no template headings is refused before anything is filed" {
    bind_wt; enable_writes
    printf '## Why\n\nA real reason, stated at length for whoever reads it.\n\n## The shape of this work\n\nWhat we do about it.\n' > "$WORK/headingless.md"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::new_sub_issue "$WT" "A smaller thing" "$WORK/headingless.md"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"description: not using the Problem/Solution/Proposal shape"* ]]
    [ "$(sent issueCreate)" = "0" ]
}

# ----------------------------------------------------------- new sub-issue

@test "a sub-issue is parented to the issue this worktree is bound to" {
    record_repo
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4002
    run --separate-stderr herdr_linear::new_sub_issue "$WT" "A smaller thing" "$DESC" ""
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
    enable_root_writes
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
    enable_root_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "P" "$WORK/p.md" team-web
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *'"teamIds": ["team-web"]'* ]] || [[ "$body" == *'team-web'* ]]
}

# Without herdr the project still exists and is usable, so this reports rather
# than failing silently.
@test "an unreachable herdr server leaves the project made and says so" {
    enable_root_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_HERDR_MODE=not_running
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run --separate-stderr herdr_linear::new_project "P" "$WORK/p.md" team-web
    [ "$status" -eq 5 ]
    [[ "$stderr" == *"no space was made"* ]]
    [ "$(sent projectCreate)" = "1" ]
}

# ------------------------------------------------------------- shadow mode

# NOTHING local is created either. A worktree bound to an issue that was never
# filed is a dangling reference.
@test "shadow mode creates no issue, no worktree and no pane" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 3 ]
    [ "$(sent issueCreate)" = "0" ]
    [ ! -e "$WT_ROOT" ]
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

# ------------------------------------------------------------- the gate (F1)

# The answer is per directory. Answering in one worktree must not file real
# issues from every other worktree on the machine.
@test "an answer given in an unrelated worktree does not enable issue creation" {
    bind_wt
    mkdir -p "$PROJECT/worktrees/elsewhere"
    git -C "$PROJECT" worktree add -q -b feature/elsewhere-x "$PROJECT/worktrees/elsewhere2" >/dev/null 2>&1
    grant_consent "$PROJECT/worktrees/elsewhere2" "$TEAM_ID" "$PROJECT_ID"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 3 ]
    [ "$(sent issueCreate)" = "0" ]
    [ ! -e "$WT_ROOT" ]
    # R9a holds for every verb, not only the session-end hook: the skip is
    # recorded where the next session is told about it.
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"A new thing"* ]]
}

# A proposal is not an answer: nobody confirmed it.
@test "a proposed but unconfirmed answer does not enable issue creation" {
    bind_wt
    herdr_linear::consent_propose "$WT" "$TEAM_ID" "$PROJECT_ID" >/dev/null
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 3 ]
    [ "$(sent issueCreate)" = "0" ]
}

# An answer given for one team does not cover a project on another. Naming the
# team is the whole scope of the question new_project asks.
@test "an answer for another team does not enable project creation" {
    enable_root_writes "$PWD"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "P" "$WORK/p.md" team-brand
    [ "$status" -eq 3 ]
    [ "$(sent projectCreate)" = "0" ]
    run herdr_linear::binding_pending_consent "$PWD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"create project \"P\""* ]]
}

# ------------------------------------------------------- partial vs failed (F3)

# Exit 4 and exit 5 answer opposite questions: whether a project now exists.
@test "a project that was never created fails rather than reporting a partial" {
    enable_root_writes
    export HERDR_LINEAR_CURL_BIN=/bin/false
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "P" "$WORK/p.md" team-web
    [ "$status" -eq 4 ]
    run grep -q 'workspace create' "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------ created_children (F4)

# created_children IS the write boundary. An issue this plugin filed but never
# recorded can never be written to by it.
@test "a created sub-issue is recorded as a child of the parent worktree" {
    record_repo
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4002
    run --separate-stderr herdr_linear::new_sub_issue "$WT" "A smaller thing" "$DESC" ""
    [ "$status" -eq 0 ]
    rec="$(herdr_linear::binding_read "$WT")"
    [[ "$rec" == *"WEB-4002"* ]]
    run herdr_linear::write_allowed "$WT" WEB-4002
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------- workspace label (F8)

@test "the workspace label argument is the label the space is created with" {
    enable_root_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    run herdr_linear::new_project "AI Canvas Tools" "$WORK/p.md" team-web "canvas"
    [ "$status" -eq 0 ]
    run grep -c -- '--label canvas' "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$output" = "1" ]
}

# ------------------------------------------------------------ scope signals
#
# R7. Two signals, reported as values, never a refusal. Each test asserts what
# was reported and that the reader exited 0 -- a non-zero exit could not tell
# "reported negative" from "crashed".

@test "the scope reader reports the path and the Linear project it resolved" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::scope_signals "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"path=inside"* ]]
    [[ "$output" == *"project=44444444-4444-4444-8444-444444444444"* ]]
}

# AE5. Unknown is not negative: the worktree is not out of scope just because
# Linear could not be asked.
@test "with Linear unreachable the path signal still answers and the project is unknown" {
    bind_wt
    export FAKE_LINEAR_MODE=http_500
    run herdr_linear::scope_signals "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"path=inside"* ]]
    [[ "$output" == *"project=unknown"* ]]
}

# AE7.
@test "a worktree outside every known root reports both signals negative and returns" {
    OUT="$WORK/elsewhere/wt"; mkdir -p "$OUT"
    run herdr_linear::scope_signals "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"path=outside"* ]]
    [[ "$output" == *"project=negative"* ]]
}

@test "an unbound worktree in scope reports a negative project without asking Linear" {
    run herdr_linear::scope_signals "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"path=inside"* ]]
    [[ "$output" == *"project=negative"* ]]
    [ "$(sent issue)" = "0" ]
}

# ------------------------------------------------------------ the from-dir

# new_project has no worktree of its own, so the answer is read for the
# directory it was invoked from. An answer given somewhere else does not travel.
@test "new_project reads the answer for the from-dir, not for another directory" {
    unset HERDR_LINEAR_PROJECTS_ROOT
    mkdir -p "$WORK/projects/alpha/worktrees/from" "$WORK/projects/beta/worktrees/other"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf '# P\n\ncontent\n' > "$WORK/p.md"
    grant_consent "$WORK/projects/beta/worktrees/other" team-web ""
    run herdr_linear::new_project "P" "$WORK/p.md" team-web "" "$WORK/projects/alpha/worktrees/from"
    [ "$status" -eq 3 ]
    [ "$(sent projectCreate)" = "0" ]

    grant_consent "$WORK/projects/alpha/worktrees/from" team-web ""
    run herdr_linear::new_project "P" "$WORK/p.md" team-web "" "$WORK/projects/alpha/worktrees/from"
    [ "$(sent projectCreate)" = "1" ]
}

# ------------------------------------------------- filing in place (R12, F1, AE8)
#
# The other row of the two-by-two: you are already standing in the worktree the
# work belongs in. Filing the ticket and then making a SECOND worktree for it
# leaves the one you are in bound to nothing and the new one empty.

# `!`-negated commands are exempt from errexit, so a negated assertion cannot
# fail its test. This is the shape the suite's assertion lint demands instead.
refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

worktree_count() { git -C "$PROJECT" worktree list | grep -c .; }

# Covers AE8. One team on the project, so the team is a fact and not a question:
# the only thing anyone was asked is the R9 first-write answer, and nothing is
# refused.
@test "an issue is filed and bound to the worktree it was asked from" {
    enable_writes "$TEAM_ID" proj-abc
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_NEW_IDENT=WEB-4002 FAKE_LINEAR_PROJECT_TEAMS=one
    run herdr_linear::new_issue_here "$WT" "A new thing" "$DESC" w1
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | cut -f1)" = "WEB-4002" ]
    # The worktree it was asked from, not a new one.
    [ "$(printf '%s' "$output" | cut -f2)" = "$WT" ]
    [ "$(herdr_linear::binding_identifier "$WT")" = "WEB-4002" ]
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
    [ "$(sent issueCreate)" = "1" ]
}

# The whole of R12. A count, not a spot check: a second worktree anywhere under
# the project is the defect, whatever it is called.
@test "filing in place creates no second worktree and no second pane" {
    enable_writes "$TEAM_ID" proj-abc
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_NEW_IDENT=WEB-4002 FAKE_LINEAR_PROJECT_TEAMS=one
    before="$(worktree_count)"
    run herdr_linear::new_issue_here "$WT" "A new thing" "$DESC" w1
    [ "$status" -eq 0 ]
    [ "$(worktree_count)" = "$before" ]
    # You are already sitting in it, so there is no pane to open.
    [ -z "$(printf '%s' "$output" | cut -f3)" ]
    refute_match -q -- '--cwd' "$FAKE_HERDR_RECORD_DIR/argv"
}

# Rebinding silently re-homes whatever the worktree was already for. Which of
# the three things the person meant -- rebind, sub-issue, a new worktree -- is a
# fork, so the verb refuses and says what it found.
@test "a worktree already bound to another issue is not silently rebound" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_NEW_IDENT=WEB-4002
    before="$(worktree_count)"
    run --separate-stderr herdr_linear::new_issue_here "$WT" "A new thing" "$DESC"
    [ "$status" -eq "$HERDR_LINEAR_CREATE_REFUSED" ]
    [[ "$stderr" == *"already bound to WEB-2870"* ]]
    [ "$(sent issueCreate)" = "0" ]
    [ "$(herdr_linear::binding_identifier "$WT")" = "WEB-2870" ]
    [ "$(worktree_count)" = "$before" ]
}

# The consent gate IS the one question. Without an answer nothing is filed --
# and nothing local is created either, so the worktree is not left bound to an
# issue that does not exist.
@test "filing in place with nobody having answered files nothing and binds nothing" {
    n="$(herdr_linear::workspace_propose w1 proj-abc)"
    herdr_linear::workspace_confirm w1 proj-abc "$n"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 \
           FAKE_LINEAR_NEW_IDENT=WEB-4002 FAKE_LINEAR_PROJECT_TEAMS=one
    run herdr_linear::new_issue_here "$WT" "A new thing" "$DESC" w1
    [ "$status" -eq "$HERDR_LINEAR_CREATE_SHADOW" ]
    [ "$(sent issueCreate)" = "0" ]
    # Presence apart from value: "nobody answered" is not "the answer was no".
    run herdr_linear::has_consent "$WT"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
}

# The issue is filed before the repository is resolved, so a scope with no
# recorded repository leaves a real issue and no worktree. That is PARTIAL, and
# the reason and the retry both reach the person: the question from
# start_from_issue and the identifier to retry with.
@test "a new issue in a scope with no recorded repository is partial and carries the question" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq "$HERDR_LINEAR_CREATE_PARTIAL" ]
    [ "$(sent issueCreate)" -eq 1 ]
    [[ "$stderr" == *"no repository is recorded"* ]]
    [[ "$stderr" == *"/work:start WEB-4001"* ]]
    [ ! -e "$NEW_WT" ]
}

# KTD29. The create tail used to discard open_session's stderr, so a session
# with no space to open in vanished with nothing said. The issue and worktree
# are real; the pane is empty and the question is on stderr.
@test "a new issue whose project has no space carries the space question" {
    record_repo
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::new_issue "$WT" "A new thing" "$DESC" ""
    [ "$status" -eq 0 ]
    [ -d "$NEW_WT" ]
    [ -z "$(printf '%s' "$output" | cut -f3)" ]
    # The question's own words: the filing lines on stderr name the project too.
    [[ "$stderr" == *"no herdr space is bound to project $PROJECT_ID"* ]]
    run grep -c '^tab create' "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$output" = "0" ]
}

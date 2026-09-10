#!/usr/bin/env bats

load setup_common

# Starting work — from a ticket, or from nothing.
#
# The gap these fill: binding assumed a worktree already existed, which is the
# uncommon case. Work usually starts by picking something off the board, or by
# having an idea.
#
# The property worth protecting: starting from an EXISTING ticket writes nothing
# to Linear. It reads the issue, makes a local worktree, records a local
# binding. So it works before the credential rotation and before any worktree is
# in the write allowlist, and it cannot damage a board.

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
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$PROJECT" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_STARTSTARTSTARTSTAR" > "$LINEAR_SECRETS_FILE"

    # A project that is a real repository, so `git worktree add` works.
    git -C "$PROJECT" init -q -b main
    git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh start.sh; do . "$ROOT/lib/$f"; done

    # Every verb here defaults its from-dir to $PWD, and the project is derived
    # from it. Standing anywhere else derives the repository running the suite.
    cd "$PROJECT" || return 1
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# start_new names a team and no project -- there is no project yet -- and the
# answer is recorded for the directory the command was run from.
grant_consent() {
    local dir="$1" team="${2:-team-web}" project="${3-}" n
    n="$(herdr_linear::consent_propose "$dir" "$team" "$project")"
    herdr_linear::consent_confirm "$dir" "$team" "$project" "$n"
}
enable_root_writes() { grant_consent "${1:-$PWD}" team-web ""; }

sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
mutations() { local n; n="$(grep -cE 'mutation' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------- from a ticket, no worktree

@test "starting from a ticket creates a worktree under worktrees/ and binds it" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT/worktrees/drawer-blank" ]
    [ -d "$output" ]
    [ "$(herdr_linear::binding_state "$output")" = "bound" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# Every worktree on this machine lives at <root>/worktrees/<name>, which is also
# what the `wt` shell function does. An earlier version of the layout builder
# used <root>/<branch>, putting worktrees beside the repositories.
@test "the worktree goes under worktrees/, not beside the repositories" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ -d "$PROJECT/worktrees/drawer-blank" ]
    [ ! -e "$PROJECT/drawer-blank" ]
}

# THE property. Starting from an existing ticket is read-only on Linear, so it
# works before the credential rotation and cannot damage a board.
@test "starting from a ticket writes nothing to Linear" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$(mutations)" = "0" ]
}

# Linear supplies a branch name per issue. Prefixing it with the repository's
# own convention gives a branch carrying the identifier, so branch matching
# finds this worktree forever after -- most branches here carry none.
@test "the branch carries the identifier, so branch matching finds it later" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    wt="$PROJECT/worktrees/drawer-blank"
    branch="$(git -C "$wt" branch --show-current)"
    [[ "$branch" == feature/web-3318-* ]]
    run herdr_linear::branch_identifier "$branch"
    [ "$output" = "WEB-3318" ]
}

@test "a custom branch prefix is honoured" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank bugfix
    branch="$(git -C "$PROJECT/worktrees/drawer-blank" branch --show-current)"
    [[ "$branch" == bugfix/web-3318-* ]]
}

# Short human names are what every worktree here is called -- cue-read,
# wcs-paper -- not the full ticket slug.
@test "with no name given, a short one is derived from the title" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    name="$(basename "$output")"
    [ "${#name}" -le 40 ]
    [[ "$name" =~ ^[a-z0-9-]+$ ]]
    [ -d "$output" ]
}

# A worktree created for a typo is worse than a refusal: it looks like work and
# is bound to nothing.
@test "an identifier that does not exist creates no worktree" {
    export FAKE_LINEAR_MODE=not_found
    run --separate-stderr herdr_linear::start_from_issue WEB-999999 nope
    [ "$status" -eq 1 ]
    [ ! -e "$PROJECT/worktrees/nope" ]
    [[ "$stderr" == *"no such issue"* ]]
}

@test "an unreachable Linear creates no worktree" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::start_from_issue WEB-3318 nope
    [ "$status" -eq 3 ]
    [ ! -e "$PROJECT/worktrees/nope" ]
}

# It may be someone's live work. Binding it to this issue would re-home it.
@test "an existing directory is never adopted" {
    mkdir -p "$PROJECT/worktrees/taken"
    printf 'someone else work\n' > "$PROJECT/worktrees/taken/file.txt"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 taken
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"already exists"* ]]
    [ -f "$PROJECT/worktrees/taken/file.txt" ]
    run herdr_linear::binding_state "$PROJECT/worktrees/taken"
    [ "$output" = "unbound" ]
}

@test "a name that cannot become a safe path is refused" {
    export FAKE_LINEAR_MODE=found_child
    for bad in ".." "--rf" "."; do
        run herdr_linear::start_from_issue WEB-3318 "$bad"
        [ "$status" -eq 1 ]
    done
}

# ------------------------------------------------ from nothing, no worktree

# A write, so it is shadow-gated like every other. The shadow path creates no
# worktree either: one bound to an issue that was never filed is a dangling
# reference.
@test "starting from nothing is shadow-gated, and creates no worktree either" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 5 ]
    # stdout is the worktree path on success, so the sentence must not land there.
    [ -z "$output" ]
    [[ "$stderr" == *"shadow: would create"* ]]
    [ "$(mutations)" = "0" ]
    [ ! -e "$PROJECT/worktrees/newthing" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create issue"* ]]
}

# The description is held to the same bar before an issue exists to carry a bad
# one.
@test "a description that fails validation stops before anything is created" {
    printf '## Why\n\nreal\n\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
}

# AE6, on the other create path. Composing from the template and then dropping
# the spine is the template abandoned halfway, so strict mode holds it here too.
# START_REFUSED is shared with a missing title and a missing team, so the stderr
# line is what identifies the refusal -- lenient writes "note: not using ...".
@test "a description with no template headings is refused before anything is created" {
    printf '## Why\n\nA real reason, stated at length for whoever reads it.\n\n## The shape of this work\n\nWhat we do about it.\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"description: not using the Problem/Solution/Proposal shape"* ]]
    [ "$(mutations)" = "0" ]
    [ ! -e "$PROJECT/worktrees/newthing" ]
}

@test "a missing description file is refused" {
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::start_new "A new thing" "$WORK/nope.md" team-web newthing
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
}

@test "a missing team is refused before anything is sent" {
    printf '## Problem\n\nreal\n\n## Solution\n\nreal\n\n## Proposal\n\nreal\n' > "$WORK/d.md"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::start_new "A new thing" "$WORK/d.md" "" newthing
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
}

# ------------------------------------------------------- idempotent retry (F2)

# The path is deterministic, so a flat refusal on an existing path made the
# documented recovery -- "run /work:start again" -- impossible.
@test "retrying start on an already-bound worktree succeeds with the same path" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    first="$output"
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
}

# The partial failure the recovery exists for: the worktree was made, the
# binding was not.
@test "retrying start on an existing but unbound worktree binds it" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    rm -rf "$HERDR_LINEAR_STORE_DIR"
    run herdr_linear::binding_state "$PROJECT/worktrees/drawer-blank"
    [ "$output" = "unbound" ]

    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT/worktrees/drawer-blank" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# The realistic partial: propose landed, confirm did not.
@test "retrying start on a worktree left at proposed finishes the binding" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    wt="$PROJECT/worktrees/drawer-blank"
    rm -rf "$HERDR_LINEAR_STORE_DIR"
    herdr_linear::binding_propose "$wt" WEB-3318 >/dev/null
    [ "$(herdr_linear::binding_state "$wt")" = "proposed" ]

    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$wt")" = "bound" ]
    [ "$(herdr_linear::binding_identifier "$wt")" = "WEB-3318" ]
}

# Somebody else's work, still never adopted.
@test "a worktree bound to a different issue is still refused" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::start_from_issue WEB-2870 drawer-blank
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"WEB-3318"* ]]
    [ "$(herdr_linear::binding_identifier "$PROJECT/worktrees/drawer-blank")" = "WEB-3318" ]
}

# ------------------------------------------------------------- the gate (F1)

# The answer is per directory. Answering in one place must not turn creation on
# from everywhere else.
@test "an answer given in an unrelated directory does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    mkdir -p "$PROJECT/worktrees/elsewhere"
    grant_consent "$PROJECT/worktrees/elsewhere" team-web ""
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
    [ ! -e "$PROJECT/worktrees/newthing" ]
}

# An answer naming another team does not cover this one.
@test "an answer for another team does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    grant_consent "$PWD" team-brand ""
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
    run herdr_linear::binding_pending_consent "$PWD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"A new thing"* ]]
}

@test "an answer recorded here does enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT/worktrees/newthing" ]
    [ "$(sent issueCreate)" -ge 1 ]
    # A field nobody reads is a field nobody should ask for. Scoped to the
    # mutation's own selection -- fetch_issue selects branchName for a reason.
    [ "$(sent 'issueCreate.*branchName')" -eq 0 ]
    [ "$(sent 'issueCreate.*identifier')" -ge 1 ]
}

# ------------------------------------------------------------ the name (F7)

# The trailing trim exists to drop a word the 40-character cut severed. It used
# to run unconditionally, so every short title lost its last word.
@test "a short title keeps its last word" {
    resp='{"data":{"issue":{"title":"AI tools drawer is blank"}}}'
    run herdr_linear::start_default_name "$resp"
    [ "$output" = "ai-tools-drawer-is-blank" ]
}

@test "a long title is cut at 40 characters with no severed word left behind" {
    resp='{"data":{"issue":{"title":"AI Tools drawer is blank when a still-processing layer is selected"}}}'
    run herdr_linear::start_default_name "$resp"
    [ "${#output}" -le 40 ]
    [[ "$output" =~ ^[a-z0-9-]+$ ]]
    [[ "$output" != *- ]]
    [ "$output" = "ai-tools-drawer-is-blank-when-a-still" ]
}

# The identifier is what the caller retries with, and start_from_issue's own
# stderr never names it.
@test "a filed issue whose worktree fails still names the identifier" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    mkdir -p "$PROJECT/worktrees/newthing"
    printf 'someone else work\n' > "$PROJECT/worktrees/newthing/file.txt"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"WEB-4001"* ]]
    [ -z "$output" ]
}

# ------------------------------------------------------------ the from-dir

# R6. Worktrees are per project, so the project is the one the caller is
# standing in -- not one root shared by everything on the machine.
@test "the worktree is made in the project the from-dir belongs to" {
    unset HERDR_LINEAR_PROJECTS_ROOT
    mkdir -p "$WORK/projects/alpha"
    git -C "$WORK/projects/alpha" init -q -b main
    git -C "$WORK/projects/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$WORK/projects/alpha" worktree add -q -b f/from "$WORK/projects/alpha/worktrees/from" >/dev/null 2>&1
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank "" "$WORK/projects/alpha/worktrees/from"
    [ "$status" -eq 0 ]
    # The reader resolves the path, and $WORK from mktemp is not resolved.
    real="$(cd "$WORK/projects/alpha" && pwd -P)"
    [ "$output" = "$real/worktrees/drawer-blank" ]
    [ -d "$output" ]
}

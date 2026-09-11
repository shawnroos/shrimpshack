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
    # The ephemeral root is a SECOND boundary, disjoint from the projects root:
    # deleting all of it must stay safe.
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/wt"
    WT_ROOT="$WORK/wt"
    # <worktrees-root>/<org>/<scope-segment>. The fake tracker answers `acme`
    # for the organisation and `AI Canvas Tools` for the project of every issue
    # the found_child and found_parent modes serve.
    BASE="$WT_ROOT/acme/ai-canvas-tools"
    CHILD="WEB-3318-ai-tools-drawer-is-blank-when-a-still"
    PARENT="WEB-2870-tool-detach-foreground"
    PKEY="project-44444444-4444-4444-8444-444444444444"
    TKEY="team-55555555-5555-4555-8555-555555555555"
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
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh repos.sh start.sh; do . "$ROOT/lib/$f"; done

    # Standing inside a repository, deliberately: the path and the repository
    # must both come from the ticket now, so every test here runs from a place
    # that WOULD have decided the answer under the old reader.
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

# The answer a person gives to the repository question, recorded the way R8
# records it: under the project key AND the team key.
record_repo() { herdr_linear::record_scope_repo "$1" "$PKEY" "$TKEY"; }
record_alpha() { record_repo "$PROJECT"; }

# Three candidates, so the repository is a choice rather than a fact.
record_three() {
    mkdir -p "$WORK/root/beta" "$WORK/root/gamma"
    record_repo "$PROJECT"
    record_repo "$WORK/root/beta"
    record_repo "$WORK/root/gamma"
}

sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
mutations() { local n; n="$(grep -cE 'mutation' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------- from a ticket, no worktree

# AE1, AE3. The path is the ticket's: organisation, scope, then the name the
# identifier leads. The caller is standing in a repository the whole time and
# no segment comes from it.
@test "starting from a ticket creates a worktree at the ticket-derived path and binds it" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    [ -d "$output" ]
    [ "$(herdr_linear::binding_state "$output")" = "bound" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# R6. The repository is the one thing here nobody can read off the path, so the
# run says which it used, where that came from, and why there was no question.
@test "the single recorded repository is stated with its source before anything is made" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    [[ "$stderr" == *"$PROJECT"* ]]
    [[ "$stderr" == *"$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json"* ]]
    [[ "$stderr" == *"only repository recorded"* ]]
}

# R1. ~/projects holds canonical repositories; these worktrees are short-lived
# and the whole ephemeral tree must stay safe to delete, so none of it lands
# inside the repository it was made from.
@test "the worktree goes under the worktrees root, not inside the repository" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ -d "$BASE/$CHILD" ]
    [ ! -e "$PROJECT/worktrees" ]
    [ ! -e "$PROJECT/$CHILD" ]
}

# THE property. Starting from an existing ticket is read-only on Linear, so it
# works before the credential rotation and cannot damage a board.
@test "starting from a ticket writes nothing to Linear" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$(mutations)" = "0" ]
}

# AE8. The branch is the directory name behind the prefix, so the identifier is
# in both strings and branch matching finds this worktree forever after. Linear's
# own branchName is lowercase, so a directory derived from it could not lead with
# an uppercase identifier (KTD2).
@test "the branch is the directory name behind the prefix, identifier case kept" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    wt="$output"
    branch="$(git -C "$wt" branch --show-current)"
    [ "$branch" = "feature/$(basename "$wt")" ]
    [ "$branch" = "feature/WEB-3318-ai-tools-drawer-is-blank-when-a-still" ]
    run herdr_linear::branch_identifier "$branch"
    [ "$output" = "WEB-3318" ]
}

@test "a custom branch prefix is honoured" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 bugfix
    branch="$(git -C "$output" branch --show-current)"
    [[ "$branch" == bugfix/WEB-3318-* ]]
}

# KTD1 trades the identical-string form away for the branch convention. An empty
# prefix gets it back with no code change, which is the reason the trade is safe.
@test "an empty branch prefix yields a branch identical to the directory name" {
    export FAKE_LINEAR_MODE=found_child HERDR_LINEAR_BRANCH_PREFIX=""
    # Through the SEAM, not a passed argument: `:-` on the seam's own default
    # would collapse the empty value back to `feature` and this is the only
    # assertion that would see it.
    . "$ROOT/lib/start.sh"
    run herdr_linear::start_branch_name "$(herdr_linear::fetch_issue WEB-3318)"
    [ "$output" = "WEB-3318-ai-tools-drawer-is-blank-when-a-still" ]
}

# R14. No caller supplies the name, so nothing can drop the identifier out of it.
# The second positional is the branch prefix now, not a name.
@test "the second argument is the branch prefix, not a worktree name" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 hotfix
    [ "$status" -eq 0 ]
    [ "$(basename "$output")" = "$CHILD" ]
    [ ! -e "$BASE/hotfix" ]
}

# A worktree created for a typo is worse than a refusal: it looks like work and
# is bound to nothing.
@test "an identifier that does not exist creates no worktree" {
    export FAKE_LINEAR_MODE=not_found
    run --separate-stderr herdr_linear::start_from_issue WEB-999999
    [ "$status" -eq 1 ]
    [ ! -e "$WT_ROOT" ]
    [[ "$stderr" == *"no such issue"* ]]
}

@test "an unreachable Linear creates no worktree" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 3 ]
    [ ! -e "$WT_ROOT" ]
}

# It may be someone's live work. Binding it to this issue would re-home it.
@test "an existing directory is never adopted" {
    record_alpha
    taken="$BASE/$CHILD"
    mkdir -p "$taken"
    printf 'someone else work\n' > "$taken/file.txt"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"already exists"* ]]
    [ -f "$taken/file.txt" ]
    run herdr_linear::binding_state "$taken"
    [ "$output" = "unbound" ]
}

# The identifier is the leading path segment now, so a traversal in it is a
# traversal in the path. Nothing is composed from it at all.
@test "an identifier that is a traversal produces no name and no path" {
    export FAKE_LINEAR_MODE=traversal_identifier
    run herdr_linear::start_worktree_name "$(herdr_linear::fetch_issue WEB-3318)"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    record_alpha
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -ne 0 ]
    [ ! -e "$WORK/root/escaped" ]
    [ ! -e "$WT_ROOT/acme/escaped" ]
}

# Anyone who can file a ticket writes the title, and it becomes a path segment.
@test "a title carrying terminal escape bytes yields a name holding none of them" {
    export FAKE_LINEAR_MODE=hostile
    run herdr_linear::start_worktree_name "$(herdr_linear::fetch_issue WEB-6666)"
    [ "$status" -eq 0 ]
    [[ "$output" == WEB-6666-* ]]
    [[ "$output" =~ ^[A-Za-z0-9._-]+$ ]]
}

# ------------------------------------------------ from nothing, no worktree

# A write, so it is shadow-gated like every other. The shadow path creates no
# worktree either: one bound to an issue that was never filed is a dangling
# reference.
@test "starting from nothing is shadow-gated, and creates no worktree either" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 5 ]
    # stdout is the worktree path on success, so the sentence must not land there.
    [ -z "$output" ]
    [[ "$stderr" == *"shadow: would create"* ]]
    [ "$(mutations)" = "0" ]
    [ ! -e "$BASE/$CHILD" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create issue"* ]]
}

# The description is held to the same bar before an issue exists to carry a bad
# one.
@test "a description that fails validation stops before anything is created" {
    printf '## Why\n\nreal\n\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
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
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"description: not using the Problem/Solution/Proposal shape"* ]]
    [ "$(mutations)" = "0" ]
    [ ! -e "$BASE/$CHILD" ]
}

@test "a missing description file is refused" {
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/nope.md" team-web
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
}

@test "a missing team is refused before anything is sent" {
    printf '## Problem\n\nreal\n\n## Solution\n\nreal\n\n## Proposal\n\nreal\n' > "$WORK/d.md"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" ""
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
}

# ------------------------------------------------------- idempotent retry (F2)

# The path is deterministic, so a flat refusal on an existing path made the
# documented recovery -- "run /work:start again" -- impossible.
@test "retrying start on an already-bound worktree succeeds with the same path" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    first="$output"
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
}

# The partial failure the recovery exists for: the worktree was made, the
# binding was not.
@test "retrying start on an existing but unbound worktree binds it" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    rm -rf "$HERDR_LINEAR_STORE_DIR"
    run herdr_linear::binding_state "$BASE/$CHILD"
    [ "$output" = "unbound" ]

    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# The realistic partial: propose landed, confirm did not.
@test "retrying start on a worktree left at proposed finishes the binding" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    wt="$BASE/$CHILD"
    rm -rf "$HERDR_LINEAR_STORE_DIR"
    herdr_linear::binding_propose "$wt" WEB-3318 >/dev/null
    [ "$(herdr_linear::binding_state "$wt")" = "proposed" ]

    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$wt")" = "bound" ]
    [ "$(herdr_linear::binding_identifier "$wt")" = "WEB-3318" ]
}

# Somebody else's work, still never adopted. The path is derived per issue now,
# so the collision is staged rather than provoked: the directory WEB-2870 derives,
# already bound to WEB-3318.
@test "a worktree bound to a different issue is still refused" {
    record_alpha
    other="$BASE/$PARENT"
    mkdir -p "$BASE"
    git -C "$PROJECT" worktree add -q -b f/other "$other" >/dev/null 2>&1
    n="$(herdr_linear::binding_propose "$other" WEB-3318)"
    herdr_linear::binding_confirm "$other" WEB-3318 "$n"
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr herdr_linear::start_from_issue WEB-2870
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"WEB-3318"* ]]
    [ "$(herdr_linear::binding_identifier "$other")" = "WEB-3318" ]
}

# ------------------------------------------------------------- the gate (F1)

# The answer is per directory. Answering in one place must not turn creation on
# from everywhere else.
@test "an answer given in an unrelated directory does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    mkdir -p "$WORK/elsewhere"
    grant_consent "$WORK/elsewhere" team-web ""
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
    [ ! -e "$BASE/$CHILD" ]
}

# An answer naming another team does not cover this one.
@test "an answer for another team does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    grant_consent "$PWD" team-brand ""
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
    run herdr_linear::binding_pending_consent "$PWD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"A new thing"* ]]
}

@test "an answer recorded here does enable creation" {
    record_alpha
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    [ "$(sent issueCreate)" -ge 1 ]
    # A field nobody reads is a field nobody should ask for. Scoped to the
    # mutation's own selection -- fetch_issue selects branchName for a reason.
    [ "$(sent 'issueCreate.*branchName')" -eq 0 ]
    [ "$(sent 'issueCreate.*identifier')" -ge 1 ]
}

# ------------------------------------------------------------ the name (F7)

# The trailing trim exists to drop a word the 40-character cut severed. It used
# to run unconditionally, so every short title lost its last word. The cut applies
# to the title, so the identifier the name leads with can never be severed.
@test "a short title keeps its last word" {
    resp='{"data":{"issue":{"identifier":"WEB-3318","title":"AI tools drawer is blank"}}}'
    run herdr_linear::start_worktree_name "$resp"
    [ "$output" = "WEB-3318-ai-tools-drawer-is-blank" ]
}

@test "a long title is cut at 40 characters with no severed word left behind" {
    resp='{"data":{"issue":{"identifier":"WEB-3318","title":"AI Tools drawer is blank when a still-processing layer is selected"}}}'
    run herdr_linear::start_worktree_name "$resp"
    [ "$output" = "WEB-3318-ai-tools-drawer-is-blank-when-a-still" ]
    [[ "$output" != *- ]]
}

# R3, KTD2. The identifier leads and keeps its case, so the directory says which
# ticket it is and shares a string with the branch.
@test "the name leads with the identifier in its original case" {
    resp='{"data":{"issue":{"identifier":"WEB-3318","title":"a blank drawer"}}}'
    run herdr_linear::start_worktree_name "$resp"
    [ "$output" = "WEB-3318-a-blank-drawer" ]
}

@test "an issue with no title yields no name" {
    resp='{"data":{"issue":{"identifier":"WEB-3318","title":""}}}'
    run herdr_linear::start_worktree_name "$resp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ----------------------------------------------------------- the typed scope

# AE2, R5a. No project, so the key is the team's and the segment is the team key
# lowercased.
@test "an issue with no project resolves a team-typed key and a team segment" {
    export FAKE_LINEAR_MODE=traversal_identifier
    resp="$(herdr_linear::fetch_issue WEB-3318)"
    run herdr_linear::start_scope "$resp"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | cut -f1)" = "team-e" ]
    [ "$(printf '%s' "$output" | cut -f2)" = "team-e" ]
    [ "$(printf '%s' "$output" | cut -f3)" = "web" ]
}

# KTD3. The team key comes back alongside the project key, because R8 records
# under both and a later project-carrying issue must find the team-keyed answer.
@test "an issue with a project resolves a project-typed key, the team key, and a slugged segment" {
    export FAKE_LINEAR_MODE=found_child
    resp="$(herdr_linear::fetch_issue WEB-3318)"
    run herdr_linear::start_scope "$resp"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | cut -f1)" = "project-44444444-4444-4444-8444-444444444444" ]
    [ "$(printf '%s' "$output" | cut -f2)" = "team-55555555-5555-4555-8555-555555555555" ]
    [ "$(printf '%s' "$output" | cut -f3)" = "ai-canvas-tools" ]
}

# slug() would REPAIR a separator into a hyphen rather than refuse it, so the
# identifier is validated before it is composed into anything.
@test "an identifier carrying a path separator is refused, not repaired" {
    resp='{"data":{"issue":{"identifier":"a/b","title":"a blank drawer"}}}'
    run herdr_linear::start_worktree_name "$resp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# A typed key becomes a filename, so an unsafe id must never reach the store.
@test "a scope id that is not a safe identifier is refused" {
    resp='{"data":{"issue":{"project":{"id":"../escaped","name":"P"},"team":{"id":"t","key":"WEB"}}}}'
    run herdr_linear::start_scope "$resp"
    [ "$status" -ne 0 ]
    resp='{"data":{"issue":{"project":null,"team":{"id":"../escaped","key":"WEB"}}}}'
    run herdr_linear::start_scope "$resp"
    [ "$status" -ne 0 ]
}

# The identifier is what the caller retries with, and start_from_issue's own
# stderr never names it.
@test "a filed issue whose worktree fails still names the identifier" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    record_alpha
    enable_root_writes
    mkdir -p "$BASE/$CHILD"
    printf 'someone else work\n' > "$BASE/$CHILD/file.txt"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"WEB-4001"* ]]
    [ -z "$output" ]
}

# ------------------------------------------------- the path is not the caller

# THE defect this change removes. Two callers standing in two different places,
# one ticket, one path.
@test "the path is identical from two different directories" {
    record_alpha
    mkdir -p "$WORK/elsewhere"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$PROJECT"
    [ "$status" -eq 0 ]
    first="$output"
    rm -rf "$first"
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$WORK/elsewhere"
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
    [ "$output" = "$BASE/$CHILD" ]
}

# R1. The organisation is the first segment, so an organisation the API cannot
# name must stop the run -- not collapse into an empty segment that puts two
# workspaces in one directory.
@test "an organisation the API cannot name creates nothing" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ORGANIZATION=empty
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 4 ]
    [ ! -e "$WT_ROOT" ]
}

# ------------------------------------------------------ the repository (R5-R8)

# AE4. Several recorded repositories make this a question, so it is asked and
# every candidate is named -- "cannot tell which" alone leaves the reader to go
# find out what is on offer.
@test "several recorded repositories create nothing and name every candidate" {
    record_three
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 6 ]
    [ -z "$output" ]
    [ ! -e "$BASE/$CHILD" ]
    [[ "$stderr" == *"$PROJECT"* ]]
    [[ "$stderr" == *"$WORK/root/beta"* ]]
    [[ "$stderr" == *"$WORK/root/gamma"* ]]
}

# AE5. R7 is explicit that the caller's own directory is never the tiebreaker.
# Standing inside one candidate is exactly the shape that used to decide it.
@test "standing inside one candidate does not break the tie" {
    record_three
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$PROJECT"
    [ "$status" -eq 6 ]
    [ ! -e "$BASE/$CHILD" ]
    [[ "$stderr" == *"several repositories"* ]]
}

# AE6. Nothing recorded is a question too, and the retry that answers it is the
# whole recovery: the answer is recorded so it is never asked again.
@test "no recorded repository asks, and the answered retry creates and records" {
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 6 ]
    [ -z "$output" ]
    [ ! -e "$BASE/$CHILD" ]
    [[ "$stderr" == *"no repository is recorded"* ]]

    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$PROJECT" "$PROJECT"
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    # R8. Under BOTH keys, so a later issue reaching this scope by only one of
    # them still resolves.
    [ -f "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json" ]
    [ -f "$HERDR_LINEAR_STORE_DIR/scopes/$TKEY.json" ]
    run herdr_linear::scope_repo "$TKEY"
    [ "$output" = "$PROJECT" ]
}

# R7a. Resolving a relative answer would let the caller's directory decide the
# repository again, which is the defect being removed.
@test "a relative repository answer is refused, and nothing is recorded or created" {
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$PROJECT" "./alpha"
    [ "$status" -eq 1 ]
    [ ! -e "$BASE/$CHILD" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json" ]
    [[ "$stderr" == *"absolute"* ]]
}

# A store that cannot be read is not an empty store. Asking a question the
# answer to which is on disk but unreadable would record a second repository
# for a scope that already has one.
@test "a repository record that cannot be read fails rather than asking" {
    record_alpha
    chmod 000 "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    chmod 600 "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json"
    [ "$status" -ne 6 ]
    [ ! -e "$BASE/$CHILD" ]
}

# --------------------------------------------------- the delete-safety promise

# AE9. The Objective promises deleting the ephemeral tree is safe, and that
# starting the same ticket again then works. The branch survives in the
# repository, and git keeps a registration for the removed path -- so without a
# prune and a reuse this fails, silently, because both streams are suppressed.
@test "a worktree deleted from disk is restarted on the same branch" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    wt="$output"
    branch="$(git -C "$wt" branch --show-current)"
    rm -rf "$wt"

    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 0 ]
    [ "$output" = "$wt" ]
    [ -d "$output" ]
    [ "$(git -C "$output" branch --show-current)" = "$branch" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# AE10, R13. The promise is a property of the CONFIGURATION. A root that is the
# projects root turns one `rm -rf` into the loss of every canonical checkout,
# so the plugin does not act under it at all.
@test "a worktrees root overlapping the projects root creates nothing" {
    record_alpha
    export HERDR_LINEAR_WORKTREES_ROOT="$HERDR_LINEAR_PROJECTS_ROOT"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -e "$HERDR_LINEAR_PROJECTS_ROOT/acme" ]
    [[ "$stderr" == *"projects root"* ]]
}

# --------------------------------------------------------- the create tail

# A partial that leaves no trace: the issue is real, the worktree is not, and
# the binding must not exist either.
@test "a failing worktree add leaves no binding" {
    record_alpha
    export FAKE_LINEAR_MODE=found_child HERDR_LINEAR_GIT_BIN=/bin/false
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 4 ]
    [ ! -d "$BASE/$CHILD" ]
    [ "$(herdr_linear::binding_state "$BASE/$CHILD")" = "unbound" ]
}

# KTD7. By this point a real issue has been filed. Collapsing the question into
# a flat failure leaves the person holding a ticket, no worktree, and no
# question they can answer.
@test "a filed issue against a multi-candidate scope asks rather than fails" {
    record_three
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web
    [ "$status" -eq 6 ]
    [ -z "$output" ]
    [[ "$stderr" == *"WEB-4001"* ]]
    [[ "$stderr" == *"several repositories"* ]]
    [ ! -e "$BASE/$CHILD" ]
}

# The answer reaches start_from_issue through start_new, so the person who was
# asked can retry the whole motion once.
@test "start_new takes the repository answer and creates the worktree" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web "$PROJECT" "$PROJECT"
    [ "$status" -eq 0 ]
    [ "$output" = "$BASE/$CHILD" ]
    [ -f "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json" ]
}

# R7a on the path that files first. start_from_issue would refuse the relative
# answer only after a real issue existed.
@test "start_new refuses a relative repository before anything is filed" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web "$PROJECT" "./alpha"
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
    [[ "$stderr" == *"absolute"* ]]
}

# An answer is recorded before anything is made, so an answer that is not a
# repository would otherwise be offered as the only candidate from then on.
@test "an answer that is not a git repository is refused and not recorded" {
    mkdir -p "$WORK/plain"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 "" "$PROJECT" "$WORK/plain"
    [ "$status" -eq 1 ]
    [ ! -e "$BASE/$CHILD" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/scopes/$PKEY.json" ]
    [[ "$stderr" == *"not a git repository"* ]]
}

# The plan's assumption: a repository that moved is asked about again, the same
# as a scope with no candidate, rather than failing on a path that is gone.
@test "a recorded repository that is gone asks again rather than failing" {
    mkdir -p "$WORK/root/moved"
    git -C "$WORK/root/moved" init -q -b main
    record_repo "$WORK/root/moved"
    rm -rf "$WORK/root/moved"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 6 ]
    [ ! -e "$BASE/$CHILD" ]
    [[ "$stderr" == *"$WORK/root/moved"* ]]
}

# The recovery adopts this issue's own worktree. A directory that merely holds
# a `.git` entry is not one, and binding it would claim a restart that did not
# happen.
@test "a directory with a .git entry that git does not recognise is never adopted" {
    record_alpha
    mkdir -p "$BASE/$CHILD"
    : > "$BASE/$CHILD/.git"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$BASE/$CHILD")" = "unbound" ]
}

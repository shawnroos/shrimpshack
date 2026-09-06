#!/usr/bin/env bats
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
    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_WRITE_ALLOWLIST="$WORK/write-enabled"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_STARTSTARTSTARTSTAR" > "$LINEAR_SECRETS_FILE"

    # A Slate root that is a real repository, so `git worktree add` works.
    git -C "$WORK/Slate" init -q -b main
    git -C "$WORK/Slate" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh start.sh; do . "$ROOT/lib/$f"; done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# Creation is gated on the worktrees ROOT being allowlisted by name.
enable_root_writes() {
    mkdir -p "$WORK/Slate/worktrees"
    printf '%s\n' "$(cd "$WORK/Slate/worktrees" && pwd -P)" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
}

sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
mutations() { local n; n="$(grep -cE 'mutation' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------- from a ticket, no worktree

@test "starting from a ticket creates a worktree under worktrees/ and binds it" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate/worktrees/drawer-blank" ]
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
    [ -d "$WORK/Slate/worktrees/drawer-blank" ]
    [ ! -e "$WORK/Slate/drawer-blank" ]
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
    wt="$WORK/Slate/worktrees/drawer-blank"
    branch="$(git -C "$wt" branch --show-current)"
    [[ "$branch" == feature/web-3318-* ]]
    run herdr_linear::branch_identifier "$branch"
    [ "$output" = "WEB-3318" ]
}

@test "a custom branch prefix is honoured" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank bugfix
    branch="$(git -C "$WORK/Slate/worktrees/drawer-blank" branch --show-current)"
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
    [ ! -e "$WORK/Slate/worktrees/nope" ]
    [[ "$stderr" == *"no such issue"* ]]
}

@test "an unreachable Linear creates no worktree" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::start_from_issue WEB-3318 nope
    [ "$status" -eq 3 ]
    [ ! -e "$WORK/Slate/worktrees/nope" ]
}

# It may be someone's live work. Binding it to this issue would re-home it.
@test "an existing directory is never adopted" {
    mkdir -p "$WORK/Slate/worktrees/taken"
    printf 'someone else work\n' > "$WORK/Slate/worktrees/taken/file.txt"
    export FAKE_LINEAR_MODE=found_child
    run --separate-stderr herdr_linear::start_from_issue WEB-3318 taken
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"already exists"* ]]
    [ -f "$WORK/Slate/worktrees/taken/file.txt" ]
    run herdr_linear::binding_state "$WORK/Slate/worktrees/taken"
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
    [ ! -e "$WORK/Slate/worktrees/newthing" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create issue"* ]]
}

# The description is held to the same bar before an issue exists to carry a bad
# one.
@test "a description that fails validation stops before anything is created" {
    printf '## Why\n\nreal\n\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n' > "$WORK/d.md"
    printf '%s\n' "$WORK/Slate/worktrees/anything" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 1 ]
    [ "$(mutations)" = "0" ]
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
    run herdr_linear::binding_state "$WORK/Slate/worktrees/drawer-blank"
    [ "$output" = "unbound" ]

    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate/worktrees/drawer-blank" ]
    [ "$(herdr_linear::binding_identifier "$output")" = "WEB-3318" ]
}

# The realistic partial: propose landed, confirm did not.
@test "retrying start on a worktree left at proposed finishes the binding" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::start_from_issue WEB-3318 drawer-blank
    [ "$status" -eq 0 ]
    wt="$WORK/Slate/worktrees/drawer-blank"
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
    [ "$(herdr_linear::binding_identifier "$WORK/Slate/worktrees/drawer-blank")" = "WEB-3318" ]
}

# ------------------------------------------------------------- the gate (F1)

# The allowlist is per-path. Allowlisting one worktree must not turn creation on
# from every other one.
@test "an allowlist naming an unrelated path does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    mkdir -p "$WORK/Slate/worktrees/elsewhere"
    printf '%s\n' "$(cd "$WORK/Slate/worktrees/elsewhere" && pwd -P)" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
    [ ! -e "$WORK/Slate/worktrees/newthing" ]
}

# A header line makes the file non-empty while matching nothing.
@test "an allowlist holding only a comment does not enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    printf '# worktrees with writes enabled\n\n' > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 5 ]
    [ "$(mutations)" = "0" ]
}

@test "the allowlisted worktree root does enable creation" {
    printf '## Problem\n\nreal problem text for the actor\n\n## Solution\n\nreal solution text\n\n## Proposal\n\nreal proposal\n' > "$WORK/d.md"
    enable_root_writes
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate/worktrees/newthing" ]
    [ "$(sent issueCreate)" -ge 1 ]
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
    mkdir -p "$WORK/Slate/worktrees/newthing"
    printf 'someone else work\n' > "$WORK/Slate/worktrees/newthing/file.txt"
    export FAKE_LINEAR_MODE=found_child FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_NEW_IDENT=WEB-4001
    run --separate-stderr herdr_linear::start_new "A new thing" "$WORK/d.md" team-web newthing
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"WEB-4001"* ]]
    [ -z "$output" ]
}

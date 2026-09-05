#!/usr/bin/env bats
# U14 — the plugin owns the issue description.
#
# Shawn chose full ownership over the fenced managed region I proposed. The
# tests are therefore built around the one thing that must hold anyway: text the
# plugin did not author is never silently lost. It regenerates what the
# repository can supply and carries everything else through byte for byte.
#
# Every test that writes also checks the backup, because a full-ownership write
# with no undo is the wrong trade at any level of confidence.

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
    export HERDR_LINEAR_DESC_BACKUP_DIR="$WORK/descriptions"
    export HERDR_LINEAR_GH_BIN="$WORK/no-such-gh"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_DESCDESCDESCDESCDES" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    HAND_WRITTEN='## What

stale text the plugin wrote last time

## Why

Users cannot see the drawer while a layer is still processing, so they think the
tool is broken and retry. This paragraph is Shawn'"'"'s and must survive verbatim.

## Not in this PR

The Separate Background fix. Tracked separately.

## Verification

stale verification'
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
enable_writes() { (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"; }
section() { printf '%s' "$2" | awk -v s="## $1" '$0==s{f=1;next} /^## /{f=0} f'; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------- carry-forward (R31)

# THE test for this unit. The repository cannot author Why -- that is intent,
# and nothing in git holds it.
@test "a hand-written Why survives a write that changes What" {
    out="$(herdr_linear::render_description "$WT" "$HAND_WRITTEN")"
    [ "$(section Why "$out" | tr -d '[:space:]')" = "$(section Why "$HAND_WRITTEN" | tr -d '[:space:]')" ]
    [[ "$(section Why "$out")" == *"must survive verbatim"* ]]
    # And What really was regenerated, so this is not passing by doing nothing.
    [[ "$(section What "$out")" == *"feature/web-2870-detach"* ]]
    [[ "$(section What "$out")" != *"stale text"* ]]
}

@test "every section the plugin cannot derive is carried through" {
    out="$(herdr_linear::render_description "$WT" "$HAND_WRITTEN")"
    for s in "Why" "Not in this PR"; do
        [ "$(section "$s" "$out" | tr -d '[:space:]')" = "$(section "$s" "$HAND_WRITTEN" | tr -d '[:space:]')" ]
    done
}

# A heading this code has never heard of must survive, and stay where it was.
@test "an unknown section is preserved, in its original position" {
    cur='## What

x

## Some Heading Nobody Planned For

free-form notes a person added

## Why

because'
    out="$(herdr_linear::render_description "$WT" "$cur")"
    [[ "$(section "Some Heading Nobody Planned For" "$out")" == *"free-form notes"* ]]
    # Order preserved: the unknown heading still sits between What and Why.
    order="$(printf '%s' "$out" | grep '^## ' | tr '\n' '|')"
    [ "$order" = "## What|## Some Heading Nobody Planned For|## Why|## Verification|" ]
}

@test "text before the first heading is preserved" {
    cur='A sentence with no heading above it.

## Why

because'
    out="$(herdr_linear::render_description "$WT" "$cur")"
    [[ "$out" == *"A sentence with no heading above it."* ]]
}

@test "an empty description gains only the sections the plugin can derive" {
    out="$(herdr_linear::render_description "$WT" "")"
    order="$(printf '%s' "$out" | grep '^## ' | tr '\n' '|')"
    [ "$order" = "## What|## Verification|" ]
}

# It must never claim a test run nobody performed.
@test "Verification says what is readable, and does not invent a result" {
    out="$(herdr_linear::render_description "$WT" "")"
    [[ "$(section Verification "$out")" == *"No CI result readable"* ]]
}

# ------------------------------------------------------------- the backup

@test "the prior description is saved before the write, and restores byte for byte" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT"
    [ "$status" -eq 0 ]
    backups="$(herdr_linear::describe_backups WEB-2870 | grep -c .)"
    [ "$backups" = "1" ]
    restored="$(herdr_linear::describe_restore WEB-2870)"
    [[ "$restored" == *"must survive verbatim"* ]]
}

@test "restore fails cleanly when there is no backup" {
    run herdr_linear::describe_restore WEB-9999
    [ "$status" -ne 0 ]
}

# --------------------------------------------------------------- boundaries

@test "an unbound worktree is never described" {
    enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT"
    [ "$status" -eq 2 ]
    [ "$(sent issueUpdate)" = "0" ]
}

@test "a misplaced or stale binding is never described" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    for st in misplaced stale; do
        herdr_linear::binding_set_state "$WT" "$st"
        run herdr_linear::describe "$WT"
        [ "$status" -eq 2 ]
    done
    [ "$(sent issueUpdate)" = "0" ]
}

@test "a worktree outside the Slate root is never described" {
    OUT="$WORK/NotSlate/wt"; mkdir -p "$OUT"
    git -C "$OUT" init -q -b main
    git -C "$OUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$OUT"
    [ "$status" -eq 2 ]
    [ "$(sent issueUpdate)" = "0" ]
}

# Rewriting to the same bytes still stamps updatedAt and shows on the feed.
@test "a description already matching what would be rendered is not rewritten" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_rendered FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT"
    [ "$status" -eq 1 ]
    [ "$(sent issueUpdate)" = "0" ]
}

@test "shadow mode renders the description and sends nothing" {
    bind_wt
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT"
    [ "$status" -eq 3 ]
    [ "$(sent issueUpdate)" = "0" ]
    [[ "$output" == *"must survive verbatim"* ]]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would rewrite the description of WEB-2870"* ]]
    # No backup is taken in shadow mode: nothing was overwritten.
    [ -z "$(herdr_linear::describe_backups WEB-2870)" ]
}

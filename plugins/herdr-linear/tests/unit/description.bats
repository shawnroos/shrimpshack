#!/usr/bin/env bats
# U14 — the issue description.
#
# The plugin owns the TEMPLATE, the VALIDATION and the WRITE. It does not author
# the prose, and an earlier version that tried to -- deriving `## What` from the
# branch and commit count -- was wrong twice over: those headings are not in the
# template, and "branch X, 4 commits" is exactly the diary content the template
# forbids.
#
# So most of this file is about refusing bad writes, and the single most
# important rule is NEVER A DIARY. An automated writer breaks that one first,
# because appending is easier than rewriting.

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
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_DESCDESCDESCDESCDES" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh description.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    GOOD="$WORK/good.md"
    cat > "$GOOD" <<'EOF'
## Problem

Editors open the AI Tools drawer while a layer is still processing and see
nothing at all, so they assume the tool is broken and start again.

### For example:
- A user selects a still-uploading image and sees an empty panel.
- They reopen twice, then switch tools for that shot.

## Solution

Opening the drawer on a processing layer says what is happening and roughly how
long is left, so waiting is a choice rather than a guess.

### For example:
- The panel keeps their place while the layer finishes.
- Nobody re-runs a render that was already running.

## Proposal

Show the drawer contents for a layer as soon as we know what it is, and a clear
processing state until then.

### Key Requirements
- The drawer never renders empty for a selectable layer.

### Constraints
- No new endpoint; layer status already arrives on the existing channel.
EOF
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
enable_writes() { (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# --------------------------------------------------------------- the template

@test "the template carries the spine, in order, with the example blocks" {
    run herdr_linear::description_template
    order="$(printf '%s' "$output" | grep '^## ' | tr '\n' '|')"
    [ "$order" = "## Problem|## Solution|## Proposal|" ]
    [[ "$output" == *"### For example:"* ]]
    [[ "$output" == *"### Key Requirements"* ]]
    [[ "$output" == *"### Constraints"* ]]
    [[ "$output" == *"implementation neutral"* ]]
}

# A half-filled template must not reach a ticket looking like a description.
@test "the unfilled template does not pass validation" {
    herdr_linear::description_template > "$WORK/tpl.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/tpl.md"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"template placeholders"* ]]
}

# --------------------------------------------------------------- validation

@test "a description following the template validates" {
    run herdr_linear::description_validate "$GOOD"
    [ "$status" -eq 0 ]
}

# THE CONFORMANCE TEST FOR THIS UNIT. WEB-3214 "Improve AI tools analytics" is a
# real ticket Shawn holds up as good, and it uses none of the spine headings --
# it uses `## Why`, `## The shape of this work`, `## Two things everyone reading
# these dashboards needs to know`, `## Worth agreeing before GA, not after`.
# Those headings are arguments a reader can act on, where `## Constraints` is a
# heading people skim past.
#
# An earlier version of the validator REJECTED it. A validator that refuses the
# work it is meant to protect is the wrong validator, so the spine became
# advisory and the fixture stays as a regression guard.
@test "WEB-3214, a ticket held up as good, passes validation" {
    run --separate-stderr herdr_linear::description_validate "$FIX/descriptions/web-3214.md"
    [ "$status" -eq 0 ]
    # Reported as a note, not a refusal.
    [[ "$stderr" == *"note: not using the Problem/Solution/Proposal shape"* ]]
}

# The spine is the default a NEW description starts from, so strict mode -- used
# when composing from the template -- does hold it.
@test "the same ticket does not pass strict mode, which is the point of the two modes" {
    run --separate-stderr herdr_linear::description_validate "$FIX/descriptions/web-3214.md" strict
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"not using the Problem/Solution/Proposal shape"* ]]
}

# `<https://...>` is a markdown autolink, and WEB-3214 ends with one. The first
# placeholder pattern matched it -- the validator calling a real ticket
# unfinished because it cited its source properly.
@test "a markdown autolink is not a template placeholder" {
    printf '## Notes\n\nSee <https://example.invalid/a/b-c-d> and <someone@example.com>.\n' > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"placeholder"* ]]
}

# A date in PROSE is fine. WEB-3214 opens with "Measured 25 Aug 2026" and is not
# a diary; it is dated HEADINGS that mark a log.
@test "a date in prose is not a diary" {
    printf '## Why\n\nMeasured 25 Aug 2026 in PROD, last 90 days. Numbers followed.\n' > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"diary"* ]]
}

@test "a missing spine section is a note in lenient mode and a refusal in strict" {
    printf '## Problem\n\nA real problem, stated at some length for the actor.\n' > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"note: not using the Problem/Solution/Proposal shape"* ]]

    run --separate-stderr herdr_linear::description_validate "$WORK/x.md" strict
    [ "$status" -ne 0 ]
}

@test "the spine out of order is a note in lenient mode and a refusal in strict" {
    printf '## Solution\n\nreal text here\n\n## Problem\n\nreal text here\n\n## Proposal\n\nreal text\n' > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md" strict
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"out of order"* ]]
}

@test "an empty section is refused whatever it is called" {
    printf '## Problem\n\n## Solution\n\nreal text\n\n## Proposal\n\nreal text\n' > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"Problem is empty"* ]]
}

# Sections after Proposal are the ticket's own business.
@test "extra sections after Proposal are allowed" {
    { cat "$GOOD"; printf '\n## Source\n\nSlack thread, 3 Sep.\n'; } > "$WORK/x.md"
    run herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------------ never a diary

@test "two dated headings read as a diary and are refused" {
    { cat "$GOOD"; printf '\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n'; } > "$WORK/x.md"
    run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"reads as a diary"* ]]
}

# One date can be a legitimate deadline or source reference. Two is a log.
@test "a single dated heading is allowed" {
    { cat "$GOOD"; printf '\n### Source, 3 Sep\n\nA call.\n'; } > "$WORK/x.md"
    run herdr_linear::description_validate "$WORK/x.md"
    [ "$status" -eq 0 ]
}

@test "log-style entries read as a diary and are refused" {
    for word in "Update: shipped half" "Progress: nearly there" "Session 2: more work" "Today: fixed it"; do
        { cat "$GOOD"; printf '\n%s\n' "$word"; } > "$WORK/x.md"
        run --separate-stderr herdr_linear::description_validate "$WORK/x.md"
        [ "$status" -ne 0 ]
        [[ "$stderr" == *"log-style entries"* ]]
    done
}

# The structural check, which needs no vocabulary at all: a new description that
# BEGINS with the whole of the old one is an append, whatever the words say.
@test "a write that only appends to the current description is refused as a diary" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    current="$(FAKE_LINEAR_MODE=desc_issue herdr_linear::_fetch_description WEB-2870 \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["description"])')"
    { printf '%s' "$current"; printf '\n\n## Notes\n\nand one more thing\n'; } > "$WORK/appended.md"
    run --separate-stderr herdr_linear::describe "$WT" "$WORK/appended.md"
    [ "$status" -eq 6 ]
    [[ "$stderr" == *"only appends"* ]]
    [ "$(sent issueUpdate)" = "0" ]
}

@test "a genuine rewrite that shares no prefix is not treated as an append" {
    run herdr_linear::description_is_append "## Problem

old text" "## Problem

entirely rewritten text"
    [ "$status" -ne 0 ]
}

# --------------------------------------------------------------- the write

@test "a valid description is written, and the prior one saved first" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT" "$GOOD"
    [ "$status" -eq 0 ]
    [ "$(sent issueUpdate)" = "1" ]
    [ "$(herdr_linear::describe_backups WEB-2870 | grep -c .)" = "1" ]
    restored="$(herdr_linear::describe_restore WEB-2870)"
    [[ "$restored" == *"Nobody re-runs a render"* ]]
}

# `## Problem` alone is no longer invalid -- that is an advisory note now. This
# needs a HARD failure, so it uses a diary: the rule that holds in every shape.
@test "an invalid description never reaches Linear" {
    bind_wt; enable_writes
    printf '## Why\n\nreal text\n\n### 2026-09-04 update\n- a\n\n### 2026-09-05 update\n- b\n' > "$WORK/x.md"
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT" "$WORK/x.md"
    [ "$status" -eq 5 ]
    [ "$(sent issueUpdate)" = "0" ]
    [ -z "$(herdr_linear::describe_backups WEB-2870)" ]
}

@test "a description identical to the current one is not rewritten" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    FAKE_LINEAR_MODE=desc_issue herdr_linear::_fetch_description WEB-2870 \
        | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin)["data"]["issue"]["description"])' > "$WORK/same.md"
    run herdr_linear::describe "$WT" "$WORK/same.md"
    [ "$status" -eq 1 ]
    [ "$(sent issueUpdate)" = "0" ]
}

@test "shadow mode prints what it would write and sends nothing" {
    bind_wt
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT" "$GOOD"
    [ "$status" -eq 3 ]
    [ "$(sent issueUpdate)" = "0" ]
    [[ "$output" == *"## Problem"* ]]
    [ -z "$(herdr_linear::describe_backups WEB-2870)" ]
}

@test "a ticket with an empty description is filled from a valid file" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_empty FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT" "$GOOD"
    [ "$status" -eq 0 ]
    [ "$(sent issueUpdate)" = "1" ]
}

# --------------------------------------------------------------- boundaries

@test "an unbound worktree is never described" {
    enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$WT" "$GOOD"
    [ "$status" -eq 2 ]
    [ "$(sent issueUpdate)" = "0" ]
}

@test "a misplaced or stale binding is never described" {
    bind_wt; enable_writes
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    for st in misplaced stale; do
        herdr_linear::binding_set_state "$WT" "$st"
        run herdr_linear::describe "$WT" "$GOOD"
        [ "$status" -eq 2 ]
    done
    [ "$(sent issueUpdate)" = "0" ]
}

@test "a worktree outside the Slate root is never described" {
    OUT="$WORK/NotSlate/wt"; mkdir -p "$OUT"
    git -C "$OUT" init -q -b main
    git -C "$OUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    export FAKE_LINEAR_MODE=desc_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::describe "$OUT" "$GOOD"
    [ "$status" -eq 2 ]
    [ "$(sent issueUpdate)" = "0" ]
}

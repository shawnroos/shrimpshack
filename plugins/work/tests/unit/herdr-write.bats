#!/usr/bin/env bats
# U10 — building herdr layout from a Linear issue.
#
# No test touches the live herdr server. The default fixture REFUSES every
# mutating verb with exit 99; these tests opt in explicitly, so a read path
# cannot quietly acquire a write and pass.
#
# The property most of this file is about is resumability. Building a tab with
# three columns means a tab, three worktrees, three panes and three bindings --
# eleven things that can fail halfway. A retry that rebuilds instead of
# continuing leaves the person worse off than if it had never run.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_JOURNAL_DIR="$WORK/journal"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_RECORD_DIR="$WORK/hrec"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=10
    mkdir -p "$WORK/Slate" "$WORK/hrec"

    # A Slate root that is a real repo, so `git worktree add` has somewhere to go.
    git -C "$WORK/Slate" init -q -b main
    git -C "$WORK/Slate" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh herdr-read.sh herdr-write.sh; do . "$ROOT/lib/$f"; done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

herdr_calls() { local n; n="$(grep -c "$1" "$FAKE_HERDR_RECORD_DIR/argv" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------------ building

@test "an issue with three children produces a tab with three columns, each bound" {
    run herdr_linear::layout_build WEB-2870 WEB-3001 WEB-3002 WEB-3003
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(herdr_calls 'tab create')" = "1" ]
    [ "$(herdr_calls 'pane split')" = "3" ]
    for c in WEB-3001 WEB-3002 WEB-3003; do
        [ "$(herdr_linear::binding_state "$HERDR_LINEAR_SLATE_ROOT/worktrees/$c")" = "bound" ]
        [ "$(herdr_linear::binding_identifier "$HERDR_LINEAR_SLATE_ROOT/worktrees/$c")" = "$c" ]
    done
}

# The path convention, pinned. These assertions previously named
# <root>/<name>, which is beside the repositories rather than among the
# worktrees -- the tests were holding a real defect in place.
@test "each column gets its own worktree, and the pane is opened in it" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ -d "$HERDR_LINEAR_SLATE_ROOT/worktrees/WEB-3001" ]
    run grep -c -- "--cwd $HERDR_LINEAR_SLATE_ROOT/worktrees/WEB-3001" "$FAKE_HERDR_RECORD_DIR/argv"
    [ "$output" = "1" ]
}

# ------------------------------------------------------------ liveness (R14)

# HERDR_ENV records launch ancestry, not reachability -- it stays set after the
# server has gone. Reporting is a complete answer; half a layout is not.
@test "a server that is not running is reported, and nothing is built" {
    export FAKE_HERDR_MODE=not_running
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 1 ]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -d "$HERDR_LINEAR_SLATE_ROOT/worktrees/WEB-3001" ]
}

@test "a dead server is reported the same way" {
    export FAKE_HERDR_MODE=dead
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 1 ]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

# ------------------------------------------------------------- names (R28)

# Validated BEFORE anything is created, so a bad title cannot leave a tab
# behind with no columns under it.
@test "a title that cannot become a safe name is refused before anything is created" {
    for bad in "--rf" ".." "." "   "; do
        rm -rf "$FAKE_HERDR_RECORD_DIR"; mkdir -p "$FAKE_HERDR_RECORD_DIR"
        run herdr_linear::layout_build WEB-2870 "$bad"
        [ "$status" -eq 2 ]
        [ "$(herdr_calls 'tab create')" = "0" ]
    done
}

@test "a bad parent name is refused too" {
    run herdr_linear::layout_build "--rf" WEB-3001
    [ "$status" -eq 2 ]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

@test "a bad name among good ones stops the whole build, not just that column" {
    run herdr_linear::layout_build WEB-2870 WEB-3001 ".." WEB-3003
    [ "$status" -eq 2 ]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -d "$HERDR_LINEAR_SLATE_ROOT/worktrees/WEB-3001" ]
}

# ------------------------------------------------------------- resumability

# The property the journal exists for. A retry after a partial failure must
# CONTINUE, not rebuild -- otherwise the person ends up with two tabs and six
# worktrees and is worse off than if it had never run.
@test "a retry after a partial failure creates no duplicate tab or worktree" {
    # First run builds one column, then fails: the pane never registers.
    export FAKE_HERDR_SLOW_PANE=999
    run herdr_linear::layout_build WEB-2870 WEB-3001 WEB-3002
    [ "$status" -eq 3 ]
    first_tabs="$(herdr_calls 'tab create')"
    [ "$first_tabs" = "1" ]

    # Retry with the pane registering normally.
    unset FAKE_HERDR_SLOW_PANE
    run herdr_linear::layout_build WEB-2870 WEB-3001 WEB-3002
    [ "$status" -eq 0 ]

    # Still exactly one tab: the journal was consulted, not ignored.
    [ "$(herdr_calls 'tab create')" = "1" ]
    [ "$(ls -1d "$HERDR_LINEAR_SLATE_ROOT"/worktrees/WEB-300* 2>/dev/null | wc -l | tr -d ' ')" = "2" ]
}

# The file's own header forbids repairing a failed retry this way: an empty
# repo shares no history with Slate and can never push.
@test "a branch that already exists fails the worktree instead of git-init a fresh repo" {
    git -C "$HERDR_LINEAR_SLATE_ROOT" branch WEB-3001
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ ! -d "$HERDR_LINEAR_SLATE_ROOT/worktrees/WEB-3001/.git" ]
}

@test "a completed column is not rebuilt on a second run" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    splits_before="$(herdr_calls 'pane split')"
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'pane split')" = "$splits_before" ]
}

@test "the journal is append-only, so a crash between read and write loses nothing" {
    herdr_linear::journal_put WEB-2870 tab "w1:t1"
    herdr_linear::journal_put WEB-2870 tab "w1:t2"
    run herdr_linear::journal_get WEB-2870 tab
    [ "$output" = "w1:t2" ]
    # Both entries survive on disk; the reader takes the last.
    run grep -c '^tab=' "$HERDR_LINEAR_JOURNAL_DIR/WEB-2870.journal"
    [ "$output" = "2" ]
}

# An identifier becomes a path segment here, and a sed program's key in
# journal_get. Today's callers only pass Linear identifiers (no `/`), but the
# shape is validated regardless so this stays true the moment that changes.
@test "an issue identifier that could escape the journal directory is refused" {
    run herdr_linear::journal_put "../escaped" tab "x"
    [ "$status" -ne 0 ]
    [ ! -e "$HERDR_LINEAR_JOURNAL_DIR/../escaped.journal" ]
}

@test "a key that could corrupt the sed program is refused" {
    herdr_linear::journal_put WEB-2870 tab "kept"
    run herdr_linear::journal_get WEB-2870 "tab/../broken"
    [ "$status" -ne 0 ]
}

# The lock is the same mkdir lock lib/binding.sh uses for the same class of
# problem: two sessions building the same parent's layout must not both miss
# `journal_get parent tab` and both create a tab, orphaning the first.
@test "the tab section is locked, so a held lock blocks a concurrent build" {
    journal_file="$(herdr_linear::_journal WEB-2870)"
    herdr_linear::_lock "$journal_file"
    export HERDR_LINEAR_LOCK_WAIT_SECONDS=1
    run herdr_linear::layout_build WEB-2870 WEB-3001
    herdr_linear::_unlock "$journal_file"
    [ "$status" -eq 3 ]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

@test "the journal is not world-readable" {
    herdr_linear::journal_put WEB-2870 tab "w1:t1"
    [ "$(stat -f %Lp "$HERDR_LINEAR_JOURNAL_DIR/WEB-2870.journal")" = "600" ]
}

# ---------------------------------------------------------- pane registration

# `split` returning is not the same as the pane existing. A caller that assumed
# it does passes against a fast fixture and races live.
@test "a pane slow to register is waited for" {
    export FAKE_HERDR_SLOW_PANE=3
    export HERDR_LINEAR_PANE_POLL_TRIES=40
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
}

@test "a pane that never registers is a failure, not a shrug" {
    export FAKE_HERDR_SLOW_PANE=999
    export HERDR_LINEAR_PANE_POLL_TRIES=3
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
}

# ------------------------------------------------------------------ the skill

@test "the layout skill cannot be invoked by the model" {
    run grep -c '^disable-model-invocation: true$' "$ROOT/skills/layout/SKILL.md"
    [ "$output" = "1" ]
}

@test "the layout skill says to re-run rather than clean up after a partial failure" {
    body="$(cat "$ROOT/skills/layout/SKILL.md")"
    [[ "$body" == *"re-running continues"* ]]
    [[ "$body" == *"clean up"* ]]
    [[ "$body" == *"turns a resumable"* ]]
}

@test "the layout skill takes the sub-issue parent from the journal, not the neighbours" {
    body="$(cat "$ROOT/skills/layout/SKILL.md")"
    [[ "$body" == *"journal_get"* ]]
    [[ "$body" == *"neighbouring columns"* ]]
}

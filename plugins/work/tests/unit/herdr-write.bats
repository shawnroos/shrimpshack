#!/usr/bin/env bats

load setup_common

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
    # Resolved: the readers derive with `pwd -P`, so an unresolved fixture path
    # compares unequal to every answer they give.
    WORK="$(cd "$WORK" && pwd -P)"

    # The containment boundary is a plain directory holding projects, as
    # ~/projects is; the repository is the project inside it.
    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    PROJECT="$WORK/root/alpha"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_JOURNAL_DIR="$WORK/journal"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_RECORD_DIR="$WORK/hrec"
    export FAKE_HERDR_ALLOW_MUTATION=1
    export HERDR_LINEAR_PANE_POLL_MS=5
    export HERDR_LINEAR_PANE_POLL_TRIES=10
    # Every column is named from its own issue, so the tracker is faked too.
    # echo_issue answers each identifier as itself, titled `Column <id>`.
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/wt"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export FAKE_LINEAR_MODE=echo_issue
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    mkdir -p "$PROJECT" "$WORK/hrec" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_LAYOUTLAYOUTLAYOUT12" > "$LINEAR_SECRETS_FILE"

    # A project that is a real repo, so `git worktree add` has somewhere to go.
    git -C "$PROJECT" init -q -b main
    git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh herdr-read.sh repos.sh start.sh herdr-write.sh; do . "$ROOT/lib/$f"; done

    # KTD11. The layout runs from the parent's own worktree, and its children
    # are made beside it, from its repository.
    BASE="$WORK/wt/acme/ai-canvas-tools"
    PARENT_WT="$BASE/WEB-2870-tool-detach-foreground"
    mkdir -p "$BASE"
    git -C "$PROJECT" worktree add -q -b feature/WEB-2870-tool-detach-foreground "$PARENT_WT" >/dev/null 2>&1
    bind_as "$PARENT_WT" WEB-2870
    # R17. The parent's project has a space, and it is not the focused one.
    export FAKE_HERDR_WORKSPACES='wA=Plugins,wG=AI Canvas Tools'
    bind_space wG 44444444-4444-4444-8444-444444444444
    cd "$PARENT_WT" || return 1
}

bind_space() { local n; n="$(herdr_linear::workspace_propose "$1" "$2")"; herdr_linear::workspace_confirm "$1" "$2" "$n"; }

bind_as() { local n; n="$(herdr_linear::binding_propose "$1" "$2")"; herdr_linear::binding_confirm "$1" "$2" "$n"; }

# The directory a column's issue derives: beside the parent, identifier first.
col() { printf '%s/%s-column-%s' "$BASE" "$1" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }

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
        [ "$(herdr_linear::binding_state "$(col "$c")")" = "bound" ]
        [ "$(herdr_linear::binding_identifier "$(col "$c")")" = "$c" ]
    done
}

# The path convention, pinned: beside the parent's worktree, named from the
# child's own issue. The caller's project directory decides nothing.
@test "each column gets its own worktree, and the pane is opened in it" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ -d "$(col WEB-3001)" ]
    [ ! -e "$PROJECT/worktrees" ]
    run grep -c -- "--cwd $(col WEB-3001)" "$FAKE_HERDR_RECORD_DIR/argv"
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
    [ ! -d "$(col WEB-3001)" ]
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
    [ ! -d "$(col WEB-3001)" ]
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
    [ "$(ls -1d "$BASE"/WEB-300* 2>/dev/null | wc -l | tr -d ' ')" = "2" ]
}

# The file's own header forbids repairing a failed retry this way: an empty
# repo shares no history with the project and can never push.
@test "a branch that already exists fails the worktree instead of git-init a fresh repo" {
    git -C "$PROJECT" branch feature/WEB-3001-column-web-3001
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ ! -e "$(col WEB-3001)/.git" ]
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

# ------------------------------------------------ the parent decides (KTD11)

# AE11. A bound parent's repository is a fact, so the recorded set is never
# consulted -- even when it names a different repository.
@test "children are made beside the parent, from the parent's repository, whatever the record says" {
    mkdir -p "$WORK/root/beta"
    git -C "$WORK/root/beta" init -q -b main
    herdr_linear::record_scope_repo "$WORK/root/beta" \
        project-44444444-4444-4444-8444-444444444444 team-55555555-5555-4555-8555-555555555555
    run herdr_linear::layout_build WEB-2870 WEB-3318 WEB-3317
    [ "$status" -eq 0 ]
    for c in WEB-3318 WEB-3317; do
        [ -d "$(col "$c")" ]
        [ "$(herdr_linear::worktree_repo "$(col "$c")")" = "$PROJECT" ]
        [ "$(git -C "$(col "$c")" branch --show-current)" = "feature/$(basename "$(col "$c")")" ]
    done
}

# The verb takes an identifier, not a path, so where it runs is the only way it
# knows which worktree is the parent's. Anywhere else is a refusal, and nothing
# is made -- no tab, no worktree, no pane.
@test "a layout run from a directory bound to nothing refuses and makes nothing" {
    # A linked worktree, not the main checkout: the main-checkout refusal would
    # otherwise answer first and this would not reach the parent check at all.
    loose="$BASE/WEB-7777-loose"
    git -C "$PROJECT" worktree add -q -b f/loose "$loose" >/dev/null 2>&1
    cd "$loose"
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq "$HERDR_LINEAR_LAYOUT_NOT_PARENT" ]
    [[ "$stderr" == *"WEB-2870"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ "$(herdr_calls 'pane split')" = "0" ]
    [ ! -e "$(col WEB-3001)" ]
}

@test "a layout run from a worktree bound to a different issue refuses" {
    other="$BASE/WEB-9999-other"
    git -C "$PROJECT" worktree add -q -b f/other "$other" >/dev/null 2>&1
    bind_as "$other" WEB-9999
    cd "$other"
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq "$HERDR_LINEAR_LAYOUT_NOT_PARENT" ]
    [[ "$stderr" == *"WEB-9999"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -e "$(col WEB-3001)" ]
}

# Beside a main checkout is beside the canonical repositories, which is the
# place this plugin keeps ephemeral trees out of.
@test "a layout run from a main checkout bound to the parent refuses" {
    bind_as "$PROJECT" WEB-2870
    cd "$PROJECT"
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq "$HERDR_LINEAR_LAYOUT_NOT_PARENT" ]
    [[ "$stderr" == *"main checkout"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -e "$WORK/root/WEB-3001-column-web-3001" ]
}

# Standing in a subdirectory of the parent's worktree is standing in it.
@test "a layout run from inside the parent's worktree is run from the parent's worktree" {
    mkdir -p "$PARENT_WT/src"
    cd "$PARENT_WT/src"
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ -d "$(col WEB-3001)" ]
}

# Every child is fetched before anything is made, so one unreadable child
# cannot leave a tab and half the columns behind, and no path is composed with
# an empty segment.
@test "a child whose issue cannot be read refuses the layout before anything is made" {
    export FAKE_LINEAR_MISSING_IDS=WEB-3002
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001 WEB-3002
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"WEB-3002"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -e "$(col WEB-3001)" ]
    [ -z "$(ls -A "$BASE" | grep -v '^WEB-2870-')" ]
}

# A retry takes a column's path from the journal, not from a fresh fetch. A
# title renamed between the runs would otherwise derive a second worktree.
@test "a retry uses the journalled path and needs no fetch for a column already made" {
    export FAKE_HERDR_SLOW_PANE=999
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ -d "$(col WEB-3001)" ]

    unset FAKE_HERDR_SLOW_PANE
    export FAKE_LINEAR_MISSING_IDS=WEB-3001
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(ls -1d "$BASE"/WEB-3001* | wc -l | tr -d ' ')" = "1" ]
}

# ------------------------------------------------ where the layout lands (U7)

# R17. The tab goes in the parent's project's space, not the focused one.
@test "the layout's tab is made in the space bound to the parent's project" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
}

# KTD30. Every column is split from the layout's own tab. An untargeted split
# lands in whatever tab has focus, which is not the tab just made.
@test "every column is split inside the layout's own tab" {
    run herdr_linear::layout_build WEB-2870 WEB-3001 WEB-3002
    [ "$status" -eq 0 ]
    tab="$output"
    [ "$(herdr_calls '^pane split --')" = "0" ]
    for c in WEB-3001 WEB-3002; do
        pane="$(herdr_linear::journal_get WEB-2870 "pane.$c")"
        [ "$(herdr_linear::tab_of_pane "$pane")" = "$tab" ]
    done
}

# R20. The parent's ticket already owns a tab in its space; the layout is that
# piece of work, so the columns go there rather than in a second tab.
@test "a parent that already has a tab in its space gets its columns there" {
    made="$(FAKE_HERDR_ALLOW_MUTATION=1 "$HERDR_BIN" tab create --workspace wG --label WEB-2870)"
    ptab="$(printf '%s' "$made" | herdr_linear::json result.tab.tab_id)"
    herdr_linear::binding_set_tab "$PARENT_WT" "$ptab"
    : > "$FAKE_HERDR_RECORD_DIR/argv"
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$output" = "$ptab" ]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

# No space for the parent's project is a question, asked before anything is
# made -- no tab, no worktree, no pane.
@test "a parent whose project has no space asks and makes nothing" {
    rm -f "$HERDR_LINEAR_STORE_DIR"/workspaces/*.json
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq "$HERDR_LINEAR_LAYOUT_ASK" ]
    [[ "$stderr" == *"44444444-4444-4444-8444-444444444444"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
    [ ! -e "$(col WEB-3001)" ]
}

# A column's session is the child's piece of work, in the parent's tab.
@test "each column's tab is recorded on the column's binding" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_tab "$(col WEB-3001)")" = "$output" ]
}

# A journalled tab is only an authority while herdr still has it in the
# parent's space. A tab closed between a failed run and its retry would
# otherwise be split from forever, and the retry could never succeed.
@test "a retry whose journalled tab is gone makes a new tab in the space" {
    herdr_linear::journal_put WEB-2870 tab wG:t999
    herdr_linear::journal_put WEB-2870 tabpane wG:p0999
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$output" != "wG:t999" ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
    pane="$(herdr_linear::journal_get WEB-2870 pane.WEB-3001)"
    [ "$(herdr_linear::tab_of_pane "$pane")" = "$output" ]
}

# R17 on a retry: a journalled tab that now sits in another space is not the
# project's space, so the columns do not follow it there.
@test "a retry whose journalled tab is in another space does not split there" {
    herdr_linear::journal_put WEB-2870 tab wA:t1
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(herdr_calls 'pane split wA:')" = "0" ]
    [ "$(herdr_calls 'tab create --workspace wG')" = "1" ]
}

# The question was answered and the layout built: the notice that asked it is
# spent, and showing it at every later session start would be a stale question.
@test "a layout that builds clears the placement question it asked earlier" {
    rm -f "$HERDR_LINEAR_STORE_DIR"/workspaces/*.json
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq "$HERDR_LINEAR_LAYOUT_ASK" ]
    run herdr_linear::binding_pending_placement "$PARENT_WT"
    [ "$status" -eq 0 ]
    bind_space wG 44444444-4444-4444-8444-444444444444
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    run herdr_linear::binding_pending_placement "$PARENT_WT"
    [ "$status" -ne 0 ]
}

# One worktree per issue. A child already started with /work:start holds its
# branch in its own worktree; a layout run from a parent elsewhere reuses that
# worktree rather than failing on the branch forever.
@test "a child already started elsewhere is laid out in its own worktree" {
    old="$PROJECT/worktrees/parent"
    git -C "$PROJECT" worktree add -q -b f/parent "$old" >/dev/null 2>&1
    bind_as "$old" WEB-2870
    herdr_linear::record_scope_repo "$PROJECT" \
        project-44444444-4444-4444-8444-444444444444 team-55555555-5555-4555-8555-555555555555
    started="$(herdr_linear::start_from_issue WEB-3001 2>/dev/null)"
    [ -d "$started" ]
    cd "$old"
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::journal_get WEB-2870 worktree.WEB-3001)" = "$started" ]
    [ ! -e "$PROJECT/worktrees/WEB-3001-column-web-3001" ]
}

# ------------------------------------------------ round-two review (U7 fixes)

# The layout refuses to run from a main checkout; it must not then turn one
# into a column because the child's branch happens to be checked out there.
@test "a child branch checked out in the main checkout is not taken as its worktree" {
    git -C "$PROJECT" checkout -q -b feature/WEB-3001-column-web-3001
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"WEB-3001"* ]]
    [ "$(herdr_linear::binding_state "$PROJECT")" = "unbound" ]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

# Somebody else's worktree is never re-homed, here any more than in start.
@test "a child branch held by a worktree bound to another issue is refused" {
    other="$BASE/elsewhere"
    git -C "$PROJECT" worktree add -q -b feature/WEB-3001-column-web-3001 "$other" >/dev/null 2>&1
    bind_as "$other" WEB-9999
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ "$(herdr_linear::binding_identifier "$other")" = "WEB-9999" ]
}

# A column whose pane died with its old tab is not done. Replacing the tab and
# skipping the column would exit 0 with the column missing.
@test "a column journalled in a tab that has since closed is split again in the new tab" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    old="$output"
    # herdr closes the tab: every pane in it goes too.
    grep -v "^$old " "$FAKE_HERDR_RECORD_DIR/tabs" > "$WORK/t" || true; mv "$WORK/t" "$FAKE_HERDR_RECORD_DIR/tabs"
    grep -v " $old " "$FAKE_HERDR_RECORD_DIR/panes" > "$WORK/p" || true; mv "$WORK/p" "$FAKE_HERDR_RECORD_DIR/panes"
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    [ "$output" != "$old" ]
    pane="$(herdr_linear::journal_get WEB-2870 pane.WEB-3001)"
    [ "$(herdr_linear::tab_of_pane "$pane")" = "$output" ]
}

# "Could not ask" is not "no such tab". Treating it as gone makes a second tab
# on every retry during an outage -- the one thing the journal exists to stop.
@test "a tab herdr cannot be asked about is not replaced" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    export FAKE_HERDR_TAB_GET_FAILS=1
    run herdr_linear::layout_build WEB-2870 WEB-3002
    [ "$status" -eq 3 ]
    [ "$(herdr_calls 'tab create')" = "1" ]
}

# A snapshot that could not be read says nothing about which panes exist.
# Taking it for "the column's pane is gone" splits a second pane into a
# finished layout; taking it for "the tab is gone" makes a second tab.
@test "a snapshot herdr cannot give makes no pane and no tab" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    splits="$(herdr_calls 'pane split')"
    export FAKE_HERDR_SNAPSHOT_FAILS=1
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ "$(herdr_calls 'pane split')" = "$splits" ]
    [ "$(herdr_calls 'tab create')" = "1" ]
}

# A locked worktree whose directory is gone is not reported prunable, but it is
# no worktree to open a column in.
@test "a child branch held by a worktree whose directory is gone is refused with a reason" {
    gone="$BASE/gone"
    git -C "$PROJECT" worktree add -q -b feature/WEB-3001-column-web-3001 "$gone" >/dev/null 2>&1
    git -C "$PROJECT" worktree lock "$gone"
    rm -rf "$gone"
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"$gone"* ]]
    [ "$(herdr_calls 'tab create')" = "0" ]
}

# The tab check reads the snapshot first. A server that goes away after that
# read must still not have its silence taken for "this column's pane is gone".
@test "a snapshot lost after the tab check makes no second pane" {
    run herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 0 ]
    splits="$(herdr_calls 'pane split')"
    rm -f "$FAKE_HERDR_RECORD_DIR/snapshots"
    export FAKE_HERDR_SNAPSHOT_FAILS_FROM=2
    run --separate-stderr herdr_linear::layout_build WEB-2870 WEB-3001
    [ "$status" -eq 3 ]
    [ "$(herdr_calls 'pane split')" = "$splits" ]
}

#!/usr/bin/env bats

load setup_common

# The scheme resolver — a name is asked for by kind, not composed by the caller.
#
# Two properties are the reason this unit exists, and both are easy to leave
# unreachable:
#
#   * R6. A scheme name nobody implemented is REFUSED, and the refusal names
#     what is valid. A resolver that quietly falls back to its default on an
#     unrecognised name turns a typo into a silently different name.
#   * R7. Every worktree and branch scheme carries the ticket identifier, so a
#     worktree stays findable from its branch. That is enforced in the resolver
#     and asserted here by ITERATING THE ENUM — a hand-copied list of scheme
#     names would leave the next scheme added untested.
#
# KTD5. The default scheme renders byte-identical names to today's. The expected
# strings below are LITERALS taken from running the current
# herdr_linear::start_worktree_name / start_branch_name once. They are
# deliberately not computed by calling those functions: once U3 routes them
# through this resolver, a computed expectation would compare the resolver with
# itself and pass no matter what it renders.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    # shellcheck source=/dev/null
    for f in sanitize.sh linear.sh schemes.sh; do . "$ROOT/lib/$f"; done
}

# The long title whose slug overruns the 40-character title cap mid-word, so the
# severed remnant is dropped. This is start.bats' own fixture ticket.
LONG_TITLE="Export panel is empty when a still-rendering frame is selected"

# ------------------------------------------------------------ unknown schemes

# AE2. The scheme is not one the plugin implements. Nothing is rendered — the
# caller gets no string it could mistake for a name and go create something with.
@test "an unrecognised worktree scheme is refused and nothing is rendered" {
    export HERDR_LINEAR_WORKTREE_SCHEME=ticket-only
    run --separate-stderr herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_UNKNOWN" ]
    [ -z "$output" ]
    [[ "$stderr" == *"ticket-only"* ]]
}

# R6. The refusal names the schemes that ARE valid, so the reader can correct the
# setting without reading the source.
@test "an unrecognised scheme names every valid scheme for that kind on stderr" {
    local scheme
    export HERDR_LINEAR_BRANCH_SCHEME=nonsense
    run --separate-stderr herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_UNKNOWN" ]
    for scheme in $HERDR_LINEAR_BRANCH_SCHEMES; do
        [[ "$stderr" == *"$scheme"* ]]
    done
}

# Plan risk note for U2. Extending the enum is a code change carrying a new test
# and a suite-floor bump, so the refusal says so — otherwise it reads as a dead
# end rather than as a request to file.
@test "the refusal says a new scheme is a code change rather than a setting" {
    export HERDR_LINEAR_TAB_SCHEME=whatever
    run --separate-stderr herdr_linear::scheme_name tab WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_UNKNOWN" ]
    [[ "$stderr" == *"code change"* ]]
}

# A name kind nobody implemented is the same class of mistake as a scheme nobody
# implemented, and gets the same treatment. Space and pane are the live examples:
# R4 names them, and neither has a rendering site in the plugin.
@test "an unrecognised name kind is refused and the valid kinds are named" {
    local kind
    run --separate-stderr herdr_linear::scheme_name pane WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_UNKNOWN" ]
    [ -z "$output" ]
    for kind in $HERDR_LINEAR_SCHEME_KINDS; do
        [[ "$stderr" == *"$kind"* ]]
    done
}

# ------------------------------------------------- R7, over the enum, not a list

# R7. The guarantee is a property of the ENUM, so the test walks the enum. A
# scheme added later without the identifier fails here the day it is written.
@test "every worktree scheme renders a name carrying the ticket identifier" {
    local scheme out
    for scheme in $HERDR_LINEAR_WORKTREE_SCHEMES; do
        export HERDR_LINEAR_WORKTREE_SCHEME="$scheme"
        out="$(herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE")"
        [ -n "$out" ]
        [[ "$out" == *"WEB-3308"* ]]
    done
}

@test "every branch scheme renders a name carrying the ticket identifier" {
    local scheme out
    for scheme in $HERDR_LINEAR_BRANCH_SCHEMES; do
        export HERDR_LINEAR_BRANCH_SCHEME="$scheme"
        out="$(herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE")"
        [ -n "$out" ]
        [[ "$out" == *"WEB-3308"* ]]
    done
}

# ------------------------------------------------------ KTD5, byte-identity

@test "the default worktree scheme reproduces today's name at the 40-character title cap" {
    run herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308-export-panel-is-empty-when-a-still" ]
}

@test "the default branch scheme reproduces today's prefixed name" {
    run herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "feature/WEB-3308-export-panel-is-empty-when-a-still" ]
}

# A title short enough to leave the cap untouched keeps its last word. Trimming
# the severed remnant unconditionally once cost every short title a word.
@test "a title under the cap keeps its final word" {
    run herdr_linear::scheme_name worktree WEB-2670 "Tool blur backdrop"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-2670-tool-blur-backdrop" ]
}

# Separator runs and punctuation collapse the same way they do today.
@test "punctuation runs collapse to single separators as today" {
    run herdr_linear::scheme_name worktree ABC-2 "Hello -- world   ///  again"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "ABC-2-hello-world-again" ]
}

# The whole-name cap is 60 and it is applied after the identifier is joined on,
# so a long team key eats into the title rather than overrunning.
@test "the whole name is cut at sixty characters" {
    run herdr_linear::scheme_name worktree LONGERTEAMKEYHERE-12345 \
        "a very long title that keeps going and going past the cap"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "${#output}" -eq 60 ]
    [ "$output" = "LONGERTEAMKEYHERE-12345-a-very-long-title-that-keeps-going-a" ]
}

# --------------------------------------------------------------- refusals

# R28, and the reason this cannot be a repair: a title of pure punctuation slugs
# to nothing, and joining that on would yield `ABC-4-`, a bare identifier with a
# trailing separator that nobody chose.
@test "a title that slugs to empty is refused rather than trimmed to the identifier" {
    run --separate-stderr herdr_linear::scheme_name worktree ABC-4 "!!!"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
    [ -z "$output" ]
}

@test "an identifier outside the safe charset is refused" {
    run --separate-stderr herdr_linear::scheme_name worktree "bad/ident" "Some title"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
    [ -z "$output" ]
}

@test "an empty identifier is refused" {
    run --separate-stderr herdr_linear::scheme_name worktree "" "Some title"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
    [ -z "$output" ]
}

# ------------------------------------------------------- choosing a scheme

@test "an unset scheme setting renders the default scheme" {
    local unset_out set_out
    unset HERDR_LINEAR_WORKTREE_SCHEME
    unset_out="$(herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE")"
    export HERDR_LINEAR_WORKTREE_SCHEME="$HERDR_LINEAR_WORKTREE_SCHEME_DEFAULT"
    set_out="$(herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE")"
    [ "$unset_out" = "$set_out" ]
    [ "$unset_out" = "WEB-3308-export-panel-is-empty-when-a-still" ]
}

# An empty value carries no alternative meaning for a scheme — unlike the branch
# prefix, where empty means "no prefix" — so it reads as "not chosen".
@test "a scheme setting that is set but empty renders the default scheme" {
    export HERDR_LINEAR_WORKTREE_SCHEME=""
    run herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308-export-panel-is-empty-when-a-still" ]
}

@test "the identifier worktree scheme renders the identifier alone" {
    export HERDR_LINEAR_WORKTREE_SCHEME=identifier
    run herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308" ]
}

@test "the worktree branch scheme renders the worktree name with no prefix" {
    export HERDR_LINEAR_BRANCH_SCHEME=worktree
    run herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308-export-panel-is-empty-when-a-still" ]
}

# KTD1. An empty prefix is what makes trading the identical-string form away
# safe, so it must still produce the identical string with no code change.
@test "an empty branch prefix makes the branch and the worktree name identical" {
    local worktree branch
    export HERDR_LINEAR_BRANCH_PREFIX=""
    worktree="$(herdr_linear::scheme_name worktree WEB-3308 "$LONG_TITLE")"
    branch="$(herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE")"
    # Pinned, not just compared: two renderings of the same wrong string are
    # equal to each other, so equality alone is an assertion that cannot fail.
    [ "$worktree" = "WEB-3308-export-panel-is-empty-when-a-still" ]
    [ "$branch" = "$worktree" ]
}

@test "a branch prefix passed as an argument beats the environment" {
    export HERDR_LINEAR_BRANCH_PREFIX=feature
    run herdr_linear::scheme_name branch WEB-2670 "Tool blur backdrop" bugfix
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "bugfix/WEB-2670-tool-blur-backdrop" ]
}

# The branch scheme composes on the WORKTREE scheme, which is what makes a
# worktree findable from its branch: changing one changes both together.
@test "the branch name follows the worktree scheme it is built from" {
    export HERDR_LINEAR_WORKTREE_SCHEME=identifier
    run herdr_linear::scheme_name branch WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "feature/WEB-3308" ]
}

# ------------------------------------------------------------------ the tab

# The identifier is emitted verbatim, NOT through herdr_linear::slug, which
# squeezes separator runs. `herdr-write.sh:229` labels a tab from the bare
# identifier today and this scheme must reproduce it byte for byte.
@test "the default tab scheme renders the bare identifier" {
    run herdr_linear::scheme_name tab WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308" ]
}

@test "the identifier-title tab scheme renders the worktree-shaped name" {
    export HERDR_LINEAR_TAB_SCHEME=identifier-title
    run herdr_linear::scheme_name tab WEB-3308 "$LONG_TITLE"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_OK" ]
    [ "$output" = "WEB-3308-export-panel-is-empty-when-a-still" ]
}

# A tab label is not a path segment, so a title that slugs to empty is not fatal
# for every tab scheme — but the identifier still has to be safe. The tab
# `identifier` scheme emits it VERBATIM, so the leading hyphen matters as much as
# the traversal: `herdr tab create --label -flag` would read the label as a flag.
@test "every tab scheme refuses an unsafe identifier" {
    local scheme hostile
    for scheme in $HERDR_LINEAR_TAB_SCHEMES; do
        export HERDR_LINEAR_TAB_SCHEME="$scheme"
        for hostile in "../escape" "-flag" ".hidden" ".."; do
            run --separate-stderr herdr_linear::scheme_name tab "$hostile" "Some title"
            [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
            [ -z "$output" ]
        done
    done
}

# ----------------------------------------------------------- R7, enforced

# The live way to lose the identifier without anyone writing a scheme that omits
# it: the 60-character whole-name cut severs an identifier longer than the cap.
# A name that no longer carries it cannot be found from its branch, so it is
# refused rather than returned.
@test "a name whose identifier is severed by the sixty-character cut is refused" {
    local long_ident
    long_ident="$(printf 'A%.0s' $(seq 1 60))-12345"
    run --separate-stderr herdr_linear::scheme_name worktree "$long_ident" "Some title"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
    [ -z "$output" ]
    [[ "$stderr" == *"dropped the identifier"* ]]
}

@test "a branch whose identifier is severed by the cut is refused too" {
    local long_ident
    long_ident="$(printf 'A%.0s' $(seq 1 60))-12345"
    run --separate-stderr herdr_linear::scheme_name branch "$long_ident" "Some title"
    [ "$status" -eq "$HERDR_LINEAR_SCHEME_REFUSED" ]
    [ -z "$output" ]
}

#!/usr/bin/env bash
# Build herdr layout from a Linear issue. Sourced, never executed.
#
# THE JOURNAL IS THE WHOLE DESIGN.
# Building a tab with three columns means a tab, three git worktrees, three
# panes and three bindings -- eleven things that can each fail halfway. Without
# a record of what was already made, a retry makes a SECOND tab and three more
# worktrees, and the person is now worse off than if it had never run. So every
# created resource is journalled against the source issue before the next step
# starts, and a retry consults the journal and continues.
#
# LIVENESS IS PROBED, NOT ASSUMED.
# HERDR_ENV records launch ancestry, not reachability -- a pane inherits it from
# whatever started it, so it stays set after the server has gone. Every run
# probes the server through lib/herdr-read.sh first and reports rather than
# half-building a layout against a socket that is not there.
#
# EVERY LINEAR-DERIVED NAME IS SLUGGED, AND A BAD ONE IS REFUSED.
# A title becomes a branch name and a directory path. `herdr_linear::slug`
# rejects rather than repairs: a title of `..`, one beginning with `--`, and one
# that slugs to nothing are refused outright, because a repaired name is a name
# nobody chose pointing at a place nobody meant.

HERDR_LINEAR_JOURNAL_DIR="${HERDR_LINEAR_JOURNAL_DIR:-$HOME/.claude/herdr-linear/layouts}"
HERDR_LINEAR_PANE_POLL_TRIES="${HERDR_LINEAR_PANE_POLL_TRIES:-40}"
HERDR_LINEAR_PANE_POLL_MS="${HERDR_LINEAR_PANE_POLL_MS:-100}"

HERDR_LINEAR_LAYOUT_OK=0
HERDR_LINEAR_LAYOUT_NO_SERVER=1
HERDR_LINEAR_LAYOUT_BAD_NAME=2
HERDR_LINEAR_LAYOUT_FAILED=3

herdr_linear::_journal() {
    local issue="$1"
    mkdir -p "$HERDR_LINEAR_JOURNAL_DIR" 2>/dev/null
    printf '%s/%s.journal' "$HERDR_LINEAR_JOURNAL_DIR" "$issue"
}

# journal_get <issue> <key> -> prints the recorded value, or fails.
herdr_linear::journal_get() {
    local f; f="$(herdr_linear::_journal "$1")"
    [ -r "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1 | grep -q . || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

# Append-only. A journal that is rewritten can lose an entry to a crash between
# read and write; appending cannot.
herdr_linear::journal_put() {
    local f; f="$(herdr_linear::_journal "$1")"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s=%s\n' "$2" "$3" >> "$f"
    chmod 600 "$f" 2>/dev/null
}

# A pane exists when herdr says it does, not when `split` returned. Polling is
# bounded and a timeout is a failure, not a shrug.
herdr_linear::await_pane() {
    local pane="$1" i=0
    while [ "$i" -lt "$HERDR_LINEAR_PANE_POLL_TRIES" ]; do
        if herdr_linear::bin >/dev/null 2>&1 \
            && "$(herdr_linear::bin)" pane get "$pane" 2>/dev/null | grep -q "$pane"; then
            return 0
        fi
        i=$(( i + 1 ))
        perl -e "select undef, undef, undef, $HERDR_LINEAR_PANE_POLL_MS/1000" 2>/dev/null || sleep 1
    done
    return 1
}

# herdr_linear::layout_build <parent-issue> <child-issue>...
#
# Idempotent by journal: a second run after a partial failure continues, and
# creates nothing twice.
herdr_linear::layout_build() {
    local parent="${1:-}" ; shift || true
    local bin tab pane slug child branch wt_path

    [ -n "$parent" ] || return "$HERDR_LINEAR_LAYOUT_FAILED"

    # Liveness first. Reporting "the herdr server is not running" is a complete
    # answer; half a layout is not.
    # herdr_linear::probe, not an invented name. It matches an exact
    # `status: running` LINE -- a substring match also accepts "not running".
    herdr_linear::probe || return "$HERDR_LINEAR_LAYOUT_NO_SERVER"
    bin="$(herdr_linear::bin)"
    [ -n "$bin" ] || return "$HERDR_LINEAR_LAYOUT_NO_SERVER"

    # Names are validated BEFORE anything is created, so a bad title cannot
    # leave a tab behind with no columns under it.
    slug="$(herdr_linear::slug "$parent")" || return "$HERDR_LINEAR_LAYOUT_BAD_NAME"
    for child in "$@"; do
        herdr_linear::slug "$child" >/dev/null || return "$HERDR_LINEAR_LAYOUT_BAD_NAME"
    done

    tab="$(herdr_linear::journal_get "$parent" tab)" || {
        tab="$("$bin" tab create --label "$slug" 2>/dev/null \
            | herdr_linear::json "result.tab.tab_id")"
        [ -n "$tab" ] || return "$HERDR_LINEAR_LAYOUT_FAILED"
        herdr_linear::journal_put "$parent" tab "$tab"
    }

    for child in "$@"; do
        # Already done on an earlier attempt: skip, do not remake.
        if herdr_linear::journal_get "$parent" "pane.$child" >/dev/null 2>&1; then
            continue
        fi

        branch="$(herdr_linear::slug "$child")" || return "$HERDR_LINEAR_LAYOUT_BAD_NAME"
        wt_path="$(herdr_linear::slate_root)/$branch"

        if ! herdr_linear::journal_get "$parent" "worktree.$child" >/dev/null 2>&1; then
            herdr_linear::_make_worktree "$wt_path" "$branch" || return "$HERDR_LINEAR_LAYOUT_FAILED"
            herdr_linear::journal_put "$parent" "worktree.$child" "$wt_path"
        fi

        pane="$("$bin" pane split --direction right --cwd "$wt_path" --no-focus 2>/dev/null \
            | herdr_linear::json "result.pane.pane_id")"
        [ -n "$pane" ] || return "$HERDR_LINEAR_LAYOUT_FAILED"
        herdr_linear::await_pane "$pane" || return "$HERDR_LINEAR_LAYOUT_FAILED"
        herdr_linear::journal_put "$parent" "pane.$child" "$pane"

        # Bound on creation: the layout IS the statement of what this worktree
        # is for, so there is nothing to propose and nothing to confirm.
        herdr_linear::_bind_created "$wt_path" "$child"
    done

    printf '%s' "$tab"
    return "$HERDR_LINEAR_LAYOUT_OK"
}

herdr_linear::_bind_created() {
    local wt="$1" child="$2" nonce
    nonce="$(herdr_linear::binding_propose "$wt" "$child" 2>/dev/null)" || return 1
    herdr_linear::binding_confirm "$wt" "$child" "$nonce" 2>/dev/null || return 1
    return 0
}

herdr_linear::_make_worktree() {
    local path="$1" branch="$2" root
    root="$(herdr_linear::slate_root)"
    [ -d "$path" ] && return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null
    "${HERDR_LINEAR_GIT_BIN:-git}" -C "$root" worktree add -b "$branch" "$path" 2>/dev/null \
        || "${HERDR_LINEAR_GIT_BIN:-git}" init -q -b "$branch" "$path" 2>/dev/null \
        || return 1
    return 0
}

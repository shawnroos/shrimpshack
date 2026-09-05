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

HERDR_LINEAR_JOURNAL_DIR="${HERDR_LINEAR_JOURNAL_DIR:-$HOME/.claude/work/layouts}"
HERDR_LINEAR_PANE_POLL_TRIES="${HERDR_LINEAR_PANE_POLL_TRIES:-40}"
HERDR_LINEAR_PANE_POLL_MS="${HERDR_LINEAR_PANE_POLL_MS:-100}"

HERDR_LINEAR_LAYOUT_OK=0
HERDR_LINEAR_LAYOUT_NO_SERVER=1
HERDR_LINEAR_LAYOUT_BAD_NAME=2
HERDR_LINEAR_LAYOUT_FAILED=3

# A journal identifier becomes a path segment (here) and a sed program (in
# journal_get, since the child identifier is embedded in the key). Today's
# callers only pass Linear identifiers, which cannot contain `/`, so this is
# not yet reachable -- but it becomes live the moment a caller passes a title.
# lib/sanitize.sh has is_safe_identifier for exactly this; kept local because
# that file is being edited elsewhere right now. Replace this with it later.
herdr_linear::_safe_journal_key() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        .|..) return 1 ;;
    esac
    return 0
}

herdr_linear::_journal() {
    local issue="$1"
    herdr_linear::_safe_journal_key "$issue" || return 1
    mkdir -p "$HERDR_LINEAR_JOURNAL_DIR" 2>/dev/null
    printf '%s/%s.journal' "$HERDR_LINEAR_JOURNAL_DIR" "$issue"
}

# journal_get <issue> <key> -> prints the recorded value, or fails.
herdr_linear::journal_get() {
    local f
    herdr_linear::_safe_journal_key "$2" || return 1
    f="$(herdr_linear::_journal "$1")" || return 1
    [ -r "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1 | grep -q . || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

# Append-only. A journal that is rewritten can lose an entry to a crash between
# read and write; appending cannot.
herdr_linear::journal_put() {
    local f
    herdr_linear::_safe_journal_key "$2" || return 1
    f="$(herdr_linear::_journal "$1")" || return 1
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

# herdr_linear::open_session <worktree-path>
#
# A pane in the CURRENT tab, working in that worktree. Split right and do not
# steal focus: the person asked for a session to exist, not to be moved into it.
# Prints the pane id.
herdr_linear::open_session() {
    local path="${1:-}" bin pane
    [ -d "$path" ] || return 1
    herdr_linear::probe || return 1
    bin="$(herdr_linear::bin)"; [ -n "$bin" ] || return 1
    pane="$("$bin" pane split --direction right --cwd "$path" --no-focus 2>/dev/null \
        | herdr_linear::json "result.pane.pane_id")"
    [ -n "$pane" ] || return 1
    herdr_linear::await_pane "$pane" || return 1
    printf '%s' "$pane"
}

# herdr_linear::layout_build <parent-issue> <child-issue>...
#
# Idempotent by journal: a second run after a partial failure continues, and
# creates nothing twice.
herdr_linear::layout_build() {
    local parent="${1:-}" ; shift || true
    local bin tab pane slug child branch wt_path journal_file

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

    # Two sessions building the same parent's layout within the poll window
    # both miss `journal_get parent tab`, both run `tab create`, and the
    # journal's `tail -1` orphans the first tab -- the concurrency twin of the
    # retry this journal exists to prevent. Reuse binding.sh's mkdir lock: it
    # is already a dependency (binding_propose/confirm below) and solves the
    # same class of problem there.
    journal_file="$(herdr_linear::_journal "$parent")" || return "$HERDR_LINEAR_LAYOUT_FAILED"

    herdr_linear::_lock "$journal_file" || return "$HERDR_LINEAR_LAYOUT_FAILED"
    tab="$(herdr_linear::journal_get "$parent" tab)"
    if [ -z "$tab" ]; then
        tab="$("$bin" tab create --label "$slug" 2>/dev/null \
            | herdr_linear::json "result.tab.tab_id")"
        if [ -z "$tab" ]; then
            herdr_linear::_unlock "$journal_file"
            return "$HERDR_LINEAR_LAYOUT_FAILED"
        fi
        herdr_linear::journal_put "$parent" tab "$tab"
    fi
    herdr_linear::_unlock "$journal_file"

    for child in "$@"; do
        herdr_linear::_lock "$journal_file" || return "$HERDR_LINEAR_LAYOUT_FAILED"

        # Already done on an earlier attempt: skip, do not remake.
        if herdr_linear::journal_get "$parent" "pane.$child" >/dev/null 2>&1; then
            herdr_linear::_unlock "$journal_file"
            continue
        fi

        branch="$(herdr_linear::slug "$child")" || {
            herdr_linear::_unlock "$journal_file"
            return "$HERDR_LINEAR_LAYOUT_BAD_NAME"
        }
        # <root>/worktrees/<name>, matching every worktree on this machine and
        # the `wt` shell function. An earlier version used <root>/<branch>,
        # which puts a worktree beside the repositories instead of among the
        # worktrees -- wrong, and invisible until someone went looking for it.
        wt_path="$(herdr_linear::slate_root)/worktrees/$branch"

        if ! herdr_linear::journal_get "$parent" "worktree.$child" >/dev/null 2>&1; then
            herdr_linear::_make_worktree "$wt_path" "$branch" || {
                herdr_linear::_unlock "$journal_file"
                return "$HERDR_LINEAR_LAYOUT_FAILED"
            }
            herdr_linear::journal_put "$parent" "worktree.$child" "$wt_path"
        fi

        pane="$("$bin" pane split --direction right --cwd "$wt_path" --no-focus 2>/dev/null \
            | herdr_linear::json "result.pane.pane_id")"
        if [ -z "$pane" ]; then
            herdr_linear::_unlock "$journal_file"
            return "$HERDR_LINEAR_LAYOUT_FAILED"
        fi
        herdr_linear::await_pane "$pane" || {
            herdr_linear::_unlock "$journal_file"
            return "$HERDR_LINEAR_LAYOUT_FAILED"
        }
        herdr_linear::journal_put "$parent" "pane.$child" "$pane"
        herdr_linear::_unlock "$journal_file"

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
    # Both streams: `worktree add` announces itself on stdout, which would
    # otherwise leak into whatever the caller is capturing.
    #
    # No `git init` fallback here. `worktree add` fails most often because the
    # branch already exists -- exactly a layout RETRY -- and a fresh empty repo
    # shares no history with Slate, can never push, and the header above
    # forbids repairing a failure this way. Fail and let the journal's own
    # resumability handle the retry.
    "${HERDR_LINEAR_GIT_BIN:-git}" -C "$root" worktree add -b "$branch" "$path" >/dev/null 2>&1 \
        || return 1
    return 0
}

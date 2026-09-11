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

# No lib sources another, and ground.sh sources sanitize.sh AFTER this file:
# without this the call below is 127, which its `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::start_worktree_name >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/start.sh"
command -v herdr_linear::_issue_project_id >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/states.sh"

HERDR_LINEAR_JOURNAL_DIR="${HERDR_LINEAR_JOURNAL_DIR:-$HOME/.claude/work/layouts}"
HERDR_LINEAR_PANE_POLL_TRIES="${HERDR_LINEAR_PANE_POLL_TRIES:-40}"
HERDR_LINEAR_PANE_POLL_MS="${HERDR_LINEAR_PANE_POLL_MS:-100}"

HERDR_LINEAR_LAYOUT_OK=0
HERDR_LINEAR_LAYOUT_NO_SERVER=1
HERDR_LINEAR_LAYOUT_BAD_NAME=2
HERDR_LINEAR_LAYOUT_FAILED=3
HERDR_LINEAR_LAYOUT_NOT_PARENT=4
HERDR_LINEAR_LAYOUT_ASK=5

HERDR_LINEAR_SESSION_OK=0
HERDR_LINEAR_SESSION_FAILED=1
# Which space the session opens in is a choice, not a fact. Nothing was made;
# the question is on stderr and recorded on the binding.
HERDR_LINEAR_SESSION_ASK=6

herdr_linear::_journal() {
    local issue="$1"
    herdr_linear::is_safe_identifier "$issue" || return 1
    mkdir -p "$HERDR_LINEAR_JOURNAL_DIR" 2>/dev/null
    printf '%s/%s.journal' "$HERDR_LINEAR_JOURNAL_DIR" "$issue"
}

# journal_get <issue> <key> -> prints the recorded value, or fails.
herdr_linear::journal_get() {
    local f
    herdr_linear::is_safe_identifier "$2" || return 1
    f="$(herdr_linear::_journal "$1")" || return 1
    [ -r "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1 | grep -q . || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

# Append-only. A journal that is rewritten can lose an entry to a crash between
# read and write; appending cannot.
herdr_linear::journal_put() {
    local f
    herdr_linear::is_safe_identifier "$2" || return 1
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

# ---------------------------------------------------------- spaces (KTD27)
#
# A space is a project. Which space is a project's is read from the workspace
# records -- a space's label is prose and names the wrong project on the machine
# this was written for (KTD13).

# Every live space bound to the project, one id per line. A record for a space
# herdr no longer reports is not a candidate: offering it would fail inside
# `tab create`, after the question could have been asked.
herdr_linear::project_spaces() {
    local pid="${1:-}" live f ws
    [ -n "$pid" ] || return 1
    # Captured before the cut: a pipeline's status is the cut's, and a failed
    # read would come back as a list with no spaces in it.
    live="$(herdr_linear::live_spaces)" || return 1
    live="$(printf '%s' "$live" | cut -f1)"
    for f in "$HERDR_LINEAR_STORE_DIR"/workspaces/*.json; do
        [ -e "$f" ] || continue
        ws="$(basename "$f" .json)"
        # workspace_project answers only for a bound record, so a proposal
        # nobody confirmed is not a candidate.
        [ "$(herdr_linear::workspace_project "$ws" 2>/dev/null)" = "$pid" ] || continue
        printf '%s\n' "$live" | grep -qxF -- "$ws" && printf '%s\n' "$ws"
    done
    return 0
}

herdr_linear::project_space() {
    local lines
    lines="$(herdr_linear::project_spaces "${1:-}")" || return 1
    printf '%s' "$lines" | herdr_linear::the_only_line
}

# Why there is no single space, said so the person can answer it. With none
# bound, the answer depends on the space this session is working from: an
# unbound one is the pairing to propose (R18); one bound to another project is
# Misplaced (R19), and which side was wrong is not this plugin's to pick.
herdr_linear::no_space_reason() {
    local pid="${1:-}" here="${2:-}" spaces labels ws other
    spaces="$(herdr_linear::project_spaces "$pid" 2>/dev/null)" || spaces=""
    labels="$(herdr_linear::live_spaces 2>/dev/null)" || labels=""
    if [ "$(printf '%s' "$spaces" | grep -c .)" -gt 1 ]; then
        printf 'several herdr spaces are bound to project %s, so which one this opens in is a choice. Ask, then name one of:\n' "$pid"
        printf '%s' "$spaces" | grep . | while IFS= read -r ws; do
            printf '  %s (%s)\n' "$ws" "$(printf '%s\n' "$labels" | awk -F '\t' -v w="$ws" '$1 == w { print $2; exit }')"
        done | herdr_linear::sanitize_stream
        return 0
    fi
    if [ -z "$here" ]; then
        printf 'no herdr space is bound to project %s, and this session is not in one. Ask which space to bind to it.\n' "$pid"
        return 0
    fi
    other=""
    [ "$(herdr_linear::workspace_state "$here" 2>/dev/null)" = "bound" ] \
        && other="$(herdr_linear::workspace_project "$here" 2>/dev/null)"
    if [ -n "$other" ] && [ "$other" != "$pid" ]; then
        printf 'Misplaced: this space (%s) is bound to project %s, and this issue is in project %s. Nothing was opened.\n' "$here" "$other" "$pid"
        printf 'Offer either move -- bind a space to project %s, or move the issue into project %s -- and do not pick which side was wrong.\n' "$pid" "$other"
        return 0
    fi
    printf 'no herdr space is bound to project %s. This space (%s) has no binding: propose binding it to project %s, and ask.\n' "$pid" "$here" "$pid"
}

# herdr_linear::_issue_space <identifier> <worktree> <what>
#
# The space bound to the issue's project, on stdout. 1 when it could not be
# read; 2 when it is a question -- the reason is on stderr and recorded on
# <worktree>'s binding, because this cannot tell whether anybody is there to
# answer (KTD29). <what> names the thing being placed, for the reason's text.
herdr_linear::_issue_space() {
    local ident="$1" at="$2" what="$3" pid ws="" reason=""
    pid="$(herdr_linear::_issue_project_id "$ident")" || {
        printf 'could not read %s from Linear, so its space is unknown; nothing was opened\n' "$ident" >&2
        return 1
    }
    if [ -z "$pid" ]; then
        reason="$(printf '%s has no project, so no herdr space is bound to it. Ask where its %s should open.' "$ident" "$what")"
    else
        ws="$(herdr_linear::project_space "$pid")" || {
            printf 'could not read the herdr spaces, so the space for %s is unknown; nothing was opened\n' "$ident" >&2
            return 1
        }
        [ -n "$ws" ] || reason="$(herdr_linear::no_space_reason "$pid" "$(herdr_linear::workspace_id 2>/dev/null)")"
    fi
    if [ -n "$reason" ]; then
        printf '%s\n' "$reason" >&2
        herdr_linear::binding_set_pending_placement "$at" "$reason" || true
        return 2
    fi
    printf '%s' "$ws"
}

# KTD28. A pane of <tab> to split from, while herdr still has that tab in
# <space>. Nothing otherwise, and the caller makes a new tab.
# Non-zero when herdr could not be asked about the tab.
herdr_linear::_pane_of_tab_in() {
    local tab="${1:-}" ws="${2:-}" where
    [ -n "$tab" ] || return 0
    where="$(herdr_linear::tab_space "$tab")" || return 1
    [ "$where" = "$ws" ] || return 0
    herdr_linear::panes_in_tab "$tab" 2>/dev/null | head -n1
}

# herdr_linear::open_session <worktree-path>
#
# A pane for the issue the worktree is bound to, in the space bound to that
# issue's project (R17), in the tab the ticket owns or a new one (R20). Never
# beside whatever pane has focus. Prints the pane id.
#
# Exit: SESSION_OK, SESSION_FAILED, or SESSION_ASK when the space is a choice --
# nothing is made, the question is on stderr, and it is recorded on the binding
# because this verb cannot tell whether anybody is there to answer (KTD29).
herdr_linear::open_session() {
    local path="${1:-}" bin ident ws rc tab target made pane
    [ -d "$path" ] || return "$HERDR_LINEAR_SESSION_FAILED"
    ident="$(herdr_linear::binding_identifier "$path" 2>/dev/null)" || return "$HERDR_LINEAR_SESSION_FAILED"
    herdr_linear::probe || return "$HERDR_LINEAR_SESSION_FAILED"
    bin="$(herdr_linear::bin)"; [ -n "$bin" ] || return "$HERDR_LINEAR_SESSION_FAILED"

    ws="$(herdr_linear::_issue_space "$ident" "$path" session)"; rc=$?
    [ "$rc" -eq 2 ] && return "$HERDR_LINEAR_SESSION_ASK"
    [ "$rc" -eq 0 ] || return "$HERDR_LINEAR_SESSION_FAILED"
    printf 'space %s: the only herdr space bound to the project of %s, read from its workspace record\n' "$ws" "$ident" >&2

    tab="$(herdr_linear::binding_tab "$path" 2>/dev/null)" || tab=""
    target="$(herdr_linear::_pane_of_tab_in "$tab" "$ws")" || {
        printf 'could not ask herdr about tab %s; nothing was opened\n' "$tab" >&2
        return "$HERDR_LINEAR_SESSION_FAILED"
    }
    if [ -n "$target" ]; then
        pane="$("$bin" pane split "$target" --direction right --cwd "$path" --no-focus 2>/dev/null \
            | herdr_linear::json "result.pane.pane_id")"
    else
        made="$("$bin" tab create --workspace "$ws" --cwd "$path" --label "$ident" --no-focus 2>/dev/null)"
        tab="$(printf '%s' "$made" | herdr_linear::json "result.tab.tab_id")"
        pane="$(printf '%s' "$made" | herdr_linear::json "result.root_pane.pane_id")"
        [ -n "$tab" ] && herdr_linear::binding_set_tab "$path" "$tab"
    fi
    [ -n "$pane" ] || return "$HERDR_LINEAR_SESSION_FAILED"
    herdr_linear::await_pane "$pane" || return "$HERDR_LINEAR_SESSION_FAILED"
    herdr_linear::binding_set_pending_placement "$path" "" || true
    printf '%s' "$pane"
    return "$HERDR_LINEAR_SESSION_OK"
}

# herdr_linear::layout_build <parent-issue> <child-issue>...
#
# Runs from the parent's own worktree. Each child's worktree is made beside it,
# from its repository, named from the child's own issue (KTD11).
#
# Idempotent by journal: a second run after a partial failure continues, and
# creates nothing twice.
herdr_linear::layout_build() {
    local parent="${1:-}" ; shift || true
    local bin tab tabpane pane slug child branch wt_path journal_file here bound repo resp
    local ws="" rc made existing owner i=0 paths=() branches=()

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

    # The verb takes an identifier, not a path, so the directory it runs in is
    # the only way it knows which worktree is the parent's. That is identity
    # verification, as bind does -- not deriving the repository from position.
    here="$("${HERDR_LINEAR_GIT_BIN:-git}" -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || here="$PWD"
    here="$(cd "$here" && pwd -P)"
    bound="$(herdr_linear::binding_identifier "$here" 2>/dev/null)" || bound=""
    if [ "$bound" != "$parent" ] \
        || [ "$(herdr_linear::binding_state "$here" 2>/dev/null)" != "bound" ]; then
        printf 'a layout for %s runs from its own worktree; %s is bound to %s\n' \
            "$parent" "$here" "${bound:-nothing}" >&2
        return "$HERDR_LINEAR_LAYOUT_NOT_PARENT"
    fi
    repo="$(herdr_linear::worktree_repo "$here")"
    # Siblings of a main checkout sit among the canonical repositories.
    if [ "$repo" = "$here" ]; then
        printf 'a layout for %s runs from its own worktree, not from the main checkout %s\n' \
            "$parent" "$here" >&2
        return "$HERDR_LINEAR_LAYOUT_NOT_PARENT"
    fi

    # Every child is read before anything is made, so one unreadable child
    # leaves no tab and no half-built columns. A column already journalled keeps
    # its path: a title renamed since would otherwise derive a second worktree.
    for child in "$@"; do
        if wt_path="$(herdr_linear::journal_get "$parent" "worktree.$child" 2>/dev/null)"; then
            branch=""
        else
            resp="$(herdr_linear::fetch_issue "$child")" || {
                printf 'could not read %s, so its column has no name; nothing was made\n' "$child" >&2
                return "$HERDR_LINEAR_LAYOUT_FAILED"
            }
            wt_path="${here%/*}/$(herdr_linear::start_worktree_name "$resp")" \
                && branch="$(herdr_linear::start_branch_name "$resp")" || {
                printf 'the title of %s cannot become a safe name; nothing was made\n' "$child" >&2
                return "$HERDR_LINEAR_LAYOUT_BAD_NAME"
            }
            # One worktree per issue: a child already started with /work:start
            # holds this branch in its own worktree, and a second `add -b` of
            # the same branch fails on every retry.
            existing="$(herdr_linear::_worktree_of_branch "$repo" "$branch")" || {
                printf 'could not list the worktrees of %s; nothing was made\n' "$repo" >&2
                return "$HERDR_LINEAR_LAYOUT_FAILED"
            }
            if [ -n "$existing" ]; then
                owner="$(herdr_linear::binding_identifier "$existing" 2>/dev/null)" || owner=""
                if [ -n "$owner" ] && [ "$owner" != "$child" ]; then
                    printf 'the branch for %s is checked out in %s, which is bound to %s; nothing was made\n' \
                        "$child" "$existing" "$owner" >&2
                    return "$HERDR_LINEAR_LAYOUT_FAILED"
                fi
                wt_path="$existing"; branch=""
            elif "${HERDR_LINEAR_GIT_BIN:-git}" -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
                # Checked out in the main checkout, or in no worktree at all.
                # Neither is a column this layout may make or take over.
                printf 'the branch for %s (%s) already exists outside any worktree the layout can use; nothing was made\n' \
                    "$child" "$branch" >&2
                return "$HERDR_LINEAR_LAYOUT_FAILED"
            fi
        fi
        paths[i]="$wt_path"; branches[i]="$branch"; i=$(( i + 1 ))
    done

    # R17. The layout's tab goes in the space bound to the parent's project,
    # resolved before anything is made -- on a retry too, because a journalled
    # tab may since have been closed or moved to another space.
    ws="$(herdr_linear::_issue_space "$parent" "$here" layout)"; rc=$?
    [ "$rc" -eq 2 ] && return "$HERDR_LINEAR_LAYOUT_ASK"
    [ "$rc" -eq 0 ] || return "$HERDR_LINEAR_LAYOUT_FAILED"
    herdr_linear::binding_set_pending_placement "$here" "" || true

    # Two sessions building the same parent's layout within the poll window
    # both miss `journal_get parent tab`, both run `tab create`, and the
    # journal's `tail -1` orphans the first tab -- the concurrency twin of the
    # retry this journal exists to prevent. Reuse binding.sh's mkdir lock: it
    # is already a dependency (binding_propose/confirm below) and solves the
    # same class of problem there.
    journal_file="$(herdr_linear::_journal "$parent")" || return "$HERDR_LINEAR_LAYOUT_FAILED"

    herdr_linear::_lock "$journal_file" || return "$HERDR_LINEAR_LAYOUT_FAILED"
    # KTD28 for the journal as for a binding: its tab counts only while herdr
    # still has it in this space. A dead one would be split from on every retry.
    tab="$(herdr_linear::journal_get "$parent" tab)" || tab=""
    tabpane="$(herdr_linear::_pane_of_tab_in "$tab" "$ws")" || tabpane="?"
    if [ -z "$tabpane" ]; then
        # R20. The parent's ticket may already own a tab in this space; the
        # layout is that piece of work, so its columns go there.
        tab="$(herdr_linear::binding_tab "$here" 2>/dev/null)" || tab=""
        tabpane="$(herdr_linear::_pane_of_tab_in "$tab" "$ws")" || tabpane="?"
        if [ -z "$tabpane" ]; then
            made="$("$bin" tab create --workspace "$ws" --cwd "$here" --label "$slug" --no-focus 2>/dev/null)"
            tab="$(printf '%s' "$made" | herdr_linear::json "result.tab.tab_id")"
            tabpane="$(printf '%s' "$made" | herdr_linear::json "result.root_pane.pane_id")"
        fi
        if [ -z "$tab" ] || [ -z "$tabpane" ] || [ "$tabpane" = "?" ]; then
            herdr_linear::_unlock "$journal_file"
            [ "$tabpane" = "?" ] && printf 'could not ask herdr about tab %s; nothing was made\n' "$tab" >&2
            return "$HERDR_LINEAR_LAYOUT_FAILED"
        fi
        herdr_linear::journal_put "$parent" tab "$tab"
        herdr_linear::binding_set_tab "$here" "$tab"
    fi
    herdr_linear::_unlock "$journal_file"
    if [ "$tabpane" = "?" ]; then
        printf 'could not ask herdr about tab %s; nothing was made\n' "$tab" >&2
        return "$HERDR_LINEAR_LAYOUT_FAILED"
    fi

    i=-1
    for child in "$@"; do
        i=$(( i + 1 ))
        wt_path="${paths[i]}"; branch="${branches[i]}"
        herdr_linear::_lock "$journal_file" || return "$HERDR_LINEAR_LAYOUT_FAILED"

        # Done on an earlier attempt only while its pane is still in this tab.
        # A pane that closed with an old tab is a column still to make.
        pane="$(herdr_linear::journal_get "$parent" "pane.$child" 2>/dev/null)" || pane=""
        if [ -n "$pane" ] && [ "$(herdr_linear::tab_of_pane "$pane" 2>/dev/null)" = "$tab" ]; then
            herdr_linear::_unlock "$journal_file"
            continue
        fi

        if ! herdr_linear::journal_get "$parent" "worktree.$child" >/dev/null 2>&1; then
            herdr_linear::_make_worktree "$wt_path" "$branch" "$repo" || {
                herdr_linear::_unlock "$journal_file"
                return "$HERDR_LINEAR_LAYOUT_FAILED"
            }
            herdr_linear::journal_put "$parent" "worktree.$child" "$wt_path"
        fi

        # KTD30. Split from a pane of this tab. An untargeted split splits
        # whatever pane has focus, which put columns in some other tab.
        pane="$("$bin" pane split "$tabpane" --direction right --cwd "$wt_path" --no-focus 2>/dev/null \
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
        herdr_linear::_bind_created "$wt_path" "$child" \
            && herdr_linear::binding_set_tab "$wt_path" "$tab"
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

# The linked worktree that has <branch> checked out in <repository>, or
# nothing. The main checkout (the first entry) and a worktree git reports as
# prunable are never an answer. Non-zero when git could not list them.
herdr_linear::_worktree_of_branch() {
    local list
    list="$("${HERDR_LINEAR_GIT_BIN:-git}" -C "$1" worktree list --porcelain 2>/dev/null)" || return 1
    printf '%s\n' "$list" | awk -v want="branch refs/heads/$2" '
        function flush() { if (hit && !dead && n > 1 && !done) { print p; done = 1 } }
        /^worktree / { flush(); n++; p = substr($0, 10); hit = 0; dead = 0; next }
        /^prunable/ { dead = 1 }
        $0 == want { hit = 1 }
        END { flush() }'
}

# herdr_linear::_make_worktree <path> <branch> <repository>
#
# The repository is passed in. Reading it from $PWD here is the caller's
# directory deciding the repository, the defect KTD11 removes from the layout.
herdr_linear::_make_worktree() {
    local path="$1" branch="$2" root="${3:-}"
    [ -n "$root" ] || return 1
    [ -d "$path" ] && return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null
    # Both streams: `worktree add` announces itself on stdout, which would
    # otherwise leak into whatever the caller is capturing.
    #
    # No `git init` fallback here. `worktree add` fails most often because the
    # branch already exists -- exactly a layout RETRY -- and a fresh empty repo
    # shares no history with the project, can never push, and the header above
    # forbids repairing a failure this way. Fail and let the journal's own
    # resumability handle the retry.
    "${HERDR_LINEAR_GIT_BIN:-git}" -C "$root" worktree add -b "$branch" "$path" >/dev/null 2>&1 \
        || return 1
    return 0
}

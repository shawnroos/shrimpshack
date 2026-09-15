#!/usr/bin/env bash
# The attended half of a board sync (KTD19): what a person running a /work
# command sees first, and the one place a person's answer to a board question is
# applied. Sourced, never executed.
#
# The fence never blocks the command it sits in: a sync that fails, is locked or
# runs past its time bound is reported and the command carries on. A board with
# no configuration prints nothing at all (R8).

command -v herdr_linear::board_config_load >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-config.sh"
command -v herdr_linear::board_sync >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-sync.sh"
command -v herdr_linear::worktree_remove >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/worktree-remove.sh"
command -v herdr_linear::record_scope_repo >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/repos.sh"

HERDR_LINEAR_BOARD_FENCE_SECONDS="${HERDR_LINEAR_BOARD_FENCE_SECONDS:-30}"
HERDR_LINEAR_BOARD_ATTENDED_LIB="${BASH_SOURCE[0]}"

HERDR_LINEAR_BOARD_ANSWER_OK=0
HERDR_LINEAR_BOARD_ANSWER_REFUSED=2
HERDR_LINEAR_BOARD_ANSWER_FAILED=4

# herdr_linear::board_sync_bounded [seconds]
# One unattended sync in its own process group, killed when it runs past the
# bound. A killed sync is safe to leave: its journal is settled by the next sync
# and its lock is taken over from the dead holder. Exit is the sync's own, or
# 124 when it was stopped.
herdr_linear::board_sync_bounded() {
    local seconds="${1:-$HERDR_LINEAR_BOARD_FENCE_SECONDS}"
    case "$seconds" in ''|*[!0-9]*) seconds=30 ;; esac
    python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(["bash", "-c", ". \"$1\" && herdr_linear::board_sync", "board-fence", sys.argv[1]],
                     start_new_session=True)
try:
    sys.exit(p.wait(timeout=int(sys.argv[2])))
except subprocess.TimeoutExpired:
    for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 2)):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            break
        try:
            p.wait(timeout=grace)
            break
        except subprocess.TimeoutExpired:
            continue
    sys.exit(124)
' "${HERDR_LINEAR_BOARD_ATTENDED_LIB%/*}/board-sync.sh" "$seconds"
}

# herdr_linear::board_fence
# Prints a `board:` line for the sync's outcome, then one `board question:` line
# per pending question (JSON with key, kind, preconditions, nonce). Always 0.
herdr_linear::board_fence() {
    local rc out
    out="$(herdr_linear::board_sync_bounded 2>&1)"; rc=$?
    case $rc in
        "$HERDR_LINEAR_BOARD_SYNC_NO_BOARD") return 0 ;;
        124) printf 'board: the sync did not finish within %ss and was stopped; carrying on\n' \
                 "$HERDR_LINEAR_BOARD_FENCE_SECONDS" ;;
        "$HERDR_LINEAR_BOARD_SYNC_LOCKED") printf 'board: another sync is running; carrying on\n' ;;
        "$HERDR_LINEAR_BOARD_SYNC_CLEAN"|"$HERDR_LINEAR_BOARD_SYNC_QUESTIONS"|"$HERDR_LINEAR_BOARD_SYNC_UNKNOWN"|"$HERDR_LINEAR_BOARD_SYNC_INCOMPLETE")
            printf 'board: %s\n' "$(printf '%s' "$out" | tail -n 1)" ;;
        *) printf 'board: the sync failed (%s): %s; carrying on\n' "$rc" "$(printf '%s' "$out" | tail -n 1)" ;;
    esac
    herdr_linear::board_questions_pending 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && printf 'board question: %s\n' "$line"
    done
    return 0
}

herdr_linear::_board_answer_refuse() {
    printf 'refused: %s\n' "$1" >&2
    return "$HERDR_LINEAR_BOARD_ANSWER_REFUSED"
}

# herdr_linear::_board_worktree_of <issue_id> -> the started ticket's worktree.
herdr_linear::_board_worktree_of() {
    local issue="$1" name ident root d
    [ "$(herdr_linear::board_reservation_field "$issue" state 2>/dev/null)" = started ] || return 1
    name="$(herdr_linear::board_reservation_field "$issue" worktree_name 2>/dev/null)" || return 1
    ident="$(herdr_linear::board_reservation_field "$issue" identifier 2>/dev/null)" || return 1
    root="$(herdr_linear::worktrees_root)"
    while IFS= read -r d; do
        [ "$(herdr_linear::binding_identifier "$d" 2>/dev/null)" = "$ident" ] && { printf '%s' "$d"; return 0; }
    done < <(find "$root" -maxdepth 3 -type d -name "$name" 2>/dev/null)
    return 1
}

# herdr_linear::board_answer <key> <nonce> <yes|no> [repository]
# Applies a person's answer to one pending board question, only with that
# question's nonce. No declines it, and a declined question is not asked again.
# A yes to a close that leaves a worktree behind prints one `board question:`
# line for the removal question it records. 0 applied; 2 refused (no such
# question, wrong nonce, or the facts changed); 4 the answer was recorded but
# applying it failed, with stderr naming the step.
herdr_linear::board_answer() {
    local key="${1:-}" nonce="${2:-}" answer="${3:-}" value="${4:-}" q kind pre space issue field
    q="$(herdr_linear::board_question "$key" 2>/dev/null)" \
        || { herdr_linear::_board_answer_refuse "there is no pending question $key"; return; }
    kind="$(printf '%s' "$q" | python3 -c 'import sys, json; print(json.load(sys.stdin)["kind"])')"
    pre="$(printf '%s' "$q" | python3 -c 'import sys, json; print(json.load(sys.stdin)["preconditions"])')"
    _pre() { printf '%s' "$pre" | python3 -c 'import sys, json; v = json.load(sys.stdin).get(sys.argv[1]); print(v if isinstance(v, str) else json.dumps(v))' "$1"; }
    space="$(_pre space)" issue="$(_pre issue)" field="$(_pre field)"

    case "$answer" in
        no)
            herdr_linear::board_question_decline "$key" "$nonce" \
                || { herdr_linear::_board_answer_refuse "that nonce does not answer $key"; return; }
            return 0 ;;
        yes) ;;
        *) herdr_linear::_board_answer_refuse "an answer is yes or no"; return ;;
    esac

    if [ "$kind" = remove-worktree ]; then
        herdr_linear::worktree_remove "$(_pre worktree)" "$nonce"
        return
    fi
    if [ "$kind" = repository ] && [ -z "$value" ]; then
        herdr_linear::_board_answer_refuse "a repository answer names the repository"; return
    fi
    if [ "$kind" = close ]; then
        [ "$(herdr_linear::board_ledger_entry "$space" "$issue" 2>/dev/null \
            | python3 -c 'import sys, json; print(json.load(sys.stdin)["pane_id"])' 2>/dev/null)" = "$(_pre pane_id)" ] \
            || { herdr_linear::_board_answer_refuse "the pane for that ticket is no longer the one asked about"; return; }
    fi
    herdr_linear::board_question_answer "$key" "$nonce" "$pre" \
        || { herdr_linear::_board_answer_refuse "that nonce does not answer $key"; return; }

    case "$kind" in
        move)
            HL_ANSWERED_MOVES="$issue" herdr_linear::board_sync_bounded >/dev/null 2>&1
            [ "$?" -ne 124 ] || { printf 'failed: the sync that moves the pane did not finish\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; } ;;
        close)
            local wt n
            herdr_linear::board_close_pane "$space" "$issue" >/dev/null 2>&1 \
                || { printf 'failed: herdr did not close the pane\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; }
            herdr_linear::board_ledger_remove "$space" "$issue" >/dev/null 2>&1
            if wt="$(herdr_linear::_board_worktree_of "$issue")"; then
                n="$(herdr_linear::worktree_remove_propose "$wt")" || return 0
                printf 'board question: %s\n' "$(herdr_linear::board_question "$(herdr_linear::worktree_remove_key "$wt")" \
                    | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps({k: d[k] for k in ("key", "kind", "preconditions", "nonce")}, sort_keys=True))')"
            fi ;;
        conflict)
            herdr_linear::board_ledger_mark_linear_change "$space" "$issue" >/dev/null 2>&1
            herdr_linear::board_sync_bounded >/dev/null 2>&1 ;;
        cap)
            local more
            more="$(printf '%s' "$pre" | python3 -c 'import sys, json; print(",".join(json.load(sys.stdin)["issues"]))')"
            HL_PLACE_MORE="$more" herdr_linear::board_sync_bounded >/dev/null 2>&1 ;;
        write-consent)
            local c
            c="$(herdr_linear::board_consent_propose "$space" "$field")" \
                && herdr_linear::board_consent_confirm "$space" "$field" "$c" \
                || { printf 'failed: the consent was not recorded\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; } ;;
        repository)
            herdr_linear::record_scope_repo "$value" "$(_pre scope)" \
                || { printf 'failed: the repository was not recorded\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; } ;;
        write-rejected|layout|space) ;;
        *) printf 'failed: no way to apply a %s question\n' "$kind" >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED" ;;
    esac
    return 0
}

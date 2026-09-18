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

# A first sync on a real board took about 30s (placing 16 panes in 6 new
# workspaces), so the bound sits well above that.
HERDR_LINEAR_BOARD_FENCE_SECONDS="${HERDR_LINEAR_BOARD_FENCE_SECONDS:-90}"
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
    case "$seconds" in ''|*[!0-9]*) seconds=90 ;; esac
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

# herdr_linear::_board_pre <preconditions-json> <key> -> that value, JSON unless a string.
herdr_linear::_board_pre() {
    printf '%s' "$1" | python3 -c 'import sys, json; v = json.load(sys.stdin).get(sys.argv[1]); print(v if isinstance(v, str) else json.dumps(v))' "$2"
}

# herdr_linear::_board_answer_synced <sync-exit> -> 0 when the answer's sync ran.
herdr_linear::_board_answer_synced() {
    case "$1" in
        "$HERDR_LINEAR_BOARD_SYNC_CLEAN"|"$HERDR_LINEAR_BOARD_SYNC_QUESTIONS"|"$HERDR_LINEAR_BOARD_SYNC_UNKNOWN") return 0 ;;
        124) printf 'failed: the sync that applies the answer did not finish\n' >&2 ;;
        *) printf 'failed: the sync that applies the answer stopped with %s\n' "$1" >&2 ;;
    esac
    return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"
}

# herdr_linear::_board_close_after <space> <issue_id> <pid>
# Closes a board pane and forgets it from a detached process, once <pid> has
# exited: the pane may be the one this answer runs in, and closing it first
# would end the answer before the ledger is updated.
herdr_linear::_board_close_after() {
    python3 -c '
import os, signal, sys, time
lib, space, issue, pid, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
if os.fork():
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
null = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
os.closerange(3, 1024)
end = time.time() + limit
while time.time() < end:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    except PermissionError:
        pass
    time.sleep(0.05)
os.execvp("bash", ["bash", "-c", ". \"$1\" && herdr_linear::board_close_pane \"$2\" \"$3\" && herdr_linear::board_ledger_remove \"$2\" \"$3\"", "board-close", lib, space, issue])
' "$HERDR_LINEAR_BOARD_ATTENDED_LIB" "$1" "$2" "$3" "$HERDR_LINEAR_BOARD_CLOSE_AFTER_SECONDS"
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
    space="$(herdr_linear::_board_pre "$pre" space)" issue="$(herdr_linear::_board_pre "$pre" issue)" field="$(herdr_linear::_board_pre "$pre" field)"

    case "$answer" in
        no)
            herdr_linear::board_question_decline "$key" "$nonce" \
                || { herdr_linear::_board_answer_refuse "that nonce does not answer $key"; return; }
            return 0 ;;
        yes) ;;
        *) herdr_linear::_board_answer_refuse "an answer is yes or no"; return ;;
    esac

    if [ "$kind" = remove-worktree ]; then
        local rc=0
        herdr_linear::worktree_remove "$(herdr_linear::_board_pre "$pre" worktree)" "$nonce" || rc=$?
        [ "$rc" -eq "$HERDR_LINEAR_REMOVE_FAILED" ] && return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"
        return "$rc"
    fi
    if [ "$kind" = repository ] && [ -z "$value" ]; then
        herdr_linear::_board_answer_refuse "a repository answer names the repository"; return
    fi
    local why="" used=1
    if [ "$kind" = close ]; then
        [ "$(herdr_linear::board_ledger_entry "$space" "$issue" 2>/dev/null \
            | python3 -c 'import sys, json; print(json.load(sys.stdin)["pane_id"])' 2>/dev/null)" = "$(herdr_linear::_board_pre "$pre" pane_id)" ] \
            || { herdr_linear::_board_answer_refuse "the pane for that ticket is no longer the one asked about"; return; }
        why="$(herdr_linear::board_in_use "$(herdr_linear::_board_pre "$pre" pane_id)" 2>/dev/null)" && used=0
        case "$used:$why" in
            0:*invoking*|1:*) ;;
            *) herdr_linear::_board_answer_refuse "that pane is in use (${why:-unknown}); close it when it is done"; return ;;
        esac
    fi
    herdr_linear::board_question_answer "$key" "$nonce" "$pre" \
        || { herdr_linear::_board_answer_refuse "that nonce does not answer $key"; return; }

    case "$kind" in
        move)
            HL_ANSWERED_MOVES="$issue" herdr_linear::board_sync_bounded >/dev/null 2>&1
            herdr_linear::_board_answer_synced $? || return ;;
        close)
            local wt n
            # The worktree question first: when the pane closing is the one this
            # answer runs in, nothing after the close would run.
            if wt="$(herdr_linear::_board_worktree_of "$issue")" \
                && n="$(herdr_linear::worktree_remove_propose "$wt")"; then
                printf 'board question: %s\n' "$(herdr_linear::board_question "$(herdr_linear::worktree_remove_key "$wt")" \
                    | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps({k: d[k] for k in ("key", "kind", "preconditions", "nonce")}, sort_keys=True))')"
            fi
            if [ "$used" -eq 0 ]; then
                herdr_linear::_board_close_after "$space" "$issue" "$$"
                return 0
            fi
            herdr_linear::board_close_pane "$space" "$issue" >/dev/null 2>&1 \
                || { printf 'failed: herdr did not close the pane\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; }
            herdr_linear::board_ledger_remove "$space" "$issue" >/dev/null 2>&1 ;;
        conflict)
            herdr_linear::board_ledger_mark_linear_change "$space" "$issue" >/dev/null 2>&1
            herdr_linear::board_sync_bounded >/dev/null 2>&1
            herdr_linear::_board_answer_synced $? || return ;;
        cap)
            local more
            more="$(printf '%s' "$pre" | python3 -c 'import sys, json; print(",".join(json.load(sys.stdin)["issues"]))')"
            HL_PLACE_MORE="$more" herdr_linear::board_sync_bounded >/dev/null 2>&1
            herdr_linear::_board_answer_synced $? || return ;;
        write-consent)
            local c
            c="$(herdr_linear::board_consent_propose "$space" "$field")" \
                && herdr_linear::board_consent_confirm "$space" "$field" "$c" \
                || { printf 'failed: the consent was not recorded\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; } ;;
        repository)
            herdr_linear::record_scope_repo "$value" "$(herdr_linear::_board_pre "$pre" scope)" \
                || { printf 'failed: the repository was not recorded\n' >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED"; } ;;
        write-rejected|layout|space) ;;
        *) printf 'failed: no way to apply a %s question\n' "$kind" >&2; return "$HERDR_LINEAR_BOARD_ANSWER_FAILED" ;;
    esac
    return 0
}

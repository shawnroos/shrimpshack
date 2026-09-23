#!/usr/bin/env bash
# The scope repository record: which repositories a Linear scope is worked in.
# Sourced, never executed.
#
# WHY THIS IS NOT THE BINDING RECORD (KTD6)
# A binding's reader validates a five-value state enum and requires a
# worktree_path. A set of repository paths has neither, and the workspace record
# already strains that schema by carrying a project id in `issue_identifier`.
# So this is a second schema over the SAME store, the same lock and the same
# write-temp-then-rename discipline, rather than a third tenant of the first.
#
# WHY THE KEY IS TYPED (KTD3)
# The key is `project-<id>`, `team-<id>`, or the two joined by a dot, so a
# project id and a team id cannot collide in one namespace. Hyphen and not
# colon: the key becomes a filename and herdr_linear::is_safe_identifier rejects
# a colon.
#
# WHY A LOOKUP TAKES THREE KEYS (R5a)
# A project can span a repository per team, so the decision belongs to neither
# alone. Each key does one job, and the start path passes them in this order:
#   * `project-<pid>.team-<tid>` is the only key WRITTEN. That pair decides once
#     and is never asked again.
#   * `team-<tid>` is a read-only fallback. The earlier rule wrote every answer
#     under both plain keys, so most teams have one; it answers a pair that has
#     not decided yet.
#   * `project-<pid>` is a read-only fallback too, for an issue whose team has
#     no record at all.
# Neither fallback is written any more, so a team that collected a repository
# per project stops being a permanent question the moment its pair is answered.

# No lib sources another, so neither of these is loaded for us. Without the
# guards the calls below are 127, which every `||` branch here would read as a
# refusal and every negative test would pass for the wrong reason.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::_lock >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/record.sh"

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
HERDR_LINEAR_SCOPE_RECORD_VERSION=1

herdr_linear::_scope_record_path() {
    local key="${1:-}"
    herdr_linear::is_safe_identifier "$key" || return 1
    printf '%s/scopes/%s.json' "$HERDR_LINEAR_STORE_DIR" "$key"
}

herdr_linear::_scope_ensure_store() {
    mkdir -p "$HERDR_LINEAR_STORE_DIR/scopes" 2>/dev/null || return 1
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_STORE_DIR/scopes" 2>/dev/null
    return 0
}

herdr_linear::_scope_py() {
    HERDR_LINEAR_SCOPE_RECORD_VERSION="$HERDR_LINEAR_SCOPE_RECORD_VERSION" \
        python3 - "$@" <<'PYEOF'
import sys, json, os, time, secrets

VERSION = int(os.environ.get("HERDR_LINEAR_SCOPE_RECORD_VERSION", "1"))

def load(path):
    """A record, or None when there is nothing usable. A truncated file, a file
    that parses to something other than a list of strings, and a record from a
    future version are all absent -- a half-read set would otherwise be handed
    out as the whole set, and the caller cannot tell the difference."""
    try:
        with open(path) as fh:
            rec = json.load(fh)
    except Exception:
        return None
    if not isinstance(rec, dict):
        return None
    if not isinstance(rec.get("version"), int) or rec["version"] > VERSION:
        return None
    repos = rec.get("repositories")
    if not isinstance(repos, list) or not all(isinstance(r, str) for r in repos):
        return None
    return rec

def save(path, rec):
    """Temp file in the SAME directory, then rename. A temp file elsewhere
    cannot be renamed atomically across a filesystem boundary, which would turn
    the write into a copy and reintroduce the torn record."""
    rec["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)

op, path, args = sys.argv[1], sys.argv[2], sys.argv[3:]

if op == "read":
    rec = load(path)
    if rec is not None:
        for r in rec["repositories"]:
            sys.stdout.write(r + "\n")
    sys.exit(0)

if op == "drop":
    rec = load(path)
    # A record `load` refuses holds no repository to keep, and leaving it would
    # have the caller believe a file it still trips over is gone.
    if rec is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        sys.exit(0)
    rec["repositories"] = [r for r in rec["repositories"] if r != args[0]]
    # An empty record and no record read the same way out of `scope_repos`, so
    # the last entry takes the file with it rather than leaving a stub that a
    # later reader would have to tell apart from a scope nobody answered for.
    if not rec["repositories"]:
        os.remove(path)
    else:
        save(path, rec)
    sys.exit(0)

if op == "add":
    rec = load(path) or {"version": VERSION, "repositories": []}
    # A candidate no longer on disk is dropped when an answer is recorded: an
    # answer given after a repository moved would otherwise sit beside the dead
    # path, and every later start would see two candidates and ask again.
    rec["repositories"] = [r for r in rec["repositories"] if os.path.isdir(r)]
    if args[0] not in rec["repositories"]:
        rec["repositories"].append(args[0])
    save(path, rec)
    sys.exit(0)

sys.exit(1)
PYEOF
}

# Every repository recorded for the scope, one path per line. A scope with none
# prints nothing and succeeds; only an unusable key or a broken reader returns
# non-zero, so a caller can tell "none recorded" from "could not ask".
herdr_linear::scope_repos() {
    local key
    key="$(herdr_linear::_scope_answering_key "$@")" || return 1
    [ -n "$key" ] || return 0
    printf '%s\n' "$(herdr_linear::_scope_read "$key")"
}

# The record file the candidates were read from, or nothing when no key holds
# any. R6 states its source, and with the team fallback the source is not
# always the first key the caller passed.
herdr_linear::scope_repo_source() {
    local key
    key="$(herdr_linear::_scope_answering_key "$@")" || return 1
    [ -n "$key" ] || return 0
    herdr_linear::_scope_record_path "$key"
}

# The first key whose record holds anything, or nothing when none does.
herdr_linear::_scope_answering_key() {
    local key lines asked=0
    for key in "$@"; do
        [ -n "$key" ] || continue
        asked=1
        lines="$(herdr_linear::_scope_read "$key")" || return 1
        [ -n "$lines" ] && { printf '%s' "$key"; return 0; }
    done
    # Every key absent is still an answer. No key at all is not: the caller
    # asked about no scope, and an empty set would read as one that is known.
    [ "$asked" -eq 1 ] || return 1
    return 0
}

herdr_linear::_scope_read() {
    local f
    f="$(herdr_linear::_scope_record_path "$1")" || return 1
    [ -e "$f" ] || return 0
    # A record that exists but cannot be opened is not an empty one. Reading it
    # as empty would ask a question whose answer is on disk, and record a second
    # repository for a scope that already has one.
    [ -r "$f" ] || return 1
    herdr_linear::_mode_ok "$f" || return 0
    herdr_linear::_scope_py read "$f"
}

# The scope's ONLY repository, or nothing. Several print nothing and succeed:
# "cannot tell" is the answer, not an error a caller would then have to
# distinguish from a store it could not read.
herdr_linear::scope_repo() {
    local lines
    lines="$(herdr_linear::scope_repos "$@")" || return 1
    printf '%s' "$lines" | herdr_linear::the_only_line
}

# Why there is no single repository, said so the reader can act on it. Several
# candidates are a QUESTION, not a dead end, so name every one: "cannot tell
# which repository" alone leaves the reader to go find out what is on offer.
herdr_linear::no_repo_reason() {
    local repos="" key=""
    repos="$(herdr_linear::scope_repos "$@" 2>/dev/null)" || repos=""
    if [ "$(printf '%s' "$repos" | grep -c .)" -gt 1 ]; then
        key="$(herdr_linear::_scope_answering_key "$@" 2>/dev/null)" || key=""
        printf 'several repositories are recorded for this scope, so which one this belongs in is a choice, not a fact. Ask, then name one of:\n'
        printf '%s' "$repos" | grep . | while IFS= read -r repo; do
            printf '  %s\n' "$repo"
        done
        # The way out, not just the question: a candidate that no longer belongs
        # here keeps this a choice for ever, and the key holding it appears on no
        # other line the reader has.
        printf 'One that no longer belongs to this scope is removed with herdr_linear::forget_scope_repo %s <path>, naming the path exactly as it is printed above.\n' \
            "${key:-<key>}"
        return 0
    fi
    printf 'no repository is recorded for this scope, so there is nothing to make the worktree from. Ask which repository to use, then pass it back as an absolute path.\n'
}

# Records the repository under every key given. The start path gives one -- the
# project-and-team pair -- because that pair is what decides a repository; a
# caller that wants a fallback key written says so by passing it.
herdr_linear::record_scope_repo() {
    local repo="${1:-}" resolved key rc=0 asked=0
    shift || return 1
    # R7a. Resolving a relative path here would let the caller's directory
    # decide the answer again, which is the defect this record exists to remove.
    case "$repo" in /*) ;; *) return 1 ;; esac
    resolved="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
    # The record is read back one path per line, so a newline in a path would
    # come back out as two repositories that both exist and neither resolve.
    case "$resolved" in ''|*$'\n'*) return 1 ;; esac

    for key in "$@"; do
        [ -n "$key" ] || continue
        asked=1
        herdr_linear::_scope_record_write "$key" "$resolved" || rc=1
    done
    [ "$asked" -eq 1 ] || return 1
    return "$rc"
}

herdr_linear::_scope_record_write() {
    local key="$1" repo="$2" f rc
    herdr_linear::_scope_ensure_store || return 1
    f="$(herdr_linear::_scope_record_path "$key")" || return 1
    herdr_linear::_lock "$f" || return 1
    if [ "${HERDR_LINEAR_LOCK_HOLD_MS:-0}" -gt 0 ] 2>/dev/null; then
        perl -e "select undef, undef, undef, ${HERDR_LINEAR_LOCK_HOLD_MS}/1000" 2>/dev/null
    fi
    herdr_linear::_scope_py add "$f" "$repo"
    rc=$?
    chmod 600 "$f" 2>/dev/null
    herdr_linear::_unlock "$f"
    return "$rc"
}

# Drops one recorded repository, or the whole record when no repository is
# given. Nothing recorded is the state the caller asked for, so it succeeds:
# only an unusable key or a write that failed returns non-zero.
herdr_linear::forget_scope_repo() {
    local key="${1:-}" repo="${2-}" f rc=0
    f="$(herdr_linear::_scope_record_path "$key")" || return 1
    [ -e "$f" ] || return 0
    herdr_linear::_lock "$f" || return 1
    if [ -n "$repo" ]; then
        # A file that cannot be OPENED is not one the reader refuses: _scope_read
        # calls the first a hard error and the second empty, and dropping ONE
        # repository from a record nobody can read would throw away every other
        # repository in it and report that as done.
        if [ ! -r "$f" ]; then
            herdr_linear::_unlock "$f"
            return 1
        fi
        # The path is matched as recorded, never resolved: the usual reason to
        # forget one is that the directory is gone, and `cd` to it would fail.
        herdr_linear::_scope_py drop "$f" "$repo"
        rc=$?
    else
        rm -f "$f" || rc=1
    fi
    herdr_linear::_unlock "$f"
    return "$rc"
}

#!/usr/bin/env bash
# The scope repository record: which repositories a Linear scope is worked in.
# Sourced, never executed.
#
# One JSON file the plugin owns, ${CLAUDE_PLUGIN_DATA}/scopes.json, keyed by
# `project-<id>.team-<id>` (the only key the start path writes), `team-<id>` or
# `project-<id>`. The old store, ~/.claude/work/scopes/<key>.json, is read on a
# miss and never written: its answer is copied into the plugin file.
#
# A key present in the plugin file is authoritative even when its list is
# empty. That is how a forgotten answer stays forgotten instead of being copied
# back from the old store on the next lookup.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"

HERDR_LINEAR_SCOPE_RECORD_VERSION=1
HERDR_LINEAR_SCOPE_LOCK_WAIT_SECONDS="${HERDR_LINEAR_SCOPE_LOCK_WAIT_SECONDS:-5}"
HERDR_LINEAR_SCOPE_LOCK_STALE_SECONDS="${HERDR_LINEAR_SCOPE_LOCK_STALE_SECONDS:-30}"

# Resolved per call, not at source time: a caller that changes HOME or
# CLAUDE_PLUGIN_DATA after sourcing must not write to the earlier location.
herdr_linear::scope_file() {
    printf '%s/scopes.json' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/work-shrimpshack}"
}

herdr_linear::_scope_old_dir() {
    printf '%s/scopes' "${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
}

# herdr_linear::pair_key <project-id> <team-id>
#
# `.` is the pair's only separator and is legal inside a Linear id, so an id
# carrying one could spell a plain key as a pair: two pairs would then share a
# record. Prints nothing and returns non-zero on a missing, unsafe or dotted id.
herdr_linear::pair_key() {
    local pid="${1:-}" tid="${2:-}"
    [ -n "$pid" ] && [ -n "$tid" ] || return 1
    herdr_linear::is_safe_identifier "$pid" || return 1
    herdr_linear::is_safe_identifier "$tid" || return 1
    case "$pid$tid" in *.*) return 1 ;; esac
    printf 'project-%s.team-%s' "$pid" "$tid"
}

herdr_linear::_scope_lock() {
    local lock="$1.lock" waited=0 now since
    while ! mkdir "$lock" 2>/dev/null; do
        now="$(date +%s)"
        since="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")"
        if [ $(( now - since )) -gt "$HERDR_LINEAR_SCOPE_LOCK_STALE_SECONDS" ]; then
            rmdir "$lock" 2>/dev/null
            continue
        fi
        waited=$(( waited + 1 ))
        [ "$waited" -gt $(( HERDR_LINEAR_SCOPE_LOCK_WAIT_SECONDS * 20 )) ] && return 1
        perl -e 'select undef, undef, undef, 0.05' 2>/dev/null || sleep 1
    done
    if [ "${HERDR_LINEAR_LOCK_HOLD_MS:-0}" -gt 0 ] 2>/dev/null; then
        perl -e "select undef, undef, undef, ${HERDR_LINEAR_LOCK_HOLD_MS}/1000" 2>/dev/null
    fi
    return 0
}

herdr_linear::_scope_unlock() { rmdir "$1.lock" 2>/dev/null; }

# Every operation runs under the lock, reads included: a read that misses the
# plugin file copies the old store's answer into it.
herdr_linear::_scope_run() {
    local op="$1" f rc
    shift
    f="$(herdr_linear::scope_file)"
    mkdir -p "${f%/*}" 2>/dev/null && chmod 700 "${f%/*}" 2>/dev/null
    [ -d "${f%/*}" ] || { printf 'cannot create %s\n' "${f%/*}" >&2; return 1; }
    herdr_linear::_scope_lock "$f" || {
        printf 'the repository record is locked by another writer: %s\n' "$f" >&2
        return 1
    }
    herdr_linear::_scope_py "$op" "$f" "$(herdr_linear::_scope_old_dir)" "$@"
    rc=$?
    herdr_linear::_scope_unlock "$f"
    return "$rc"
}

herdr_linear::_scope_py() {
    HERDR_LINEAR_SCOPE_RECORD_VERSION="$HERDR_LINEAR_SCOPE_RECORD_VERSION" \
        python3 - "$@" <<'PYEOF'
import sys, json, os, stat, time, secrets

VERSION = int(os.environ["HERDR_LINEAR_SCOPE_RECORD_VERSION"])
op, path, old_dir, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]

class Unusable(Exception):
    pass

def valid_repos(v):
    return isinstance(v, list) and all(isinstance(r, str) for r in v)

def load():
    try:
        with open(path) as fh:
            text = fh.read()
    except FileNotFoundError:
        return {"version": VERSION, "scopes": {}}
    except OSError as e:
        raise Unusable("cannot be read (%s)" % e.strerror)
    if not text.strip():
        return {"version": VERSION, "scopes": {}}
    try:
        doc = json.loads(text)
    except ValueError:
        raise Unusable("is not valid JSON")
    if (not isinstance(doc, dict) or not isinstance(doc.get("version"), int)
            or doc["version"] > VERSION or not isinstance(doc.get("scopes"), dict)
            or not all(isinstance(e, dict) and valid_repos(e.get("repositories"))
                       for e in doc["scopes"].values())):
        raise Unusable("does not hold a scope record this plugin reads")
    return doc

def old_repos(key):
    """The retired store's answer, or None. A file anyone else could have
    written is not trusted, as the retired reader did not trust it."""
    f = os.path.join(old_dir, key + ".json")
    try:
        st = os.stat(f)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        return None
    try:
        with open(f) as fh:
            rec = json.load(fh)
    except PermissionError:
        raise Unusable("cannot be consulted: the old record %s cannot be read" % f)
    except Exception:
        return None
    if (not isinstance(rec, dict) or not isinstance(rec.get("version"), int)
            or rec["version"] > 1 or not valid_repos(rec.get("repositories"))):
        return None
    return rec["repositories"]

def save(doc):
    """Temp file in the same directory, then rename: a rename across a
    filesystem boundary is a copy, which would reintroduce a torn file."""
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".scopes.tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)

def put(doc, key, repos):
    doc["scopes"][key] = {
        "repositories": repos,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

def resolve(doc, key):
    """The key's repositories, and whether the old store supplied them."""
    entry = doc["scopes"].get(key)
    if entry is not None:
        return entry["repositories"], False
    repos = old_repos(key)
    if repos:
        return list(repos), True
    return [], False

try:
    doc = load()
except Unusable as e:
    sys.stderr.write("the repository record %s %s; it was left as it is. "
                     "Fix or remove it, then try again.\n" % (path, e))
    sys.exit(2)

try:
    if op == "lookup":
        for key in args:
            repos, imported = resolve(doc, key)
            if imported:
                put(doc, key, repos)
                save(doc)
            if repos:
                sys.stdout.write(key + "\n")
                for r in repos:
                    sys.stdout.write(r + "\n")
                break
        sys.exit(0)

    if op == "add":
        repo, keys = args[0], args[1:]
        for key in keys:
            repos, _ = resolve(doc, key)
            # A path no longer on disk would sit beside the new answer and turn
            # every later start into a question again.
            repos = [r for r in repos if os.path.isdir(r)]
            if repo not in repos:
                repos.append(repo)
            put(doc, key, repos)
        save(doc)
        sys.exit(0)

    if op == "forget":
        key, repo = args[0], (args[1] if len(args) > 1 else None)
        repos, imported = resolve(doc, key)
        if key not in doc["scopes"] and not imported:
            sys.exit(0)
        put(doc, key, [] if repo is None else [r for r in repos if r != repo])
        save(doc)
        sys.exit(0)
except Unusable as e:
    sys.stderr.write("the repository record %s; nothing was changed.\n" % e)
    sys.exit(2)

sys.exit(1)
PYEOF
}

# Prints the answering key on the first line, then its repositories. Every key
# absent prints nothing and succeeds. No usable key at all is an error: the
# caller asked about no scope, and an empty set would read as a known one.
herdr_linear::_scope_lookup() {
    local key
    local -a keys=()
    for key in "$@"; do
        [ -n "$key" ] || continue
        herdr_linear::is_safe_identifier "$key" || return 1
        keys+=("$key")
    done
    [ "${#keys[@]}" -gt 0 ] || return 1
    herdr_linear::_scope_run lookup "${keys[@]}"
}

# Every repository recorded for the first key holding any, one per line. A
# record that cannot be read returns non-zero, never an empty set: answering
# empty would ask a question whose answer is on disk.
herdr_linear::scope_repos() {
    local out
    out="$(herdr_linear::_scope_lookup "$@")" || return 1
    [ -n "$out" ] || return 0
    printf '%s\n' "$out" | sed 1d
}

# The key whose record answered, or nothing when none did.
herdr_linear::scope_repo_source() {
    local out
    out="$(herdr_linear::_scope_lookup "$@")" || return 1
    [ -n "$out" ] || return 0
    printf '%s' "$out" | head -n 1
}

# The scope's ONLY repository, or nothing. Several print nothing and succeed.
herdr_linear::scope_repo() {
    local lines
    lines="$(herdr_linear::scope_repos "$@")" || return 1
    printf '%s' "$lines" | herdr_linear::the_only_line
}

# Why there is no single repository, said so the reader can act on it.
herdr_linear::no_repo_reason() {
    local out repos key
    if ! out="$(herdr_linear::_scope_lookup "$@" 2>/dev/null)"; then
        printf 'the repository record %s could not be read, so nothing was asked. Fix or remove that file, then try again.\n' \
            "$(herdr_linear::scope_file)"
        return 0
    fi
    key="$(printf '%s' "$out" | head -n 1)"
    repos="$(printf '%s\n' "$out" | sed 1d)"
    if [ "$(printf '%s' "$repos" | grep -c .)" -gt 1 ]; then
        printf 'several repositories are recorded for this scope, so which one this belongs in is a choice, not a fact. Ask, then name one of:\n'
        printf '%s\n' "$repos" | grep . | while IFS= read -r repo; do
            printf '  %s\n' "$repo"
        done
        printf 'One that no longer belongs to this scope is removed with herdr_linear::forget_scope_repo %s <path>, naming the path exactly as it is printed above.\n' \
            "$key"
        return 0
    fi
    printf 'no repository is recorded for this scope, so there is nothing to make the worktree from. Ask which repository to use, then pass it back as an absolute path.\n'
}

# herdr_linear::record_scope_repo <absolute-repo> <key>...
herdr_linear::record_scope_repo() {
    local repo="${1:-}" resolved key
    shift || return 1
    # A relative path would let the caller's directory decide the answer again.
    case "$repo" in /*) ;; *) return 1 ;; esac
    resolved="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
    # Read back one path per line, so a newline would come out as two paths.
    case "$resolved" in ''|*$'\n'*) return 1 ;; esac
    local -a keys=()
    for key in "$@"; do
        [ -n "$key" ] || continue
        herdr_linear::is_safe_identifier "$key" || return 1
        keys+=("$key")
    done
    [ "${#keys[@]}" -gt 0 ] || return 1
    herdr_linear::_scope_run add "$resolved" "${keys[@]}"
}

# herdr_linear::forget_scope_repo <key> [repo]
#
# Drops one repository, or every repository for the key. The path is matched as
# recorded, never resolved: the usual reason to forget one is that it is gone.
# Nothing recorded is the state asked for, so it succeeds.
herdr_linear::forget_scope_repo() {
    local key="${1:-}" repo="${2-}"
    herdr_linear::is_safe_identifier "$key" || return 1
    if [ -n "$repo" ]; then
        herdr_linear::_scope_run forget "$key" "$repo"
    else
        herdr_linear::_scope_run forget "$key"
    fi
}

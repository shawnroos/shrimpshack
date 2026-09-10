#!/usr/bin/env bash
# The binding store: which Linear issue a worktree is bound to, and in what state.
# Sourced, never executed.
#
# WHAT A BINDING IS KEYED ON (KTD4)
# The worktree's resolved real path AND the branch recorded at confirmation.
# Path alone is not identity: worktree names recur here by convention, so a
# recreated worktree would inherit a record still reading `bound` and ground the
# session in the previous work's issue. A record whose recorded branch no longer
# matches the path's current branch reads as `proposed`.
#
# WHAT THE NONCE DOES, AND WHAT IT DOES NOT
# `confirm` requires the nonce that `propose` generated and stored. That makes a
# confirmation impossible to reach except through a proposal that was actually
# written -- no accidental confirmation, no stale one, and no cross-session one
# where two sessions share a worktree.
#
# It is NOT an attendedness check, and must not be described as one. U1 proved
# no field separates an interactive session from a headless one: `claude -p`
# reports the same `source: startup` an interactive start reports. A headless
# session running the bind skill would call propose, receive the nonce, and call
# confirm. Nothing in this file can prevent that.
#
# R6 is therefore satisfied by a PAIR: this file guarantees confirm requires the
# current proposal's nonce; U7's skill guarantees the nonce reaches confirm only
# after a human answered a prompt. Neither half satisfies R6 alone, and claiming
# otherwise here would be a check narrower than its invariant.
#
# WHY READS DO NOT WRITE
# A branch mismatch reports an EFFECTIVE state rather than rewriting the record.
# Downgrading on read would make every read a lock-taking mutation, which turns
# grounding -- the hot path, run on every session start -- into a writer, and
# makes a read during a concurrent mutation block. The next mutation persists it.

# --------------------------------------------------------------- configuration

# Outside version control, which R7 requires, and outside ${CLAUDE_PLUGIN_ROOT},
# which changes on plugin update.
# No lib sources another, and ground.sh sources sanitize.sh AFTER this file:
# without this the call below is 127, which its `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
HERDR_LINEAR_PIN_DIR="${HERDR_LINEAR_PIN_DIR:-$HOME/.claude/linear-pin}"
HERDR_LINEAR_RECORD_VERSION=1

# A lock older than this is treated as abandoned. A session that dies mid-write
# must not wedge the worktree permanently.
HERDR_LINEAR_LOCK_STALE_SECONDS="${HERDR_LINEAR_LOCK_STALE_SECONDS:-30}"
HERDR_LINEAR_LOCK_WAIT_SECONDS="${HERDR_LINEAR_LOCK_WAIT_SECONDS:-10}"
# Test seam only: holds the critical section open so a real race can be staged.
HERDR_LINEAR_LOCK_HOLD_MS="${HERDR_LINEAR_LOCK_HOLD_MS:-0}"

HERDR_LINEAR_BINDING_OK=0
HERDR_LINEAR_BINDING_ABSENT=1    # no record, or one that failed validation
HERDR_LINEAR_BINDING_REFUSED=2   # the operation is not permitted in this state
HERDR_LINEAR_BINDING_LOCKED=3    # the lock could not be taken

# ------------------------------------------------------------------ identity

# Verbatim from ~/.claude/hooks/linear-pin.sh:30-36, so a seed lookup finds what
# that hook actually wrote. Deriving it independently would silently find
# nothing, which is indistinguishable from "no pin exists".
# Note `--show-toplevel` in a worktree returns the WORKTREE's path, not the main
# repository's, and a detached HEAD has no branch and therefore no key.
herdr_linear::_pin_branch_key() {
    local cwd="$1" root branch
    root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || return 1
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    [ -n "$branch" ] || return 1
    printf '%s' "${root}#${branch}" | shasum | cut -c1-16
}

# Never fails. A directory that is not a repository at all still has to answer
# -- the consent reader runs from an unbound checkout, and under `set -e` a
# non-zero here would take the caller down with it.
herdr_linear::_current_branch() {
    git -C "$1" --no-optional-locks branch --show-current 2>/dev/null || true
}

herdr_linear::binding_key() {
    local resolved
    resolved="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
    printf '%s' "$resolved" | shasum | cut -c1-16
}

herdr_linear::_record_path() {
    local key
    key="$(herdr_linear::binding_key "$1")" || return 1
    printf '%s/bindings/%s.json' "$HERDR_LINEAR_STORE_DIR" "$key"
}

herdr_linear::_ensure_store() {
    mkdir -p "$HERDR_LINEAR_STORE_DIR/bindings" 2>/dev/null || return 1
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_STORE_DIR/bindings" 2>/dev/null
    return 0
}

# --------------------------------------------------------------------- locking

# mkdir, not flock: mkdir is atomic on every POSIX filesystem and needs nothing
# installed. flock on this machine is a Homebrew binary, so depending on it
# would fail on a clean checkout -- and a lock that silently does not lock is
# worse than no lock at all.
herdr_linear::_lock() {
    local lock="$1.lock" waited=0 age now
    while ! mkdir "$lock" 2>/dev/null; do
        now=$(date +%s)
        age=$(( now - $(herdr_linear::_mtime "$lock" 2>/dev/null || echo "$now") ))
        if [ "$age" -gt "$HERDR_LINEAR_LOCK_STALE_SECONDS" ]; then
            rmdir "$lock" 2>/dev/null
            continue
        fi
        waited=$(( waited + 1 ))
        [ "$waited" -gt $(( HERDR_LINEAR_LOCK_WAIT_SECONDS * 20 )) ] && return 1
        perl -e 'select undef, undef, undef, 0.05' 2>/dev/null || sleep 1
    done
    return 0
}

herdr_linear::_unlock() { rmdir "$1.lock" 2>/dev/null; }

herdr_linear::_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ------------------------------------------------------------------ the record

# One implementation, python3, for both reading and writing. An earlier helper in
# this plugin kept a jq path and a python path in parallel and they disagreed on
# booleans -- `// empty` collapses a legitimate false into the missing-key
# sentinel. Two implementations of one contract is a divergence waiting to be
# found in production, so this has one.
herdr_linear::_py() {
    HERDR_LINEAR_RECORD_VERSION="$HERDR_LINEAR_RECORD_VERSION" python3 - "$@" <<'PYEOF'
import sys, json, os, time, secrets

VALID_STATES = {"unbound", "proposed", "bound", "misplaced", "stale"}
REQUIRED = ("version", "worktree_path", "state")
VERSION = int(os.environ.get("HERDR_LINEAR_RECORD_VERSION", "1"))

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def load(path):
    """Returns a record, or None when there is nothing usable.

    'Usable' is a whole-shape test, not a parse test. A truncated file, a file
    that parses but has no state, a state outside the enum, and a record from a
    future version are all ABSENT. Validating only 'did json.load throw' passes
    a record whose state is the string 'confirmed' -- a value no code writes and
    no branch handles, which would then fall through every state check silently.
    """
    try:
        with open(path) as fh:
            rec = json.load(fh)
    except Exception:
        return None
    if not isinstance(rec, dict):
        return None
    for field in REQUIRED:
        if field not in rec:
            return None
    if rec.get("state") not in VALID_STATES:
        return None
    if not isinstance(rec.get("version"), int) or rec["version"] > VERSION:
        return None
    rec.setdefault("branch_at_confirmation", "")
    rec.setdefault("issue_identifier", "")
    rec.setdefault("declined", [])
    rec.setdefault("proposal", None)
    rec.setdefault("pending_judgment", None)
    rec.setdefault("consent", None)
    rec.setdefault("consent_proposal", None)
    rec.setdefault("pending_consent", None)
    rec.setdefault("created_children", [])
    rec.setdefault("created_documents", [])
    rec.setdefault("description_head", "")
    rec.setdefault("issue_updated_at", "")
    for k in ("declined", "created_children", "created_documents"):
        if not isinstance(rec[k], list):
            return None
    return rec

def blank(path_value):
    return {
        "version": VERSION, "worktree_path": path_value, "state": "unbound",
        "branch_at_confirmation": "", "issue_identifier": "", "declined": [],
        "proposal": None, "pending_judgment": None,
        "consent": None, "consent_proposal": None, "pending_consent": None,
        "created_children": [],
        "created_documents": [], "description_head": "",
        "issue_updated_at": "", "updated_at": now(),
    }

def save(path, rec):
    """Temp file in the SAME directory, then rename. A temp file elsewhere
    cannot be renamed atomically across a filesystem boundary, which would turn
    the write into a copy and reintroduce the torn-record case."""
    rec["updated_at"] = now()
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)

op = sys.argv[1]
path = sys.argv[2]
args = sys.argv[3:]

if op == "read":
    rec = load(path)
    if rec is None:
        sys.exit(1)
    sys.stdout.write(json.dumps(rec))
    sys.exit(0)

if op == "field":
    rec = load(path)
    if rec is None:
        sys.exit(1)
    v = rec.get(args[0])
    sys.stdout.write("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
    sys.exit(0)

def consent_covers(rec, team, project, branch):
    """R10. Team and branch are exact. A request naming no project is covered by
    the answer for that team -- start_new and new_project name a team only. The
    reverse is not covered: an answer that named no project never named one."""
    c = rec.get("consent")
    if not isinstance(c, dict):
        return False
    if c.get("team", "") != team:
        return False
    if project and c.get("project", "") != project:
        return False
    return c.get("branch", "") == branch

if op == "has-consent":
    rec = load(path)
    sys.exit(0 if rec is not None and isinstance(rec.get("consent"), dict) else 1)

if op == "consent-ok":
    rec = load(path)
    if rec is None:
        sys.exit(1)
    sys.exit(0 if consent_covers(rec, args[0], args[1], args[2]) else 1)

if op == "pending-consent":
    rec = load(path)
    if rec is None or not rec.get("pending_consent"):
        sys.exit(1)
    sys.stdout.write(rec["pending_consent"])
    sys.exit(0)

# ---- mutations. Each loads, applies, saves. The caller holds the lock.
rec = load(path) or blank(args[0] if op == "init" else "")

if op == "init":
    rec["worktree_path"] = args[0]
    save(path, rec)
    sys.exit(0)

if op == "propose":
    worktree, identifier = args[0], args[1]
    if identifier in rec["declined"]:
        sys.exit(2)               # R4: a declined candidate is never re-proposed
    rec["worktree_path"] = worktree
    rec["state"] = "proposed"
    rec["proposal"] = {
        "identifier": identifier,
        "nonce": secrets.token_hex(16),
        "presented_at": now(),
    }
    save(path, rec)
    sys.stdout.write(rec["proposal"]["nonce"])
    sys.exit(0)

if op == "confirm":
    identifier, nonce, branch = args[0], args[1], args[2]
    p = rec.get("proposal")
    if not p or p.get("identifier") != identifier or not nonce or p.get("nonce") != nonce:
        sys.exit(2)
    rec["state"] = "bound"
    rec["issue_identifier"] = identifier
    rec["branch_at_confirmation"] = branch
    rec["proposal"] = None
    save(path, rec)
    sys.exit(0)

if op == "decline":
    identifier = args[0]
    if identifier not in rec["declined"]:
        rec["declined"].append(identifier)
    p = rec.get("proposal")
    if p and p.get("identifier") == identifier:
        rec["proposal"] = None
    if rec["state"] == "proposed" and not rec["proposal"]:
        rec["state"] = "unbound"
    save(path, rec)
    sys.exit(0)

if op == "set-state":
    if args[0] not in VALID_STATES:
        sys.exit(2)
    rec["state"] = args[0]
    save(path, rec)
    sys.exit(0)

if op == "add-child":
    # R30 bounds writes to the bound issue and issues created beneath it, so the
    # list of what was created is itself part of the authorization boundary.
    if args[0] not in rec["created_children"]:
        rec["created_children"].append(args[0])
    save(path, rec)
    sys.exit(0)

if op == "add-document":
    # R32. A document the plugin created. Same mechanism as created_children:
    # the list bounds what may be MODIFIED later, and is never derived from
    # Linear -- a tracker-derived list of "documents on this issue" would let
    # anyone attach a document into the writable set.
    doc_id, title = args[0], (args[1] if len(args) > 1 else "")
    if not any(d.get("id") == doc_id for d in rec["created_documents"]):
        rec["created_documents"].append({"id": doc_id, "title": title})
    save(path, rec)
    sys.exit(0)

if op == "document-id-for":
    # Which document, if any, this plugin already made for that title.
    for d in rec["created_documents"]:
        if d.get("title") == args[0]:
            sys.stdout.write(d.get("id", ""))
            sys.exit(0)
    sys.exit(1)

if op == "owns-document":
    sys.exit(0 if any(d.get("id") == args[0] for d in rec["created_documents"]) else 1)

if op == "set-description-head":
    rec["description_head"] = args[0]
    save(path, rec)
    sys.exit(0)

if op == "consent-propose":
    worktree, team, project = args[0], args[1], args[2]
    if not rec["worktree_path"]:
        rec["worktree_path"] = worktree
    rec["consent_proposal"] = {
        "team": team, "project": project,
        "nonce": secrets.token_hex(16), "presented_at": now(),
    }
    save(path, rec)
    sys.stdout.write(rec["consent_proposal"]["nonce"])
    sys.exit(0)

if op == "consent-confirm":
    # The same nonce rule the binding uses, and the same limit on what it
    # proves: it orders confirm after propose. What makes the answer a PERSON'S
    # is that every skill carrying the fence is disable-model-invocation, and
    # that nothing under lib/, hooks/ or commands/ calls this op.
    team, project, branch, nonce = args[0], args[1], args[2], args[3]
    p = rec.get("consent_proposal")
    if (not p or not nonce or p.get("nonce") != nonce
            or p.get("team") != team or p.get("project") != project):
        sys.exit(2)
    rec["consent"] = {
        "team": team, "project": project, "branch": branch, "answered_at": now(),
    }
    rec["consent_proposal"] = None
    rec["pending_consent"] = None
    save(path, rec)
    sys.exit(0)

if op == "consent-decline":
    # An absent answer and a refused one both mean do not write, so this records
    # no third state: it clears the proposal and the notice and leaves `consent`
    # as it found it. Not a revoke -- a recorded yes is never offered this.
    #
    # The same nonce rule the confirm half uses, for a different reason. A
    # decline authorises nothing, but it CLEARS the deferred-write notice, which
    # is the only surfaced evidence that a write was skipped. The nonce makes a
    # decline answer a proposal that actually happened, so nothing can erase
    # that evidence by answering a question nobody asked.
    team, project, nonce = args[0], args[1], args[2]
    p = rec.get("consent_proposal")
    if (not p or not nonce or p.get("nonce") != nonce
            or p.get("team") != team or p.get("project") != project):
        sys.exit(2)
    rec["consent_proposal"] = None
    rec["pending_consent"] = None
    save(path, rec)
    sys.exit(0)

if op == "set-pending-consent":
    # KTD3. Its own slot. `set-judgment` replaces its single slot wholesale, and
    # a consent question landing there would evict the squash-merge question --
    # which has already happened once.
    rec["pending_consent"] = args[0]
    save(path, rec)
    sys.exit(0)

if op == "set-judgment":
    rec["pending_judgment"] = {"text": args[0], "recorded_at": now(), "presented_in": []}
    save(path, rec)
    sys.exit(0)

if op == "take-judgment":
    # R18: re-presented ONCE at the start of the next session, until answered.
    # "Once" is per session, not once ever -- so the session id that already saw
    # it is recorded, and any other session still gets it.
    session = args[0]
    j = rec.get("pending_judgment")
    if not j:
        sys.exit(1)
    seen = j.setdefault("presented_in", [])
    if session and session in seen:
        sys.exit(1)
    if session:
        seen.append(session)
        save(path, rec)
    sys.stdout.write(j.get("text", ""))
    sys.exit(0)

if op == "clear-judgment":
    rec["pending_judgment"] = None
    save(path, rec)
    sys.exit(0)

sys.exit(64)
PYEOF
}

# A record not owned by this user, or writable by group or other, is ABSENT --
# not repaired. Something else can write it, so nothing it says is trustworthy,
# and silently fixing the mode would hide that.
herdr_linear::_mode_ok() {
    local f="$1" mode owner
    [ -f "$f" ] || return 1
    mode="$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null)"
    owner="$(stat -f %u "$f" 2>/dev/null || stat -c %u "$f" 2>/dev/null)"
    [ "$owner" = "$(id -u)" ] || return 1
    case "$mode" in
        *[2367]) return 1 ;;   # other-writable
    esac
    case "$mode" in
        ?[2367]?) return 1 ;;  # group-writable
    esac
    return 0
}

# ------------------------------------------------------------- public read path

# herdr_linear::binding_read <worktree>
# Prints the record as JSON with `state` replaced by the EFFECTIVE state. Never
# writes, never locks.
herdr_linear::binding_read() {
    local wt="${1:-}" rec f branch recorded state
    f="$(herdr_linear::_record_path "$wt")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    rec="$(herdr_linear::_py read "$f")" || return "$HERDR_LINEAR_BINDING_ABSENT"

    state="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null)"
    if [ "$state" = "bound" ]; then
        recorded="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("branch_at_confirmation",""))' 2>/dev/null)"
        branch="$(herdr_linear::_current_branch "$wt")"
        if [ "$recorded" != "$branch" ]; then
            rec="$(printf '%s' "$rec" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["state"]="proposed";d["downgraded_from_bound"]=True;print(json.dumps(d))')"
        fi
    fi
    printf '%s' "$rec"
    return "$HERDR_LINEAR_BINDING_OK"
}

herdr_linear::binding_state() {
    local rec
    rec="$(herdr_linear::binding_read "$1")" || { printf 'unbound'; return "$HERDR_LINEAR_BINDING_ABSENT"; }
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null
}

herdr_linear::binding_identifier() {
    local rec id
    rec="$(herdr_linear::binding_read "$1")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    id="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issue_identifier",""))' 2>/dev/null)"
    # A proposed record has no identifier yet; that is absent, not hostile, and
    # callers distinguish the two.
    [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    # A record written before this guard existed, or edited by anything that can
    # reach the store, is untrusted at read time too.
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    printf '%s' "$id"
}

# The pin store is a SEED and is never written. It holds a bare identifier with
# no room for proposed, declined or stale, so what it yields is a candidate for
# a proposal -- never a binding.
herdr_linear::binding_seed_candidate() {
    local wt="${1:-}" key f id
    key="$(herdr_linear::_pin_branch_key "$wt")" || return 1
    f="$HERDR_LINEAR_PIN_DIR/branch/$key"
    [ -r "$f" ] || return 1
    id="$(cat "$f" 2>/dev/null)"
    printf '%s' "$id" | grep -qE '^[A-Z][A-Z0-9]{1,7}-[0-9]{1,6}$' || return 1
    printf '%s' "$id"
}

# ---------------------------------------------------------- public write path

herdr_linear::_mutate_at() {
    local f="$1" op="$2"; shift 2
    local rc
    herdr_linear::_ensure_store || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_lock "$f" || return "$HERDR_LINEAR_BINDING_LOCKED"
    if [ "$HERDR_LINEAR_LOCK_HOLD_MS" -gt 0 ] 2>/dev/null; then
        perl -e "select undef, undef, undef, $HERDR_LINEAR_LOCK_HOLD_MS/1000" 2>/dev/null
    fi
    herdr_linear::_py "$op" "$f" "$@"
    rc=$?
    chmod 600 "$f" 2>/dev/null
    herdr_linear::_unlock "$f"
    return "$rc"
}

herdr_linear::_mutate() {
    local wt="$1"; shift
    local f
    herdr_linear::_ensure_store || return "$HERDR_LINEAR_BINDING_ABSENT"
    f="$(herdr_linear::_record_path "$wt")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mutate_at "$f" "$@"
}

herdr_linear::binding_propose() {
    local wt="${1:-}" id="${2:-}"
    [ -n "$wt" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    # The record is a delivery channel: what is written here comes back out of
    # binding_identifier and becomes a path segment downstream.
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$wt" propose "$(cd "$wt" && pwd -P)" "$id"
}

# The nonce is the whole gate. See the header: it orders confirm after propose,
# and it is NOT a proof that a human answered.
herdr_linear::binding_confirm() {
    local wt="${1:-}" id="${2:-}" nonce="${3:-}" branch
    [ -n "$wt" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    branch="$(herdr_linear::_current_branch "$wt")"
    herdr_linear::_mutate "$wt" confirm "$id" "$nonce" "$branch"
}

herdr_linear::binding_decline()       { herdr_linear::_mutate "${1:-}" decline "${2:-}"; }
herdr_linear::binding_set_state()     { herdr_linear::_mutate "${1:-}" set-state "${2:-}"; }
herdr_linear::binding_add_child() {
    herdr_linear::is_safe_identifier "${2:-}" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "${1:-}" add-child "$2"
}
herdr_linear::binding_add_document()  { herdr_linear::_mutate "${1:-}" add-document "${2:-}" "${3:-}"; }
herdr_linear::binding_set_desc_head() { herdr_linear::_mutate "${1:-}" set-description-head "${2:-}"; }
herdr_linear::binding_desc_head() {
    local rec
    rec="$(herdr_linear::binding_read "${1:-}")" || return 1
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("description_head",""))' 2>/dev/null
}
herdr_linear::binding_document_for()  { herdr_linear::_mutate "${1:-}" document-id-for "${2:-}"; }
herdr_linear::binding_owns_document() { herdr_linear::_mutate "${1:-}" owns-document "${2:-}"; }
herdr_linear::binding_set_judgment()  { herdr_linear::_mutate "${1:-}" set-judgment "${2:-}"; }
herdr_linear::binding_clear_judgment(){ herdr_linear::_mutate "${1:-}" clear-judgment; }

# Prints the pending judgment once per session, then not again for that session.
herdr_linear::binding_take_judgment() {
    herdr_linear::_mutate "${1:-}" take-judgment "${2:-${CLAUDE_SESSION_ID:-}}"
}

# ------------------------------------------------------------ write consent
#
# KTD1. Consent shares ONE mechanism with the binding: the path-hash key. It
# carries its own team, project and branch, and the reader compares all three
# itself. It cannot ride on `branch_at_confirmation`, which is compared only
# when the state is `bound`, is rewritten by every confirm including the
# no-human pairs in start.sh and create.sh, and is empty for the unbound
# checkout R9 has to cover.
#
# The reader requires no binding at all: `start_new` and `new_project` run from
# a checkout that has none.

# herdr_linear::has_consent <dir> -> 0 when an answer is RECORDED here.
# Presence, asked separately from value: the store reads through `_py field`,
# which prints an empty string for an absent key and for a null one alike.
herdr_linear::has_consent() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py has-consent "$f"
}

# herdr_linear::consent_ok <dir> <team> [project] -> 0 when the recorded answer
# covers this write. Never writes, never locks -- it is on the path of every
# mutation, and a read that takes the lock blocks during one.
herdr_linear::consent_ok() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" f branch
    [ -n "$team" ] || return 1
    f="$(herdr_linear::_record_path "$dir")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    branch="$(herdr_linear::_current_branch "$dir")"
    herdr_linear::_py consent-ok "$f" "$team" "$project" "$branch"
}

# The write half. KTD2: `consent_confirm` has exactly one class of caller -- the
# ask-and-record fence in a write skill, every one of which is
# disable-model-invocation. Nothing under lib/, hooks/ or commands/ may call it.
herdr_linear::consent_propose() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" resolved
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    resolved="$(cd "$dir" 2>/dev/null && pwd -P)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$dir" consent-propose "$resolved" "$team" "$project"
}

herdr_linear::consent_confirm() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" nonce="${4:-}" branch
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    branch="$(herdr_linear::_current_branch "$dir")"
    herdr_linear::_mutate "$dir" consent-confirm "$team" "$project" "$branch" "$nonce"
}

# R9a. What a run with nobody to ask would have written, kept where the next
# session can find it -- and NOT in the judgment slot, which holds one thing.
herdr_linear::binding_set_pending_consent() {
    herdr_linear::_mutate "${1:-}" set-pending-consent "${2:-}"
}

herdr_linear::binding_pending_consent() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py pending-consent "$f"
}

# The answer to no, and symmetric with confirm in both halves of the rule. KTD2
# governs who may call it -- a decline is a person's answer, so nothing under
# lib/, hooks/ or commands/ may -- and the nonce governs what it may answer.
herdr_linear::consent_decline() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" nonce="${4:-}"
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$dir" consent-decline "$team" "$project" "$nonce"
}

HERDR_LINEAR_SHADOW_LOG="${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/work/shadow.log}"

herdr_linear::_shadow_log() {
    mkdir -p "$(dirname "$HERDR_LINEAR_SHADOW_LOG")" 2>/dev/null
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HERDR_LINEAR_SHADOW_LOG"
}

# herdr_linear::consent_gate <dir> <team> <project> <what> [detail]
#   0  the recorded answer covers this write; proceed
#   1  it does not; the skip is logged and recorded, and the caller returns its
#      own shadow code
#
# The record is written on EVERY path, not just the hook's. No verb here can
# tell whether a person is watching -- all six are reachable from a subagent, a
# headless run, or another plugin sourcing lib/ -- and the costs are asymmetric:
# over-recording costs one line in one session, and only while the write still
# has not happened, while under-recording drops a write silently in exactly the
# unattended case R9a exists for.
herdr_linear::consent_gate() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" what="${4:-}" detail="${5:-}"
    herdr_linear::consent_ok "$dir" "$team" "$project" && return 0
    herdr_linear::_shadow_log "SHADOW would $what${detail:+ $detail}"
    # A locked or unreadable store must not turn a refusal into a proceed.
    herdr_linear::binding_set_pending_consent "$dir" \
        "Nothing here has answered the write question yet, so this did not happen: $what. Run /work:describe or /work:new from this worktree to answer it; answering no clears this notice." \
        || true
    return 1
}

# ------------------------------------------------- workspace to project (R9, R10)
#
# Keyed on the herdr workspace ID, which is a stable opaque handle -- a rename
# changes the workspace's label and not its id, which is exactly why R10 holds
# without any extra machinery. The record shape is the worktree one reused:
# `issue_identifier` carries the Linear project id, and the branch fields stay
# empty because a workspace has no branch to disagree with.
herdr_linear::_workspace_record_path() {
    local ws="${1:-}"
    herdr_linear::is_safe_identifier "$ws" 2>/dev/null || case "$ws" in
        ''|*[!A-Za-z0-9_:-]*) return 1 ;;
    esac
    printf '%s/workspaces/%s.json' "$HERDR_LINEAR_STORE_DIR" "$ws"
}

herdr_linear::workspace_read() {
    local f
    f="$(herdr_linear::_workspace_record_path "${1:-}")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_py read "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
}

herdr_linear::workspace_state() {
    local rec
    rec="$(herdr_linear::workspace_read "$1")" || { printf 'unbound'; return "$HERDR_LINEAR_BINDING_ABSENT"; }
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null
}

herdr_linear::workspace_project() {
    local rec
    rec="$(herdr_linear::workspace_read "$1")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issue_identifier",""))' 2>/dev/null
}

herdr_linear::workspace_propose() {
    local ws="${1:-}" project="${2:-}" f
    [ -n "$ws" ] && [ -n "$project" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_record_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    herdr_linear::_mutate_at "$f" propose "workspace:$ws" "$project"
}

# Same nonce rule, and the same limit on what it proves. See the header.
herdr_linear::workspace_confirm() {
    local ws="${1:-}" project="${2:-}" nonce="${3:-}" f
    [ -n "$ws" ] && [ -n "$project" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_record_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" confirm "$project" "$nonce" ""
}

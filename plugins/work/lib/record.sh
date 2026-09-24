#!/usr/bin/env bash
# The record engine every store in this plugin writes through: one python3
# program that loads, validates and saves a record, the mkdir lock that orders
# writers, and the store directory the records live in.
# Sourced, never executed.
#
# It knows nothing about what a record MEANS. lib/binding.sh keys one on a
# worktree and lib/scope-record.sh keys one on a herdr space or session; both
# are thin shells over this. It is one program on purpose: load() and save()
# split across two files would be two implementations of one contract, which is
# the divergence the comment on _py records.

# ---------------------------------------------------------------- the store

# Outside version control, which R7 requires, and outside ${CLAUDE_PLUGIN_ROOT},
# which changes on plugin update.
HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
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
    rec.setdefault("pending_placement", None)
    rec.setdefault("tab", "")
    rec.setdefault("view", None)
    rec.setdefault("created_views", [])
    rec.setdefault("created_children", [])
    rec.setdefault("created_documents", [])
    rec.setdefault("description_head", "")
    rec.setdefault("issue_updated_at", "")
    rec.setdefault("prior_bindings", [])
    rec.setdefault("display_name", "")
    rec.setdefault("team_ids", [])
    for k in ("declined", "created_children", "created_documents", "created_views", "prior_bindings", "team_ids"):
        if not isinstance(rec[k], list):
            return None
    return rec

def blank(path_value):
    return {
        "version": VERSION, "worktree_path": path_value, "state": "unbound",
        "branch_at_confirmation": "", "issue_identifier": "", "declined": [],
        "proposal": None, "pending_judgment": None,
        "consent": None, "consent_proposal": None, "pending_consent": None,
        "pending_placement": None, "tab": "",
        "view": None, "created_views": [],
        "created_children": [],
        "created_documents": [], "description_head": "",
        "issue_updated_at": "", "prior_bindings": [],
        "display_name": "", "team_ids": [], "updated_at": now(),
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

if op == "pending-placement":
    rec = load(path)
    if rec is None or not rec.get("pending_placement"):
        sys.exit(1)
    sys.stdout.write(rec["pending_placement"])
    sys.exit(0)

if op == "view":
    rec = load(path)
    if rec is None or not rec.get("view"):
        sys.exit(1)
    sys.stdout.write(json.dumps(rec["view"], sort_keys=True))
    sys.exit(0)

if op == "list-effective":
    # Every binding in the store with the state binding_read would report, in
    # one process: the snapshot used to spend about seven processes a record,
    # which is 25 seconds at 40 worktrees against the board's refresh deadline.
    # The state comes from load() on the record at the worktree's own key, as
    # binding_read reads it, and a bound record whose branch has moved reads as
    # proposed, as binding_read downgrades it.
    import glob, hashlib, subprocess
    def mode_ok(f):
        try:
            st = os.stat(f)
        except OSError:
            return False
        return os.path.isfile(f) and st.st_uid == os.getuid() and not st.st_mode & 0o022
    for f in sorted(glob.glob(os.path.join(path, "bindings", "*.json"))):
        if not mode_ok(f):
            continue
        try:
            raw = json.load(open(f))
        except Exception:
            continue
        if not isinstance(raw, dict):
            continue
        tab = raw.get("tab") if isinstance(raw.get("tab"), str) else ""
        wt = str(raw.get("worktree_path") or "")
        row = [f, str(raw.get("issue_identifier") or ""), wt, tab]
        if any("\x1f" in c or "\n" in c for c in row):
            continue
        if not os.path.isdir(wt):
            print("\x1f".join(row + ["worktree_missing"]))
            continue
        key = hashlib.sha1(os.path.realpath(wt).encode()).hexdigest()[:16]
        kf = os.path.join(path, "bindings", key + ".json")
        rec = load(kf) if mode_ok(kf) else None
        if rec is None:
            continue
        eff = rec["state"]
        if eff == "bound":
            try:
                branch = subprocess.run(["git", "-C", wt, "--no-optional-locks", "branch", "--show-current"],
                                        capture_output=True, text=True).stdout.rstrip("\n")
            except Exception:
                branch = ""
            if rec.get("branch_at_confirmation", "") != branch:
                eff = "proposed"
        print("\x1f".join(row + [eff]))
    sys.exit(0)

if op == "list-workspaces":
    # A workspace record has no branch to disagree with, so the loaded state
    # is already the state workspace_state reports.
    #
    # This session's directory first, then the flat one for records written
    # before space records were keyed by session -- and an id found in both is
    # this session's, which is the same precedence the read path applies. Other
    # sessions' directories are not walked: their spaces are not this one's.
    import glob, re
    WS_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", re.ASCII)
    session_dir = args[0] if args else os.path.join(path, "workspaces")
    seen = set()
    for d in (session_dir, os.path.join(path, "workspaces")):
        for f in sorted(glob.glob(os.path.join(d, "*.json"))):
            ws = os.path.basename(f)[:-len(".json")]
            if not WS_ID.fullmatch(ws) or ws in seen:
                continue
            try:
                st = os.stat(f)
            except OSError:
                continue
            if not os.path.isfile(f) or st.st_uid != os.getuid() or st.st_mode & 0o022:
                continue
            rec = load(f)
            if rec is None:
                continue
            seen.add(ws)
            name = rec.get("project_name")
            print(json.dumps({"id": ws, "state": rec["state"],
                              "project_id": str(rec.get("issue_identifier") or "") or None,
                              "project_name": name if isinstance(name, str) else None}))
    sys.exit(0)

if op == "owns-view":
    rec = load(path)
    sys.exit(0 if rec is not None and args[0] in rec["created_views"] else 1)

# The view ops refuse a record the loader cannot read instead of writing a
# blank one: a view landing on a fabricated unbound record is a board for a
# space nobody bound.
if op in ("set-view", "clear-view", "add-view") and load(path) is None:
    sys.exit(1)

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
    # Two optional trailing fields, written in the SAME save as the binding:
    # a display label, and the ids of the teams the bound thing belongs to. A
    # second op for them would leave a window in which the record reads bound
    # and the guard finds no teams to compare against.
    identifier, nonce, branch = args[0], args[1], args[2]
    display = args[3] if len(args) > 3 else None
    team_ids = list(args[4:])
    p = rec.get("proposal")
    if not p or p.get("identifier") != identifier or not nonce or p.get("nonce") != nonce:
        sys.exit(2)
    prev = rec.get("issue_identifier") or ""
    if prev and prev != identifier:
        rec["display_name"] = ""
        rec["team_ids"] = []
        # What the plugin created and chose under the previous binding does not
        # carry over: created_children and created_documents are the write
        # bound, and a view names the old project. They move to prior_bindings
        # rather than vanish, so a created item can still be found to delete.
        rec["prior_bindings"].append({
            "issue_identifier": prev, "view": rec["view"],
            "created_views": rec["created_views"],
            "created_children": rec["created_children"],
            "created_documents": rec["created_documents"],
            "until": now(),
        })
        rec["view"] = None
        rec["created_views"] = []
        rec["created_children"] = []
        rec["created_documents"] = []
        rec["description_head"] = ""
        rec["issue_updated_at"] = ""
    rec["state"] = "bound"
    rec["issue_identifier"] = identifier
    rec["branch_at_confirmation"] = branch
    rec["proposal"] = None
    if display is not None:
        rec["display_name"] = display
    if team_ids:
        rec["team_ids"] = team_ids
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

if op == "set-tab":
    rec["tab"] = args[0]
    save(path, rec)
    sys.exit(0)

if op == "set-view":
    view_id, name = args[0], args[1]
    layout = None
    if len(args) > 2 and args[2]:
        try:
            layout = json.loads(args[2])
        except ValueError:
            sys.exit(2)
        if not isinstance(layout, dict):
            sys.exit(2)
    rec["view"] = {"id": view_id, "name": name, "layout": layout, "fetched_at": now()}
    save(path, rec)
    sys.exit(0)

if op == "clear-view":
    rec["view"] = None
    save(path, rec)
    sys.exit(0)

if op == "add-view":
    # Same bound as created_children: the list of views this plugin created
    # is what a later change-view verb may touch, and it is never read from
    # Linear.
    if args[0] not in rec["created_views"]:
        rec["created_views"].append(args[0])
    save(path, rec)
    sys.exit(0)

if op == "set-pending-placement":
    # KTD29. Its own slot: consent-confirm clears pending_consent, and a space
    # question landing there would be cleared by an answer to a different one.
    rec["pending_placement"] = args[0] or None
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

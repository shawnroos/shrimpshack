#!/usr/bin/env bash
# The session binding store: which Linear scope a herdr session is bound to.
# Sourced, never executed.
#
# Keyed by the session's name, because herdr cannot rename a session: a binding
# made after a session was created is recorded against the name it already has
# (R6). The record family has its own version; HERDR_LINEAR_RECORD_VERSION
# belongs to the worktree binding and is not shared.
#
# The nonce protocol is the worktree binding's (see binding.sh): confirm needs
# the nonce propose wrote, and binds only what that proposal named. It proves a
# proposal was written, not that a person answered; the callers allowed to
# confirm are held to person-typed surfaces by consent_caller_check.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::_lock >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/binding.sh"

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
HERDR_LINEAR_SESSION_BINDING_VERSION=1

herdr_linear::_session_binding_path() {
    local name="${1:-}"
    herdr_linear::is_safe_identifier "$name" || return 1
    printf '%s/sessions/%s/binding.json' "$HERDR_LINEAR_STORE_DIR" "$name"
}

herdr_linear::_session_binding_py() {
    HERDR_LINEAR_SESSION_BINDING_VERSION="$HERDR_LINEAR_SESSION_BINDING_VERSION" python3 - "$@" <<'PYEOF'
import sys, json, os, time, secrets, re

VERSION = int(os.environ["HERDR_LINEAR_SESSION_BINDING_VERSION"])
STATES = {"unbound", "proposed", "bound", "declined"}
KINDS = {"organization", "team", "project", "initiative"}

def load(path):
    try:
        with open(path) as fh:
            rec = json.load(fh)
    except Exception:
        return None
    if not isinstance(rec, dict) or rec.get("state") not in STATES:
        return None
    if not isinstance(rec.get("version"), int) or rec["version"] > VERSION:
        return None
    for k in ("kind", "scope_id", "scope_name"):
        rec.setdefault(k, "")
    rec.setdefault("proposal", None)
    rec.setdefault("asked", False)
    if rec["state"] == "bound" and rec["kind"] not in KINDS:
        return None
    return rec

def blank(name):
    return {"version": VERSION, "session": name, "state": "unbound",
            "kind": "", "scope_id": "", "scope_name": "",
            "proposal": None, "asked": False}

def save(path, rec):
    rec["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)

op, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
existing = load(path) if os.path.exists(path) else None
if os.path.exists(path) and existing is None and op != "read":
    sys.exit(2)
rec = existing or blank(name)

if op == "read":
    if existing is None:
        sys.exit(1)
    sys.stdout.write(json.dumps(rec))
    sys.exit(0)

if op == "propose":
    kind, scope_id, scope_name = args
    if kind not in KINDS:
        sys.exit(2)
    scope_name = re.sub(r"[\x00-\x1f\x7f]", "", scope_name)[:120]
    nonce = secrets.token_hex(16)
    rec["proposal"] = {"kind": kind, "scope_id": scope_id,
                       "scope_name": scope_name, "nonce": nonce}
    rec["state"] = "bound" if rec.get("scope_id") and rec["state"] == "bound" else "proposed"
    save(path, rec)
    sys.stdout.write(nonce)
    sys.exit(0)

if op in ("confirm", "decline"):
    p = rec.get("proposal")
    nonce = args[0]
    if not isinstance(p, dict) or not nonce or not secrets.compare_digest(str(p.get("nonce", "")), nonce):
        sys.exit(2)
    rec["proposal"] = None
    if op == "confirm":
        rec["kind"], rec["scope_id"], rec["scope_name"] = p["kind"], p["scope_id"], p["scope_name"]
        rec["state"] = "bound"
    else:
        rec["state"] = "bound" if rec["state"] == "bound" else "declined"
    save(path, rec)
    sys.exit(0)

if op == "unbind":
    save(path, blank(name))
    sys.exit(0)

if op == "mark-asked":
    rec["asked"] = True
    save(path, rec)
    sys.exit(0)

sys.exit(2)
PYEOF
}

herdr_linear::_session_binding_mutate() {
    local name="$1" op="$2" f rc
    shift 2
    herdr_linear::is_safe_identifier "$name" || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_session_binding_path "$name")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    mkdir -p "${f%/*}" 2>/dev/null || return "$HERDR_LINEAR_BINDING_ABSENT"
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_STORE_DIR/sessions" "${f%/*}" 2>/dev/null
    herdr_linear::_lock "$f" || return "$HERDR_LINEAR_BINDING_LOCKED"
    # Not repaired by writing through it: something else can write this file.
    if [ -e "$f" ] && ! herdr_linear::_mode_ok "$f"; then
        herdr_linear::_unlock "$f"
        return "$HERDR_LINEAR_BINDING_REFUSED"
    fi
    herdr_linear::_session_binding_py "$op" "$f" "$name" "$@"
    rc=$?
    [ -e "$f" ] && chmod 600 "$f" 2>/dev/null
    herdr_linear::_unlock "$f"
    [ "$rc" -eq 0 ] || return "$HERDR_LINEAR_BINDING_REFUSED"
}

# herdr_linear::session_binding_read <session>
herdr_linear::session_binding_read() {
    local f
    f="$(herdr_linear::_session_binding_path "${1:-}")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_session_binding_py read "$f" "$1" || return "$HERDR_LINEAR_BINDING_ABSENT"
}

# herdr_linear::session_scope [session name]
# The bound scope of the session this process runs in, as `kind<TAB>id<TAB>name`.
# A caller that already resolved the name passes it: resolving it again probes
# herdr when the socket is not in the environment.
# Fails when there is no session or it is not bound: an unbound session applies
# no scope checks (R13).
herdr_linear::session_scope() {
    local name rec
    command -v herdr_linear::session_name >/dev/null 2>&1 \
        || . "${BASH_SOURCE[0]%/*}/session.sh"
    name="${1:-}"
    [ -n "$name" ] || name="$(herdr_linear::session_name)" || return 1
    rec="$(herdr_linear::session_binding_read "$name")" || return 1
    printf '%s' "$rec" | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r.get("state") != "bound" or not r.get("scope_id"):
    sys.exit(1)
sys.stdout.write("%s\t%s\t%s" % (r["kind"], r["scope_id"], r["scope_name"]))
'
}

herdr_linear::session_binding_state() {
    local rec
    rec="$(herdr_linear::session_binding_read "${1:-}")" || { printf 'unbound'; return 0; }
    printf '%s' "$rec" | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"], end="")'
}

# herdr_linear::session_binding_propose <session> <kind> <scope id> <display name>
# Prints the nonce the confirmation must carry.
herdr_linear::session_binding_propose() {
    local name="${1:-}" kind="${2:-}" id="${3:-}" display="${4:-}"
    [ -n "$kind" ] && [ -n "$display" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_session_binding_mutate "$name" propose "$kind" "$id" "$display"
}

herdr_linear::session_binding_confirm() {
    herdr_linear::_session_binding_mutate "${1:-}" confirm "${2:-}"
}

herdr_linear::session_binding_decline() {
    herdr_linear::_session_binding_mutate "${1:-}" decline "${2:-}"
}

herdr_linear::session_binding_unbind() {
    herdr_linear::_session_binding_mutate "${1:-}" unbind
}

herdr_linear::session_binding_mark_asked() {
    herdr_linear::_session_binding_mutate "${1:-}" mark-asked
}

# 0 when the start-time ask should open: no binding, no pending proposal, not
# declined, and not already asked. An unreadable record never asks (R7 says an
# unbound session is never blocked; a question over a record nobody can trust
# would be one).
herdr_linear::session_binding_should_ask() {
    local name="${1:-}" f
    f="$(herdr_linear::_session_binding_path "$name")" || return 1
    [ -e "$f" ] || return 0
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_session_binding_py read "$f" "$name" \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); sys.exit(0 if r["state"]=="unbound" and not r["asked"] else 1)'
}

# herdr_linear::session_rebind_preview <kind> <scope id>
# What binding this session to a new scope would leave outside it, before
# anything is written (R5): one line per workspace of this session and per
# worktree bound from it, `outside|unknown<TAB>workspace|worktree<TAB>what<TAB>project or issue`.
# A worktree belongs to this session when its binding holds a tab here.
herdr_linear::session_rebind_preview() {
    local kind="${1:-}" id="${2:-}" session root line what key subject rc
    case "$kind" in
        organization) return 0 ;;
        team|project|initiative) ;;
        *) return "$HERDR_LINEAR_BINDING_REFUSED" ;;
    esac
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    command -v herdr_linear::session_name >/dev/null 2>&1 \
        || . "${BASH_SOURCE[0]%/*}/session.sh"
    command -v herdr_linear::scope_contains_project >/dev/null 2>&1 \
        || . "${BASH_SOURCE[0]%/*}/scope-linear.sh"
    session="$(herdr_linear::session_name)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    root="$(herdr_linear::session_store_root)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    while IFS=$'\t' read -r what key subject; do
        [ -n "$what" ] || continue
        if [ "$what" = workspace ]; then
            herdr_linear::scope_contains_project "$kind" "$id" "$subject" >/dev/null; rc=$?
        else
            herdr_linear::scope_contains_issue "$kind" "$id" "$subject" >/dev/null; rc=$?
        fi
        case "$rc" in
            "$HERDR_LINEAR_SCOPE_INSIDE") ;;
            "$HERDR_LINEAR_SCOPE_OUTSIDE") printf 'outside\t%s\t%s\t%s\n' "$what" "$key" "$subject" ;;
            *) printf 'unknown\t%s\t%s\t%s\n' "$what" "$key" "$subject" ;;
        esac
    done < <(python3 - "$root/workspaces" "$HERDR_LINEAR_STORE_DIR/bindings" "$session" <<'PYEOF'
import glob, json, os, re, stat, sys
spaces, bindings, session = sys.argv[1:4]
SAFE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

def records(d):
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        try:
            st = os.lstat(f)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
                continue
            r = json.load(open(f))
        except (OSError, ValueError):
            continue
        if isinstance(r, dict) and r.get("state") in ("bound", "misplaced", "stale"):
            yield f, r

def clean(s):
    return re.sub(r"[\t\n\r\x00-\x1f\x7f]", " ", str(s))

for f, r in records(spaces):
    project = r.get("issue_identifier") or ""
    if SAFE.fullmatch(project):
        print("workspace\t%s\t%s" % (clean(os.path.basename(f)[:-5]), project))
for f, r in records(bindings):
    tabs = r.get("tabs") if isinstance(r.get("tabs"), dict) else {}
    tab = r.get("tab") if session == "default" else tabs.get(session)
    ident = r.get("issue_identifier") or ""
    if tab and SAFE.fullmatch(ident):
        print("worktree\t%s\t%s" % (clean(r.get("worktree_path", "")), ident))
PYEOF
)
}

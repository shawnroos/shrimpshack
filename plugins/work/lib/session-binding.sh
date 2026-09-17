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

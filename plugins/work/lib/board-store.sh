#!/usr/bin/env bash
# Board records: reservations, the pane ledger, pending questions, space
# consent and the sync-state record. Sourced, never executed.
#
# A second record family over the binding store (KTD7): its own version
# constant, the same lock, atomic write and mode rules. Keys are Linear issue
# ids, never identifiers (KTD1), so a team move that renumbers a ticket keeps
# every record.
#
# Space names are display text ("No project", "In Progress") and cannot pass
# is_safe_identifier, so ledger and consent files are named by a hash of the
# space name and the name is kept inside the record; a record whose stored name
# differs from the one asked for is refused rather than read as that space.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::_lock >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/binding.sh"

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
HERDR_LINEAR_BOARD_RECORD_VERSION=1

HERDR_LINEAR_BOARD_OK=0
HERDR_LINEAR_BOARD_ABSENT=1
HERDR_LINEAR_BOARD_REFUSED=2
HERDR_LINEAR_BOARD_LOCKED=3
HERDR_LINEAR_BOARD_UNREADABLE=4

herdr_linear::_board_refuse() {
    printf 'refused: %s\n' "$1" >&2
    return "$HERDR_LINEAR_BOARD_REFUSED"
}

herdr_linear::_board_path() {
    local family="${1:-}" key="${2:-}"
    herdr_linear::is_safe_identifier "$family" || return 1
    herdr_linear::is_safe_identifier "$key" || return 1
    printf '%s/board/%s/%s.json' "$HERDR_LINEAR_STORE_DIR" "$family" "$key"
}

# herdr_linear::_board_key_path <family> <key> [what the key is, for the refusal]
herdr_linear::_board_key_path() {
    local family="$1" key="${2:-}" what="${3:-issue id}"
    herdr_linear::is_safe_identifier "$key" \
        || { herdr_linear::_board_refuse "that $what is not a safe identifier"; return; }
    herdr_linear::_board_path "$family" "$key"
}

herdr_linear::_board_space_path() {
    local family="$1" space="${2:-}" key
    case "$space" in
        ''|*$'\n'*) herdr_linear::_board_refuse "a space name must be one non-empty line"; return ;;
    esac
    key="$(printf '%s' "$space" | shasum | cut -c1-16)"
    herdr_linear::is_safe_identifier "$key" || return "$HERDR_LINEAR_BOARD_REFUSED"
    herdr_linear::_board_path "$family" "$key"
}

herdr_linear::_board_sync_path() {
    printf '%s/board/sync-state.json' "$HERDR_LINEAR_STORE_DIR"
}

herdr_linear::_board_py() {
    HERDR_LINEAR_BOARD_RECORD_VERSION="$HERDR_LINEAR_BOARD_RECORD_VERSION" \
        python3 - "$@" <<'PYEOF'
import sys, json, os, secrets, datetime

VERSION = int(os.environ["HERDR_LINEAR_BOARD_RECORD_VERSION"])
ABSENT, REFUSED = 1, 2

def now():
    # Microseconds: sync-state times are compared as strings, and a write and a
    # sync inside one second must still order.
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

def refuse(msg):
    sys.stderr.write("refused: %s\n" % msg)
    sys.exit(REFUSED)

def is_bool(v): return isinstance(v, bool)
def is_str(v): return isinstance(v, str)
def is_count(v): return isinstance(v, int) and not is_bool(v) and v >= 0

SAFE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
ALNUM = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

def safe_id(s):
    return is_str(s) and s != "" and s[0] in ALNUM and all(c in SAFE for c in s)

def valid_groups(g):
    return isinstance(g, dict) and all(is_str(k) and (v is None or is_str(v)) for k, v in g.items())

def valid_reservation(r):
    return (all(is_str(r.get(k)) for k in ("issue_id", "identifier", "worktree_name", "branch"))
            and is_bool(r.get("repository_unknown")) and r.get("state") in ("reserved", "started"))

def valid_entry(e):
    return (isinstance(e, dict) and is_str(e.get("pane_id")) and e.get("role") in ("home", "pointer")
            and valid_groups(e.get("groups")) and is_bool(e.get("board_created"))
            and is_bool(e.get("hidden")) and is_str(e.get("hidden_fingerprint"))
            and is_bool(e.get("pending_linear_change"))
            and ("terminal_id" not in e or is_str(e["terminal_id"])))

def valid_ledger(r):
    return (is_str(r.get("space")) and isinstance(r.get("panes"), dict)
            and all(valid_entry(e) for e in r["panes"].values()))

def valid_question(r):
    return (all(is_str(r.get(k)) for k in ("key", "kind", "preconditions", "nonce"))
            and is_bool(r.get("declined")))

def valid_consent(r):
    return (is_str(r.get("space")) and isinstance(r.get("fields"), dict)
            and isinstance(r.get("proposals"), dict))

def valid_counts(c):
    return isinstance(c, dict) and all(is_str(k) and is_count(v) for k, v in c.items())

def valid_rendered(r):
    return isinstance(r, dict) and all(
        is_str(s) and isinstance(fields, dict) and all(
            is_str(f) and isinstance(vals, list) and all(v is None or is_str(v) for v in vals)
            for f, vals in fields.items())
        for s, fields in r.items())

def valid_sync(r):
    return (all(k not in r or is_str(r[k]) for k in
                ("last_complete_sync_at", "last_plugin_write_at", "behind_marked_at"))
            and ("members" not in r or (isinstance(r["members"], list) and all(safe_id(m) for m in r["members"])))
            and ("rendered" not in r or valid_rendered(r["rendered"])))

VALIDATORS = {"res": valid_reservation, "ledger": valid_ledger, "q": valid_question,
              "consent": valid_consent, "sync": valid_sync}

def load(path, family):
    """('missing'|'unusable'|'future'|'ok', record)."""
    if not path or not os.path.exists(path):
        return "missing", None
    try:
        with open(path) as fh:
            rec = json.load(fh)
    except Exception:
        return "unusable", None
    if not isinstance(rec, dict) or not isinstance(rec.get("version"), int) or is_bool(rec.get("version")):
        return "unusable", None
    if rec["version"] > VERSION:
        return "future", None
    if not VALIDATORS[family](rec):
        return "unusable", None
    return "ok", rec

def save(path, rec):
    rec["version"] = VERSION
    rec["updated_at"] = now()
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)

def for_read(path, family):
    status, rec = load(path, family)
    if status != "ok":
        sys.exit(ABSENT)
    return rec

def for_write(path, family, blank=None):
    """A future-version record is left exactly as found: a newer plugin wrote
    it and still reads it. An unusable one is replaced, as the binding store
    does."""
    status, rec = load(path, family)
    if status == "future":
        refuse("the record was written by a newer version of the plugin and is left as it is: %s" % path)
    if status == "ok":
        return rec
    if blank is None:
        sys.exit(ABSENT)
    return blank

def canonical(pre):
    try:
        return json.dumps(json.loads(pre), sort_keys=True, separators=(",", ":"))
    except Exception:
        return pre

op, path, args = sys.argv[1], sys.argv[2], sys.argv[3:]

# ---- reservations

if op == "res-read":
    sys.stdout.write(json.dumps(for_read(path, "res"), sort_keys=True))
    sys.exit(0)

if op == "res-field":
    v = for_read(path, "res").get(args[0])
    sys.stdout.write("" if v is None else (v if is_str(v) else json.dumps(v)))
    sys.exit(0)

if op == "res-reserve":
    issue, identifier, name, branch, unknown = args
    rec = for_write(path, "res", blank={
        "issue_id": issue, "worktree_name": name, "branch": branch,
        "repository_unknown": unknown == "true", "state": "reserved", "reserved_at": now()})
    if rec["issue_id"] != issue:
        refuse("the reservation on disk belongs to another issue id")
    rec["identifier"] = identifier
    save(path, rec)
    sys.exit(0)

if op == "res-start":
    rec = for_write(path, "res")
    rec["state"] = "started"
    rec.setdefault("started_at", now())
    save(path, rec)
    sys.exit(0)

if op == "res-set-repo-unknown":
    rec = for_write(path, "res")
    rec["repository_unknown"] = args[0] == "true"
    save(path, rec)
    sys.exit(0)

if op == "res-remove":
    for_write(path, "res")
    os.remove(path)
    sys.exit(0)

# ---- pane ledger

def ledger_for_read(space):
    rec = for_read(path, "ledger")
    if rec["space"] != space:
        sys.exit(ABSENT)
    return rec

def ledger_for_write(space, create):
    rec = for_write(path, "ledger", blank={"space": space, "panes": {}} if create else None)
    if rec["space"] != space:
        refuse("the ledger file on disk belongs to another space name")
    return rec

def entry_for_write(space, issue):
    rec = ledger_for_write(space, False)
    if issue not in rec["panes"]:
        sys.exit(ABSENT)
    return rec, rec["panes"][issue]

if op == "ledger-entries":
    sys.stdout.write(json.dumps(ledger_for_read(args[0])["panes"], sort_keys=True))
    sys.exit(0)

if op == "ledger-entry":
    panes = ledger_for_read(args[0])["panes"]
    if args[1] not in panes:
        sys.exit(ABSENT)
    sys.stdout.write(json.dumps(panes[args[1]], sort_keys=True))
    sys.exit(0)

if op == "ledger-put":
    space, issue, pane, role, groups_json, created = args[:6]
    try:
        groups = json.loads(groups_json)
    except Exception:
        refuse("the group values are not JSON")
    if not valid_groups(groups):
        refuse("the group values must be an object of field to value or null")
    rec = ledger_for_write(space, True)
    old = rec["panes"].get(issue) or {}
    rec["panes"][issue] = {
        "pane_id": pane, "role": role, "groups": groups, "board_created": created == "true",
        "hidden": old.get("hidden", False), "hidden_fingerprint": old.get("hidden_fingerprint", ""),
        "pending_linear_change": False,
    }
    terminal = args[6] if len(args) > 6 and args[6] else old.get("terminal_id")
    if terminal:
        rec["panes"][issue]["terminal_id"] = terminal
    save(path, rec)
    sys.exit(0)

if op == "ledger-set-pane":
    rec, e = entry_for_write(args[0], args[1])
    e["pane_id"] = args[2]
    if args[3]:
        e["terminal_id"] = args[3]
    save(path, rec)
    sys.exit(0)

if op == "ledger-remove":
    rec, _ = entry_for_write(args[0], args[1])
    del rec["panes"][args[1]]
    save(path, rec)
    sys.exit(0)

if op == "ledger-hide":
    rec, e = entry_for_write(args[0], args[1])
    e["hidden"], e["hidden_fingerprint"] = True, args[2]
    save(path, rec)
    sys.exit(0)

if op == "ledger-unhide":
    rec, e = entry_for_write(args[0], args[1])
    e["hidden"], e["hidden_fingerprint"] = False, ""
    save(path, rec)
    sys.exit(0)

if op == "ledger-hidden":
    e = ledger_for_read(args[0])["panes"].get(args[1])
    sys.exit(0 if e and e["hidden"] and e["hidden_fingerprint"] == args[2] else 1)

if op == "ledger-mark-linear-change":
    rec, e = entry_for_write(args[0], args[1])
    e["pending_linear_change"] = True
    save(path, rec)
    sys.exit(0)

# ---- pending questions

if op == "q-propose":
    key, kind, pre = args[0], args[1], canonical(args[2])
    rec = for_write(path, "q", blank={})
    if rec and rec["kind"] == kind and rec["preconditions"] == pre:
        if rec["declined"]:
            refuse("this question was declined and its preconditions have not changed")
        sys.stdout.write(rec["nonce"])
        sys.exit(0)
    rec = {"key": key, "kind": kind, "preconditions": pre, "nonce": secrets.token_hex(16),
           "declined": False, "recorded_at": now()}
    save(path, rec)
    sys.stdout.write(rec["nonce"])
    sys.exit(0)

def question_answerable(rec, nonce):
    if not nonce or rec["nonce"] != nonce:
        refuse("the nonce does not match the question as recorded")
    if rec["declined"]:
        refuse("this question was declined")

if op == "q-answer":
    rec = for_write(path, "q")
    question_answerable(rec, args[0])
    if rec["preconditions"] != canonical(args[1]):
        refuse("the question's preconditions no longer hold")
    os.remove(path)
    sys.exit(0)

if op == "q-decline":
    rec = for_write(path, "q")
    question_answerable(rec, args[0])
    rec["declined"] = True
    rec["declined_at"] = now()
    save(path, rec)
    sys.exit(0)

if op == "q-drop":
    for_write(path, "q")
    os.remove(path)
    sys.exit(0)

if op == "q-read":
    sys.stdout.write(json.dumps(for_read(path, "q"), sort_keys=True))
    sys.exit(0)

if op == "q-pending":
    out = []
    for f in [path] + args:
        status, rec = load(f, "q")
        if status == "ok" and not rec["declined"]:
            out.append({k: rec[k] for k in ("key", "kind", "preconditions", "nonce")})
    for q in sorted(out, key=lambda q: q["key"]):
        sys.stdout.write(json.dumps(q, sort_keys=True) + "\n")
    sys.exit(0)

# ---- space consent

def consent_for_write(space):
    rec = for_write(path, "consent", blank={"space": space, "fields": {}, "proposals": {}})
    if rec["space"] != space:
        refuse("the consent file on disk belongs to another space name")
    return rec

if op == "consent-covers":
    rec = for_read(path, "consent")
    sys.exit(0 if rec["space"] == args[0] and isinstance(rec["fields"].get(args[1]), dict) else 1)

if op == "consent-propose":
    space, field = args
    rec = consent_for_write(space)
    nonce = secrets.token_hex(16)
    rec["proposals"][field] = {"nonce": nonce, "presented_at": now()}
    save(path, rec)
    sys.stdout.write(nonce)
    sys.exit(0)

if op in ("consent-confirm", "consent-decline"):
    space, field, nonce = args
    rec = consent_for_write(space)
    p = rec["proposals"].get(field)
    if not isinstance(p, dict) or not nonce or p.get("nonce") != nonce:
        refuse("the nonce does not match a consent question for this space and field")
    del rec["proposals"][field]
    if op == "consent-confirm":
        rec["fields"][field] = {"answered_at": now()}
    save(path, rec)
    sys.exit(0)

# ---- sync state

def behind(rec):
    last = rec.get("last_complete_sync_at")
    if not last:
        return True
    return any(rec.get(k) and rec[k] > last for k in ("last_plugin_write_at", "behind_marked_at"))

if op == "sync-read":
    rec = for_read(path, "sync")
    rec["behind"] = behind(rec)
    sys.stdout.write(json.dumps(rec, sort_keys=True))
    sys.exit(0)

if op == "sync-behind":
    status, rec = load(path, "sync")
    sys.exit(0 if status != "ok" or behind(rec) else 1)

if op == "sync-complete":
    try:
        doc = json.loads(args[0])
    except Exception:
        refuse("the sync document is not JSON")
    expected = {"observed", "unknown", "pending_questions", "members", "rendered"}
    if not isinstance(doc, dict) or set(doc) != expected:
        refuse("the sync document must hold exactly: %s" % ", ".join(sorted(expected)))
    if not (valid_counts(doc["observed"]) and valid_counts(doc["unknown"])
            and is_count(doc["pending_questions"])
            and isinstance(doc["members"], list) and all(safe_id(m) for m in doc["members"])
            and valid_rendered(doc["rendered"])):
        refuse("the sync document has a malformed count, member id or rendered group")
    rec = for_write(path, "sync", blank={})
    rec.update(doc)
    rec["members"] = sorted(set(doc["members"]))
    rec["last_complete_sync_at"] = now()
    save(path, rec)
    sys.exit(0)

if op in ("sync-record-write", "sync-mark-behind"):
    rec = for_write(path, "sync", blank={})
    rec["last_plugin_write_at" if op == "sync-record-write" else "behind_marked_at"] = now()
    save(path, rec)
    sys.exit(0)

if op == "sync-failed":
    rec = for_write(path, "sync", blank={})
    rec["last_failure"] = {"stage": args[0], "message": args[1], "at": now()}
    save(path, rec)
    sys.exit(0)

# ---- board consent gate

if op == "gate":
    consented, safe, space, field, issue, value = args
    reasons = []
    if consented != "0":
        reasons.append("no consent for this field in this space")
    status, rec = load(path, "sync")
    if status != "ok" or not rec.get("last_complete_sync_at"):
        reasons.append("no complete filter read is recorded")
    else:
        if safe != "0":
            reasons.append("issue id is not a safe identifier")
        elif issue not in rec.get("members", []):
            reasons.append("ticket is not in the last complete filter read")
        if value not in rec.get("rendered", {}).get(space, {}).get(field, []):
            reasons.append("target group was not rendered by the board")
    if not reasons:
        sys.exit(0)
    # json.dumps keeps Linear-authored text to one escaped line in the log.
    sys.stdout.write("SHADOW board would set %s to %s on %s in %s: %s" % (
        json.dumps(field), json.dumps(value), json.dumps(issue), json.dumps(space), "; ".join(reasons)))
    sys.exit(1)

sys.exit(64)
PYEOF
}

herdr_linear::_board_read() {
    local f="$1" op="$2"
    shift 2
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    [ -r "$f" ] || return "$HERDR_LINEAR_BOARD_UNREADABLE"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_py "$op" "$f" "$@"
}

herdr_linear::_board_mutate() {
    local f="$1" op="$2" dir rc
    shift 2
    case "$f" in
        "$HERDR_LINEAR_STORE_DIR"/board/*.json) ;;
        *) herdr_linear::_board_refuse "a board record lives under the board store"; return ;;
    esac
    herdr_linear::is_safe_identifier "$(basename "$f" .json)" \
        || { herdr_linear::_board_refuse "that record name is not a safe identifier"; return; }
    dir="${f%/*}"
    mkdir -p "$dir" 2>/dev/null || return "$HERDR_LINEAR_BOARD_ABSENT"
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_STORE_DIR/board" "$dir" 2>/dev/null
    herdr_linear::_lock "$f" || return "$HERDR_LINEAR_BOARD_LOCKED"
    if [ "${HERDR_LINEAR_LOCK_HOLD_MS:-0}" -gt 0 ] 2>/dev/null; then
        perl -e "select undef, undef, undef, ${HERDR_LINEAR_LOCK_HOLD_MS}/1000" 2>/dev/null
    fi
    if [ -e "$f" ] && [ ! -r "$f" ]; then
        herdr_linear::_unlock "$f"
        herdr_linear::_board_refuse "the record cannot be read: $f"
        return "$HERDR_LINEAR_BOARD_UNREADABLE"
    fi
    # Not repaired by writing through it: something else can write this file.
    if [ -e "$f" ] && ! herdr_linear::_mode_ok "$f"; then
        herdr_linear::_unlock "$f"
        herdr_linear::_board_refuse "the record's owner or mode is wrong: $f"
        return
    fi
    herdr_linear::_board_py "$op" "$f" "$@"
    rc=$?
    [ -e "$f" ] && chmod 600 "$f" 2>/dev/null
    herdr_linear::_unlock "$f"
    return "$rc"
}

herdr_linear::_board_bool() {
    case "${1:-}" in
        true|false) return 0 ;;
    esac
    herdr_linear::_board_refuse "a flag must be true or false"
}

herdr_linear::_board_safe_branch() {
    local rest="${1:-}" seg
    case "$rest" in ''|/*|*/|*//*) return 1 ;; esac
    while :; do
        seg="${rest%%/*}"
        herdr_linear::is_safe_identifier "$seg" || return 1
        case "$seg" in *.lock|*..*) return 1 ;; esac
        [ "$seg" = "$rest" ] && return 0
        rest="${rest#*/}"
    done
}

# ------------------------------------------------------------- reservations

# herdr_linear::board_reserve <issue_id> <identifier> <worktree_name> <branch> <repository_unknown true|false>
# The first reservation fixes the worktree name and branch; a later call only
# updates the display identifier.
herdr_linear::board_reserve() {
    local issue="${1:-}" identifier="${2:-}" name="${3:-}" branch="${4:-}" unknown="${5:-false}" f
    f="$(herdr_linear::_board_key_path reservations "$issue")" || return
    herdr_linear::is_safe_identifier "$identifier" \
        || { herdr_linear::_board_refuse "that identifier is not a safe identifier"; return; }
    herdr_linear::is_safe_identifier "$name" \
        || { herdr_linear::_board_refuse "that worktree name is not a safe identifier"; return; }
    herdr_linear::_board_safe_branch "$branch" \
        || { herdr_linear::_board_refuse "that branch has an unsafe segment"; return; }
    herdr_linear::_board_bool "$unknown" || return
    herdr_linear::_board_mutate "$f" res-reserve "$issue" "$identifier" "$name" "$branch" "$unknown"
}

herdr_linear::board_reservation() {
    local f
    f="$(herdr_linear::_board_key_path reservations "${1:-}")" || return
    herdr_linear::_board_read "$f" res-read
}

herdr_linear::board_reservation_field() {
    local f
    f="$(herdr_linear::_board_key_path reservations "${1:-}")" || return
    herdr_linear::_board_read "$f" res-field "${2:-}"
}

herdr_linear::board_reservation_start() {
    local f
    f="$(herdr_linear::_board_key_path reservations "${1:-}")" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" res-start
}

herdr_linear::board_reservation_set_repo_unknown() {
    local f
    f="$(herdr_linear::_board_key_path reservations "${1:-}")" || return
    herdr_linear::_board_bool "${2:-}" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" res-set-repo-unknown "$2"
}

herdr_linear::board_reservation_remove() {
    local f
    f="$(herdr_linear::_board_key_path reservations "${1:-}")" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" res-remove
}

# ------------------------------------------------------------- pane ledger

# herdr_linear::board_ledger_put <space> <issue_id> <pane_id> <home|pointer> <groups-json> <board_created true|false> [terminal_id]
# Records a pane as observed at a completed sync. Group values change only
# here (KTD4), and writing them clears a pending Linear change. Without a
# terminal id the one already recorded is kept.
herdr_linear::board_ledger_put() {
    local space="${1:-}" issue="${2:-}" pane="${3:-}" role="${4:-}" groups="${5:-}" created="${6:-}" terminal="${7:-}" f
    herdr_linear::is_safe_identifier "$issue" \
        || { herdr_linear::_board_refuse "that issue id is not a safe identifier"; return; }
    herdr_linear::_board_pane_ref "pane id" "$pane" || return
    [ -z "$terminal" ] || herdr_linear::_board_pane_ref "terminal id" "$terminal" || return
    case "$role" in
        home|pointer) ;;
        *) herdr_linear::_board_refuse "a ledger role is home or pointer"; return ;;
    esac
    herdr_linear::_board_bool "$created" || return
    f="$(herdr_linear::_board_space_path ledger "$space")" || return
    herdr_linear::_board_mutate "$f" ledger-put "$space" "$issue" "$pane" "$role" "$groups" "$created" "$terminal"
}

herdr_linear::_board_pane_ref() {
    case "${2:-}" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_.-]*)
            herdr_linear::_board_refuse "that $1 has characters outside letters, digits and :_.-"; return ;;
    esac
}

# herdr_linear::board_ledger_set_pane <space> <issue_id> <pane_id> [terminal_id]
# Where the pane is now, after a move renamed it or a restart renewed its
# terminal. Groups, hidden and a pending Linear change are left as they are.
herdr_linear::board_ledger_set_pane() {
    herdr_linear::_board_pane_ref "pane id" "${3:-}" || return
    [ -z "${4:-}" ] || herdr_linear::_board_pane_ref "terminal id" "$4" || return
    herdr_linear::_board_ledger_op ledger-set-pane "${1:-}" "${2:-}" "$3" "${4:-}"
}

herdr_linear::_board_ledger_op() {
    local op="$1" space="${2:-}" issue="${3:-}" f
    shift 3
    herdr_linear::is_safe_identifier "$issue" \
        || { herdr_linear::_board_refuse "that issue id is not a safe identifier"; return; }
    f="$(herdr_linear::_board_space_path ledger "$space")" || return
    case "$op" in
        ledger-entry|ledger-hidden)
            herdr_linear::_board_read "$f" "$op" "$space" "$issue" "$@" ;;
        *)
            [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
            herdr_linear::_board_mutate "$f" "$op" "$space" "$issue" "$@" ;;
    esac
}

herdr_linear::board_ledger_entry() {
    herdr_linear::_board_ledger_op ledger-entry "${1:-}" "${2:-}"
}

herdr_linear::board_ledger_entries() {
    local space="${1:-}" f
    f="$(herdr_linear::_board_space_path ledger "$space")" || return
    herdr_linear::_board_read "$f" ledger-entries "$space"
}

herdr_linear::board_ledger_remove() {
    herdr_linear::_board_ledger_op ledger-remove "${1:-}" "${2:-}"
}

# herdr_linear::board_ledger_hide <space> <issue_id> <fingerprint>
# The fingerprint is whatever marks the ticket as changed, such as updatedAt.
herdr_linear::board_ledger_hide() {
    herdr_linear::_board_ledger_op ledger-hide "${1:-}" "${2:-}" "${3:-}"
}

herdr_linear::board_ledger_unhide() {
    herdr_linear::_board_ledger_op ledger-unhide "${1:-}" "${2:-}"
}

# 0 while the ticket is hidden and its fingerprint is the one it was hidden at.
herdr_linear::board_ledger_hidden() {
    herdr_linear::_board_ledger_op ledger-hidden "${1:-}" "${2:-}" "${3:-}"
}

herdr_linear::board_ledger_mark_linear_change() {
    herdr_linear::_board_ledger_op ledger-mark-linear-change "${1:-}" "${2:-}"
}

# ------------------------------------------------------------- pending questions

# herdr_linear::board_question_propose <key> <kind> <preconditions>
# Prints the nonce. Re-recording the same open question keeps its nonce, so an
# unattended sync does not invalidate a question already on screen.
herdr_linear::board_question_propose() {
    local key="${1:-}" kind="${2:-}" f
    f="$(herdr_linear::_board_key_path questions "$key" "question key")" || return
    [ -n "$kind" ] || { herdr_linear::_board_refuse "a question needs a kind"; return; }
    herdr_linear::_board_mutate "$f" q-propose "$key" "$kind" "${3:-}"
}

# herdr_linear::board_question_answer <key> <nonce> <current-preconditions>
herdr_linear::board_question_answer() {
    local f
    f="$(herdr_linear::_board_key_path questions "${1:-}" "question key")" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" q-answer "${2:-}" "${3:-}"
}

herdr_linear::board_question_decline() {
    local f
    f="$(herdr_linear::_board_key_path questions "${1:-}" "question key")" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" q-decline "${2:-}"
}

herdr_linear::board_question_drop() {
    local f
    f="$(herdr_linear::_board_key_path questions "${1:-}" "question key")" || return
    [ -e "$f" ] || return "$HERDR_LINEAR_BOARD_ABSENT"
    herdr_linear::_board_mutate "$f" q-drop
}

herdr_linear::board_question() {
    local f
    f="$(herdr_linear::_board_key_path questions "${1:-}" "question key")" || return
    herdr_linear::_board_read "$f" q-read
}

# One JSON object per line for every open question, sorted by key.
herdr_linear::board_questions_pending() {
    local f
    local -a usable=()
    for f in "$HERDR_LINEAR_STORE_DIR"/board/questions/*.json; do
        [ -f "$f" ] && [ -r "$f" ] || continue
        herdr_linear::_mode_ok "$f" || continue
        usable+=("$f")
    done
    [ "${#usable[@]}" -gt 0 ] || return 0
    herdr_linear::_board_py q-pending "${usable[@]}"
}

# ------------------------------------------------------------- space consent

herdr_linear::board_consent_propose() {
    local space="${1:-}" field="${2:-}" f
    [ -n "$field" ] || { herdr_linear::_board_refuse "consent needs a field"; return; }
    f="$(herdr_linear::_board_space_path consent "$space")" || return
    herdr_linear::_board_mutate "$f" consent-propose "$space" "$field"
}

herdr_linear::board_consent_confirm() {
    local space="${1:-}" field="${2:-}" f
    [ -n "$field" ] || { herdr_linear::_board_refuse "consent needs a field"; return; }
    f="$(herdr_linear::_board_space_path consent "$space")" || return
    [ -e "$f" ] || { herdr_linear::_board_refuse "no consent question was asked for this space"; return; }
    herdr_linear::_board_mutate "$f" consent-confirm "$space" "$field" "${3:-}"
}

herdr_linear::board_consent_decline() {
    local space="${1:-}" field="${2:-}" f
    [ -n "$field" ] || { herdr_linear::_board_refuse "consent needs a field"; return; }
    f="$(herdr_linear::_board_space_path consent "$space")" || return
    [ -e "$f" ] || { herdr_linear::_board_refuse "no consent question was asked for this space"; return; }
    herdr_linear::_board_mutate "$f" consent-decline "$space" "$field" "${3:-}"
}

# Never writes, never locks: it is on the path of every write-back.
herdr_linear::board_consent_covers() {
    local space="${1:-}" field="${2:-}" f
    [ -n "$field" ] || return 1
    f="$(herdr_linear::_board_space_path consent "$space" 2>/dev/null)" || return 1
    herdr_linear::_board_read "$f" consent-covers "$space" "$field"
}

# ------------------------------------------------------------- sync state

# herdr_linear::board_sync_complete <json>
# {"observed":{name:int},"unknown":{name:int},"pending_questions":int,
#  "members":[issue ids],"rendered":{space:{field:[values]}}}
# Only a complete filter read may call this (KTD9): its members and rendered
# groups are what the board consent gate allows writes against.
herdr_linear::board_sync_complete() {
    herdr_linear::_board_mutate "$(herdr_linear::_board_sync_path)" sync-complete "${1:-}"
}

# herdr_linear::board_sync_failed <stage> <message>
herdr_linear::board_sync_failed() {
    herdr_linear::_board_mutate "$(herdr_linear::_board_sync_path)" sync-failed "${1:-}" "${2:-}"
}

herdr_linear::board_record_linear_write() {
    herdr_linear::_board_mutate "$(herdr_linear::_board_sync_path)" sync-record-write
}

herdr_linear::board_mark_behind() {
    herdr_linear::_board_mutate "$(herdr_linear::_board_sync_path)" sync-mark-behind
}

# The record with a computed `behind`.
herdr_linear::board_sync_state() {
    herdr_linear::_board_read "$(herdr_linear::_board_sync_path)" sync-read
}

# 0 when the board may be behind Linear. A missing or unusable record is behind:
# nothing proves a complete sync happened.
herdr_linear::board_behind() {
    local f
    f="$(herdr_linear::_board_sync_path)"
    { [ -f "$f" ] && [ -r "$f" ] && herdr_linear::_mode_ok "$f"; } || return 0
    herdr_linear::_board_py sync-behind "$f"
}

# ------------------------------------------------------------- board consent gate

# herdr_linear::board_consent_gate <space> <field> <issue_id> <target_value>
#   0  the space consented to this field, the ticket is in the last complete
#      filter read, and the target is a group the board rendered (KTD8)
#   1  refused; exactly one shadow log line names every failed fact
herdr_linear::board_consent_gate() {
    local space="${1:-}" field="${2:-}" issue="${3:-}" value="${4:-}" f consented=1 safe=1 line
    herdr_linear::board_consent_covers "$space" "$field" && consented=0
    herdr_linear::is_safe_identifier "$issue" && safe=0
    f="$(herdr_linear::_board_sync_path)"
    { [ -f "$f" ] && [ -r "$f" ] && herdr_linear::_mode_ok "$f"; } || f=""
    line="$(herdr_linear::_board_py gate "$f" "$consented" "$safe" "$space" "$field" "$issue" "$value")" && return 0
    # A gate that crashed must still refuse, and still leave its line.
    [ -n "$line" ] || line="SHADOW board would set a field: the gate could not evaluate its facts"
    herdr_linear::_shadow_log "$line"
    return 1
}

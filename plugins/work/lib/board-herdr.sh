#!/usr/bin/env bash
# The herdr board writer: creates, moves, closes and labels the board's own
# panes, and nothing else (R13). Sourced, never executed.
#
# Facts this file is built on, from docs/board-spikes.md:
#   * `layout.apply` kills every process in the tab, so a tab is built from
#     chained `pane.move` calls and never applied (KTD5).
#   * The CLI `pane move` takes focus. Moves go over the socket with
#     focus:false, so a sync never pulls a person out of the pane they type in.
#   * A move inside a pane's own tab does nothing (same_tab); reordering goes
#     through a scratch tab that closes itself when its last pane leaves.
#   * A move to another workspace renames the pane; its terminal id and label
#     stay. A restart keeps pane ids and renews terminal ids. So every board
#     pane carries a label, and a pane is found by id, then terminal, then label.
#   * The last pane leaving a tab closes the tab.
# Every effect is read back. One that cannot be observed is UNKNOWN, never OK.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::probe >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/herdr-read.sh"
command -v herdr_linear::board_ledger_entry >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-store.sh"

HERDR_LINEAR_BOARD_PANE_OK=0
HERDR_LINEAR_BOARD_PANE_NO_SERVER=1
HERDR_LINEAR_BOARD_PANE_REFUSED=2
HERDR_LINEAR_BOARD_PANE_UNKNOWN=3
HERDR_LINEAR_BOARD_PANE_FAILED=4
HERDR_LINEAR_BOARD_PANE_IN_USE=5
HERDR_LINEAR_BOARD_PANE_GONE=6

# KTD11: 120x40 cells at a readable 30x10 per pane is four by four.
HERDR_LINEAR_BOARD_PANE_CAP="${HERDR_LINEAR_BOARD_PANE_CAP:-16}"
HERDR_LINEAR_BOARD_METADATA_SOURCE="work-board"

herdr_linear::_board_pane_refuse() {
    printf 'refused: %s\n' "$1" >&2
    return "$HERDR_LINEAR_BOARD_PANE_REFUSED"
}

# herdr_linear::board_pane_label <issue_id> <home|pointer> [space]
# A pointer's label carries its space, because every claiming space has one.
herdr_linear::board_pane_label() {
    local issue="${1:-}" role="${2:-}" space="${3:-}" key
    herdr_linear::is_safe_identifier "$issue" \
        || { herdr_linear::_board_pane_refuse "that issue id is not a safe identifier"; return; }
    case "$role" in
        home) printf 'work:%s' "$issue" ;;
        pointer)
            case "$space" in
                ''|*$'\n'*) herdr_linear::_board_pane_refuse "a pointer label needs its space name"; return ;;
            esac
            key="$(printf '%s' "$space" | shasum | cut -c1-16)"
            printf 'work:%s:pointer:%s' "$issue" "$key"
            ;;
        *) herdr_linear::_board_pane_refuse "a board pane is home or pointer"; return ;;
    esac
}

# The socket the CLI talks to, from `status server`. HERDR_LINEAR_SOCKET_PATH
# overrides it. Nothing, and non-zero, when neither names one.
herdr_linear::board_socket_path() {
    local line
    if [ -n "${HERDR_LINEAR_SOCKET_PATH:-}" ]; then
        printf '%s' "$HERDR_LINEAR_SOCKET_PATH"
        return 0
    fi
    herdr_linear::probe || return 1
    line="$(printf '%s\n' "$HERDR_LINEAR_PROBE_OUT" | sed -n 's/^socket: //p' | head -n1)"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

herdr_linear::_board_placeholders() {
    local d="${HERDR_LINEAR_JOURNAL_DIR:-$HOME/.claude/work/layouts}"
    mkdir -p "$d" 2>/dev/null
    printf '%s/board-placeholders' "$d"
}

herdr_linear::_board_invoking() {
    printf '%s %s' "${HERDR_PANE_ID:-}" "$(herdr_linear::pane_id 2>/dev/null)"
}

# <space> <issue> [require-owned] -> `<label>\t<pane_id>` from the ledger.
herdr_linear::_board_owned() {
    local space="$1" issue="$2" entry rc fields
    entry="$(herdr_linear::board_ledger_entry "$space" "$issue" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { herdr_linear::_board_pane_refuse "the board has no pane for $issue in $space"; return; }
    fields="$(printf '%s' "$entry" | python3 -c 'import sys, json
e = json.load(sys.stdin)
print("%s\t%s\t%s" % (e["role"], e["pane_id"], "true" if e["board_created"] else "false"))')" \
        || { herdr_linear::_board_pane_refuse "the ledger entry for $issue cannot be read"; return; }
    if [ "${3:-owned}" = owned ] && [ "$(printf '%s' "$fields" | cut -f3)" != true ]; then
        herdr_linear::_board_pane_refuse "the board did not create the pane for $issue; it is never moved or closed"
        return
    fi
    printf '%s\t%s' "$(herdr_linear::board_pane_label "$issue" "$(printf '%s' "$fields" | cut -f1)" "$space")" \
        "$(printf '%s' "$fields" | cut -f2)"
}

herdr_linear::_board_ready() {
    herdr_linear::probe || { printf 'the herdr server is not running; nothing was changed\n' >&2; return "$HERDR_LINEAR_BOARD_PANE_NO_SERVER"; }
    [ -n "$(herdr_linear::bin)" ] || return "$HERDR_LINEAR_BOARD_PANE_NO_SERVER"
}

# ---------------------------------------------------------------- reads

# herdr_linear::board_locate <space> <issue_id>
# `<pane_id>\t<terminal_id>\t<tab_id>\t<workspace_id>`; GONE when the snapshot
# holds no such pane, UNKNOWN when it cannot be read.
herdr_linear::board_locate() {
    local owned
    owned="$(herdr_linear::_board_owned "${1:-}" "${2:-}" any)" || return
    herdr_linear::_board_herdr_py find "$(printf '%s' "$owned" | cut -f1)" "$(printf '%s' "$owned" | cut -f2)" ""
}

# herdr_linear::board_in_use <pane_id>
# 0 and the reasons (invoking, focused, agent) when in use; 1 when not; UNKNOWN
# when the snapshot cannot be read. A pane with any detected agent counts,
# whatever its status (KTD3).
herdr_linear::board_in_use() {
    HL_INVOKING="$(herdr_linear::_board_invoking)" herdr_linear::_board_herdr_py in-use "${1:-}"
}

# herdr_linear::board_tab_columns <tab_id>
# The tab as JSON columns of rows, from `layout.export`. 1 when the tree is not
# a chain of columns each a chain of rows (a conflict, never a write-back);
# GONE for no such tab; UNKNOWN when the layout cannot be read.
herdr_linear::board_tab_columns() {
    herdr_linear::_board_herdr_py columns "${1:-}"
}

# ---------------------------------------------------------------- create

# herdr_linear::board_create_pane <space> <issue_id> <home|pointer> <dir> <placement>
# placement: split:<pane_id>:<right|down> or tab:<workspace_id>:<tab label>
# A reserved or pointer pane: a shell in <dir>, which must exist and must not be
# inside a git work tree, labelled, never focused. A pointer pane carries
# HERDR_LINEAR_BOARD_HOME so it can reach its home pane through
# board_focus_home. Prints `<pane_id>\t<terminal_id>\t<tab_id>\t<workspace_id>`;
# UNKNOWN when the pane or its label cannot be read back.
herdr_linear::board_create_pane() {
    local space="${1:-}" issue="${2:-}" role="${3:-}" dir="${4:-}" placement="${5:-}" label rest rc
    label="$(herdr_linear::board_pane_label "$issue" "$role" "$space")" || return
    [ -d "$dir" ] || { herdr_linear::_board_pane_refuse "a board pane opens in an existing directory; $dir is not one"; return; }
    if "${HERDR_LINEAR_GIT_BIN:-git}" -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        herdr_linear::_board_pane_refuse "$dir is inside a git work tree; a reserved pane holds no worktree shell"
        return
    fi
    case "$placement" in
        split:*:right|split:*:down)
            rest="${placement#split:}"
            set -- split "${rest%:*}" "${rest##*:}" ;;
        tab:?*)
            rest="${placement#tab:}"
            set -- tab "${rest%%:*}" "$( [ "$rest" = "${rest#*:}" ] || printf '%s' "${rest#*:}")" ;;
        *) herdr_linear::_board_pane_refuse "a placement is split:<pane>:<right|down> or tab:<workspace>:<label>"; return ;;
    esac
    herdr_linear::_board_ready || return
    HL_ISSUE="$issue" HL_ROLE="$role" HL_DIR="$dir" herdr_linear::_board_herdr_py create "$label" "$@"; rc=$?
    return "$rc"
}

# ---------------------------------------------------------------- move

herdr_linear::_board_move() {
    local allow="$1" space="$2" issue="$3" tab="$4" dir="${5:-}" target="${6:-}" owned
    case "$tab" in
        new:?*:*) ;;
        *)
            case "$dir" in right|down) ;; *) herdr_linear::_board_pane_refuse "a split is right or down"; return ;; esac
            [ -n "$tab" ] && [ -n "$target" ] || { herdr_linear::_board_pane_refuse "a move names its tab and target pane"; return; } ;;
    esac
    owned="$(herdr_linear::_board_owned "$space" "$issue")" || return
    herdr_linear::_board_ready || return
    HL_INVOKING="$(herdr_linear::_board_invoking)" herdr_linear::_board_herdr_py move \
        "$issue" "$(printf '%s' "$owned" | cut -f1)" "$(printf '%s' "$owned" | cut -f2)" "$tab" "$dir" "$target" "$allow"
}

# herdr_linear::board_move_pane <space> <issue_id> <tab_id> <right|down> <target_pane_id>
# herdr_linear::board_move_pane <space> <issue_id> new:<workspace_id>:<label>
# `<issue>\t<pane_id>\t<terminal_id>\t<tab_id>\t<workspace_id>\t<moved|same_tab>\t<closed_tab_id>`.
# IN_USE, and nothing moved, when the pane is in use (R19).
herdr_linear::board_move_pane() {
    herdr_linear::_board_move no "$@"
}

# The same move for a pane in use, after a person said yes. Never from a hook.
herdr_linear::board_move_in_use() {
    herdr_linear::_board_move yes "$@"
}

# ---------------------------------------------------------------- apply

herdr_linear::_board_apply() {
    local allow="$1" space="$2" tab="$3" tree="$4" keys key owned panes="" held="" arg rc
    local -a kept=()
    shift 4
    [ -n "$tab" ] || { herdr_linear::_board_pane_refuse "an apply names its tab"; return; }
    keys="$(herdr_linear::_board_herdr_py keys "$tree")" || return
    for key in $keys; do
        owned="$(herdr_linear::_board_owned "$space" "$key")" || return
        panes="$panes$key"$'\t'"$owned"$'\n'
    done
    for arg in "$@"; do
        case "$arg" in
            held:*)
                local IFS=,
                for key in ${arg#held:}; do
                    owned="$(herdr_linear::_board_owned "$space" "$key" any 2>/dev/null)" || continue
                    held="$held$key"$'\t'"$owned"$'\n'
                done
                unset IFS ;;
            *) kept+=("$arg") ;;
        esac
    done
    set -- ${kept[@]+"${kept[@]}"}
    if [ "$#" -gt 0 ] && [ ! -d "${HERDR_LINEAR_WORKTREES_ROOT:-}" ]; then
        herdr_linear::_board_pane_refuse "a kept tab's placeholder opens in the worktrees root, and it is not a directory"
        return
    fi
    herdr_linear::_board_ready || return
    HL_INVOKING="$(herdr_linear::_board_invoking)" HL_PLACEHOLDERS="$(herdr_linear::_board_placeholders)" \
        HL_DIR="${HERDR_LINEAR_WORKTREES_ROOT:-}" HL_HELD="$held" \
        herdr_linear::_board_herdr_py apply "$tab" "$tree" "$panes" "$allow" "$@"; rc=$?
    return "$rc"
}

# herdr_linear::board_apply_tab <space> <tab_id|new:<workspace_id>:<label>> <columns-json> [kept_tab_id...] [held:<issue>,...]
# Builds the tab as columns of rows (`[["issue",...],...]`, left to right, top
# to bottom) by chained moves: column heads first, then rows under them. The
# tab keeps a pane throughout. A kept tab that would lose its last pane gets a
# placeholder, which its own apply closes. Prints one line per ticket:
# `<issue>\t<pane_id>\t<terminal_id>\t<tab_id>\t<workspace_id>`.
# A held ticket's pane is never moved. Held and outside the tab, it is left out
# of the tab. Held inside the tab and not its first pane, it keeps a column of
# its own on the left and the columns are built to its right, because herdr
# splits only right and down: the tab then reads back as the held columns
# followed by the columns asked for. Held panes stacked in one column leave no
# room for that, and are IN_USE with nothing moved, one `<issue>\theld` line each.
# REFUSED before anything moves for a ticket the board did not create, a pane in
# the tab the board does not own, or more panes than the cap; IN_USE when any
# pane that would move is in use; UNKNOWN when the result cannot be read back.
herdr_linear::board_apply_tab() {
    herdr_linear::_board_apply no "$@"
}

herdr_linear::board_apply_tab_in_use() {
    herdr_linear::_board_apply yes "$@"
}

# ---------------------------------------------------------------- close

# herdr_linear::board_close_pane <space> <issue_id>
# Only a pane the ledger marks board-created (R13). GONE when it was already
# closed; UNKNOWN when the close cannot be read back. The ledger is the caller's.
herdr_linear::board_close_pane() {
    local owned
    owned="$(herdr_linear::_board_owned "${1:-}" "${2:-}")" || return
    herdr_linear::_board_ready || return
    herdr_linear::_board_herdr_py close "$(printf '%s' "$owned" | cut -f1)" "$(printf '%s' "$owned" | cut -f2)"
}

# herdr_linear::board_focus_home <issue_id>
herdr_linear::board_focus_home() {
    local label
    label="$(herdr_linear::board_pane_label "${1:-}" home)" || return
    herdr_linear::_board_ready || return
    herdr_linear::_board_herdr_py focus "$label"
}

# ---------------------------------------------------------------- sync state

# herdr_linear::board_sync_title <sync-state-json>
herdr_linear::board_sync_title() {
    HL_STATE="${1:-}" python3 -c '
import json, os
try:
    s = json.loads(os.environ["HL_STATE"] or "{}")
except ValueError:
    s = {}
f = s.get("last_failure")
done = s.get("last_complete_sync_at")
if f and (not done or str(f.get("at", "")) >= str(done)):
    print("work board: sync failed at %s" % f.get("stage", "an unknown stage"))
elif not done:
    print("work board: never synced")
else:
    parts = ["behind Linear" if s.get("behind") else "matches Linear"]
    q = s.get("pending_questions") or 0
    if q:
        parts.append("%d question%s" % (q, "" if q == 1 else "s"))
    u = sum((s.get("unknown") or {}).values())
    if u:
        parts.append("%d unknown" % u)
    print("work board: " + " · ".join(parts))
'
}

# herdr_linear::board_show_sync_state <space>
# The sync-state record shown on every ledger pane of the space (KTD16). One
# `<issue>\t<ok|gone|unknown>` line per pane; UNKNOWN when any title could not be
# read back.
herdr_linear::board_show_sync_state() {
    local space="${1:-}" state entries issue owned rows="" title rc
    state="$(herdr_linear::board_sync_state 2>/dev/null)" || state=""
    title="$(herdr_linear::board_sync_title "$state")"
    entries="$(herdr_linear::board_ledger_entries "$space" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { herdr_linear::_board_pane_refuse "the board has no ledger for $space"; return; }
    for issue in $(printf '%s' "$entries" | python3 -c 'import sys, json; print("\n".join(sorted(json.load(sys.stdin))))'); do
        owned="$(herdr_linear::_board_owned "$space" "$issue" any)" || continue
        rows="$rows$issue"$'\t'"$owned"$'\n'
    done
    herdr_linear::_board_ready || return
    herdr_linear::_board_herdr_py metadata "$title" "$rows"
}

# ---------------------------------------------------------------- engine

herdr_linear::_board_herdr_py() {
    local bin sock=""
    bin="$(herdr_linear::bin)"
    [ -n "$bin" ] || return "$HERDR_LINEAR_BOARD_PANE_NO_SERVER"
    case "${1:-}" in
        columns|move|apply|focus) sock="$(herdr_linear::board_socket_path)" ;;
    esac
    HL_BIN="$bin" HL_SOCK="$sock" HL_CAP="$HERDR_LINEAR_BOARD_PANE_CAP" \
        HL_POLL_TRIES="${HERDR_LINEAR_PANE_POLL_TRIES:-40}" HL_POLL_MS="${HERDR_LINEAR_PANE_POLL_MS:-100}" \
        HL_SOURCE="$HERDR_LINEAR_BOARD_METADATA_SOURCE" python3 - "$@" <<'PYEOF'
import json, os, socket, subprocess, sys, time

OK, NO_SERVER, REFUSED, UNKNOWN, FAILED, IN_USE, GONE = 0, 1, 2, 3, 4, 5, 6
BIN, SOCK = os.environ["HL_BIN"], os.environ.get("HL_SOCK", "")
op, args = sys.argv[1], sys.argv[2:]


def say(msg):
    sys.stderr.write(msg + "\n")


def herdr(*argv):
    """(result, error-code). error-code 'unreachable' when herdr gave no JSON at all."""
    p = subprocess.run([BIN] + list(argv), capture_output=True, text=True)
    for stream in (p.stdout, p.stderr):
        try:
            d = json.loads(stream.strip().splitlines()[-1]) if stream.strip() else None
        except ValueError:
            d = None
        if isinstance(d, dict) and "result" in d and p.returncode == 0:
            return d["result"], None
        if isinstance(d, dict) and "error" in d:
            return None, d["error"].get("code", "error")
    return None, "unreachable"


def snapshot():
    res, err = herdr("api", "snapshot")
    if err or not isinstance(res, dict) or not isinstance(res.get("snapshot", {}).get("panes"), list):
        return None
    return res["snapshot"]


class Unreachable(Exception):
    def __init__(self, sent):
        Exception.__init__(self)
        self.sent = sent


SEQ = [0]


def sock(method, params):
    """(result, error-code). Unreachable(sent) when there is no answer."""
    if not SOCK:
        raise Unreachable(False)
    SEQ[0] += 1
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(SOCK)
    except OSError:
        raise Unreachable(False)
    try:
        s.sendall((json.dumps({"id": "work-board:%d" % SEQ[0], "method": method, "params": params}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        d = json.loads(buf)
    except (OSError, ValueError):
        raise Unreachable(True)
    finally:
        s.close()
    if "error" in d:
        return None, d["error"].get("code", "error")
    return d.get("result"), None


def locate(snap, label, pane_id, term):
    panes = snap["panes"]
    for key, want in (("pane_id", pane_id), ("terminal_id", term)):
        if want:
            hit = [p for p in panes if p.get(key) == want]
            if hit:
                return hit[0]
    hit = [p for p in panes if label and p.get("label") == label]
    return hit[0] if len(hit) == 1 else None


def await_pane(pid):
    """A pane exists when herdr answers for it, not when split returned."""
    for _ in range(int(os.environ["HL_POLL_TRIES"])):
        res, err = herdr("pane", "get", pid)
        if res and (res.get("pane") or {}).get("pane_id") == pid:
            return True
        time.sleep(int(os.environ["HL_POLL_MS"]) / 1000.0)
    return False


def row(p):
    return "\t".join([p["pane_id"], p.get("terminal_id", ""), p["tab_id"], p["workspace_id"]])


def in_use(snap, p):
    invoking = os.environ.get("HL_INVOKING", "").split()
    reasons = []
    if p["pane_id"] in invoking:
        reasons.append("invoking")
    if snap.get("focused_pane_id") == p["pane_id"] or p.get("focused"):
        reasons.append("focused")
    if p.get("agent") or any(a.get("pane_id") == p["pane_id"] for a in snap.get("agents") or []):
        reasons.append("agent")
    return reasons


def leaves(n):
    return [n["pane_id"]] if n["type"] == "pane" else leaves(n["first"]) + leaves(n["second"])


def chain(n, d):
    if n["type"] == "split" and n["direction"] == d:
        return chain(n["first"], d) + chain(n["second"], d)
    return [n]


def canonical(root):
    out = []
    for col in chain(root, "right"):
        rows = chain(col, "down")
        if any(r["type"] != "pane" for r in rows):
            return None
        out.append([r["pane_id"] for r in rows])
    return out


def export(tab):
    """(root, exit code)."""
    try:
        res, err = sock("layout.export", {"tab_id": tab})
    except Unreachable:
        return None, UNKNOWN
    if err == "tab_not_found":
        return None, GONE
    if err or not isinstance(res, dict) or "layout" not in res:
        return None, UNKNOWN
    return res["layout"]["root"], OK


if op == "find":
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read, so where the pane is is unknown")
        sys.exit(UNKNOWN)
    p = locate(snap, *args)
    if p is None:
        sys.exit(GONE)
    print(row(p))
    sys.exit(OK)

if op == "in-use":
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read, so whether the pane is in use is unknown")
        sys.exit(UNKNOWN)
    hit = [p for p in snap["panes"] if p["pane_id"] == args[0]]
    if not hit:
        sys.exit(GONE)
    reasons = in_use(snap, hit[0])
    if reasons:
        print(" ".join(reasons))
        sys.exit(OK)
    sys.exit(1)

if op == "columns":
    root, code = export(args[0])
    if code != OK:
        sys.exit(code)
    cols = canonical(root)
    if cols is None:
        sys.exit(1)
    print(json.dumps(cols, separators=(",", ":")))
    sys.exit(OK)

if op == "keys":
    try:
        tree = json.loads(args[0])
    except ValueError:
        tree = None
    ok = (isinstance(tree, list) and tree and all(isinstance(c, list) and c for c in tree)
          and all(isinstance(k, str) and k for c in tree for k in c))
    if not ok:
        say("refused: a desired tab is a non-empty list of non-empty columns of issue ids")
        sys.exit(REFUSED)
    flat = [k for c in tree for k in c]
    if len(flat) != len(set(flat)):
        say("refused: a desired tab names a ticket twice")
        sys.exit(REFUSED)
    if len(flat) > int(os.environ["HL_CAP"]):
        say("refused: a desired tab holds %d panes, over the cap of %s" % (len(flat), os.environ["HL_CAP"]))
        sys.exit(REFUSED)
    print("\n".join(flat))
    sys.exit(OK)

if op == "create":
    label, kind, where, extra = args
    issue, role, cwd = os.environ["HL_ISSUE"], os.environ["HL_ROLE"], os.environ["HL_DIR"]
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; nothing was created")
        sys.exit(UNKNOWN)
    if any(p.get("label") == label for p in snap["panes"]):
        say("refused: a pane labelled %s is already open; a second one would make both unfindable" % label)
        sys.exit(REFUSED)
    env = ["--env", "HERDR_LINEAR_BOARD_ISSUE=%s" % issue]
    if role == "pointer":
        env += ["--env", "HERDR_LINEAR_BOARD_HOME=%s" % issue]
    if kind == "split":
        res, err = herdr("pane", "split", where, "--direction", extra, "--cwd", cwd, "--no-focus", *env)
        pane = (res or {}).get("pane", {}).get("pane_id")
    else:
        res, err = herdr("tab", "create", "--workspace", where, "--cwd", cwd, "--label", extra or label, "--no-focus", *env)
        pane = (res or {}).get("root_pane", {}).get("pane_id")
    if not pane:
        say("herdr made no pane (%s); nothing was created" % (err or "no pane id"))
        sys.exit(UNKNOWN if err == "unreachable" else FAILED)
    _, err = herdr("pane", "rename", pane, label) if await_pane(pane) else (None, "never registered")
    snap = None if err else snapshot()
    hit = [p for p in snap["panes"] if p["pane_id"] == pane] if snap else []
    p = hit[0] if hit else None
    if p is None or p.get("label") != label:
        print("\t".join([pane, "", "", ""]))
        say("pane %s was created but its label cannot be read back; its state is unknown" % pane)
        sys.exit(UNKNOWN)
    print(row(p))
    sys.exit(OK)

if op == "move":
    issue, label, pane_id, tab, direction, target, allow = args
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; nothing moved, and where %s is is unknown" % issue)
        sys.exit(UNKNOWN)
    p = locate(snap, label, pane_id, "")
    if p is None:
        say("the pane for %s is gone; nothing moved" % issue)
        sys.exit(GONE)
    reasons = in_use(snap, p)
    if reasons and allow != "yes":
        print("%s\t%s" % (issue, " ".join(reasons)))
        say("the pane for %s is in use (%s); ask before moving it" % (issue, ", ".join(reasons)))
        sys.exit(IN_USE)
    if tab.startswith("new:"):
        new_ws, _, new_label = tab[4:].partition(":")
        dest = {"type": "new_tab", "workspace_id": new_ws, "label": new_label or None}
    else:
        dest = {"type": "tab", "tab_id": tab, "split": direction, "target_pane_id": target}
    try:
        res, err = sock("pane.move", {"pane_id": p["pane_id"], "focus": False, "destination": dest})
    except Unreachable as e:
        if not e.sent:
            say("the herdr socket cannot be reached; nothing moved")
            sys.exit(NO_SERVER)
        res, err = None, None
    if err:
        say("herdr refused the move of %s: %s" % (issue, err))
        sys.exit(FAILED)
    mr = (res or {}).get("move_result") or {}
    after = snapshot()
    moved = locate(after, label, (mr.get("pane") or {}).get("pane_id"), p.get("terminal_id")) if after else None
    if moved is None:
        say("the move of %s cannot be read back; its result is unknown" % issue)
        sys.exit(UNKNOWN)
    if tab.startswith("new:"):
        tab = (mr.get("created_tab") or {}).get("tab_id") or tab
    if moved["tab_id"] != tab:
        say("herdr answered the move of %s, but the pane is in %s, not %s" % (issue, moved["tab_id"], tab))
        sys.exit(FAILED)
    print("\t".join([issue, row(moved), "same_tab" if mr.get("reason") == "same_tab" else "moved",
                     mr.get("closed_tab_id") or ""]))
    sys.exit(OK)

if op == "apply":
    tab_spec, tree_json, panes_tsv, allow = args[:4]
    keep = set(args[4:])
    tree = json.loads(tree_json)
    info = {}
    for line in panes_tsv.splitlines():
        if line:
            k, label, pid = line.split("\t")
            info[k] = {"label": label, "ledger": pid}
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; nothing moved")
        sys.exit(UNKNOWN)
    cur = {}
    for k in info:
        p = locate(snap, info[k]["label"], info[k]["ledger"], "")
        if p is None:
            say("the pane for %s is gone; nothing moved" % k)
            sys.exit(GONE)
        cur[k] = p
    held = {}
    for line in os.environ.get("HL_HELD", "").splitlines():
        if line:
            k, label, pid = line.split("\t")
            p = cur.get(k) or locate(snap, label, pid, "")
            if p is not None:
                held[k] = dict(p, label=label)

    def report():
        for k, p in sorted(list(cur.items()) + [(k, p) for k, p in held.items() if k not in cur]):
            print("%s\t%s" % (k, row(p)))

    def without(keys):
        return [c for c in ([k for k in col if k not in keys] for col in tree) if c]

    ws_of_tab = {t["tab_id"]: t["workspace_id"] for t in snap["tabs"]}
    held_cols = []
    if tab_spec.startswith("new:"):
        rest = tab_spec[4:]
        new_ws, _, new_label = rest.partition(":")
        if new_ws not in [w["workspace_id"] for w in snap["workspaces"]]:
            say("refused: no workspace %s" % new_ws)
            sys.exit(REFUSED)
        T, in_t, placeholders_in_t = None, [], []
        tree = without(held)
    else:
        T = tab_spec
        if T not in ws_of_tab:
            say("tab %s is gone; nothing moved" % T)
            sys.exit(GONE)
        root, code = export(T)
        if code != OK:
            say("the layout of %s cannot be read; nothing moved" % T)
            sys.exit(code)
        in_t = leaves(root)
        held_here = {k for k, p in held.items() if p["pane_id"] in in_t}
        if held_here and held_here != {tree[0][0]}:
            tree = without(held)
            by_pane = {p["pane_id"]: k for k, p in held.items() if k in held_here}
            layout = canonical(root)
            held_cols = [c for c in ([by_pane[p] for p in col if p in by_pane] for col in layout or []) if c]
            if layout is None or any(len(c) > 1 for c in held_cols):
                for k in sorted(held_here):
                    print("%s\theld" % k)
                say("held panes share a column of %s, so nothing can be built beside them; nothing moved" % T)
                sys.exit(IN_USE)
        else:
            tree = without(set(held) - held_here)
        want = [[held[k]["pane_id"] for k in c] for c in held_cols] + \
            [[cur[k]["pane_id"] for k in col] for col in tree]
        if canonical(root) == want:
            report()
            sys.exit(OK)
        try:
            recorded = set(l.strip() for l in open(os.environ["HL_PLACEHOLDERS"]) if l.strip())
        except OSError:
            recorded = set()
        # By pane id alone: a restart renews terminal ids and keeps pane ids.
        placeholders_in_t = [p for p in in_t if p in recorded]
        ours = set(p["pane_id"] for p in cur.values()) | set(p["pane_id"] for p in held.values())
        foreign = [p for p in in_t if p not in ours and p not in placeholders_in_t]
        if foreign:
            say("refused: tab %s holds panes the board does not own (%s); nothing moved" % (T, ", ".join(foreign)))
            sys.exit(REFUSED)
        new_ws = ws_of_tab[T]
    if not tree:
        report()
        sys.exit(OK)

    building = [k for col in tree for k in col]
    anchor = None if held_cols else tree[0][0]
    anchor_stays = anchor is not None and T is not None and cur[anchor]["pane_id"] in in_t
    moving = [k for k in building if not (k == anchor and anchor_stays)]
    busy = [(k, in_use(snap, cur[k])) for k in moving]
    busy = [(k, r) for k, r in busy if r]
    if busy and allow != "yes":
        for k, r in busy:
            print("%s\t%s" % (k, " ".join(r)))
        say("panes in use would move (%s); ask before applying this tab" % ", ".join(k for k, _ in busy))
        sys.exit(IN_USE)

    count = {}
    for p in snap["panes"]:
        count[p["tab_id"]] = count.get(p["tab_id"], 0) + 1

    def fail(code, msg):
        say(msg + "; the tab is partly built")
        sys.exit(code)

    def placeholder(k):
        src = cur[k]
        res, err = herdr("pane", "split", src["pane_id"], "--direction", "down", "--cwd", os.environ["HL_DIR"], "--no-focus")
        pid = (res or {}).get("pane", {}).get("pane_id")
        if not pid:
            fail(UNKNOWN if err == "unreachable" else FAILED, "no placeholder could be made in %s" % src["tab_id"])
        # Recorded before anything else can fail: an unrecorded placeholder is
        # a foreign pane that refuses its tab's apply for good.
        with open(os.environ["HL_PLACEHOLDERS"], "a") as f:
            f.write("%s\n" % pid)
        os.chmod(os.environ["HL_PLACEHOLDERS"], 0o600)
        if not await_pane(pid):
            fail(UNKNOWN, "placeholder %s never registered" % pid)
        herdr("pane", "rename", pid, "work:placeholder")
        count[src["tab_id"]] += 1

    def move(k, dest):
        src = cur[k]["tab_id"]
        if src in keep and src != T and count.get(src, 0) == 1:
            placeholder(k)
        try:
            res, err = sock("pane.move", {"pane_id": cur[k]["pane_id"], "focus": False, "destination": dest})
        except Unreachable as e:
            fail(UNKNOWN if e.sent else NO_SERVER, "the move of %s got no answer from herdr" % k)
        if err:
            fail(FAILED, "herdr refused the move of %s: %s" % (k, err))
        mr = (res or {}).get("move_result") or {}
        pane = mr.get("pane") or {}
        if not mr.get("changed") or not pane.get("pane_id"):
            fail(UNKNOWN, "the move of %s did not report a change" % k)
        count[src] -= 1
        cur[k] = dict(cur[k], pane_id=pane["pane_id"], tab_id=pane["tab_id"], workspace_id=pane["workspace_id"])
        count[pane["tab_id"]] = count.get(pane["tab_id"], 0) + 1
        return (mr.get("created_tab") or {}).get("tab_id")

    def into(k, split, target_key):
        move(k, {"type": "tab", "tab_id": T, "split": split, "target_pane_id": cur[target_key]["pane_id"]})

    if T is None:
        T = move(anchor, {"type": "new_tab", "workspace_id": new_ws, "label": new_label or None})
        if not T:
            fail(UNKNOWN, "the new tab for %s was not reported" % anchor)
    elif anchor is not None and not anchor_stays:
        move(anchor, {"type": "tab", "tab_id": T, "split": "right", "target_pane_id": in_t[0]})
    scratch = scratch_key = None
    for k in [k for k in building if k != anchor and cur[k]["tab_id"] == T]:
        if scratch is None:
            scratch, scratch_key = move(k, {"type": "new_tab", "workspace_id": new_ws, "label": "work:scratch"}), k
        else:
            move(k, {"type": "tab", "tab_id": scratch, "split": "right", "target_pane_id": cur[scratch_key]["pane_id"]})
    for pid in placeholders_in_t:
        _, err = herdr("pane", "close", pid)
        if err and err != "pane_not_found":
            fail(UNKNOWN if err == "unreachable" else FAILED, "placeholder %s could not be closed" % pid)
        keep_lines = [l for l in open(os.environ["HL_PLACEHOLDERS"]) if l.strip() != pid]
        open(os.environ["HL_PLACEHOLDERS"], "w").writelines(keep_lines)
    if held_cols:
        target = held[held_cols[-1][0]]["pane_id"]
        for col in tree:
            move(col[0], {"type": "tab", "tab_id": T, "split": "right", "target_pane_id": target})
            target = cur[col[0]]["pane_id"]
    else:
        for j in range(1, len(tree)):
            into(tree[j][0], "right", tree[j - 1][0])
    for col in tree:
        for i in range(1, len(col)):
            into(col[i], "down", col[i - 1])

    root, code = export(T)
    want = [[held[k]["pane_id"] for k in c] for c in held_cols] + [[cur[k]["pane_id"] for k in col] for col in tree]
    if code != OK:
        say("tab %s cannot be read back after the moves; its layout is unknown" % T)
        sys.exit(UNKNOWN)
    if canonical(root) != want:
        say("tab %s reads back as %s, not %s" % (T, json.dumps(canonical(root)), json.dumps(want)))
        sys.exit(FAILED)
    after = snapshot()
    if after is None:
        say("the herdr snapshot cannot be read after the moves; the panes' ids are unknown")
        sys.exit(UNKNOWN)
    for k, p in list(cur.items()):
        cur[k] = locate(after, info[k]["label"], p["pane_id"], p.get("terminal_id"))
    for k, p in list(held.items()):
        held[k] = locate(after, p["label"], p["pane_id"], p.get("terminal_id"))
    lost = sorted(k for k, p in list(cur.items()) + list(held.items()) if p is None)
    if lost:
        say("the pane for %s cannot be found after the moves" % ", ".join(lost))
        sys.exit(UNKNOWN)
    report()
    sys.exit(OK)

if op == "close":
    label, pane_id = args
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; nothing was closed")
        sys.exit(UNKNOWN)
    p = locate(snap, label, pane_id, "")
    if p is None:
        sys.exit(GONE)
    _, err = herdr("pane", "close", p["pane_id"])
    if err == "pane_not_found":
        sys.exit(GONE)
    if err and err != "unreachable":
        say("herdr refused to close %s: %s" % (p["pane_id"], err))
        sys.exit(FAILED)
    after = snapshot()
    if after is None:
        say("the close of %s cannot be read back; its result is unknown" % p["pane_id"])
        sys.exit(UNKNOWN)
    if locate(after, label, p["pane_id"], p.get("terminal_id")) is not None:
        say("pane %s is still open after the close" % p["pane_id"])
        sys.exit(FAILED)
    sys.exit(OK)

if op == "focus":
    label = args[0]
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; the home pane is unknown")
        sys.exit(UNKNOWN)
    p = locate(snap, label, "", "")
    if p is None:
        sys.exit(GONE)
    try:
        _, err = sock("pane.focus", {"pane_id": p["pane_id"]})
    except Unreachable as e:
        sys.exit(UNKNOWN if e.sent else NO_SERVER)
    if err:
        say("herdr refused to focus %s: %s" % (p["pane_id"], err))
        sys.exit(FAILED)
    after = snapshot()
    if after is None or after.get("focused_pane_id") != p["pane_id"]:
        sys.exit(UNKNOWN)
    sys.exit(OK)

if op == "metadata":
    title, rows_tsv = args
    snap = snapshot()
    if snap is None:
        say("the herdr snapshot cannot be read; no pane shows the sync state")
        sys.exit(UNKNOWN)
    targets = []
    for line in rows_tsv.splitlines():
        if not line:
            continue
        issue, label, pid = line.split("\t")
        p = locate(snap, label, pid, "")
        if p is None:
            print("%s\tgone" % issue)
            continue
        herdr("pane", "report-metadata", "--source", os.environ["HL_SOURCE"], "--title", title, p["pane_id"])
        targets.append((issue, label, p))
    after = snapshot()
    code = OK
    for issue, label, p in targets:
        q = locate(after, label, p["pane_id"], p.get("terminal_id")) if after else None
        if q is None or q.get("title") != title:
            print("%s\tunknown" % issue)
            code = UNKNOWN
        else:
            print("%s\tok" % issue)
    sys.exit(code)

sys.exit(64)
PYEOF
}

#!/usr/bin/env bash
# The unattended half of a board sync (KTD2): one call brings herdr in line with
# Linear as far as it can without asking anyone, records every question for the
# next /work command, and never asks or closes. Its one Linear write is a
# consented write-back of a pane a person moved (R25-R27). Sourced; run
# directly it performs one sync, so an agent can be told a path, not a verb.
#
# The python3 driver calls each board verb in a fresh bash, so every herdr and
# store effect goes through the verb that owns it.
#
# Crash safety (KTD9): every tab apply is journalled as one intent before herdr
# is called and cleared only after the ledger holds the result. The next sync
# settles each uncleared intent before it reads anything else. An intent that
# cannot be settled marks its tickets' Linear change pending, so a half-built
# tab is never read as a person's move.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::probe >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/herdr-read.sh"
command -v herdr_linear::board_ledger_entry >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-store.sh"
command -v herdr_linear::board_config_load >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-config.sh"
command -v herdr_linear::board_issues >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-linear.sh"
command -v herdr_linear::board_plan >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-plan.sh"
command -v herdr_linear::board_apply_tab >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-herdr.sh"
command -v herdr_linear::scheme_name >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/schemes.sh"
command -v herdr_linear::scope_repo >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/repos.sh"

HERDR_LINEAR_BOARD_SYNC_LIB="${BASH_SOURCE[0]}"

HERDR_LINEAR_BOARD_SYNC_CLEAN=0
HERDR_LINEAR_BOARD_SYNC_NO_BOARD=1      # no configuration: nothing to do
HERDR_LINEAR_BOARD_SYNC_REFUSED=2       # the configuration is refused; named in sync state
HERDR_LINEAR_BOARD_SYNC_LOCKED=3        # another sync holds the board lock
HERDR_LINEAR_BOARD_SYNC_INCOMPLETE=4    # a Linear read did not finish; nobody left the view
HERDR_LINEAR_BOARD_SYNC_QUESTIONS=5     # applied; questions wait for the next /work command
HERDR_LINEAR_BOARD_SYNC_NO_SERVER=6
HERDR_LINEAR_BOARD_SYNC_FAILED=7        # an early stage failed; named in sync state
HERDR_LINEAR_BOARD_SYNC_UNKNOWN=8       # some effects could not be read back

HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS="${HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS:-10}"
# A holder writes its pid in the instant after mkdir; a lock with no pid older
# than this was left by a process killed in that instant.
HERDR_LINEAR_BOARD_SYNC_PIDLESS_SECONDS=5

herdr_linear::_board_sync_lock_dir() {
    printf '%s/board/sync.lock' "$HERDR_LINEAR_STORE_DIR"
}

# kill -0 fails for a live process of another user too; only "no such process"
# is dead.
herdr_linear::_board_pid_alive() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null && return 0
    kill -0 "$1" 2>&1 | grep -qi 'not permitted'
}

# The board lock records its holder. A holder that is no longer running is
# taken over; a live one is waited for and then refused, however old its lock.
# Takeover runs under binding.sh's lock on the lock itself, so two syncs cannot
# both remove a dead holder's lock and one of them remove the other's new one.
herdr_linear::_board_sync_lock() {
    local lock me="$1" pid age waited=0
    lock="$(herdr_linear::_board_sync_lock_dir)"
    mkdir -p "${lock%/*}" 2>/dev/null || return 1
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_STORE_DIR/board" 2>/dev/null
    while :; do
        if mkdir "$lock" 2>/dev/null; then
            printf '%s\n' "$me" > "$lock/pid"
            return 0
        fi
        if herdr_linear::_lock "$lock"; then
            pid="$(cat "$lock/pid" 2>/dev/null)"
            age=$(( $(date +%s) - $(herdr_linear::_mtime "$lock" 2>/dev/null || date +%s) ))
            if { [ -n "$pid" ] && ! herdr_linear::_board_pid_alive "$pid"; } \
                || { [ -z "$pid" ] && [ -d "$lock" ] && [ "$age" -gt "$HERDR_LINEAR_BOARD_SYNC_PIDLESS_SECONDS" ]; }; then
                rm -f "$lock/pid"
                rmdir "$lock" 2>/dev/null
                herdr_linear::_unlock "$lock"
                continue
            fi
            herdr_linear::_unlock "$lock"
        fi
        waited=$(( waited + 1 ))
        [ "$waited" -gt $(( HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS * 20 )) ] && return 1
        perl -e 'select undef, undef, undef, 0.05' 2>/dev/null || sleep 1
    done
}

herdr_linear::_board_sync_unlock() {
    local lock
    lock="$(herdr_linear::_board_sync_lock_dir)"
    [ "$(cat "$lock/pid" 2>/dev/null)" = "$1" ] || return 0
    rm -f "$lock/pid"
    rmdir "$lock" 2>/dev/null
}

# herdr_linear::board_write_back_gate <space> <issue> <level-kind> <target|--none> [<descendant-id>...]
#   0  allowed: the board write bound and the space's consent (KTD8)
#   HERDR_LINEAR_BOARD_WRITE_SHADOW  refused; exactly one shadow log line
# The descendants are the moved ticket's sub-tickets, at any depth, from the
# last complete read: a parent write under one of them makes a cycle.
herdr_linear::board_write_back_gate() {
    local space="${1-}" issue="${2-}" kind="${3-}" target="${4-}" d
    shift 4 2>/dev/null || set --
    case "$kind" in
        team|project|milestone|cycle|assignee|state|priority|parent|sub-ticket|label-group:?*) ;;
        *)
            herdr_linear::_shadow_log "SHADOW board would set \"$kind\" on \"$issue\" in \"$space\": a $kind group is not a Linear field"
            return "$HERDR_LINEAR_BOARD_WRITE_SHADOW" ;;
    esac
    case "$kind" in
        parent|sub-ticket)
            for d in "$issue" "$@"; do
                [ "$target" = "$d" ] || continue
                herdr_linear::_shadow_log "SHADOW board would set \"$kind\" to \"$target\" on \"$issue\" in \"$space\": the target is the ticket itself or one of its sub-tickets"
                return "$HERDR_LINEAR_BOARD_WRITE_SHADOW"
            done ;;
    esac
    herdr_linear::board_consent_gate "$space" "$kind" "$issue" "$target" \
        || return "$HERDR_LINEAR_BOARD_WRITE_SHADOW"
    return 0
}

# herdr_linear::board_write_back <space> <issue> <level-kind> <target|--none> <from|--none> [<descendant-id>...]
# R25. Sets the field a pane was moved across to the group it was moved into.
# <from> is the group it left; a label group removes that label.
# Exit 0 written; BOARD_WRITE_SHADOW refused by the gate (nothing sent);
# otherwise the field write's code.
herdr_linear::board_write_back() {
    local space="${1-}" issue="${2-}" kind="${3-}" target="${4-}" from="${5-}" field rc why
    local -a descendants=("${@:6}") removed=()
    herdr_linear::board_write_back_gate "$space" "$issue" "$kind" "$target" ${descendants[@]+"${descendants[@]}"} \
        || return "$HERDR_LINEAR_BOARD_WRITE_SHADOW"
    case "$kind" in
        team) field=teamId ;;
        project) field=projectId ;;
        milestone) field=projectMilestoneId ;;
        cycle) field=cycleId ;;
        assignee) field=assigneeId ;;
        state) field=stateId ;;
        priority) field=priority ;;
        parent|sub-ticket) field=parentId ;;
        *) field=labelGroup; removed=("${from:---none}") ;;
    esac
    herdr_linear::board_write_field "$issue" "$field" "$target" ${removed[@]+"${removed[@]}"}; rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            "$HERDR_LINEAR_BOARD_WRITE_REJECTED") why="Linear rejected the write" ;;
            "$HERDR_LINEAR_REFUSED") why="the write was refused before it was sent" ;;
            *) why="the Linear request failed with code $rc" ;;
        esac
        herdr_linear::_shadow_log "SHADOW board did not set \"$kind\" to \"$target\" on \"$issue\" in \"$space\": $why"
        return "$rc"
    fi
    # The write happened; a store that cannot record it must not report a failed write.
    herdr_linear::board_record_linear_write >/dev/null 2>&1 || true
    return 0
}

# herdr_linear::board_sync
# Exit: CLEAN, NO_BOARD, REFUSED, LOCKED, INCOMPLETE, QUESTIONS, NO_SERVER,
# FAILED or UNKNOWN (constants above). One summary line on stdout. Safe from an
# agent's shell; never from a hook (a paginated read does not fit a hook).
herdr_linear::board_sync() (
    local me rc
    me="$BASHPID"
    herdr_linear::board_config_load >/dev/null 2>&1
    [ "$?" -eq "$HERDR_LINEAR_BOARD_ABSENT" ] && return "$HERDR_LINEAR_BOARD_SYNC_NO_BOARD"
    if ! herdr_linear::_board_sync_lock "$me"; then
        printf 'another board sync is running; nothing was changed\n' >&2
        return "$HERDR_LINEAR_BOARD_SYNC_LOCKED"
    fi
    trap 'herdr_linear::_board_sync_unlock "'"$me"'"' EXIT
    HL_LIB="$HERDR_LINEAR_BOARD_SYNC_LIB" HL_CAP="$HERDR_LINEAR_BOARD_PANE_CAP" \
        HL_INVOKING="$(herdr_linear::pane_id 2>/dev/null)" \
        HL_PANE_DIR="${HERDR_LINEAR_WORKTREES_ROOT:-$HOME/worktrees}" \
        python3 -c "$HERDR_LINEAR_BOARD_SYNC_PY"
    rc=$?
    return "$rc"
)


IFS= read -r -d '' HERDR_LINEAR_BOARD_SYNC_PY <<'PYEOF' || true
import hashlib, json, os, secrets, subprocess, sys

CLEAN, NO_BOARD, REFUSED, LOCKED, INCOMPLETE, QUESTIONS, NO_SERVER, FAILED, UNKNOWN = range(9)
P_OK, P_NO_SERVER, P_REFUSED, P_UNKNOWN, P_FAILED, P_IN_USE, P_GONE = range(7)
LIB = os.environ["HL_LIB"]
BOARD = os.path.join(os.environ["HERDR_LINEAR_STORE_DIR"], "board")
JOURNAL = os.path.join(BOARD, "journal.json")
HELD_TABS = os.path.join(BOARD, "held-tabs.json")
CAP = int(os.environ.get("HL_CAP") or 16)
PANE_DIR = os.environ["HL_PANE_DIR"]
PLACING = ("place", "recreate-pointer")
PARKING = "work:parking"


class Stop(Exception):
    def __init__(self, code):
        Exception.__init__(self)
        self.code = code


def call(verb, *args):
    p = subprocess.run(["bash", "-c", '. "$0" 2>/dev/null || exit 70; "$@"', LIB, "herdr_linear::" + verb]
                       + [str(a) for a in args], capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def space_key(space):
    return hashlib.sha1(space.encode()).hexdigest()[:16]


def label_of(issue, role, space):
    return "work:%s" % issue if role == "home" else "work:%s:pointer:%s" % (issue, space_key(space))


def last_line(text, fallback):
    lines = [l for l in (text or "").strip().splitlines() if l.strip()]
    return lines[-1] if lines else fallback


def dump(v):
    return json.dumps(v, sort_keys=True)


def write_private(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.%s" % (path, os.getpid(), secrets.token_hex(4))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# Labels match only when settling a crashed apply, which runs before the engine;
# after that the engine finds a pane by label and emits relink.
def locate(snap, space, issue, entry, by_label):
    panes = snap["panes"]
    for key in ("pane_id", "terminal_id"):
        want = entry.get(key)
        hit = [p for p in panes if want and p.get(key) == want]
        if hit:
            return hit[0]
    if not by_label:
        return None
    hit = [p for p in panes if p.get("label") == label_of(issue, entry["role"], space)]
    return hit[0] if len(hit) == 1 else None


def in_use_panes(snap, everything):
    """KTD3, as board-herdr.sh and the engine read it."""
    if everything:
        return {p["pane_id"] for p in snap["panes"]}
    busy = {os.environ.get("HL_INVOKING"), snap.get("focused_pane_id")}
    busy |= {p["pane_id"] for p in snap["panes"] if p.get("focused") or p.get("agent")}
    busy |= {a.get("pane_id") for a in snap.get("agents") or [] if isinstance(a, dict)}
    return busy - {None, ""}


def chain(n, d):
    if n.get("type") == "split" and n.get("direction") == d:
        return chain(n["first"], d) + chain(n["second"], d)
    return [n]


def columns_of(tree):
    """Anchors are dropped: a board pane is a ticket, so a cell with no ticket has
    no pane, and its row reads back as unknown rather than as a move."""
    cols = [[leaf for leaf in chain(col, "down") if leaf.get("type") == "pane"] for col in chain(tree, "right")]
    return [c for c in cols if c]


def tree_of_columns(cols):
    def link(nodes, d):
        return nodes[0] if len(nodes) == 1 else {"type": "split", "direction": d, "ratio": 0.5,
                                                   "first": nodes[0], "second": link(nodes[1:], d)}
    return link([link([{"type": "pane", "pane_id": p} for p in col], "down") for col in cols], "right")


class Sync:
    def __init__(self):
        self.observed, self.unknown = {}, {}
        self.created = 0
        self.surplus = []
        self.asked_scopes = set()
        self.restarted = False
        self.parks = []

    def count(self, bucket, key, n=1):
        bucket[key] = bucket.get(key, 0) + n

    def fail(self, stage, message, code):
        call("board_sync_failed", stage, last_line(message, stage))
        print("board sync failed at %s: %s" % (stage, last_line(message, "no detail")))
        raise Stop(code)


    def private(self, path, stage):
        st = os.stat(path)
        if st.st_uid != os.getuid() or st.st_mode & 0o022:
            self.fail(stage, "the owner or mode of %s is wrong" % path, FAILED)

    def journal(self):
        if not os.path.exists(JOURNAL):
            return {}
        self.private(JOURNAL, "journal")
        try:
            with open(JOURNAL) as f:
                intents = json.load(f)["intents"]
            assert isinstance(intents, dict)
            return intents
        except (OSError, ValueError, KeyError, TypeError, AssertionError):
            self.fail("journal", "the journal cannot be read: %s" % JOURNAL, FAILED)

    def journal_put(self, iid, intent):
        intents = self.journal()
        if intent is None:
            intents.pop(iid, None)
        else:
            intents[iid] = intent
        write_private(JOURNAL, json.dumps({"version": 1, "intents": intents}, indent=1, sort_keys=True))


    def snapshot(self):
        rc, out, err = call("snapshot")
        try:
            snap = json.loads(out)["result"]["snapshot"]
            assert isinstance(snap.get("panes"), list)
            return snap
        except Exception:
            self.fail("herdr snapshot", err or "the herdr snapshot cannot be read", FAILED)

    def ledgers(self):
        names = set()
        d = os.path.join(BOARD, "ledger")
        for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            try:
                with open(os.path.join(d, n)) as f:
                    s = json.load(f).get("space")
                if isinstance(s, str):
                    names.add(s)
            except (OSError, ValueError, AttributeError):
                pass
        out = {}
        for space in sorted(names):
            rc, text, _ = call("board_ledger_entries", space)
            if rc == 0 and json.loads(text):
                out[space] = json.loads(text)
        return out

    def relink(self, snap, led, by_label=False):
        """True when herdr restarted: every pane still under its id has a new terminal."""
        kept = renewed = 0
        for space, entries in led.items():
            for issue, e in entries.items():
                p = locate(snap, space, issue, e, by_label)
                if p is None:
                    continue
                if e.get("terminal_id") and p["pane_id"] == e["pane_id"]:
                    kept += 1
                    renewed += p.get("terminal_id") != e["terminal_id"]
                term = p.get("terminal_id") or ""
                if p["pane_id"] != e["pane_id"] or (term and term != e.get("terminal_id")):
                    if call("board_ledger_set_pane", space, issue, p["pane_id"], term)[0] == 0:
                        e["pane_id"], e["terminal_id"] = p["pane_id"], term or e.get("terminal_id")
                        self.count(self.observed, "relinked")
        return kept > 0 and renewed == kept

    def tab_columns(self, tab):
        rc, out, _ = call("board_tab_columns", tab)
        return rc, (json.loads(out) if rc == 0 else None)

    @staticmethod
    def workspace(snap, space):
        hits = sorted(w["workspace_id"] for w in snap.get("workspaces", []) if w.get("label") == space)
        return hits[0] if len(hits) == 1 else None

    @staticmethod
    def tab_named(snap, ws, name, panes):
        tabs = [t for t in snap.get("tabs", []) if t.get("workspace_id") == ws and t.get("label") == name]
        holding = [t for t in tabs if any(p.get("tab_id") == t["tab_id"] and p["pane_id"] in panes
                                          for p in snap["panes"])]
        pick = sorted(holding or tabs, key=lambda t: t["tab_id"])
        return pick[0]["tab_id"] if pick else None


    def ask(self, kind, key, pre):
        rc, _, err = call("board_question_propose", "%s-%s" % (kind, key), kind, dump(pre))
        if rc == 0:
            self.count(self.observed, "questions_recorded")
        elif "declined" not in err:
            self.count(self.unknown, "questions")

    def put(self, space, issue, pane, leaf, term):
        rc = call("board_ledger_put", space, issue, pane, leaf["role"], dump(leaf["groups"]),
                  "true" if leaf["created"] else "false", term or "")[0]
        if rc != 0:
            self.count(self.unknown, "ledger")
        return rc == 0

    def settle(self, intent, rows):
        for line in rows.splitlines():
            parts = line.split("\t")
            leaf = intent["leaves"].get(parts[0]) if len(parts) >= 3 else None
            if leaf is None or leaf["hold"]:
                continue
            if self.put(intent["space"], parts[0], parts[1], leaf, parts[2]) and leaf["from_space"]:
                call("board_ledger_remove", leaf["from_space"], parts[0])

    def unsettle(self, intent):
        """Nothing of an unfinished apply is ever read as a person's move (KTD4)."""
        for issue, leaf in intent["leaves"].items():
            if leaf["hold"] or not (leaf["new"] or leaf["from_space"] or leaf["groups"] != leaf["old_groups"]):
                continue
            if leaf["from_space"]:
                call("board_ledger_remove", intent["space"], issue)
                call("board_ledger_mark_linear_change", leaf["from_space"], issue)
            else:
                call("board_ledger_mark_linear_change", intent["space"], issue)


    def in_place(self, snap, led, intent):
        entries = led.get(intent["space"], {})
        want, rows, panes = [], [], set()
        for col in intent["columns"]:
            ids = []
            for issue in col:
                p = locate(snap, intent["space"], issue, entries[issue], True) if issue in entries else None
                if p is None:
                    return None
                ids.append(p["pane_id"])
                panes.add(p["pane_id"])
                rows.append("\t".join([issue, p["pane_id"], p.get("terminal_id") or ""]))
            want.append(ids)
        tab = self.tab_named(snap, intent["ws"], intent["label"], panes)
        if tab is None or self.tab_columns(tab) != (0, want):
            return None
        return "\n".join(rows)

    def reconcile(self):
        for iid, intent in sorted(self.journal().items()):
            if intent.get("kind") == "park":
                self.parks.append(iid)
                continue
            snap = self.snapshot()
            led = self.ledgers()
            self.relink(snap, led, by_label=True)
            space = intent["space"]
            for issue, leaf in intent["leaves"].items():
                if not leaf["new"] or issue in led.get(space, {}):
                    continue
                hit = [p for p in snap["panes"] if p.get("label") == label_of(issue, leaf["role"], space)]
                if len(hit) == 1:
                    self.put(space, issue, hit[0]["pane_id"], leaf, hit[0].get("terminal_id"))
            led = self.ledgers()
            rows = self.in_place(snap, led, intent)
            if rows is None:
                cols = [[i for i in col if i in led.get(space, {})] for col in intent["columns"]]
                cols = [c for c in cols if c]
                spec = self.tab_named(snap, intent["ws"], intent["label"], set()) \
                    or "new:%s:%s" % (intent["ws"], intent["label"])
                held = [i for i in intent.get("held", []) if i in led.get(space, {})]
                rc, out, _ = call("board_apply_tab", space, spec, dump(cols),
                                  *(["held:" + ",".join(held)] if held else [])) if cols else (P_FAILED, "", "")
                rows = out if rc == P_OK else None
            if rows is None:
                self.unsettle(intent)
                self.count(self.unknown, "interrupted")
            else:
                self.settle(intent, rows)
                self.count(self.observed, "resumed")
            self.journal_put(iid, None)


    def run(self):
        rc, config_text, err = call("board_config_load")
        if rc == 1:
            raise Stop(NO_BOARD)
        if rc != 0:
            self.fail("configuration", err or "the board configuration is refused", REFUSED)
        config = json.loads(config_text)
        if call("probe")[0] != 0:
            self.fail("herdr", "the herdr server is not running", NO_SERVER)

        self.reconcile()

        reads, self.read_failure = [], None
        mappings = [("global", config["global"])] + list(config.get("spaces", {}).items())
        for name, m in mappings:
            rc, out, err = call("board_issues", dump(m["filter"]))
            try:
                doc = json.loads(out)
            except ValueError:
                doc = {}
            if rc != 0:
                self.read_failure = self.read_failure or "the %s read stopped with %d: %s" % (
                    name, rc, last_line(err, "no detail"))
            reads.append({"mapping": name, "complete": rc == 0 and doc.get("complete") is True,
                          "tickets": doc.get("tickets") or []})
        self.tickets = {t["id"]: t for r in reads for t in r["tickets"] if isinstance(t, dict) and "id" in t}

        snap = self.snapshot()
        led = self.ledgers()
        restarted = self.restarted = self.relink(snap, led)
        if restarted:
            self.count(self.observed, "herdr_restarts")

        layouts, ambiguous = {}, []
        ledger_panes = {e["pane_id"] for es in led.values() for e in es.values()}
        marked = self.held_tabs()
        for t in sorted(snap.get("tabs", []), key=lambda t: t["tab_id"]):
            if t["tab_id"] in marked or t.get("label") == PARKING or not any(p.get("tab_id") == t["tab_id"] and p["pane_id"] in ledger_panes
                                                for p in snap["panes"]):
                continue
            rc, cols = self.tab_columns(t["tab_id"])
            if rc == 0:
                layouts[t["tab_id"]] = tree_of_columns(cols)
            elif rc == 1:
                ambiguous.append(t["tab_id"])

        previous = {}
        rc, state_text, _ = call("board_sync_state")
        if rc == 0:
            previous = {"rendered": json.loads(state_text).get("rendered") or {}}
        # Every person's move is a write-back candidate; the gate decides which
        # are written. With no consent recorded that is none: shadow mode.
        doc = {"config": config, "reads": reads, "snapshot": self.unparked(snap), "layouts": layouts, "ledger": led,
               "previous": previous, "aliases": {},
               "in_use": {"invoking_pane_id": os.environ.get("HL_INVOKING") or None,
                          "treat_all_in_use": restarted},
               "writes_enabled": True}
        self.reads_complete = self.read_failure is None and all(r["complete"] for r in reads)
        self.sent = set()
        plan_text, plan = self.plan(doc)
        if self.settle_write_backs(plan, led):
            plan_text, plan = self.plan(doc)
        write_private(os.path.join(BOARD, "last-plan.json"), plan_text)

        self.execute(plan, snap, led, ambiguous)
        self.finish_parks()

        rc, pending, _ = call("board_questions_pending")
        waiting = len([l for l in pending.splitlines() if l.strip()])
        if rc != 0:
            self.count(self.unknown, "questions")
        complete = plan["complete"] and self.read_failure is None
        if complete:
            body = {"observed": self.observed, "unknown": self.unknown, "pending_questions": waiting,
                    "members": plan["members"], "rendered": plan["rendered"]}
            if call("board_sync_complete", dump(body))[0] != 0:
                self.count(self.unknown, "sync_state")
        else:
            call("board_sync_failed", "linear read", self.read_failure or "a Linear read did not finish")
        for s in plan["spaces"]:
            call("board_show_sync_state", s["name"])

        print("board sync: %s; %d question%s waiting%s%s" % (
            ", ".join("%s %d" % kv for kv in sorted(self.observed.items())) or "nothing changed",
            waiting, "" if waiting == 1 else "s",
            "; unknown: " + ", ".join("%s %d" % kv for kv in sorted(self.unknown.items())) if self.unknown else "",
            "" if complete else "; the Linear read was incomplete, so no ticket left the view"))
        if not complete:
            raise Stop(INCOMPLETE)
        if waiting:
            raise Stop(QUESTIONS)
        raise Stop(UNKNOWN if self.unknown else CLEAN)

    def plan(self, doc):
        inp = os.path.join(BOARD, "plan-input.json")
        write_private(inp, json.dumps(doc))
        rc, plan_text, err = call("board_plan", inp)
        if rc != 0:
            self.fail("plan", err or "the placement engine refused its input", FAILED)
        return plan_text, json.loads(plan_text)

    def descendants(self, issue):
        children = {}
        for t in self.tickets.values():
            parent = (t.get("parent") or {}).get("id") if isinstance(t.get("parent"), dict) else None
            if parent:
                children.setdefault(parent, []).append(t["id"])
        out, todo = [], list(children.get(issue, []))
        while todo:
            i = todo.pop()
            if i not in out and i != issue:
                out.append(i)
                todo += children.get(i, [])
        return sorted(out)

    def settle_write_backs(self, plan, led):
        """Every candidate is gated, and with a complete read the allowed ones are
        written now. A move that is refused or not written is restored at this
        sync and never replayed: its ticket is marked as a Linear change, so the
        next plan puts the pane back and never offers the move again. A ticket
        with any such field is restored whole."""
        self.homes(led)
        refused, allowed = set(), []
        for a in plan["actions"]:
            if a["kind"] != "write-back-candidate":
                continue
            space, issue, kind = a["space"], a["issue_id"], a["field"]
            target = a["target_value"] if a["target_value"] is not None else "--none"
            if call("board_write_back_gate", space, issue, kind, target, *self.descendants(issue))[0] == 0:
                allowed.append(a)
                continue
            refused.add((self.source(space, issue, a["role"]), issue))
            if call("board_consent_covers", space, kind)[0] != 0:
                self.ask("write-consent", "%s-%s" % (space_key(space), space_key(kind)), {"space": space, "field": kind})
        for a in allowed if self.reads_complete else []:
            space, issue, kind = a["space"], a["issue_id"], a["field"]
            src = self.source(space, issue, a["role"])
            if (src, issue) in refused:
                continue
            target = a["target_value"] if a["target_value"] is not None else "--none"
            was = a["from_value"] if a["from_value"] is not None else "--none"
            if call("board_write_back", space, issue, kind, target, was, *self.descendants(issue))[0] == 0:
                self.sent.add((space, issue, kind))
                self.count(self.observed, "written_back")
                continue
            refused.add((src, issue))
            self.count(self.observed, "write_backs_rejected")
            self.ask("write-rejected", "%s-%s-%s" % (issue, space_key(space), space_key(kind)),
                     {"space": space, "issue": issue, "field": kind, "target": a["target_value"]})
        for src, issue in sorted(refused):
            e = led.get(src, {}).get(issue)
            if e is not None and call("board_ledger_mark_linear_change", src, issue)[0] == 0:
                e["pending_linear_change"] = True
                self.count(self.observed, "write_backs_refused")
            else:
                self.count(self.unknown, "write_backs")
        return bool(refused)

    def write_back(self, a, led):
        space, issue, role, kind = a["space"], a["issue_id"], a["role"], a["field"]
        if (space, issue, kind) not in self.sent:
            return
        src = self.source(space, issue, role)
        e = led.get(src, {}).get(issue)
        if e is None:
            self.count(self.unknown, "ledger")
            return
        groups = self.written.setdefault((src, issue), dict(a["restore_groups"]))
        groups[kind] = a["target_value"]
        if self.put(src, issue, e["pane_id"], {"role": e["role"], "groups": groups, "created": e["board_created"]},
                    e.get("terminal_id")):
            e["groups"] = dict(groups)

    def execute(self, plan, snap, led, ambiguous):
        self.plan_actions = plan["actions"]
        self.homes(led)
        self.deferred = set()
        self.written = {}

        for a in plan["actions"]:
            k, space, issue, role = a["kind"], a["space"], a["issue_id"], a["role"]
            key = "%s-%s" % (issue, space_key(space))
            if k == "hide":
                if call("board_ledger_hide", space, issue, a.get("fingerprint") or "")[0] == 0:
                    self.count(self.observed, "hidden")
            elif k == "unhide":
                if call("board_ledger_unhide", space, issue)[0] == 0:
                    self.count(self.observed, "unhidden")
            elif k == "forget":
                if call("board_ledger_remove", space, issue)[0] == 0:
                    self.count(self.observed, "forgotten")
            elif k == "relink":
                term = [p.get("terminal_id") or "" for p in snap["panes"] if p["pane_id"] == a["pane_id"]]
                if call("board_ledger_set_pane", space, issue, a["pane_id"], *term[:1])[0] == 0:
                    self.count(self.observed, "relinked")
            elif k == "close-question":
                self.ask("close", key, {"space": space, "issue": issue, "pane_id": a["pane_id"]})
            elif k == "conflict-question":
                self.ask("conflict", key, {"space": space, "issue": issue, "fields": a.get("fields"),
                                           "reason": a.get("reason")})
            elif k == "move-question":
                self.deferred.add((space, issue))
                self.ask("move", key, {"space": space, "issue": issue, "groups": a.get("groups")})
                call("board_ledger_mark_linear_change", self.source(space, issue, role), issue)
            elif k == "write-back-candidate":
                self.write_back(a, led)
            elif k == "agreement" and self.source(space, issue, role) == space:
                e = led.get(space, {}).get(issue)
                if e and self.put(space, issue, e["pane_id"], {"role": e["role"], "groups": a["groups"],
                                                               "created": e["board_created"]}, e.get("terminal_id")):
                    e["groups"] = a["groups"]
                    self.count(self.observed, "agreed")
        for tab in ambiguous:
            self.ask("layout", tab.replace(":", "-"), {"tab": tab})

        touching = {(a["space"], a["issue_id"]) for a in plan["actions"]
                    if a["kind"] in PLACING + ("move", "agreement")}
        self.hold = {(s["name"], leaf["issue_id"]) for s in plan["spaces"] for t in s["tabs"]
                     for c in columns_of(t["tree"]) for leaf in c if leaf.get("hold")}
        marked = self.held_tabs()
        jobs = []
        for s in plan["spaces"]:
            ws = self.workspace(snap, s["name"])
            for t in s["tabs"]:
                cols = columns_of(t["tree"])
                live = self.tab_named(snap, ws, t["name"], set()) if ws else None
                if not any((s["name"], leaf["issue_id"]) in touching for c in cols for leaf in c) \
                        and live not in marked:
                    continue
                if ws is None:
                    self.ask("space", space_key(s["name"]), {"space": s["name"]})
                    continue
                jobs.append((s["name"], ws, t["name"], cols))
        for job in self.leaving_first(jobs, snap, led):
            self.apply(*job)
        if self.surplus:
            self.ask("cap", "surplus", {"cap": CAP, "issues": sorted(self.surplus)})

    def leaving_first(self, jobs, snap, led):
        """A tab still holding a pane another tab takes is refused as foreign, so
        the taking tab goes first."""
        self.homes(led)
        tab_of = {p["pane_id"]: p.get("tab_id") for p in snap["panes"]}
        def live_tab(space, issue, role):
            e = led.get(self.source(space, issue, role), {}).get(issue)
            return tab_of.get(e["pane_id"]) if e else None
        takes = []
        for space, ws, label, cols in jobs:
            takes.append({live_tab(space, leaf["issue_id"], leaf["role"]) for c in cols for leaf in c
                          if (space, leaf["issue_id"]) not in self.deferred and not leaf.get("hold")})
        owns = [self.tab_named(snap, ws, label, set()) for _, ws, label, _ in jobs]
        order, left = [], list(range(len(jobs)))
        while left:
            free = [i for i in left if not any(j != i and owns[i] and owns[i] in takes[j] and owns[i] != owns[j]
                                               for j in left)]
            if not free:
                self.park(jobs, left, owns, snap, led)
                return [jobs[i] for i in order + left]
            order.append(free[0])
            left.remove(free[0])
        return [jobs[i] for i in order]

    def park(self, jobs, left, owns, snap, led):
        """A cycle of tabs each holding a pane another takes: every such pane waits
        in a parking tab of its own workspace, so each tab can then be built."""
        busy = in_use_panes(snap, self.restarted)
        panes = {p["pane_id"]: p for p in snap["panes"]}
        labels = {t["tab_id"]: t.get("label") for t in snap["tabs"]}
        cycle = {owns[i] for i in left if owns[i]}
        intent = {"kind": "park", "panes": {}}
        for j in left:
            space, _, _, cols = jobs[j]
            for leaf in (l for c in cols for l in c):
                issue, role = leaf["issue_id"], leaf["role"]
                src = self.source(space, issue, role)
                e = led.get(src, {}).get(issue)
                p = panes.get(e["pane_id"]) if e else None
                if p is None or p["tab_id"] not in cycle or p["tab_id"] == owns[j] or leaf.get("hold") \
                        or (space, issue) in self.deferred or p["pane_id"] in busy:
                    continue
                intent["panes"][p["pane_id"]] = {"space": src, "issue": issue, "tab": p["tab_id"],
                                                 "label": labels.get(p["tab_id"]), "ws": p["workspace_id"]}
        if not intent["panes"]:
            return
        iid = secrets.token_hex(8)
        self.journal_put(iid, intent)
        self.parks.append(iid)
        parking = {}
        for pid, info in sorted(intent["panes"].items()):
            where = parking.get(info["ws"])
            dest = [where[0], "right", where[1]] if where else ["new:%s:%s" % (info["ws"], PARKING)]
            rc, out, _ = call("board_move_pane", info["space"], info["issue"], *dest)
            parts = out.strip().split("\t")
            if rc == P_OK and len(parts) >= 4:
                parking.setdefault(info["ws"], (parts[3], parts[1]))
                self.count(self.observed, "parked")
            else:
                self.count(self.unknown, "parking")

    def parked(self):
        intents = self.journal()
        return {pid: info for iid in self.parks for pid, info in intents.get(iid, {}).get("panes", {}).items()}

    def unparked(self, snap):
        """The plan reads a parked pane where it was parked from: the parking tab
        is no board tab, and a pane in it would read as moved off the board."""
        parked = self.parked()
        tabs = {t["tab_id"]: t for t in snap.get("tabs", [])}
        out = json.loads(json.dumps(snap))
        for p in out["panes"]:
            info = parked.get(p["pane_id"])
            if info is None or tabs.get(p.get("tab_id"), {}).get("label") != PARKING:
                continue
            p["tab_id"] = info["tab"]
            if info["tab"] not in tabs:
                tabs[info["tab"]] = {"tab_id": info["tab"], "workspace_id": info["ws"], "label": info["label"]}
                out["tabs"].append(tabs[info["tab"]])
        return out

    def finish_parks(self):
        if not self.parks:
            return
        snap = self.snapshot()
        parking = {t["tab_id"] for t in snap["tabs"] if t.get("label") == PARKING}
        still = {p["pane_id"] for p in snap["panes"] if p.get("tab_id") in parking}
        intents = self.journal()
        for iid in self.parks:
            if still & set(intents.get(iid, {}).get("panes", {})):
                self.count(self.unknown, "parked")
            else:
                self.journal_put(iid, None)

    def held_tabs(self):
        if not os.path.exists(HELD_TABS):
            return set()
        self.private(HELD_TABS, "held tabs")
        try:
            with open(HELD_TABS) as f:
                tabs = json.load(f)["tabs"]
            return set(t for t in tabs if isinstance(t, str))
        except (OSError, ValueError, KeyError, TypeError):
            self.fail("held tabs", "the held-tab record cannot be read: %s" % HELD_TABS, FAILED)

    def mark_held(self, tab, held):
        tabs = self.held_tabs()
        if held == (tab in tabs):
            return
        tabs = tabs | {tab} if held else tabs - {tab}
        write_private(HELD_TABS, json.dumps({"version": 1, "tabs": sorted(tabs)}))

    def homes(self, led):
        home = {}
        for space, entries in led.items():
            for issue, e in entries.items():
                if e["role"] == "home":
                    home.setdefault(issue, space)
        self.source = lambda space, issue, role: home.get(issue, space) if role == "home" else space

    def action(self, space, issue, kinds):
        hit = [a for a in self.plan_actions if a["space"] == space and a["issue_id"] == issue and a["kind"] in kinds]
        return hit[0] if hit else None

    def reserve(self, t):
        issue, ident, title = t["id"], t.get("identifier") or "", t.get("title") or ""
        if call("board_reservation", issue)[0] == 0:
            return True
        rc, name, _ = call("scheme_name", "worktree", ident, title)
        rc2, branch, _ = call("scheme_name", "branch", ident, title)
        if rc != 0 or rc2 != 0 or not name.strip() or not branch.strip():
            self.count(self.unknown, "unnameable")
            return False
        keys = [k for k in ("project-%s" % ((t.get("project") or {}).get("id") or ""),
                            "team-%s" % ((t.get("team") or {}).get("id") or "")) if not k.endswith("-")]
        rc, repo, _ = call("scope_repo", *keys) if keys else (1, "", "")
        repo_unknown = rc != 0 or not repo.strip()
        if repo_unknown and keys and keys[0] not in self.asked_scopes:
            self.asked_scopes.add(keys[0])
            self.ask("repository", keys[0], {"scope": keys[0]})
        return call("board_reserve", issue, ident, name.strip(), branch.strip(),
                    "true" if repo_unknown else "false")[0] == 0

    def apply(self, space, ws, label, cols):
        # Every earlier apply moved panes, closed tabs and renamed panes it took
        # across workspaces, so each tab is planned against herdr as it is now.
        snap = self.snapshot()
        led = self.ledgers()
        self.relink(snap, led)
        self.homes(led)
        panes = {p["pane_id"]: p for p in snap["panes"]}
        busy = in_use_panes(snap, self.restarted)
        def pane_of(issue, role):
            e = led.get(self.source(space, issue, role), {}).get(issue)
            return panes.get(e["pane_id"]) if e else None
        tab = self.tab_named(snap, ws, label, {p["pane_id"] for c in cols for l in c
                                               for p in [pane_of(l["issue_id"], l["role"])] if p})
        held = sorted(i for i, e in led.get(space, {}).items()
                      if (space, i) in self.deferred or (space, i) in self.hold or e["pane_id"] in busy)

        intent = {"space": space, "ws": ws, "label": label, "columns": [], "leaves": {}, "held": held}
        for c in cols:
            out = []
            for leaf in c:
                issue, role = leaf["issue_id"], leaf["role"]
                place = self.action(space, issue, PLACING)
                if issue in held:
                    e = led[space][issue]
                    intent["leaves"][issue] = {"role": role, "groups": e["groups"], "created": e["board_created"],
                                               "new": False, "from_space": None, "hold": True,
                                               "old_groups": e["groups"]}
                elif (space, issue) in self.deferred:
                    continue
                elif place is not None:
                    if self.created >= CAP:
                        self.surplus.append(issue)
                        continue
                    if role == "home" and not (issue in self.tickets and self.reserve(self.tickets[issue])):
                        continue
                    self.created += 1
                    intent["leaves"][issue] = {"role": role, "groups": place.get("groups") or {}, "created": True,
                                               "new": True, "from_space": None, "hold": False, "old_groups": None}
                else:
                    src = self.source(space, issue, role)
                    e = led.get(src, {}).get(issue)
                    if e is None:
                        continue
                    move = self.action(space, issue, ("move", "agreement"))
                    intent["leaves"][issue] = {"role": role, "groups": move["groups"] if move else e["groups"],
                                               "created": e["board_created"], "new": False,
                                               "from_space": src if src != space else None,
                                               "hold": bool(leaf.get("hold")), "old_groups": e["groups"]}
                out.append(issue)
            if out:
                intent["columns"].append(out)
        if not any(not leaf["hold"] for leaf in intent["leaves"].values()):
            return

        iid = secrets.token_hex(8)
        self.journal_put(iid, intent)
        for issue, leaf in intent["leaves"].items():
            if leaf["from_space"]:
                e = led[leaf["from_space"]][issue]
                self.put(space, issue, e["pane_id"], {"role": e["role"], "groups": e["groups"],
                                                      "created": e["board_created"]}, e.get("terminal_id"))
                call("board_ledger_mark_linear_change", space, issue)

        anchor = None
        if tab is not None:
            here = sorted(p["pane_id"] for p in snap["panes"] if p.get("tab_id") == tab)
            anchor = here[0] if here else None
        for issue in [i for c in intent["columns"] for i in c if intent["leaves"][i]["new"]]:
            leaf = intent["leaves"][issue]
            os.makedirs(PANE_DIR, exist_ok=True)
            where = "split:%s:down" % anchor if anchor else "tab:%s:%s" % (ws, label)
            rc, out, _ = call("board_create_pane", space, issue, leaf["role"], PANE_DIR, where)
            parts = out.strip().split("\t") if out.strip() else []
            if rc == P_REFUSED:
                hit = [p for p in self.snapshot()["panes"] if p.get("label") == label_of(issue, leaf["role"], space)]
                parts = [hit[0]["pane_id"], hit[0].get("terminal_id") or "", hit[0]["tab_id"]] if len(hit) == 1 else []
            elif rc != P_OK:
                self.count(self.unknown, "placements")
            if not parts or not parts[0] or not self.put(space, issue, parts[0], leaf, parts[1] if len(parts) > 1 else ""):
                intent["columns"] = [c for c in ([i for i in c if i != issue] for c in intent["columns"]) if c]
                del intent["leaves"][issue]
                continue
            self.count(self.observed, "placed")
            anchor = anchor or parts[0]
            tab = tab or (parts[2] if len(parts) > 2 and parts[2] else None)
        self.journal_put(iid, intent)
        if not intent["columns"]:
            self.journal_put(iid, None)
            return

        rc, out, err = call("board_apply_tab", space, tab or "new:%s:%s" % (ws, label), dump(intent["columns"]),
                            *(["held:" + ",".join(held)] if held else []))
        if rc == P_OK:
            self.settle(intent, out)
            for issue, leaf in intent["leaves"].items():
                if not leaf["new"] and not leaf["hold"] and (leaf["from_space"] or leaf["groups"] != leaf["old_groups"]):
                    self.count(self.observed, "moved")
            self.journal_put(iid, None)
            self.mark_built(intent, out)
            return
        if rc == P_IN_USE:
            lines = [l.partition("\t") for l in out.splitlines()]
            waiting = {i for i, _, why in lines if why != "held"}
            if any(why == "held" for _, _, why in lines):
                waiting |= {i for i, leaf in intent["leaves"].items() if not leaf["hold"] and not leaf["new"]
                            and (leaf["from_space"] or leaf["groups"] != leaf["old_groups"])}
            for issue in sorted(waiting & set(intent["leaves"])):
                self.ask("move", "%s-%s" % (issue, space_key(space)),
                         {"space": space, "issue": issue, "tab": label, "reason": "tab-in-use"})
            self.count(self.observed, "tabs_deferred")
        elif rc == P_NO_SERVER:
            self.unsettle(intent)
            self.journal_put(iid, None)
            self.fail("herdr", err or "the herdr server stopped answering", NO_SERVER)
        elif rc == P_REFUSED:
            where = tab or "%s-%s" % (ws, space_key(label))
            self.ask("layout", where.replace(":", "-"), {"tab": where, "label": label,
                                                         "reason": last_line(err, "refused")})
            self.count(self.observed, "tabs_refused")
        else:
            self.count(self.unknown, "tabs")
        self.unsettle(intent)
        self.journal_put(iid, None)

    def mark_built(self, intent, rows):
        """A tab built around a held pane reads back as columns the board did not
        render; until it is rebuilt, its layout is kept out of the plan."""
        where = {}
        for line in rows.splitlines():
            parts = line.split("\t")
            if len(parts) >= 4:
                where[parts[0]] = (parts[1], parts[3])
        tabs = {where[i][1] for c in intent["columns"] for i in c if i in where and not intent["leaves"][i]["hold"]}
        if len(tabs) != 1:
            return
        tab = tabs.pop()
        rc, cols = self.tab_columns(tab)
        expect = [c for c in ([where[i][0] for i in col if i in where and where[i][1] == tab]
                              for col in intent["columns"]) if c]
        self.mark_held(tab, rc != 0 or cols != expect)

try:
    Sync().run()
except Stop as s:
    sys.exit(s.code)
PYEOF

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    herdr_linear::board_sync
    exit
fi

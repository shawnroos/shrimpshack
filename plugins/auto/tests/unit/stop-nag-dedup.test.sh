#!/usr/bin/env bash
# auto U2 (finding #9): the Stop hook fired an IDENTICAL blocking message on every
# turn-end (~10x across a run) even while the boss was correctly yielding for live
# work. U2 de-duplicates that nag: the FIRST block for a given blocking state
# emits the full guidance; subsequent turns with the SAME state emit a terse
# one-liner. The block itself is ALWAYS preserved (deliberate-stop is not
# silenced — there is no per-agent liveness signal to safely downgrade the block;
# that is deferred to future work). When the blocking state clears or changes,
# the full guidance re-emits.
#
# Institutional anchors:
#   - field-notes-2026-07-21 finding #9 (identical blocking re-prompt ~10x)
#   - KTD2: dedup ≠ silence — a fresh run-level beat does not prove agent liveness

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }

# Plant a single blocking run (driver=self, fresh beat → not stale, met=false).
plant_block() {
  local repo="$1" run="$2" blockers="$3"
  mkdir -p "${repo}/.claude/auto"
  "$PY" - "$repo" "$run" "$blockers" <<'PYEOF'
import json, sys, os
repo, run, blockers = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = {
  "run_id": run, "loop_phase": "work",
  "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
  "exit_predicate_result": {"met": False, "blockers": blockers, "majors": 0,
                            "all_steps_terminal": False},
}
with open(os.path.join(repo, ".claude", "auto", run + ".json"), "w") as f:
  json.dump(data, f)
PYEOF
}

decide() { ( cd "$1" && "$PY" "$ON_STOP" "$1" </dev/null 2>/dev/null ) || true; }
is_block() { printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; }
is_full() { printf '%s' "$1" | grep -q 'YIELD silently'; }   # full-guidance marker

echo "stop-nag-dedup.test.sh"

REPO="$(mktemp -d -t auto-test.XXXXXX)"
plant_block "$REPO" "run-x" 1

it "#9: first block emits the FULL guidance and blocks"
OUT1="$(decide "$REPO")"
if is_block "$OUT1" && is_full "$OUT1"; then pass; else fail "expected full block, got: $OUT1"; fi

it "#9: a task run's second block on the SAME state is DEDUPED (terse) but STILL blocks"
OUT2="$(decide "$REPO")"
if is_block "$OUT2" && ! is_full "$OUT2"; then pass; else fail "expected deduped block, got: $OUT2"; fi

it "#9: a CHANGED blocking state re-emits the full guidance"
plant_block "$REPO" "run-x" 3   # blockers 1 → 3 : signature changes
OUT3="$(decide "$REPO")"
if is_block "$OUT3" && is_full "$OUT3"; then pass; else fail "expected full block after change, got: $OUT3"; fi

it "#9: when blocking clears, the nag state resets (allow stop, no message)"
rm -f "${REPO}/.claude/auto/run-x.json"
OUT4="$(decide "$REPO")"
if [ -z "$(printf '%s' "$OUT4" | tr -d '[:space:]')" ]; then pass; else fail "expected silent allow, got: $OUT4"; fi

it "#9: after a clear, a NEW block emits full guidance again (state was reset)"
plant_block "$REPO" "run-x" 1
OUT5="$(decide "$REPO")"
if is_block "$OUT5" && is_full "$OUT5"; then pass; else fail "expected full block after reset, got: $OUT5"; fi

rm -rf "$REPO"

WORK="$(mktemp -d -t auto-nag-prog.XXXXXX)"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO
for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
NOREPO="${WORK}/norepo"
OTHER="${WORK}/other-cwd"
mkdir -p "$NOREPO" "${OTHER}/.claude/auto"

stop_as() {
  local cwd="$1" sid="$2" repo="${3:-}"
  ( cd "$cwd" && "$PY" "$ON_STOP" "$repo" <<< "{\"session_id\": \"${sid}\"}" 2>/dev/null ) || true
}
verdict() {
  if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then echo allow; return; fi
  if printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; then echo block; else echo "other:$1"; fi
}

prog() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import programme_records
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
load, save = programme_records.load, programme_records.save
args = sys.argv[2:]
NOW = datetime.datetime.now(datetime.timezone.utc)
def iso(minutes=0):
    return (NOW + datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
def item(item_id, state, rule=None, pane=None):
    it = ph.new_item(item_id, item_id, state=state, now_iso=iso(-30))
    it["matched_rule"] = rule
    it["owner"] = {"pane": pane, "terminal_id": None, "session_id": "sess-w"}
    if state == "waiting":
        it["waiting_on"] = {"who": "shawn", "watcher": None, "reporter": "shawn"}
    return it
def quiet_rows(run):
    return [r for r in pj.read(run) if r.get("kind") == "stop_quiet"]
$(cat)
PYEOF
}

make_prog() {
  prog "$1" "$2" "$3" <<'EOF'
space, sid, rule = args
run = ph.create_programme([space], sid)["run"]
rec = load(run)
rec["programme"]["items"] = {"linear:AI-1": item("linear:AI-1", "waiting")}
rec["programme"]["agreement"]["accepted"] = {"at": iso(-60), "prompt_id": "p000001"}
if rule == "until_time":
    rec["programme"]["items"]["linear:AI-1"]["matched_rule"] = "r1"
    rec["programme"]["agreement"]["terms"]["stop_rule"].update(value="until_time", until=iso(600))
save(run, rec)
print(run)
EOF
}

RUN="$(make_prog w2 sess-pm nothing)"

it "AE6: the PM's first stop with no_rule_proposed blocks and names the propose-rule fix"
P1="$(stop_as "$NOREPO" sess-pm)"
if [ "$(verdict "$P1")" = block ] && printf '%s' "$P1" | grep -q 'programme.sh propose-rule'; then pass; else fail "got: $P1"; fi

it "AE6: the PM's second stop with the same reasons is let through with no message"
P2="$(stop_as "$NOREPO" sess-pm)"
if [ "$(verdict "$P2")" = allow ]; then pass; else fail "expected silent allow, got: $P2"; fi

it "AE6: the quiet stop journals one stop_quiet row for the PM's session"
GOT="$(prog "$RUN" <<'EOF'
rows = quiet_rows(args[0])
print(len(rows), rows[0]["session_id"] if rows else "-", rows[0]["payload"].get("stop_rule") if rows else "-")
EOF
)"
if [ "$GOT" = "1 sess-pm nothing_it_can_act_on" ]; then pass; else fail "got: $GOT"; fi

it "the same session stopping from another cwd with the same reasons is still quiet"
P_OTHER="$(stop_as "$OTHER" sess-pm "$OTHER")"
if [ "$(verdict "$P_OTHER")" = allow ]; then pass; else fail "got: $P_OTHER"; fi

it "AE6: an added open item blocks again with the full fix text"
prog "$RUN" <<'EOF' >/dev/null
rec = load(args[0])
rec["programme"]["items"]["linear:AI-2"] = item("linear:AI-2", "open", rule="r1", pane="w2:p4")
save(args[0], rec)
EOF
P3="$(stop_as "$NOREPO" sess-pm)"
if [ "$(verdict "$P3")" = block ] && printf '%s' "$P3" | grep -q 'linear:AI-2 is open' \
   && printf '%s' "$P3" | grep -q 'propose-rule'; then pass; else fail "got: $P3"; fi

it "a new session driving the same programme with the same reasons blocks once"
prog "$RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["driving_session_id"] = "sess-new"; save(args[0], rec)
ph._write_lease("default", "w2", args[0], ph.home_path(args[0]), "sess-new", iso())
EOF
N1="$(verdict "$(stop_as "$NOREPO" sess-new)")"
N2="$(verdict "$(stop_as "$NOREPO" sess-new)")"
if [ "$N1 $N2" = "block allow" ]; then pass; else fail "got: $N1 $N2"; fi

U_RUN="$(make_prog w3 sess-until until_time)"

it "until_time: the first stop blocks, the next is quiet"
U1="$(verdict "$(stop_as "$NOREPO" sess-until)")"
U2="$(verdict "$(stop_as "$NOREPO" sess-until)")"
if [ "$U1 $U2" = "block allow" ]; then pass; else fail "got: $U1 $U2"; fi

it "until_time: a new claim after a quiet stop blocks again"
prog "$U_RUN" <<'EOF' >/dev/null
pj.append_claim(args[0], "sess-w", {"item": "linear:AI-1", "deliverable": "merged", "ref": "pr-1"})
EOF
U3="$(stop_as "$NOREPO" sess-until)"
if [ "$(verdict "$U3")" = block ] && printf '%s' "$U3" | grep -q 'unread_claim'; then pass; else fail "got: $U3"; fi

S_RUN="$(make_prog w4 sess-store nothing)"

it "an unwritable stop store lets the stop through"
SHOWN="$(prog "$S_RUN" sess-store <<'EOF'
print(ph.stop_shown_path(args[0], args[1]))
EOF
)"
mkdir -p "$SHOWN"
P_STORE="$(stop_as "$NOREPO" sess-store)"
if [ "$(verdict "$P_STORE")" = allow ]; then pass; else fail "got: $P_STORE"; fi

rm -rf "$WORK"

echo ""
echo "stop-nag-dedup.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

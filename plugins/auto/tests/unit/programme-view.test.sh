#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
MOD="${AUTO_ROOT}/mods/programme-view"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-view.test.sh"

WORK="$(mktemp -d -t auto-programme-view.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr; do
  printf '#!/bin/sh\nexit 1\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def mutate(run, fn):
    def body(rec):
        rec["programme"] = ph.normalize_programme(rec["programme"])
        fn(rec["programme"])
    core._with_locked_run_record(ph.home_path(run), run, body)
$(cat)
PYEOF
}

new_run() {
  run_py "$1" <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
}

RUN="$(new_run w2)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
VIEW="${HOME_DIR}/views/view.json"

run_py "$RUN" <<'EOF' >/dev/null
run = args[0]
def seed(p):
    p["agreement"]["accepted"] = {"at": "2026-10-01T00:00:00Z", "prompt_id": "p000000", "quote": "go"}
    done = ph.new_item("linear:AI-1", "Ship the parser", state="done", now_iso="2026-09-30T00:00:00Z")
    done["matched_rule"] = [{"id": "code-change"}]
    done["deliverables"] = {"merged": {"result": "confirmed", "ref": "org/repo#1", "checked_at": "2026-10-02T00:00:00Z"}}
    done["owner"] = {"pane": "w2:p1", "terminal_id": None, "session_id": "sess-w1"}
    wait = ph.new_item("herdr:w2-p3", "\x1b[31mRED\x1b[0m title\x07", state="waiting", now_iso="2026-10-03T00:00:00Z")
    wait["matched_rule"] = [{"id": "code-change"}]
    wait["deliverables"] = {"merged": {"result": "unknown"}}
    wait["waiting_on"] = {"who": "ci", "watcher": None, "reporter": None}
    handed = ph.new_item("linear:AI-3", "Flag rollout", state="handed", now_iso="2026-09-30T00:00:00Z")
    handed["handed"] = {"at": "2026-10-03T01:00:00Z", "question": "Turn the flag on for everyone?", "answered": None}
    p["items"] = {i["id"]: i for i in (done, wait, handed)}
    p["working_model"]["queue"] = [{"id": "q000001", "action": "check_ci", "item": "herdr:w2-p3", "why": "PR opened", "at": "2026-10-03T02:00:00Z"}]
mutate(run, seed)
pj.append(run, "stopped_unwatched", "sess-pm", {"items": ["herdr:w2-p3"]})
pj.append(run, "stopped_unwatched", "sess-pm", {"items": ["herdr:w2-p3"]})
EOF

it "no view exists before a programme write"
check "absent" "$([ -e "$VIEW" ] && echo present || echo absent)"

OUT="$("$PY" "$PROG" set-now "Watching CI on the parser" --item herdr:w2-p3 2>&1)"
it "set-now succeeds"
has '"ok": true' "$OUT"

it "a programme write refreshes views/view.json"
check "present" "$([ -f "$VIEW" ] && echo present || echo absent)"

it "view.json is mode 0600"
check "600" "$(stat -f '%Lp' "$VIEW" 2>/dev/null || stat -c '%a' "$VIEW" 2>/dev/null)"

it "the views folder is mode 0700"
check "700" "$(stat -f '%Lp' "${HOME_DIR}/views" 2>/dev/null || stat -c '%a' "${HOME_DIR}/views" 2>/dev/null)"

view_q() {
  "$PY" - "$VIEW" "$1" <<'EOF' 2>&1
import json, sys
v = json.load(open(sys.argv[1]))
m = v["model"]
items = {i["id"]: i for i in m["items"]}
print(eval(sys.argv[2]))
EOF
}

it "the model has all seven parts"
check "doing_now queue watching waiting_on_whom decisions_for_shawn just_did rules_in_force" \
  "$(view_q '" ".join(k for k in ["doing_now","queue","watching","waiting_on_whom","decisions_for_shawn","just_did","rules_in_force"] if k in m)')"

it "doing now is the set-now text"
check "Watching CI on the parser|herdr:w2-p3" "$(view_q 'm["doing_now"]["text"] + "|" + m["doing_now"]["item"]')"

it "the queue lists the queued action"
check "check_ci herdr:w2-p3" "$(view_q '" ".join(m["queue"][0][k] for k in ("action","item"))')"

it "the waiting item shows unwatched"
check "herdr:w2-p3 ci False" "$(view_q '" ".join(str(w[k]) for w in m["waiting_on_whom"] for k in ("item","who","watched"))')"

it "watching explains the unwatched wait"
has "herdr:w2-p3" "$(view_q 'json.dumps(m["watching"])')"

it "decisions for Shawn lists the handed item with its question"
check "linear:AI-3|Turn the flag on for everyone?" "$(view_q '"|".join([d["item"] + "|" + d["question"] for d in m["decisions_for_shawn"] if d["kind"] == "handed"])')"

it "just did shows the latest journal write first"
check "working_now" "$(view_q 'm["just_did"][0]["kind"]')"

it "just did never shows prompts"
check "0" "$(view_q 'sum(1 for j in m["just_did"] if j["kind"] == "prompt")')"

it "rules in force carry the agreement terms"
check "nothing_it_can_act_on" "$(view_q 'm["rules_in_force"]["agreement"]["terms"]["stop_rule"]["value"]')"

it "items list all three with effective states"
check "herdr:w2-p3=waiting linear:AI-1=done linear:AI-3=handed" \
  "$(view_q '" ".join(i["id"] + "=" + i["effective_state"] for i in m["items"])')"

it "the done item shows its deliverable evidence"
check "merged:confirmed:org/repo#1|1 of 1 confirmed" \
  "$(view_q '"|".join([":".join([d["name"], d["result"], d["ref"]]) for d in items["linear:AI-1"]["deliverables"]] + [items["linear:AI-1"]["evidence"]])')"

it "the owner pane is shown"
check "w2:p1" "$(view_q 'items["linear:AI-1"]["owner_pane"]')"

it "an item with no owner session reads session unknown"
check "session unknown" "$(view_q 'items["herdr:w2-p3"]["session"]')"

it "the stopped unwatched mark shows once on its item as needing Shawn"
check "['new', 'stopped unwatched']|True" "$(view_q 'str(items["herdr:w2-p3"]["marks"]) + "|" + str(items["herdr:w2-p3"]["needs_shawn"])')"

it "the item that joined before acceptance is not new"
check "[]" "$(view_q 'str(items["linear:AI-1"]["marks"])')"

it "an escape sequence in a title is stripped from the model"
check "RED title" "$(view_q 'items["herdr:w2-p3"]["title"]')"

it "no raw escape byte anywhere in view.json"
check "0" "$("$PY" -c 'import sys; print(open(sys.argv[1], encoding="utf-8").read().count("\x1b") + open(sys.argv[1], encoding="utf-8").read().count("\\u001b"))' "$VIEW")"

it "the programme is not ended and not done"
check "None False" "$(view_q 'str(m["programme"]["ended"]) + " " + str(m["programme"]["done"])')"

STATUS="$("$PY" "$PROG" status 2>&1)"
it "status prints the seven part headings"
for head in "Doing now" "Queue" "Watching" "Who waits on whom" "Decisions for Shawn" "Just did" "Rules in force" "Items"; do
  has "$head" "$STATUS"
done

it "status text has no escape byte"
check "0" "$(printf '%s' "$STATUS" | LC_ALL=C grep -c $'\x1b')"

it "status shows the waiting item as unwatched"
has "herdr:w2-p3 waits on ci (unwatched)" "$STATUS"

it "status marks the item needing Shawn"
has "needs Shawn" "$STATUS"

it "status names the session unknown"
has "session unknown" "$STATUS"

it "status text is the view rows, line for line (mod parity)"
check "same" "$("$PY" - "$VIEW" "$STATUS" <<'EOF'
import json, sys
rows = [r["text"] for r in json.load(open(sys.argv[1]))["rows"]]
print("same" if "\n".join(rows) == sys.argv[2] else "differs:\n" + "\n".join(rows))
EOF
)"

JSON_OUT="$("$PY" "$PROG" status --json 2>&1)"
it "status --json carries the same model and rows as view.json"
check "same" "$("$PY" - "$VIEW" "$JSON_OUT" <<'EOF'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.loads(sys.argv[2])
for d in (a, b):
    d.pop("generated_at", None)
print("same" if a == b else "differs")
EOF
)"

it "status --json lists the same items in the same states as the view"
check "same" "$("$PY" - "$VIEW" "$JSON_OUT" <<'EOF'
import json, sys
pick = lambda v: [(i["id"], i["effective_state"], tuple(i["marks"])) for i in v["model"]["items"]]
print("same" if pick(json.load(open(sys.argv[1]))) == pick(json.loads(sys.argv[2])) else "differs")
EOF
)"

it "status works from a session that does not drive the programme"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" status --run "$RUN" 2>&1)"
has "Decisions for Shawn" "$OUT"

it "status accepts an empty positional from the slash command"
OUT="$("$PY" "$PROG" status "" 2>&1)"
has "Rules in force" "$OUT"

it "status is listed by describe as a read"
has '"status"' "$("$PY" "$PROG" describe 2>&1)"

it "a failed view refresh never fails the write"
mv "$VIEW" "${VIEW}.keep" && mkdir "$VIEW"
OUT="$("$PY" "$PROG" set-now "still going" 2>&1)"
RC=$?
rmdir "$VIEW" && mv "${VIEW}.keep" "$VIEW"
check "0" "$RC"
it "a failed view refresh says so on stderr"
has "view refresh failed" "$OUT"

EMPTY="$(new_run w9)"
EMPTY_VIEW="${CLAUDE_AUTO_DATA_DIR}/programmes/${EMPTY}/views/view.json"
OUT="$("$PY" "$PROG" status --run "$EMPTY" 2>&1)"
it "an empty programme renders no items"
has "no items" "$OUT"
it "an empty programme still renders the rules in force"
has "stop_rule: nothing_it_can_act_on" "$OUT"
it "an empty programme reads done"
has "done: yes" "$OUT"

run_py "$EMPTY" <<'EOF' >/dev/null
ph.end_programme(args[0], "finished")
EOF
OUT="$("$PY" "$PROG" status --run "$EMPTY" --json 2>&1)"
it "an ended programme shows ended apart from done"
check "finished True" "$("$PY" -c 'import json,sys; m=json.loads(sys.argv[1])["model"]["programme"]; print(m["ended"]["reason"], m["done"])' "$OUT")"
OUT="$("$PY" "$PROG" status --run "$EMPTY" 2>&1)"
it "status text names the ended programme"
has "ended: finished" "$OUT"

QUIET="$(new_run w7)"
run_py "$QUIET" <<'EOF' >/dev/null
def seed(p):
    wait = ph.new_item("herdr:w7-p1", "Waiting quietly", state="waiting")
    wait["waiting_on"] = {"who": "ci", "watcher": None, "reporter": None}
    p["items"] = {wait["id"]: wait}
mutate(args[0], seed)
EOF
OUT="$("$PY" "$PROG" status --run "$QUIET" --json 2>&1)"
it "an unwatched wait with no stopped_unwatched entry carries no stopped mark"
check "False False" "$("$PY" -c 'import json,sys; i=json.loads(sys.argv[1])["model"]["items"][0]; print("stopped unwatched" in i["marks"], i["needs_shawn"])' "$OUT")"

WATCHED="$(new_run w8)"
run_py "$WATCHED" <<'EOF' >/dev/null
def seed(p):
    now = core.now_iso()
    p["watchers"] = {
        "cron": {"task_id": "c1", "kind": "cron", "prompt": "Run the programme sweep.", "last_beat_at": now},
        "remit": {"process_id": "4242", "last_beat_at": now},
        "tracker-source": {"task_id": "bh1i1vbv7", "kind": "monitor", "last_beat_at": now},
        "stray": {"task_id": "t9", "kind": "monitor", "last_beat_at": now},
    }
    p["sources"] = {"plans": {"unsupported_since": now, "unavailable_since": None},
                    "tracker": {"unavailable_since": now, "watcher": "tracker-source"},
                    "herdr": {"unavailable_since": now, "watcher": "remit"}}
mutate(args[0], seed)
EOF
OUT="$("$PY" "$PROG" status --run "$WATCHED" 2>&1)"
it "a watcher with no item never renders as None"
lacks "None:" "$OUT"
it "the cron watcher renders as the cadence fallback"
has "cron (live) — hourly fallback" "$OUT"
it "the remit watcher renders as watching the space"
has "remit (live) — watches the space" "$OUT"
it "a source watcher renders by the source it watches"
has "tracker-source (live) — watches source tracker" "$OUT"
it "the remit watcher still watches the space when it also covers a source outage"
has "herdr: remit (live) — herdr unavailable since" "$OUT"
it "a watcher that watches nothing recorded says so"
has "stray (live) — watches nothing recorded" "$OUT"
it "a source outage with a live watcher renders live"
has "tracker: tracker-source (live) — tracker unavailable since" "$OUT"
it "an unsupported source renders as not available on this machine"
has "plans: not available on this machine" "$OUT"
it "a source never read yet says so"
has "tasks: not read yet" "$OUT"
it "the view never says board"
lacks "board" "$OUT"

it "the mod reads the view format this module writes"
FORMAT="$(run_py <<'EOF'
print(load_lib_module("programme_view").VIEW_FORMAT)
EOF
)"
has "const VIEW_FORMAT = ${FORMAT}" "$(cat "${MOD}/register.tsx")"

it "the mod is declared in the plugin's hooks file"
check "../../mods/programme-view/register.tsx" "$("$PY" -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["modules"]))' "${AUTO_ROOT}/.claude/hooks/hooks.json")"

it "the mod's slash command does not share a name with a command or skill"
NAME="$(sed -n "s/^ *name: '\(.*\)',$/\1/p" "${MOD}/register.tsx")"
check "programme-view|absent" "${NAME}|$([ -e "${AUTO_ROOT}/commands/${NAME}.md" ] || [ -e "${AUTO_ROOT}/skills/${NAME}" ] && echo present || echo absent)"

echo "programme-view.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

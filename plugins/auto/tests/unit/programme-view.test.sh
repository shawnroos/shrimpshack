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

WORK_OUT="$(run_py <<'EOF'
import datetime
pv = load_lib_module("programme_view")
prog = load_lib_module("programme")
NOW = datetime.datetime(2026, 10, 19, 10, 0, 0, tzinfo=datetime.timezone.utc)
def ago(seconds):
    return (NOW - datetime.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
def step(title, clause=None):
    return {"title": title, "clause": clause}
def traj(recorded_at, done=(), current=None, planned=(), finish="PR merged", location=None, h="h0"):
    return {"done": list(done), "current": current, "planned": list(planned), "finish": finish,
            "location": location, "recorded_at": recorded_at, "session_id": "sess-pm", "hash": h}
def rec(items=(), cadence="on_change", seconds=3600, sweeps=None):
    block = ph.new_programme_block([("local", "w2")], "2026-10-19T08:00:00Z")
    block["agreement"]["terms"]["cadence"].update(value=cadence, seconds=seconds)
    block["items"] = {i["id"]: i for i in items}
    if sweeps is not None:
        block["trajectory_sweeps"] = sweeps
    return {"run_id": "prog-x", "programme": block}
def item(key, state="open", joined="2026-10-19T08:00:00Z", trajectory=None, waiting_on=None, owner=None):
    i = ph.new_item(key, f"title {key}", state=state, now_iso=joined)
    i["trajectory"] = trajectory
    i["waiting_on"] = waiting_on
    if owner:
        i["owner"].update(owner)
    return i
def row(kind, at, **payload):
    return {"kind": kind, "at": at, "session_id": "sess-pm", "payload": payload}
def view(r, journal=(), rules=None):
    return pv.build(r, list(journal), NOW, rules=rules)
def work(v):
    return {w["id"]: w for w in v["work"]}
def out(name, value):
    print(f"{name}={value}")

v = view(rec([item("t:a", trajectory=traj(ago(2400)))], cadence="fixed", seconds=900))
w = work(v)["t:a"]
out("fixed900", f"{w['age_seconds']} {w['faded']}")

v = view(rec([item("t:a", trajectory=traj(ago(1500)))], sweeps=[ago(2400), ago(1800)]))
w = work(v)["t:a"]
out("onchange10", f"{w['fade_after_seconds']} {w['faded']}")

v = view(rec([item("t:a", trajectory=traj(ago(4200))), item("t:b", trajectory=traj(ago(4860)))],
             sweeps=[ago(7200), ago(4800)]))
out("onchange40", f"{work(v)['t:a']['faded']} {work(v)['t:b']['faded']} {work(v)['t:a']['fade_after_seconds']}")

v = view(rec([item("t:a", trajectory=traj(ago(1500)))], cadence="fixed", seconds=600))
w = work(v)["t:a"]
out("fixed600", f"{w['fade_after_seconds']} {w['faded']}")

v = view(rec([item("t:a", trajectory=traj(ago(2000)))], sweeps=[ago(2000)]))
w = work(v)["t:a"]
out("onesweep", f"{w['fade_after_seconds']} {w['faded']}")

v = view(rec([item("t:a")]))
w = work(v)["t:a"]
out("noplan", f"{w['no_plan']} {w['steps']} {w['age_seconds']} {w['faded']}")

def proposal_view(refusal_at, target="cadence"):
    r = rec()
    r["programme"]["agreement"]["terms"]["cadence"]["proposal"] = {
        "value": "fixed", "extras": {"seconds": 900}, "at": "2026-10-19T09:00:00Z", "origin": "ui", "state": "pending"}
    j = [row("approval_refused", refusal_at, verb="amend-term", target=target, refused_prompt_id="p1",
             reason="prompt p1 was not typed by Shawn")]
    return {t["key"]: t for t in view(r, j)["contract"]["terms"]}["cadence"]["proposal"]
p = proposal_view("2026-10-19T09:05:00Z")
out("refused_newer", f"{p['state']}|{p.get('reason')}")
out("refused_older", proposal_view("2026-10-19T08:55:00Z")["state"])
out("refused_other_term", proposal_view("2026-10-19T09:05:00Z", target="stop_rule")["state"])

r = rec([item("t:a")])
r["programme"]["agreement"]["terms"]["cadence"]["proposal"] = {
    "value": "fixed", "extras": {}, "at": "2026-10-19T09:00:00Z", "origin": "pm", "state": "superseded"}
p = {t["key"]: t for t in view(r)["contract"]["terms"]}["cadence"]["proposal"]
out("superseded_kept", p["state"])

waiting = {"who": "ci", "watcher": None, "reporter": "worker-1"}
v = view(rec([item("t:w", state="waiting", trajectory=traj(ago(60)), waiting_on=waiting)]))
out("reporter_only", work(v)["t:w"]["watch"]["state"])

r = rec([item("t:w", state="waiting", trajectory=traj(ago(60)),
              waiting_on={"who": "system", "watcher": "t-w", "reporter": None})])
r["programme"]["watchers"] = {"t-w": {"item": "t:w", "retry": {"deliverable": "merged"}, "last_beat_at": None}}
out("retry", work(view(r))["t:w"]["watch"]["state"])

r = rec([item("t:w", state="waiting", trajectory=traj(ago(60)),
              waiting_on={"who": "ci", "watcher": "cad", "reporter": "worker-1"})], seconds=900)
r["programme"]["watchers"] = {"cad": {"kind": "cron", "task_id": "c1", "prompt": "/sweep", "last_beat_at": ago(100)}}
watch = work(view(r))["t:w"]["watch"]
out("cron_live", f"{watch['state']} {watch.get('interval_seconds')}")

r = rec([item("t:w", state="waiting", trajectory=traj(ago(60)),
              waiting_on={"who": "ci", "watcher": "mon", "reporter": None})], seconds=900)
r["programme"]["watchers"] = {"mon": {"kind": "monitor", "task_id": "m1", "last_beat_at": ago(120)}}
watch = work(view(r))["t:w"]["watch"]
out("monitor_live", f"{watch['state']} {watch.get('interval_seconds')} {watch.get('beat_age_seconds')}")

r = rec([item("t:w", state="waiting", trajectory=traj(ago(60)),
              waiting_on={"who": "ci", "watcher": "mon", "reporter": None})], seconds=900)
r["programme"]["watchers"] = {"mon": {"kind": "monitor", "task_id": "m1", "last_beat_at": ago(5000)}}
out("stale_watcher", work(view(r))["t:w"]["watch"]["state"])

v = view(rec([item("t:w", state="waiting", trajectory=traj(ago(60)), waiting_on={"who": "ci"})]))
out("nothing", work(v)["t:w"]["watch"]["state"])
v = view(rec([item("t:a", trajectory=traj(ago(60)))]))
out("open_watch", work(v)["t:a"]["watch"])

v = view(rec([item("t:d", state="done"), item("t:h", state="handed"), item("t:x", state="dropped"),
              item("t:a")]))
out("finished_absent", " ".join(w["id"] for w in v["work"]))

items = [item("t:old", joined="2026-10-19T07:00:00Z", trajectory=traj(ago(60), h="ho")),
         item("t:chg", joined="2026-10-19T08:30:00Z", trajectory=traj(ago(60), h="hc")),
         item("t:new", joined="2026-10-19T09:00:00Z"),
         item("t:w", state="waiting", joined="2026-10-19T09:30:00Z", waiting_on={"who": "ci"})]
j = [row("trajectory_changed", ago(600), item="t:chg", old_hash="hb", new_hash="hx"),
     row("trajectory_changed", ago(300), item="t:chg", old_hash="hx", new_hash="hc")]
v = view(rec(items), j)
out("order", " ".join(w["id"] for w in v["work"]))
w = work(v)
out("changed", f"{w['t:chg']['changed_since_first']} {w['t:chg']['change_hash']} {w['t:chg']['hash']} "
               f"{w['t:old']['changed_since_first']} {w['t:old']['change_hash']}")

c = "term:cadence"
items = [item("t:a", trajectory=traj(ago(60), done=[step("old", c), step("older", c)], current=step("now", c),
                                     planned=[step("next", c), step("free"), step("i", "instruction:i1")])),
         item("t:w", state="waiting", waiting_on={"who": "ci"},
              trajectory=traj(ago(60), current=step("wait", c), planned=[step("then", "term:remit")])),
         item("t:d", state="done", trajectory=traj(ago(60), current=step("gone", c)))]
r = rec(items)
r["programme"]["instructions"] = [
    {"id": "i1", "quote": "keep PRs small", "applies_to": "t:a", "state": "active", "at": ago(900)},
    {"id": "i2", "quote": "no force pushes", "applies_to": None, "state": "active", "at": ago(900)},
    {"id": "i3", "quote": "old", "applies_to": None, "state": "closed", "at": ago(900)}]
v = view(r, rules=prog.rules_in_force(r, {}))
terms = {t["key"]: t for t in v["contract"]["terms"]}
out("reliant", f"{terms['cadence']['reliant_steps']} {terms['remit']['reliant_steps']} {terms['stop_rule']['reliant_steps']}")
ins = {i["id"]: i for i in v["contract"]["instructions"]}
out("instructions", " ".join(sorted(ins)) + f" | {ins['i1']['scope']} {ins['i1']['reliant_steps']} {ins['i1']['quote']}"
                    f" | {ins['i2']['scope']} {ins['i2']['applies_to']} {ins['i2']['reliant_steps']}")
w = work(v)["t:a"]
out("steps", " ".join(f"{s['kind']}:{s['clause_label']}" for s in w["steps"]))
out("no_clause", f"{[s for s in w['steps'] if s['title'] == 'free'][0]['no_clause']}")
out("waiting_glyph", work(v)["t:w"]["steps"][0]["kind"])
out("finish", w["finish"])

r = rec()
tools = r["programme"]["agreement"]["terms"]["tools_of_record"]
tools["options"] = tools["options"] + ["sentry", "jira"]
tools["option_descriptions"] = {"sentry": "Error reports from Sentry."}
tools["value"] = ["tracker", "sentry"]
r["programme"]["agreement"]["terms"]["mystery"] = {"key": "mystery", "options": ["a"], "value": "a",
                                                    "set_by": "default", "set_at": "2026-10-19T08:00:00Z"}
terms = {t["key"]: t for t in view(r)["contract"]["terms"]}
opts = {o["name"]: o for o in terms["tools_of_record"]["options"]}
out("option_desc", f"{opts['sentry']['description']}|{opts['jira']['description']}|{opts['tracker']['description']}")
out("option_active", " ".join(n for n, o in opts.items() if o["active"]))
out("option_names", " ".join(opts))
out("mystery", f"{terms['mystery']['description']}|{terms['mystery']['binding']}|{terms['mystery']['options'][0]['description']}")
out("cadence_meta", f"{terms['cadence']['binding']}|{terms['cadence']['description']}|{terms['cadence']['label']}|{terms['cadence']['value_text']}")
active = [o["name"] for o in terms["cadence"]["options"] if o["active"]]
out("cadence_active", " ".join(active))

r = rec()
cad = r["programme"]["agreement"]["terms"]["cadence"]
cad.update(set_at="2026-10-19T09:30:00Z", set_by="shawn", why="slower")
cad["notes"] = [{"text": "try hourly next week", "at": "2026-10-19T09:31:00Z", "origin": "ui"}]
j = [row("rules_loaded", "2026-10-19T09:10:00Z", source="startup")]
v = view(r, j)
out("reread", f"{v['reread']['last_at']}|{' '.join(v['reread']['changed_since'])}|{v['reread']['requested']}")
terms = {t["key"]: t for t in v["contract"]["terms"]}
out("term_facts", f"{terms['cadence']['set_by']}|{terms['cadence']['why']}|{terms['cadence']['notes'][0]['text']}")
v = view(r, j + [row("reread_requested", "2026-10-19T09:40:00Z", origin="ui")])
out("reread_requested", v["reread"]["requested"])
v = view(r, j + [row("reread_requested", "2026-10-19T09:40:00Z", origin="ui"),
                 row("rules_acked", "2026-10-19T09:45:00Z")])
out("reread_after_ack", f"{v['reread']['last_at']}|{v['reread']['changed_since']}|{v['reread']['requested']}")

v = view(rec([item("t:a", owner={"pane": "w2:p7", "session_id": "sess-worker"},
                   trajectory=traj(ago(60), current=step("Write view test", c), location={"tab": "auto", "pane": "tests"}))]))
w = work(v)["t:a"]
out("location", f"{w['location']}|{w['session_id']}")
out("work_json", json.dumps(v["work"]))
out("rows_text", pv.render_text(v).replace("\n", " ¶ "))

v = view({"run_id": "prog-empty", "programme": {}})
out("empty", f"{v['work']}|{len(v['contract']['terms'])}|{v['contract']['instructions']}|{v['reread']['last_at']}|{v['view_format']}")
v = view({})
out("no_block", f"{v['work']}|{v['reread']['requested']}")
EOF
)"
got() { printf '%s\n' "$WORK_OUT" | sed -n "s/^$1=//p"; }

it "fixed cadence 900s: a trajectory recorded 2400s ago reads 2400s old and faded (AE2)"
check "2400 True" "$(got fixed900)"
it "on-change cadence, sweeps 10 minutes apart: the 30-minute floor applies, 25 minutes is not faded"
check "1800 False" "$(got onchange10)"
it "on-change cadence, sweeps 40 minutes apart: 70 minutes is not faded, 81 minutes is"
check "False True 4800" "$(got onchange40)"
it "fixed cadence of 10 minutes: the threshold is the 30-minute floor, not 20 minutes"
check "1800 False" "$(got fixed600)"
it "only one sweep recorded: the 30-minute floor applies"
check "1800 True" "$(got onesweep)"
it "an open item with no trajectory is in work with no plan yet"
check "True [] None False" "$(got noplan)"
it "a refusal newer than the pending proposal renders refused with its reason"
check "refused|prompt p1 was not typed by Shawn" "$(got refused_newer)"
it "a refusal older than the proposal leaves it pending"
check "pending" "$(got refused_older)"
it "a refusal for another term leaves the proposal pending"
check "pending" "$(got refused_other_term)"
it "a settled proposal keeps its stored state"
check "superseded" "$(got superseded_kept)"
it "a wait with a named reporter and no watcher reads reporter_only (AE6)"
check "reporter_only" "$(got reporter_only)"
it "a retry watcher with no process and no beat reads retry_never_started"
check "retry_never_started" "$(got retry)"
it "a cron watcher with a fresh beat reads watcher_live with the cadence interval"
check "watcher_live 900" "$(got cron_live)"
it "a live monitor watcher shows the last beat's age, not an interval"
check "watcher_live None 120" "$(got monitor_live)"
it "a stale watcher with no reporter reads nothing_watching"
check "nothing_watching" "$(got stale_watcher)"
it "a wait with no reporter and no watcher reads nothing_watching"
check "nothing_watching" "$(got nothing)"
it "an open item carries no watch state"
check "None" "$(got open_watch)"
it "done, handed and dropped items are absent from work"
check "t:a" "$(got finished_absent)"
it "work orders waiting first, then plan-changed, then join time"
check "t:w t:chg t:old t:new" "$(got order)"
it "a changed item carries the newest change hash beside its trajectory hash"
check "True hc hc False None" "$(got changed)"
it "reliant counts take current and planned steps of open and waiting items, not done steps"
check "3 1 0" "$(got reliant)"
it "instructions show quote, own or inherited scope and reliant steps; closed ones are absent"
check "i1 i2 | own 1 keep PRs small | inherited programme 0" "$(got instructions)"
it "steps carry their glyph kind and clause label"
check "done:cadence done:cadence current:cadence planned:cadence planned:no clause planned:instruction i1" "$(got steps)"
it "a step with no clause is flagged no_clause"
check "True" "$(got no_clause)"
it "a waiting item's current step uses the waiting glyph"
check "waiting" "$(got waiting_glyph)"
it "a work entry carries its finish"
check "PR merged" "$(got finish)"
it "option descriptions come from the guide, then the term, else no description"
check "Error reports from Sentry.|no description|The issue tracker." "$(got option_desc)"
it "a multi-select term marks every chosen option active"
check "tracker sentry" "$(got option_active)"
it "options are exactly the ones the term defines"
check "tracker tasks plans sentry jira" "$(got option_names)"
it "a term outside the guide reads no description and binding none"
check "no description|none|no description" "$(got mystery)"
it "a term carries binding, description, label and value text"
check "code|How often the PM sweeps the programme.|cadence|on_change, seconds 3600" "$(got cadence_meta)"
it "the active option is marked"
check "on_change" "$(got cadence_active)"
it "reread: rules loaded at 09:10 and cadence set at 09:30 give changed since cadence"
check "2026-10-19T09:10:00Z|cadence|False" "$(got reread)"
it "a term carries who set it, why and its notes"
check "shawn|slower|try hourly next week" "$(got term_facts)"
it "a re-read request newer than the last re-read shows as requested"
check "True" "$(got reread_requested)"
it "an ack after the request clears it and resets changed since"
check "2026-10-19T09:45:00Z|[]|False" "$(got reread_after_ack)"
it "location is the stored tab and pane names, and the session is the owner's"
check "auto › tests|sess-worker" "$(got location)"
it "no herdr pane code reaches a work entry"
lacks "w2:p7" "$(got work_json)"
it "the text rows carry a Work section with the current step"
has "Work ¶   title t:a: Write view test" "$(got rows_text)"
it "a record with no trajectories gives empty work, full contract terms and an empty reread"
check "[]|5|[]|None|2" "$(got empty)"
it "a record with no programme block still builds"
check "[]|False" "$(got no_block)"

it "the mod reads the view format this module writes"
FORMAT="$(run_py <<'EOF'
print(load_lib_module("programme_view").VIEW_FORMAT)
EOF
)"
has "const VIEW_FORMAT = ${FORMAT}" "$(cat "${MOD}/register.tsx")"
it "the view ships as format 2"
check "2" "$FORMAT"

it "the mod is declared in the plugin's hooks file"
check "../../mods/programme-view/register.tsx" "$("$PY" -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["modules"]))' "${AUTO_ROOT}/.claude/hooks/hooks.json")"

it "the mod's slash command does not share a name with a command or skill"
NAME="$(sed -n "s/^ *name: '\(.*\)',$/\1/p" "${MOD}/register.tsx")"
check "programme-view|absent" "${NAME}|$([ -e "${AUTO_ROOT}/commands/${NAME}.md" ] || [ -e "${AUTO_ROOT}/skills/${NAME}" ] && echo present || echo absent)"

echo "programme-view.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

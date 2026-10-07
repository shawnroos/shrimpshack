#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
HOOKS="${AUTO_ROOT}/.claude/hooks"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-flow.test.sh"

WORK="$(mktemp -d -t auto-programme-flow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO LINEAR_API_KEY CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
export CALLS SNAP PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
  "pane get")
    pane="$3"
    printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"w2:t1"}},"type":"pane_info"}\n' \
      "$pane" "${pane%%:*}" "${pane##*:}" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
esac
exit 0
EOF

cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
printf 'board %s\n' "$*" >> "$CALLS"
echo '{"error":{"code":7,"message":"plugin op unsupported"}}'
exit 1
EOF

cat > "${FAKES}/spinoff" <<'EOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
exit 0
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

"$PY" - "$SNAP" <<'PYEOF'
import json, sys
def pane(pid, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": pid.split(":")[0],
           "terminal_id": "term_" + pid.split(":")[1], "agent": "claude", "agent_status": "idle",
           "cwd": "/tmp", "label": None, "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
def sess(value):
    return {"source": "auto", "agent": "claude", "kind": "id", "value": value}
panes = [
    pane("w2:p10", label="PM", agent_session=sess("sess-pm")),
    pane("w2:p30", label="AI-753: Shot kinds", agent_session=sess("sess-w1")),
    pane("w2:p31", label="scratch", agent_session=sess("sess-w2")),
]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": panes}}}
json.dump(doc, open(sys.argv[1], "w"))
PYEOF

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def rec_path(run):
    return os.path.join(ph.home_path(run), ".claude", "auto", run + ".json")
def load(run):
    return json.load(open(rec_path(run)))
def save(run, rec):
    json.dump(rec, open(rec_path(run), "w"))
def ago(hours):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")
$(cat)
PYEOF
}

OUT=""
CODE=0
as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID="${WS:-w2}" "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

json_of() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[0]); print(json.dumps($1, sort_keys=True) if not isinstance($1, str) else $1)" <<< "$OUT" 2>&1
}

typed() {
  local sid="$1" text="$2"
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "prompt": sys.argv[2], "hook_event_name": "UserPromptSubmit"}))' "$sid" "$text")"
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID="${WS:-w2}" bash "${HOOKS}/on-user-prompt.sh" <<< "$payload" 2>/dev/null )
}

prompt_id_of() {
  "$PY" -c '
import json, re, sys
raw = sys.stdin.read().strip()
if not raw:
    print(""); sys.exit()
ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
print(json.loads(re.search(r"\{.*\}", ctx).group(0))["prompt_id"])' <<< "$1"
}

stop_hook() {
  local sid="$1" refire="${2:-false}"
  ( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< "{\"session_id\":\"$sid\",\"stop_hook_active\":$refire}" 2>/dev/null )
}

verdict() {
  if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then echo allow; return; fi
  if printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; then echo block; else echo "other:$1"; fi
}

kinds() {
  run_py "$1" <<'EOF'
print(" ".join(r["kind"] for r in pj.read(args[0])))
EOF
}

last_entry() {
  run_py "$1" "$2" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

lease_session() {
  run_py "$1" <<'EOF'
lease = ph.read_lease(ph.lease_path("default", args[0]))
print(lease.get("session_id") if lease else "<none>")
EOF
}

driver_of() {
  run_py "$1" <<'EOF'
print(load(args[0]).get("driving_session_id"))
EOF
}

age_beat() {
  run_py "$1" <<'EOF'
rec = load(args[0])
rec["loop"]["last_beat_at"] = ago(3)
save(args[0], rec)
EOF
}

it "start outside a herdr space is refused"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-pm "$PY" "$PROG" start 2>&1)"; CODE=$?
check "1" "$CODE"

it "F1: start takes the lease and journals the start"
as sess-pm start
check "0" "$CODE"
RUN="$(json_of 'd["run"]')"
check "sess-pm" "$(lease_session w2)"

it "F1: the start entry is the first journal entry"
check "programme_started" "$(kinds "$RUN")"

it "F1: the agreement is proposed and shown after the lease exists"
as sess-pm propose-agreement
check "0" "$CODE"
as sess-pm rules
has "<auto-rules>" "$OUT"
check "programme_started agreement_proposed" "$(kinds "$RUN")"

it "start in a space with a live lease is refused, naming the holder"
as sess-other start
check "1" "$CODE"
has "held by run ${RUN} (session sess-pm)" "$OUT"

it "F1: a typed acceptance accepts the agreement"
P_ACCEPT="$(prompt_id_of "$(typed sess-pm 'yes, run it on those terms')")"
as sess-pm accept-agreement --prompt "$P_ACCEPT"
check "0" "$CODE"

it "F1: the sweep proposes the worker panes"
as sess-pm sweep
check "0" "$CODE"
ADOPT="$("$PY" -c '
import json, sys
d = json.loads(sys.stdin.read())
print(" ".join(sorted(p["item"] + "|" + p["pane"] + "|" + (p.get("session_id") or "") for p in d["proposals"] if p["action"] == "adopt")))' <<< "$OUT" 2>&1)"
check "herdr:w2/p31|w2:p31|sess-w2 linear:AI-753|w2:p30|sess-w1" "$ADOPT"

for row in $ADOPT; do
  IFS='|' read -r item pane sid <<< "$row"
  as sess-pm add-item "$item" --pane "$pane" --session "$sid"
done
it "F1: after acceptance the proposed items are adopted"
check "0" "$CODE"
ITEMS="$(run_py "$RUN" <<'EOF'
print(" ".join(sorted(load(args[0])["programme"]["items"])))
EOF
)"
check "herdr:w2/p31 linear:AI-753" "$ITEMS"

it "F1: the journal holds the start entries in order"
check "programme_started agreement_proposed prompt agreement_accepted item_added item_added" "$(kinds "$RUN")"

as sess-pm set-waiting linear:AI-753 --who team-x

it "the driving session is held while a wait is unwatched"
check "block" "$(verdict "$(stop_hook sess-pm)")"

it "takeover on a live lease is refused"
typed sess-b '/auto:programme-takeover' >/dev/null
as sess-b takeover
check "1" "$CODE"
has "live" "$OUT"
check "sess-pm" "$(driver_of "$RUN")"

it "takeover on a live lease journals the refusal"
has '"verb": "takeover"' "$(last_entry "$RUN" request_refused)"

it "a driving-session write keeps an aged lease live"
age_beat "$RUN"
as sess-pm set-now "sweeping"
check "0" "$CODE"
check "live" "$(run_py "$RUN" <<'EOF2'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w2"))))
EOF2
)"

age_beat "$RUN"

it "takeover with no journaled request is refused"
as sess-c takeover
check "1" "$CODE"
has "no typed takeover request" "$OUT"
check "sess-pm" "$(lease_session w2)"

it "a request typed while the lease was live does not authorise a takeover"
as sess-b takeover
check "1" "$CODE"

it "takeover on an orphaned lease from a new session cites its request"
typed sess-b '/auto:programme-takeover' >/dev/null
as sess-b takeover
check "0" "$CODE"
has "<auto-rules>" "$OUT"
has "linear:AI-753" "$OUT"

it "takeover rewrites the lease and the driving session together"
check "sess-b sess-b" "$(lease_session w2) $(driver_of "$RUN")"

it "takeover journals both session ids and the request"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"from_session": "sess-pm"' "$ENTRY"
has '"to_session": "sess-b"' "$ENTRY"
has '"request": {"at": "' "$ENTRY"

it "after takeover the lease is live again"
check "live" "$(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w2"))))
EOF
)"

it "after takeover the old session is no longer held"
check "allow" "$(verdict "$(stop_hook sess-pm)")"

it "after takeover the new session is held"
check "block" "$(verdict "$(stop_hook sess-b)")"

it "the same request cannot be used twice"
age_beat "$RUN"
as sess-b takeover
check "1" "$CODE"
run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0])
rec["loop"]["last_beat_at"] = ago(0)
save(args[0], rec)
EOF

it "a handover request from a worker session is refused"
typed sess-w1 '/auto:programme-handover sess-w1' >/dev/null
as sess-w1 handover sess-w1
check "1" "$CODE"
check "sess-b" "$(driver_of "$RUN")"

it "a handover request from a worker session is journaled as refused"
ENTRY="$(last_entry "$RUN" request_refused)"
has '"verb": "handover"' "$ENTRY"
has '"session_id": "sess-w1"' "$ENTRY"

it "a handover naming another session than the typed request is refused"
typed sess-b '/auto:programme-handover sess-d' >/dev/null
as sess-b handover sess-e
check "1" "$CODE"

it "a handover typed in the driving session moves the lease and driving session"
as sess-b handover sess-d
check "0" "$CODE"
check "sess-d sess-d" "$(lease_session w2) $(driver_of "$RUN")"

it "handover journals both ids and cites the typed prompt"
ENTRY="$(last_entry "$RUN" handed_over)"
has '"from_session": "sess-b"' "$ENTRY"
has '"to_session": "sess-d"' "$ENTRY"
has '"cites": ["p' "$ENTRY"

it "after handover the old driver is no longer held"
check "allow" "$(verdict "$(stop_hook sess-b)")"

it "after handover the new driver is held"
check "block" "$(verdict "$(stop_hook sess-d)")"

it "a handover request without a cited prompt is refused"
run_py "$RUN" <<'EOF' >/dev/null
pj.append(args[0], "handover_request", "sess-d",
          {"verb": "handover", "text": "/auto:programme-handover sess-b", "origin": "typed",
           "space": "default.w2", "lease_status": "live", "driving": True})
EOF
as sess-d handover sess-b
check "1" "$CODE"

it "a typed handover hands the programme back"
typed sess-d '/auto:programme-handover sess-b' >/dev/null
as sess-d handover sess-b
check "0 sess-b" "$CODE $(driver_of "$RUN")"

it "a used handover request cannot move the programme again"
as sess-b handover sess-d
check "1" "$CODE"
check "sess-b" "$(driver_of "$RUN")"

typed sess-b '/auto:programme-handover sess-d' >/dev/null
as sess-b handover sess-d

it "an end request from a worker session on a live lease is refused"
typed sess-w1 '/auto:programme-end' >/dev/null
as sess-w1 end
check "1" "$CODE"
check "sess-d" "$(lease_session w2)"

it "an end request from a worker session is journaled as refused"
has '"verb": "end"' "$(last_entry "$RUN" request_refused)"

as sess-d watcher-beat cron --task-id cron-77 --prompt "sweep the programme now"

it "end with no typed request is refused"
as sess-d end
check "1" "$CODE"

it "end from a typed request in the driving session releases the lease"
typed sess-d '/auto:programme-end' >/dev/null
as sess-d end
check "0" "$CODE"
check "<none>" "$(lease_session w2)"

it "end names the cron fallback to remove"
has "cron-77" "$OUT"

it "the ended run shows ended"
as sess-d status --run "$RUN"
has "ended: ended_by_shawn" "$OUT"

it "the ended run journals its end with both reason and request"
ENTRY="$(last_entry "$RUN" programme_ended)"
has '"reason": "ended_by_shawn"' "$ENTRY"
has '"cron_task_ids": ["cron-77"]' "$ENTRY"

it "after end the driver is no longer held"
check "allow" "$(verdict "$(stop_hook sess-d)")"

WS=w5
as sess-x start
RUN5="$(json_of 'd["run"]')"
it "expire leaves an agreement inside its cadence alone"
as sess-x expire
check "0" "$CODE"
check "sess-x" "$(lease_session w5)"

run_py "$RUN5" <<'EOF' >/dev/null
rec = load(args[0])
rec["programme"]["created_at"] = ago(2)
save(args[0], rec)
EOF
it "an agreement left unaccepted past one cadence ends the programme"
as sess-x expire
check "0" "$CODE"
check "<none>" "$(lease_session w5)"
has '"reason": "agreement_unaccepted"' "$(last_entry "$RUN5" programme_ended)"

it "after expiry a new start in that space needs no takeover"
as sess-y start
check "0" "$CODE"

it "start splits a slash command's single argument string into spaces"
as sess-z start "--space w6 w7"
check "0" "$CODE"
check "sess-z sess-z" "$(lease_session w6) $(lease_session w7)"

WS=w3
it "set-waiting --due stores the due time for the wait-due watcher"
as sess-e start
RUN3="$(json_of 'd["run"]')"
as sess-e add-item linear:AI-901
as sess-e set-waiting linear:AI-901 --who team-x --reporter shawn --due 2026-10-08T09:00:00Z
check "0" "$CODE"
check '"2026-10-08T09:00:00Z"' "$(run_py "$RUN3" <<'EOF'
print(json.dumps(load(args[0])["programme"]["items"]["linear:AI-901"]["waiting_on"].get("due_at")))
EOF
)"

it "set-waiting --due refuses a value that is not a time"
as sess-e set-waiting linear:AI-901 --who team-x --due tomorrow
check "1" "$CODE"

it "end to end: a record built only through verbs holds the PM with the expected reasons"
as sess-e propose-agreement
P3="$(prompt_id_of "$(typed sess-e 'accepted')")"
as sess-e accept-agreement --prompt "$P3"
as sess-e add-item linear:AI-900 --kind fix_only
as sess-e set-waiting linear:AI-900 --who team-y
as sess-e queue --action ping_worker --item linear:AI-901
OUT_STOP="$(stop_hook sess-e)"
check "block" "$(verdict "$OUT_STOP")"
has "unwatched_wait linear:AI-900" "$OUT_STOP"
has "queued_action 1" "$OUT_STOP"
lacks "linear:AI-901 " "$(printf '%s' "$OUT_STOP" | grep -o 'unwatched_wait[^;.]*')"

it "end to end: the PM's re-fire is allowed and journals the unwatched wait"
check "allow" "$(verdict "$(stop_hook sess-e true)")"
has '"linear:AI-900"' "$(last_entry "$RUN3" stopped_unwatched)"

session_start() {
  local sid="$1" pane="$2" entry="$3"
  ( cd "$NOREPO" && HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_WORKSPACE_ID="${pane%%:*}" CLAUDE_CODE_ENTRYPOINT="$entry" \
    bash "${HOOKS}/on-session-start.sh" <<< "{\"session_id\":\"$sid\",\"source\":\"startup\",\"cwd\":\"$NOREPO\"}" 2>/dev/null )
}
pre_compact() { ( cd "$NOREPO" && bash "${HOOKS}/on-pre-compact.sh" <<< "{\"session_id\":\"$1\",\"trigger\":\"auto\"}" 2>/dev/null ); }
compact_start() { ( cd "$NOREPO" && bash "${HOOKS}/on-session-start.sh" <<< "{\"session_id\":\"$1\",\"source\":\"compact\"}" 2>/dev/null ); }
FLAG="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN3}/.compact-flag"

session_start sess-fork w3:p11 cli >/dev/null
session_start sess-child w3:p40 sdk-cli >/dev/null
BEFORE="$(kinds "$RUN3" | wc -w | tr -d ' ')"

it "cross-session: a fork's prompt gets no injected text and no journal entry"
check "" "$(typed sess-fork 'what is the programme doing')"
it "cross-session: a headless child's prompt gets no injected text"
check "" "$(typed sess-child 'run the eval')"
it "cross-session: neither prompt was journaled"
check "$BEFORE" "$(kinds "$RUN3" | wc -w | tr -d ' ')"

it "cross-session: only the PM's prompt is journaled and answered"
has "auto-data" "$(typed sess-e 'carry on')"
check "$((BEFORE + 1))" "$(kinds "$RUN3" | wc -w | tr -d ' ')"

it "cross-session: the fork and the child stop freely, the PM is held"
check "allow allow block" "$(verdict "$(stop_hook sess-fork)") $(verdict "$(stop_hook sess-child)") $(verdict "$(stop_hook sess-e)")"

it "cross-session: re-fires of the fork and child journal nothing"
N_UNW="$(kinds "$RUN3" | tr ' ' '\n' | grep -c stopped_unwatched)"
stop_hook sess-fork true >/dev/null
stop_hook sess-child true >/dev/null
check "$N_UNW" "$(kinds "$RUN3" | tr ' ' '\n' | grep -c stopped_unwatched)"

it "cross-session: compaction in the fork or child sets no flag"
pre_compact sess-fork
pre_compact sess-child
check "absent" "$([ -e "$FLAG" ] && echo present || echo absent)"

it "cross-session: compaction in the PM sets the flag"
pre_compact sess-e
check "present" "$([ -e "$FLAG" ] && echo present || echo absent)"

it "cross-session: only the PM gets the rules in force after compaction"
check "" "$(compact_start sess-fork)$(compact_start sess-child)"
has "auto-rules" "$(compact_start sess-e)"

echo
echo "programme-flow.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-sources.test.sh"

WORK="$(mktemp -d -t auto-programme-sources.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
export CALLS SNAP PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server")
    [ -n "${FAKE_HERDR_DOWN:-}" ] && exit 1
    echo "status: running"; echo "version: 0.9.3" ;;
  "api snapshot")
    [ -n "${FAKE_HERDR_SLEEP:-}" ] && sleep "$FAKE_HERDR_SLEEP"
    cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
  "agent prompt")
    exit "${FAKE_PROMPT_EXIT:-0}" ;;
esac
exit 0
EOF

cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
printf 'board %s\n' "$*" >> "$CALLS"
if [ -n "${FAKE_BOARD_JSON:-}" ]; then cat "$FAKE_BOARD_JSON"; exit 0; fi
if [ -n "${FAKE_BOARD_OUTAGE:-}" ]; then echo "board: linear request failed: connection reset" >&2; exit 2; fi
echo '{"error":{"code":7,"message":"plugin op unsupported: work plugin 0.6.1 has no bin/work-snapshot.sh"}}'
exit 1
EOF

cat > "${FAKES}/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CALLS"
cat > "${CALLS}.curlconfig"
[ -n "${FAKE_CURL_EXIT:-}" ] && exit "$FAKE_CURL_EXIT"
cat "$FAKE_LINEAR_JSON"
EOF

cat > "${FAKES}/spinoff" <<'EOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  shift
done
echo "  herdr agent pane: w2:p40 (launched with the brief)"
if [ -n "${FAKE_SPINOFF_AGENT:-}" ]; then
  "$PY" - "$SNAP" "$sid" <<'PYEOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t3", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"].append(pane)
snap["agents"].append(pane)
json.dump(doc, open(path, "w"))
PYEOF
fi
exit "${FAKE_SPINOFF_EXIT:-0}"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

REPO_BRANCH="${WORK}/wt/ai-753"
mkdir -p "$REPO_BRANCH"
( cd "$REPO_BRANCH" && git init -q && git checkout -q -b ai-753-shot-kinds ) || echo "git setup failed"
PLAIN_DIR="${WORK}/wt/plain"
mkdir -p "$PLAIN_DIR"

write_snapshot() {
  "$PY" - "$SNAP" "$REPO_BRANCH" "$PLAIN_DIR" "$1" <<'PYEOF'
import json, sys
path, branch_dir, plain_dir, variant = sys.argv[1:5]
def pane(pid, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": pid.split(":")[0],
           "terminal_id": "term_" + pid.split(":")[1], "agent": None, "agent_status": "unknown",
           "cwd": plain_dir, "label": None, "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
def sess(value):
    return {"source": "auto", "agent": "claude", "kind": "id", "value": value}
panes = [
    pane("w2:p1", label="Sidebar"),
    pane("w2:p2"),
    pane("w2:p10", agent="claude", agent_status="idle", label="PM", agent_session=sess("sess-pm")),
    pane("w2:p11", agent="claude", agent_status="idle", label="Linear: AI Editor"),
    pane("w2:p30", agent="claude", agent_status="working", cwd=branch_dir,
         terminal_title_stripped="Shot kinds \x1b]0;evil\x07\x1b[31mred\x1b[0m"),
    pane("w2:p31", agent="claude", agent_status="idle", terminal_title_stripped="Claude Code"),
    pane("w9:p5", agent="claude", agent_status="idle", cwd=branch_dir),
]
if variant == "fork":
    panes[4]["agent_session"] = sess("sess-fork")
if variant == "owned":
    panes[4]["agent_session"] = sess("sess-w1")
if variant == "exited":
    panes[5]["agent"] = None
if variant == "utf":
    panes[5]["terminal_title_stripped"] = "fix UTF-8 parsing"
if variant == "reused":
    panes[5]["terminal_id"] = "term_new"
agents = [p for p in panes if p["agent"]]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}, {"workspace_id": "w9", "label": "Other"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": agents}}}
json.dump(doc, open(path, "w"))
PYEOF
}

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
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
items = prog["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

source_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == "source_changed" and r["payload"]["source"] == args[1]]))
EOF
}

registry_line() {
  run_py "$@" <<'EOF'
sid, pane, terminal = args
folder = os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "sessions")
os.makedirs(folder, exist_ok=True)
row = {"at": "2026-10-07T09:00:00Z", "session_id": sid, "pane_id": pane, "terminal_id": terminal,
       "server": "default", "workspace": "w2", "interactive": True, "cwd": "/tmp/" + sid}
with open(os.path.join(folder, "default.w2.jsonl"), "a") as fh:
    fh.write(json.dumps(row) + "\n")
EOF
}

jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
calls() { cat "$CALLS" 2>/dev/null; }

write_snapshot base
registry_line sess-ghost w2:p77 term_p77
registry_line sess-stale w2:p31 term_gone

it "describe lists the source verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"
for verb in sweep start-worker prompt-item; do
  case " $VERBS " in *" $verb "*) ;; *) VERBS="MISSING:$verb $VERBS" ;; esac
done
lacks "MISSING:" "$VERBS"

: > "$CALLS"
prog sweep
it "sweep exits 0"
check 0 "$CODE"
it "sweep proposes exactly the two worker panes"
check '[["herdr:w2/p31", "adopt"], ["linear:AI-753", "adopt"]]' "$(jq_py 'sorted([p["item"], p["action"]] for p in d["proposals"])')"
it "the branch names the issue"
check '["branch"]' "$(jq_py '[p["signals"] for p in d["proposals"] if p["item"] == "linear:AI-753"][0]')"
it "shells, the PM pane and the tracker pane are skipped with a reason"
check '[["w2:p1", "shell"], ["w2:p10", "pm"], ["w2:p11", "tracker"], ["w2:p2", "shell"]]' "$(jq_py 'sorted([s["pane"], s["why"]] for s in d["skipped"])')"
it "a pane outside the remit is not read"
lacks "w9:p5" "$OUT"
it "pane titles are stripped of escape sequences"
check '"Shot kinds red"' "$(jq_py '[p["title"] for p in d["panes"] if p["pane_id"] == "w2:p30"][0]')"
it "no escape sequence reaches the output"
lacks "u001b" "$OUT"
it "an escape sequence's payload is stripped with it"
lacks "evil" "$OUT"
it "a registry line naming a pane absent from the snapshot is ignored"
lacks "sess-ghost" "$OUT"
it "a registry line whose terminal changed is ignored"
lacks "sess-stale" "$OUT"
it "a pane with no reported session and no registry line is session unknown"
check '[null, null]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p31"][0]')"
it "the snapshot's agent session is the owner"
check '["sess-pm", "snapshot"]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p10"][0]')"
it "every tracker provider failing marks the tracker down with each provider's reason"
check '[true, null]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["provider"]]')"
has "board: w2: plugin op unsupported" "$(jq_py 'd["sources"]["tracker"]["reason"]')"
it "with no Linear key the linear-api provider is tried too, and issues stay unverified"
check '[["board", "unsupported"], ["linear-api", "unavailable"]]' "$(jq_py '[[t["provider"], t["state"]] for t in d["sources"]["tracker"]["tried"]]')"
it "a provider that could not answer named issues leaves the tracker an outage"
check '"unavailable"' "$(jq_py 'd["sources"]["tracker"]["state"]')"
it "herdr is available"
check 'false' "$(jq_py 'd["sources"]["herdr"]["unavailable"]')"
it "sweep writes nothing to the journal"
check 0 "$(journal_count source_changed)"
it "sweep calls herdr snapshot once, bounded behind a probe"
check '2' "$(grep -cE '^herdr (status server|api snapshot)' "$CALLS")"
it "a missing snapshot op is unsupported for that provider, not an outage"
check '"unsupported"' "$(jq_py 'd["sources"]["tracker"]["tried"][0]["state"]')"
it "herdr answering is available"
check '"available"' "$(jq_py 'd["sources"]["herdr"]["state"]')"
export FAKE_BOARD_OUTAGE=1
prog sweep
unset FAKE_BOARD_OUTAGE
it "a supported provider command that fails is an outage"
check '["unavailable", true]' "$(jq_py '[d["sources"]["tracker"]["tried"][0]["state"], d["sources"]["tracker"]["unavailable"]]')"
mkdir -p "${WORK}/nopath"
PATH="${WORK}/nopath" prog sweep
it "herdr and every tracker provider missing from PATH are unsupported"
check '["unsupported", "unsupported"]' "$(jq_py '[d["sources"]["herdr"]["state"], d["sources"]["tracker"]["state"]]')"

registry_line sess-w2 w2:p31 term_p31
prog sweep
it "a registry line for a live pane with the same terminal gives the owner"
check '["sess-w2", "registry"]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p31"][0]')"

export LINEAR_API_KEY="lin_api_FAKEKEYFAKEKEYFAKEKEY1234"
export FAKE_LINEAR_JSON="${WORK}/linear.json"
printf '%s' '{"data":{"i0":{"identifier":"AI-753","title":"Shot kinds \u001b[2Jwipe","url":"https://linear.app/x/AI-753","state":{"name":"In Progress","type":"started"}}}}' > "$FAKE_LINEAR_JSON"
: > "$CALLS"
write_snapshot utf
prog sweep
write_snapshot base
it "a failing first provider falls back to the next, and the output names the one that answered"
check '"linear-api"' "$(jq_py 'd["sources"]["tracker"]["provider"]')"
it "the tracker is available through the fallback"
check '[false, "available"]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["state"]]')"
it "each issue names the provider that answered"
check '"linear-api"' "$(jq_py 'd["issues"]["AI-753"]["source"]')"
it "the issue title from Linear is sanitized"
check '"Shot kinds wipe"' "$(jq_py 'd["issues"]["AI-753"]["title"]')"
it "the Linear key never appears in a command line"
lacks "FAKEKEY" "$(calls)"
it "the Linear key goes to curl on stdin"
has "Authorization: lin_api_FAKEKEY" "$(cat "${CALLS}.curlconfig")"
it "Linear is asked about every named issue"
has 'UTF-8' "$(cat "${CALLS}.curlconfig")"
it "a name Linear does not know is not proposed as an issue"
check '["herdr:w2/p31", "linear:AI-753"]' "$(jq_py 'sorted(p["item"] for p in d["proposals"])')"

export FAKE_CURL_EXIT=7
prog sweep
it "a failing fallback read leaves the tracker unavailable, with no provider"
check '[true, null]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["provider"]]')"
unset FAKE_CURL_EXIT
it "curl missing from PATH makes Linear unsupported"
check 'unsupported' "$(PATH="${WORK}/nopath" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_tracker").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"
it "a failing curl leaves Linear an outage"
check 'unavailable' "$(FAKE_CURL_EXIT=7 "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_tracker").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"

export FAKE_BOARD_JSON="${WORK}/board.json"
cat > "$FAKE_BOARD_JSON" <<'EOF'
{"project":{"name":"Ai Editor"},"groups":[{"key":"started","label":"In Progress","issues":["AI-753","AI-760"]}],
 "issues":{"AI-753":{"identifier":"AI-753","title":"Shot kinds","state":{"name":"In Progress","type":"started"},"bindings":[]},
           "AI-760":{"identifier":"AI-760","title":"Bound by the board","state":{"name":"Todo","type":"unstarted"},"bindings":[{"tab":"w2:t1","panes":["w2:p31"]}]}},
 "pane_status":{}}
EOF
: > "$CALLS"
prog sweep
it "the first provider answering is the tracker's provider"
check '"board"' "$(jq_py 'd["sources"]["tracker"]["provider"]')"
it "later providers are not read when the first answers"
lacks "curl" "$(calls)"
it "a tracker binding names the issue of an otherwise issueless pane"
check '[["linear:AI-753", ["branch"]], ["linear:AI-760", ["tracker"]]]' "$(jq_py 'sorted([p["item"], p["signals"]] for p in d["proposals"])')"
unset FAKE_BOARD_JSON LINEAR_API_KEY

export FAKE_HERDR_SLEEP=5
export CLAUDE_AUTO_SOURCE_TIMEOUT="0.5"
START_S=$SECONDS
prog sweep
it "a herdr timeout returns within the bound"
check 1 "$(( SECONDS - START_S < 4 ? 1 : 0 ))"
it "herdr timing out flags it unavailable"
check 'true' "$(jq_py 'd["sources"]["herdr"]["unavailable"]')"
it "an unavailable herdr gives no pane list rather than an empty one"
check '[null, null]' "$(jq_py '[d["panes"], d["proposals"]]')"
it "the reason names the timeout"
has "timed out" "$(jq_py 'd["sources"]["herdr"]["reason"]')"
unset FAKE_HERDR_SLEEP
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"

export FAKE_HERDR_DOWN=1
prog sweep --record-sources
it "sweep --record-sources records a source going unavailable"
check 0 "$CODE"
it "the herdr source is recorded unavailable"
check 'true' "$(field 'prog["sources"]["herdr"]["unavailable_since"] is not None')"
it "the change is journaled through set-source"
check 1 "$(source_count herdr)"
it "the failing tracker is recorded in the same sweep"
check 1 "$(source_count tracker)"
it "a tracker with only unsupported providers is recorded as unsupported, with no outage"
check '[true, null]' "$(field '[prog["sources"]["tracker"]["unsupported_since"] is not None, prog["sources"]["tracker"]["unavailable_since"]]')"
prog sweep --record-sources
it "an unchanged source is not recorded again"
check 1 "$(source_count herdr)"
unset FAKE_HERDR_DOWN
export FAKE_BOARD_OUTAGE=1
prog sweep --record-sources
unset FAKE_BOARD_OUTAGE
it "a real tracker outage after unsupported is recorded as an outage"
check '[null, true]' "$(field '[prog["sources"]["tracker"]["unsupported_since"], prog["sources"]["tracker"]["unavailable_since"] is not None]')"
check 2 "$(source_count tracker)"
prog sweep --record-sources
it "herdr coming back is recorded"
check 'null' "$(field 'prog["sources"]["herdr"]["unavailable_since"]')"

CLAUDE_CODE_SESSION_ID=sess-other prog sweep --record-sources
it "another session cannot record sources"
check 1 "$CODE"

prog add-item linear:AI-753 --title "Shot kinds"
prog add-item herdr:w2/p31 --title "issueless pane"

: > "$CALLS"
prog sweep
it "an existing item is reported as known, not adopted again"
check '"known"' "$(jq_py '[p["action"] for p in d["proposals"] if p["item"] == "linear:AI-753"][0]')"

: > "$CALLS"
prog start-worker linear:AI-753 -- --name shot-kinds --handoff /tmp/h.md --target tab
it "start-worker where spinoff exits 0 but no agent appears fails"
check 1 "$CODE"
SID_FAILED="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
it "spinoff got a minted lowercase uuid"
check 1 "$(printf '%s' "$SID_FAILED" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')"
it "the caller's spinoff arguments pass through"
has "--name shot-kinds --handoff /tmp/h.md --target tab" "$(calls)"
it "the item records the failed start"
check "[false, \"${SID_FAILED}\"]" "$(field '[items["linear:AI-753"]["starts"][-1]["ok"], items["linear:AI-753"]["starts"][-1]["session_id"]]')"
it "a failed start does not set the owner"
check 'null' "$(field 'items["linear:AI-753"]["owner"]["session_id"]')"
it "the failed start is journaled"
has "no agent" "$(journal_last worker_start_failed)"
ATTEMPT_FAILED="$(jq_py 'd["attempt"]' | tr -d '"')"
it "a launch with no agent appearing stays uncertain, not failed"
check '"uncertain"' "$(jq_py 'd["operation_state"]')"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 -- --name shot-kinds --handoff /tmp/h.md
it "a second start while the first launch is uncertain is refused by default"
check 1 "$CODE"
it "the refusal names the uncertain attempt"
has "$ATTEMPT_FAILED" "$OUT"
it "the refused retry never calls spinoff"
lacks "spinoff" "$(calls)"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 --despite "$ATTEMPT_FAILED" -- --name shot-kinds --handoff /tmp/h.md
it "start-worker succeeds when the agent appears"
check 0 "$CODE"
SID_OK="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
it "the owner is the new pane, its terminal and the minted session"
check "[\"w2:p40\", \"term_p40\", \"${SID_OK}\"]" "$(field '[items["linear:AI-753"]["owner"][k] for k in ("pane", "terminal_id", "session_id")]')"
it "the start is verified with herdr agent list"
has "herdr agent list" "$(calls)"
it "the successful start is journaled"
has "$SID_OK" "$(journal_last worker_started)"
it "each start mints a new session id"
check 1 "$([ "$SID_OK" != "$SID_FAILED" ] && echo 1 || echo 0)"

: > "$CALLS"
prog start-worker linear:AI-753 -- --name x --session-id 0b9f2c4e-7a1d-4e5b-9c3f-2d8e6a1b4c70
it "start-worker refuses a caller-supplied --session-id"
check 1 "$CODE"
prog start-worker linear:AI-999 -- --name x
it "start-worker refuses an unknown item"
check 1 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-other prog start-worker linear:AI-753 -- --name x
it "start-worker refuses a session that does not drive the programme"
check 1 "$CODE"
it "refused starts never call spinoff"
lacks "spinoff" "$(calls)"

write_snapshot fork
prog add-item linear:AI-753 --pane w2:p30 --terminal-id term_p30 --session sess-w1
: > "$CALLS"
prog prompt-item linear:AI-753 "please rebase"
it "prompt-item refuses when the pane reports a different session than the owner"
check 1 "$CODE"
it "the owner mismatch is journaled"
has "sess-fork" "$(journal_last prompt_refused)"
it "nothing is sent on an owner mismatch"
lacks "agent prompt" "$(calls)"

write_snapshot owned
: > "$CALLS"
prog prompt-item linear:AI-753 $'please \x1b[2Jrebase\x07 now'
it "prompt-item sends when the reported session is the owner"
check 0 "$CODE"
it "the prompt goes to the recorded pane, with escape sequences stripped"
has "herdr agent prompt w2:p30 please rebase now" "$(calls)"
it "no raw escape byte reaches herdr"
lacks $'\x1b' "$(calls)"
it "the send is journaled"
has '"sent": true' "$(journal_last prompt_sent)"
it "a confirmed owner is not session unknown"
check 'false' "$(jq_py 'd["session_unknown"]')"

prog add-item herdr:w2/p31 --pane w2:p31 --terminal-id term_p31
rm -f "${CLAUDE_AUTO_DATA_DIR}/sessions/default.w2.jsonl"
write_snapshot base
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item to a pane with no registry entry and no reported session is sent"
check 0 "$CODE"
it "that send is marked session unknown"
check 'true' "$(jq_py 'd["session_unknown"]')"
it "the journal marks it session unknown"
has '"session_unknown": true' "$(journal_last prompt_sent)"

write_snapshot exited
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a pane whose agent has exited"
check 1 "$CODE"
it "nothing is typed into the shell"
lacks "agent prompt" "$(calls)"
it "the exited agent refusal is journaled"
has "no live agent" "$(journal_last prompt_refused)"

write_snapshot reused
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a pane whose terminal changed"
check 1 "$CODE"
has "terminal" "$(journal_last prompt_refused)"

write_snapshot base
prog add-item linear:AI-770 --title "pm pane" --pane w2:p10
: > "$CALLS"
prog prompt-item linear:AI-770 "hello me"
it "prompt-item to the PM's own pane is refused"
check 1 "$CODE"
it "the driver refusal is journaled"
has "driver" "$(journal_last prompt_refused)"
it "nothing is sent to the PM's pane"
lacks "agent prompt" "$(calls)"

registry_line sess-pm w2:p12 term_p12
prog add-item linear:AI-771 --title "pm pane by registry" --pane w2:p12
prog prompt-item linear:AI-771 "hello me"
it "a driver pane known only from the registry is refused"
check 1 "$CODE"
it "it is refused as the driver's pane"
has "driver" "$(journal_last prompt_refused)"

prog add-item linear:AI-772 --title "tracker pane" --pane w2:p11
prog prompt-item linear:AI-772 "hello tracker"
it "prompt-item to a tracker pane is refused"
check 1 "$CODE"

prog add-item linear:AI-773 --title "no pane"
prog prompt-item linear:AI-773 "hello"
it "prompt-item refuses an item with no pane"
check 1 "$CODE"

FAKE_PROMPT_EXIT=1 prog prompt-item herdr:w2/p31 "status?"
it "a failed herdr send exits non-zero"
check 1 "$CODE"
it "a failed send is journaled as not sent"
has '"sent": false' "$(journal_last prompt_sent)"

touch "${HOME_DIR}/.compact-flag"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item obeys the compact flag"
check 1 "$CODE"
it "nothing is sent while the compact flag is set"
lacks "agent prompt" "$(calls)"
rm -f "${HOME_DIR}/.compact-flag"

CLAUDE_CODE_SESSION_ID=sess-other prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a session that does not drive the programme"
check 1 "$CODE"

seed_decision() {
  run_py "$RUN" "$1" "${2:-shawn}" <<'EOF'
run, why, by = args
pd = load_lib_module("programme_decisions")
out = {}
def body(rec):
    rec["programme"] = ph.normalize_programme(rec["programme"])
    out["id"] = pd.add_decision(rec["programme"], kind="product_scope", by=by, item="programme", why=why)["id"]
core._with_locked_run_record(ph.home_path(run), run, body)
print(out["id"])
EOF
}
DEC="$(seed_decision "Export stays PNG only this release")"
SENT_BEFORE="$(journal_count prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision d000000
it "prompt-item refuses an unknown decision id"
check 1 "$CODE"
has "unknown decision" "$OUT"
it "nothing is sent for an unknown decision id"
lacks "agent prompt" "$(calls)"
check "$SENT_BEFORE" "$(journal_count prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision "$DEC"
it "prompt-item with a decision sends"
check 0 "$CODE"
it "the prompt carries the decision text"
has "Export stays PNG only this release" "$(calls)"
it "the prompt names who decided"
has "(product_scope, decided by shawn)" "$(calls)"
it "the prompt carries the reopen clause"
has "stop and state that evidence" "$(calls)"
it "the prompt_sent row carries the decision ids"
check "[\"${DEC}\"]" "$(journal_last prompt_sent | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["payload"]["decision_ids"]))')"

DEC_PM="$(seed_decision "Crop helper stays as is" pm)"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision "$DEC_PM"
it "a PM decision reads as decided by pm in the prompt"
has "(product_scope, decided by pm)" "$(calls)"

LONG="$("$PY" -c 'print("x" * 3990)')"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "$LONG" --decision "$DEC"
it "prompt-item refuses when the decision text pushes the prompt over the cap"
check 1 "$CODE"
has "4000" "$OUT"
it "nothing is sent over the cap"
lacks "agent prompt" "$(calls)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "build it" --restriction "source only" --source pm_choice
it "prompt-item with a pm_choice restriction sends"
check 0 "$CODE"
it "the restriction is recorded on the item with its source"
check '["source only", "pm_choice"]' "$(field '[items["herdr:w2/p31"]["restrictions"][-1][k] for k in ("text", "source")]')"
it "the prompt names the restriction and its source"
has "source only (source: pm_choice)" "$(calls)"
it "the prompt_sent row carries the restriction"
has '"source": "pm_choice"' "$(journal_last prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "build it" --restriction "no deploys"
it "a restriction without a source refuses"
check 2 "$CODE"
has "--source" "$OUT"
prog prompt-item herdr:w2/p31 "build it" --restriction "no deploys" --source vibes
it "a restriction with an unknown source refuses"
check 2 "$CODE"
it "nothing is sent for a refused restriction"
lacks "agent prompt" "$(calls)"
check 1 "$(field 'len(items["herdr:w2/p31"]["restrictions"])')"

# Main's launch tests above leave an uncertain launch on AI-753, which refuses a new one by design.
prog add-item linear:AI-790 --title "Shot kinds brief"
BRIEF="${WORK}/brief.md"
printf 'Build shot kinds.\n' > "$BRIEF"
: > "$CALLS"
prog start-worker linear:AI-790 --decision "$DEC" -- --name shot-kinds --target tab
it "start-worker with a decision refuses without --handoff"
check 2 "$CODE"
has "--handoff" "$OUT"
prog start-worker linear:AI-790 --decision d000000 -- --name shot-kinds --handoff "$BRIEF"
it "start-worker refuses an unknown decision id"
check 1 "$CODE"
prog start-worker linear:AI-790 --restriction "no deploys" -- --name shot-kinds --handoff "$BRIEF"
it "start-worker refuses a restriction without a source"
check 2 "$CODE"
it "refused decision starts never call spinoff"
lacks "spinoff" "$(calls)"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-790 --decision "$DEC" --restriction "source only" --source pm_choice \
  -- --name shot-kinds --handoff "$BRIEF"
it "start-worker with a decision and --handoff starts"
check 0 "$CODE"
PASSED="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')"
it "spinoff gets a copy in the programme home, not the original"
has "${HOME_DIR}/" "$PASSED"
it "the copy carries the original brief, the decision text and the reopen clause"
COPY="$(cat "$PASSED" 2>/dev/null)"
has "Build shot kinds." "$COPY"
has "Export stays PNG only this release" "$COPY"
has "stop and state that evidence" "$COPY"
it "the copy carries the restriction with its source"
has "source only (source: pm_choice)" "$COPY"
it "the original brief is unchanged"
check "Build shot kinds." "$(cat "$BRIEF")"
it "the restriction is recorded on the started item"
check '["source only", "pm_choice"]' "$(field '[items["linear:AI-790"]["restrictions"][-1][k] for k in ("text", "source")]')"
it "the worker_started row carries the decision ids"
has "$DEC" "$(journal_last worker_started)"
run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    rec["programme"].setdefault("context", {})["decisions"] = {"crop-scope": [
        {"rev": 1, "scope": "crop only", "reason": "Shawn wants crop first", "limits": ["no export work"],
         "applies_to": ["programme"], "requirements": [], "state": "accepted"}]}
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
prog add-item linear:AI-791 --title "Crop brief"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-791 --decision crop-scope -- --name crop --handoff "$BRIEF"
it "start-worker takes a decision record id and quotes its revision and limits"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "decision:crop-scope@1 (decision record): crop only; reason: Shawn wants crop first; limits: no export work" "$COPY"
prog prompt-item herdr:w2/p31 "carry on" --decision no-such-record
it "a decision id in neither the log nor the decision records refuses"
check 1 "$CODE"
has "no accepted decision record" "$OUT"

run_py "$RUN" <<'EOF' >/dev/null
def ruling(effect, kind, applies_to, scope, state="accepted", legacy=None):
    return [{"rev": 1, "state": state, "kind": kind, "effect": effect, "legacy": legacy, "applies_to": applies_to,
             "until": None, "scope": scope, "reason": "Shawn said so", "quote": scope, "limits": [], "requirements": []}]
def body(rec):
    decisions = rec["programme"]["context"]["decisions"]
    decisions["r-grant"] = ruling("grant", "dependency_bump", ["linear:AI-792"], "bump minor deps freely")
    decisions["r-hold"] = ruling("restrict", "merge_around_gate", ["linear:AI-792"], "never merge around CI")
    decisions["r-call"] = ruling("decided", "product_call", ["programme"], "PNG export only")
    decisions["r-other"] = ruling("grant", "dependency_bump", ["linear:AI-790"], "another item's grant")
    decisions["r-shut"] = ruling("restrict", "prod_deploy", ["linear:AI-792"], "closed hold", state="closed")
    decisions["i0legacy"] = ruling("decided", None, ["linear:AI-792"], "keep PRs small", legacy="instruction")
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
prog add-item linear:AI-792 --title "Rulings brief"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision "$DEC" -- --name rulings --handoff "$BRIEF"
it "start-worker's brief lists the item's grant, restrict and decided Rulings beside the decision-log row"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "Settled decisions this work carries:" "$COPY"
has "Export stays PNG only this release" "$COPY"
has "- ruling:r-grant (dependency_bump, grant): bump minor deps freely; reason: Shawn said so" "$COPY"
has "- ruling:r-hold (merge_around_gate, restrict): never merge around CI" "$COPY"
has "- ruling:r-call (product_call, decided): PNG export only" "$COPY"
has "- ruling:i0legacy (legacy instruction, decided): keep PRs small" "$COPY"
it "the brief leaves out another item's Ruling and a closed one"
lacks "another item's grant" "$COPY"
lacks "closed hold" "$COPY"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision r-hold -- --name rulings2 --handoff "$BRIEF"
it "a Ruling passed with --decision reads as a Ruling, once"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check "0 1" "$CODE $(printf '%s\n' "$COPY" | grep -c 'ruling:r-hold')"
lacks "(decision record)" "$COPY"

run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    decisions = rec["programme"]["context"]["decisions"]
    for rid in [r for r in decisions if r.startswith("r-") or r == "i0legacy"]:
        del decisions[rid]
    decisions["r-narrow"] = [{"rev": 1, "state": "accepted", "kind": "tool_choice", "effect": "grant", "legacy": None,
                              "applies_to": ["linear:AI-792"], "until": None, "scope": "PM picks tools",
                              "reason": "Shawn said so", "quote": "tools are yours", "limits": [], "requirements": [],
                              "baseline": "act"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
mkdir -p "$(dirname "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"
printf '{"autonomy": {"tool_choice": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 -- --name narrowed --handoff "$BRIEF"
it "a grant whose kind Authority now holds narrower than its baseline reaches the brief as conflicted, not settled"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check 0 "$CODE"
has "ruling:r-narrow" "$COPY"
has "conflicted: wait for Shawn" "$COPY"
lacks "Settled decisions this work carries:" "$COPY"
lacks "stop and state that evidence" "$COPY"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision r-narrow -- --name narrowed2 --handoff "$BRIEF"
it "the same grant cited with --decision is conflicted too"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check "0 1" "$CODE $(printf '%s\n' "$COPY" | grep -c 'ruling:r-narrow')"
has "conflicted: wait for Shawn" "$COPY"
lacks "stop and state that evidence" "$COPY"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

prog add-item linear:AI-793 --title "No handoff"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-793 -- --name plain --target tab
it "start-worker with no handoff still starts when programme-wide Rulings exist"
check 0 "$CODE"
write_snapshot base

seed_behaviours() {
  run_py "$RUN" "$1" <<'EOF' >/dev/null
run, spec = args
def body(rec):
    rec["programme"] = ph.normalize_programme(rec["programme"])
    rec["programme"]["behaviours"] = [b for b in rec["programme"]["behaviours"] if b["id"] not in {e["id"] for e in json.loads(spec)}]
    rec["programme"]["behaviours"] += json.loads(spec)
core._with_locked_run_record(ph.home_path(run), run, body)
EOF
}
seed_behaviours '[{"id": "bpm", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "the item changes the editor", "checks": [{"text": "the item is an editor change", "by": "pm"}]},
  "do": ["run the editor smoke test"]},
 {"id": "bpmself", "layer": "programme", "applies_to": "pm", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "always", "checks": []}, "do": ["post a tracker note"]}]'

prog add-item linear:AI-792 --title "No behaviour matches"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 -- --name plain --target tab
it "start-worker with only a PM-checked behaviour the PM did not name needs no --handoff, as today"
check 0 "$CODE"
lacks "--handoff" "$(grep '^spinoff ' "$CALLS")"
it "that start records no behaviour delivery and names the held-back behaviour"
check "null" "$(field 'items["linear:AI-792"].get("behaviour_deliveries")')"
has '"behaviours_held_back": ["bpm"]' "$OUT"

write_snapshot base
seed_behaviours '[{"id": "bui", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "the work changes UI", "checks": [{"text": "the diff touches UI files", "by": "agent"}]},
  "do": ["browser-verify the change"], "evidence": "a browser recording attached"}]'
prog add-item linear:AI-793 --title "UI change"
: > "$CALLS"
prog start-worker linear:AI-793 -- --name ui --target tab
it "start-worker with a matching worker behaviour and no --handoff is refused with the existing message"
check 2 "$CODE"
has "needs --handoff" "$OUT"
lacks "spinoff" "$(calls)"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-793 -- --name ui --handoff "$BRIEF"
it "F2: start-worker with a matching behaviour writes a brief copy carrying the behaviours block"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "Behaviours this work follows:" "$COPY"
has "- bui: when the work changes UI. do: browser-verify the change. evidence: a browser recording attached" "$COPY"
it "a PM-only behaviour and an unnamed PM-checked behaviour stay out of the brief"
lacks "bpmself" "$COPY"
lacks "- bpm:" "$COPY"
it "F2: the item records the brief delivery"
check '[["bui", "brief", "start-worker"]]' "$(field '[[d["id"], d["reason"], d["via"]] for d in items["linear:AI-793"]["behaviour_deliveries"]]')"
prog add-item linear:AI-795 --title "UI change that fails to start"
prog start-worker linear:AI-795 -- --name uifail --handoff "$BRIEF"
it "a start where no agent appears records no behaviour delivery on the item"
check "1 null" "$CODE $(field 'items["linear:AI-795"].get("behaviour_deliveries")')"
it "the worker_started row and the recovery request carry the behaviour ids"
has '"behaviour_ids": ["bui"]' "$(journal_last worker_started)"
check "with" "$(run_py "$RUN" "$BRIEF" <<'EOF'
rec = load_lib_module("programme_recovery")
rows = [r["payload"] for r in pj.read(args[0]) if r["kind"] == "operation_admitted" and r["payload"].get("item") == "linear:AI-793"]
op = rows[-1]
base = {"spinoff": ["--name", "ui", "--handoff", args[1]], "decision_ids": [], "restrictions": []}
with_ids = rec.request_digest("launch", op["item"], op["target"], dict(base, behaviour_ids=["bui"]))
print("with" if op["digest"] == with_ids else ("without" if op["digest"] == rec.request_digest("launch", op["item"], op["target"], base) else "neither"))
EOF
)"

write_snapshot base
prog add-item linear:AI-794 --title "Editor change"
: > "$CALLS"
prog start-worker linear:AI-794 --behaviour bpmself -- --name ed --handoff "$BRIEF"
it "start-worker refuses --behaviour naming a PM-only behaviour, and never calls spinoff"
check 1 "$CODE"
lacks "spinoff" "$(calls)"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-794 --behaviour bpm -- --name ed --handoff "$BRIEF"
it "start-worker --behaviour adds a PM-checked behaviour the PM saw hold"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "- bpm: when the item changes the editor" "$COPY"
check '["bpm", "bui"]' "$(field 'sorted(d["id"] for d in items["linear:AI-794"]["behaviour_deliveries"])')"

write_snapshot base
run_py "$RUN" <<'EOF' >/dev/null
import datetime
pj.append_row(args[0], pj.entry("claim", "sess-w", {"item": "herdr:w2/p31", "deliverable": "merged", "ref": "pr:9"},
                                now=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc)), channel="claims")
pb = load_lib_module("programme_behaviours")
def body(rec):
    pb.record_delivery(rec["programme"]["items"]["herdr:w2/p31"], "bpm", "brief", "start-worker")
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
seed_behaviours '[{"id": "bearly", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-03-01T00:00:00Z",
  "when": {"text": "the work changes UI", "checks": [{"text": "the diff touches UI files", "by": "agent"}]},
  "do": ["attach a browser recording"], "evidence": "a browser recording attached"},
 {"id": "blate", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "history": [{"event": "recorded", "at": "2026-09-01T00:00:00Z"}],
  "when": {"text": "a claim is made", "checks": []}, "do": ["name the test command in the claim"]}]'
SENT_BEFORE="$(journal_count prompt_sent)"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bpm --reason relevant
it "a behaviour delivered in the brief is still due for a relevant reminder when its PM check holds"
check 0 "$CODE"
has "herdr agent prompt w2:p31 Behaviour bpm" "$(calls)"
check '["bpm", "relevant", "remind-behaviour"]' "$(field '[items["herdr:w2/p31"]["behaviour_deliveries"][-1][k] for k in ("id", "reason", "via")]')"
it "the reminder journals one behaviour_reminded row and no prompt_sent row"
check "1 ${SENT_BEFORE}" "$(journal_count behaviour_reminded) $(journal_count prompt_sent)"
has '"behaviour": "bpm"' "$(journal_last behaviour_reminded)"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back
it "a behaviour created after the worker started but before its claim sends the claim back"
check 0 "$CODE"
has '"timing": "send_back"' "$OUT"
has "sent back" "$(calls)"
has "a browser recording attached" "$(calls)"
it "AE2: the first send-back reports a count of 1"
has '"sent_back_count": 1' "$OUT"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back
it "AE2: a second send-back of the same behaviour on the same item reports a count of 2"
check 0 "$CODE"
has '"sent_back_count": 2' "$OUT"
check 2 "$(field 'len([d for d in items["herdr:w2/p31"]["behaviour_deliveries"] if d["id"] == "bearly" and d["reason"] == "sent_back"])')"

: > "$CALLS"
DELIVERIES_BEFORE="$(field 'len(items["herdr:w2/p31"]["behaviour_deliveries"])')"
prog remind-behaviour herdr:w2/p31 blate --reason sent_back
it "AE3: a send-back of a behaviour recorded after the item's claim is refused as remind-only"
check 1 "$CODE"
has "remind" "$OUT"
lacks "agent prompt" "$(calls)"
check "$DELIVERIES_BEFORE" "$(field 'len(items["herdr:w2/p31"]["behaviour_deliveries"])')"
prog remind-behaviour herdr:w2/p31 blate --reason relevant
it "AE3: the reminder goes out, reports remind-only and tells the worker it applies from now on"
check 0 "$CODE"
has '"timing": "remind_only"' "$OUT"
has "from now on" "$(calls)"
it "AE3: the item records the relevant delivery with the claim it came after"
check '["blate", "relevant", "claim", "2026-06-01T00:00:00Z", "remind_only"]' "$(field '[items["herdr:w2/p31"]["behaviour_deliveries"][-1][k] for k in ("id", "reason", "trigger", "trigger_at", "timing")]')"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back --trigger merge
it "a send-back against a trigger the item has not passed is refused"
check 1 "$CODE"
lacks "agent prompt" "$(calls)"

seed_behaviours "[{\"id\": \"blong\", \"layer\": \"programme\", \"applies_to\": \"workers\", \"state\": \"active\", \"at\": \"2026-01-01T00:00:00Z\",
  \"when\": {\"text\": \"always\", \"checks\": []}, \"do\": [\"$("$PY" -c 'print("y" * 5000)')\"]}]"
: > "$CALLS"
prog remind-behaviour herdr:w2/p31 blong --reason relevant
it "a reminder over the 4000-character cap is cut to fit and still names the behaviour id"
check 0 "$CODE"
has "herdr agent prompt w2:p31 Behaviour blong" "$(calls)"
check "True" "$("$PY" -c 'import sys; t=open(sys.argv[1]).read().split("herdr agent prompt w2:p31 ", 1)[1].rstrip("\n"); print(len(t) <= 4000 and t.endswith("..."))' "$CALLS")"

REFUSED_BEFORE="$(journal_count prompt_refused)"
: > "$CALLS"
prog remind-behaviour linear:AI-773 bearly --reason relevant
it "remind-behaviour to an item with no owner pane is refused like prompt-item"
check 1 "$CODE"
has "no recorded pane" "$OUT"
lacks "agent prompt" "$(calls)"
check "$((REFUSED_BEFORE + 1)) null" "$(journal_count prompt_refused) $(field 'items["linear:AI-773"].get("behaviour_deliveries")')"

prog remind-behaviour herdr:w2/p31 bpmself --reason relevant
it "remind-behaviour refuses a PM-only behaviour"
check 1 "$CODE"
prog remind-behaviour herdr:w2/p31 bnosuch --reason relevant
it "remind-behaviour refuses an unknown behaviour"
check 1 "$CODE"
prog remind-behaviour herdr:w2/p31 bui --reason later
it "remind-behaviour refuses an unknown reason"
check 2 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-other prog remind-behaviour herdr:w2/p31 bui --reason relevant
it "remind-behaviour refuses a session that does not drive the programme"
check 1 "$CODE"
write_snapshot base

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-sources.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

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
it "shells, the PM pane and the board pane are skipped with a reason"
check '[["w2:p1", "shell"], ["w2:p10", "pm"], ["w2:p11", "board"], ["w2:p2", "shell"]]' "$(jq_py 'sorted([s["pane"], s["why"]] for s in d["skipped"])')"
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
it "the board failing marks it unavailable with its reason"
check 'true' "$(jq_py 'd["sources"]["board"]["unavailable"]')"
it "with no Linear key, Linear is unavailable too, and issues stay unverified"
check '[true, null]' "$(jq_py '[d["sources"]["linear"]["unavailable"], d["issues_source"]]')"
it "herdr is available"
check 'false' "$(jq_py 'd["sources"]["herdr"]["unavailable"]')"
it "sweep writes nothing to the journal"
check 0 "$(journal_count source_changed)"
it "sweep calls herdr snapshot once, bounded behind a probe"
check '2' "$(grep -cE '^herdr (status server|api snapshot)' "$CALLS")"
it "a board plugin with no snapshot op is unsupported, not an outage"
check '"unsupported"' "$(jq_py 'd["sources"]["board"]["state"]')"
it "herdr answering is available"
check '"available"' "$(jq_py 'd["sources"]["herdr"]["state"]')"
export FAKE_BOARD_OUTAGE=1
prog sweep
unset FAKE_BOARD_OUTAGE
it "a supported board command that fails is an outage"
check '["unavailable", true]' "$(jq_py '[d["sources"]["board"]["state"], d["sources"]["board"]["unavailable"]]')"
mkdir -p "${WORK}/nopath"
PATH="${WORK}/nopath" prog sweep
it "herdr and board missing from PATH are unsupported"
check '["unsupported", "unsupported"]' "$(jq_py '[d["sources"]["herdr"]["state"], d["sources"]["board"]["state"]]')"

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
it "a board error falls back to Linear and marks the issues linear-direct"
check '"linear-direct"' "$(jq_py 'd["issues_source"]')"
it "Linear-direct is available"
check 'false' "$(jq_py 'd["sources"]["linear"]["unavailable"]')"
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
it "a failing Linear read flags Linear unavailable"
check '[true, null]' "$(jq_py '[d["sources"]["linear"]["unavailable"], d["issues_source"]]')"
unset FAKE_CURL_EXIT
it "curl missing from PATH makes Linear unsupported"
check 'unsupported' "$(PATH="${WORK}/nopath" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_sources").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"
it "a failing curl leaves Linear an outage"
check 'unavailable' "$(FAKE_CURL_EXIT=7 "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_sources").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"

export FAKE_BOARD_JSON="${WORK}/board.json"
cat > "$FAKE_BOARD_JSON" <<'EOF'
{"project":{"name":"Ai Editor"},"groups":[{"key":"started","label":"In Progress","issues":["AI-753","AI-760"]}],
 "issues":{"AI-753":{"identifier":"AI-753","title":"Shot kinds","state":{"name":"In Progress","type":"started"},"bindings":[]},
           "AI-760":{"identifier":"AI-760","title":"Bound by the board","state":{"name":"Todo","type":"unstarted"},"bindings":[{"tab":"w2:t1","panes":["w2:p31"]}]}},
 "pane_status":{}}
EOF
: > "$CALLS"
prog sweep
it "a working board is the issue source"
check '"board"' "$(jq_py 'd["issues_source"]')"
it "Linear is not read when the board answers"
lacks "curl" "$(calls)"
it "a board binding names the issue of an otherwise issueless pane"
check '[["linear:AI-753", ["branch"]], ["linear:AI-760", ["board"]]]' "$(jq_py 'sorted([p["item"], p["signals"]] for p in d["proposals"])')"
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
it "the failing board is recorded in the same sweep"
check 1 "$(source_count board)"
it "the unsupported board is recorded as unsupported, with no outage"
check '[true, null]' "$(field '[prog["sources"]["board"]["unsupported_since"] is not None, prog["sources"]["board"]["unavailable_since"]]')"
prog sweep --record-sources
it "an unchanged source is not recorded again"
check 1 "$(source_count herdr)"
unset FAKE_HERDR_DOWN
export FAKE_BOARD_OUTAGE=1
prog sweep --record-sources
unset FAKE_BOARD_OUTAGE
it "a real board outage after unsupported is recorded as an outage"
check '[null, true]' "$(field '[prog["sources"]["board"]["unsupported_since"], prog["sources"]["board"]["unavailable_since"] is not None]')"
check 2 "$(source_count board)"
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

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 -- --name shot-kinds --handoff /tmp/h.md
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

prog add-item linear:AI-772 --title "board pane" --pane w2:p11
prog prompt-item linear:AI-772 "hello board"
it "prompt-item to the board pane is refused"
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

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-sources.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

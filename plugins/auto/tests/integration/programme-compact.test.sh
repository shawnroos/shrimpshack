#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOKS="${AUTO_ROOT}/.claude/hooks"
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

echo "programme-compact.test.sh"

WORK="$(mktemp -d -t auto-programme-compact.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset CLAUDE_AUTO_REPO 2>/dev/null || true
for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

MARKER_PY="${WORK}/marker-python"
MARKER_LOG="${WORK}/marker.log"
cat > "$MARKER_PY" <<EOF
#!/usr/bin/env bash
echo ran >> "$MARKER_LOG"
exit 0
EOF
chmod +x "$MARKER_PY"

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
    return core.run_record_path(ph.home_path(run), run)
def load(run):
    return json.load(open(rec_path(run)))
def save(run, rec):
    json.dump(rec, open(rec_path(run), "w"))
$(cat)
PYEOF
}

session_start() {
  local payload="$1" cwd="${2:-$NOREPO}"
  ( cd "$cwd" && bash "${HOOKS}/on-session-start.sh" <<< "$payload" 2>/dev/null )
}

pre_compact() {
  ( cd "$NOREPO" && bash "${HOOKS}/on-pre-compact.sh" <<< "$1" 2>/dev/null )
}

context_of() {
  "$PY" -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("<empty>"); sys.exit(0)
try:
    d = json.loads(raw)
except ValueError:
    print("<not-json>" + raw); sys.exit(0)
h = d.get("hookSpecificOutput") or {}
print(h.get("hookEventName", "") + "|" + (h.get("additionalContext") or ""))
' <<< "$1"
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
FLAG="${HOME_DIR}/.compact-flag"

typed() {
  run_py "$RUN" "$1" <<'EOF'
run, text = args
print(pj.append_prompt(run, "sess-pm", text, "typed")["prompt_id"])
EOF
}

P_RULE="$(typed "don't fix other teams' breaks")"
P_GONE="$(typed "hold the flaky suite until Friday")"
P_TERM="$(typed "stop rule: only when done")"

it "the PM records the instruction to leave other teams' breaks alone"
prog record-instruction --prompt "$P_RULE"
check 0 "$CODE"
prog record-instruction --prompt "$P_GONE" --why "suite is unreliable"
GONE_ID="$("$PY" -c 'import json,sys; print(json.loads(sys.stdin.read())["instruction"])' <<< "$OUT" 2>&1)"
it "a second instruction is closed before compaction"
prog close-instruction "$GONE_ID" --as fulfilled --why "Friday came"
check 0 "$CODE"

it "the shim default data dir matches programme_home for SessionStart and PreCompact"
DEF="$(sed -n 's/^DEFAULT_DATA_DIR = "~\/\(.*\)"$/\1/p' "${AUTO_ROOT}/lib/programme_home.py")"
OK=1
for shim in on-session-start.sh on-pre-compact.sh; do
  grep -q "\${HOME:-}/${DEF}" "${HOOKS}/${shim}" 2>/dev/null || OK=0
done
check 1 "$OK"

it "hooks.json registers PreCompact on the pre-compact shim with a timeout"
check "on-pre-compact.sh 5" "$("$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]["PreCompact"][0]["hooks"][0]
print(h["command"].rsplit("/", 1)[-1], h.get("timeout"))
' "${HOOKS}/hooks.json" 2>&1)"

it "a non-driving session's PreCompact sets no flag"
pre_compact '{"session_id":"sess-other","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}'
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"

it "a non-driving session's compact SessionStart injects nothing"
check "<empty>" "$(context_of "$(session_start '{"session_id":"sess-other","source":"compact"}')")"

it "a sub-agent compaction inside the PM session sets no flag"
pre_compact '{"session_id":"sess-pm","agent_id":"agent-1","agent_type":"Explore","trigger":"auto","custom_instructions":null}'
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"

it "the forked session in agent_session_ids sets no flag"
run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["agent_session_ids"] = ["sess-fork"]; save(args[0], rec)
EOF
pre_compact '{"session_id":"sess-fork","trigger":"auto","custom_instructions":null}'
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"

run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["driving_session_id"] = "sess-new"; save(args[0], rec)
EOF
it "a lease's session whose record names another driver sets no flag"
pre_compact '{"session_id":"sess-pm","trigger":"auto","custom_instructions":null}'
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"
it "a lease's session whose record names another driver gets no block"
check "<empty>" "$(context_of "$(session_start '{"session_id":"sess-pm","source":"compact"}')")"
run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["driving_session_id"] = "sess-pm"; save(args[0], rec)
EOF

it "the driving session's PreCompact sets the flag from outside any repo"
OUT="$(pre_compact '{"session_id":"sess-pm","hook_event_name":"PreCompact","trigger":"manual","custom_instructions":null}')"
check present "$([ -e "$FLAG" ] && echo present || echo absent)"
it "PreCompact never blocks compaction"
lacks "block" "$OUT"
it "the flag file is private to the user"
check 600 "$(stat -f '%Lp' "$FLAG" 2>/dev/null || stat -c '%a' "$FLAG" 2>/dev/null)"

CTX="$(context_of "$(session_start '{"session_id":"sess-pm","source":"compact"}')")"
it "the compact SessionStart answers as a SessionStart hook"
has "SessionStart|" "$CTX"
it "the compact SessionStart injects the rules-in-force block"
has "<auto-rules>" "$CTX"
it "the injected block holds the instruction verbatim from the record"
has "don't fix other teams' breaks" "$CTX"
it "an instruction closed before compaction is absent from the block"
lacks "hold the flaky suite" "$CTX"
it "the block names the programme"
has "\"run\": \"${RUN}\"" "$CTX"

it "the driving session gets the block at a resumed session start too"
has "don't fix other teams' breaks" "$(context_of "$(session_start '{"session_id":"sess-pm","source":"resume"}')")"

it "a sub-agent's SessionStart in the PM session injects nothing"
check "<empty>" "$(context_of "$(session_start '{"session_id":"sess-pm","source":"compact","agent_id":"agent-1"}')")"

REPO="${WORK}/repo"
mkdir -p "${REPO}/.claude/auto"
cat > "${REPO}/.claude/auto/task-1.json" <<'EOF'
{"run_id": "task-1", "loop_phase": "work", "loop": {"driver": "manual", "last_beat_at": "2020-01-01T00:00:00Z"}}
EOF
CTX_REPO="$(context_of "$(session_start '{"session_id":"sess-pm","source":"compact"}' "$REPO")")"
it "inside a repo, the compact context keeps the task-run resume hint"
has "loop task-1 can be resumed" "$CTX_REPO"
it "inside a repo, the compact context also carries the rules block"
has "don't fix other teams' breaks" "$CTX_REPO"
it "inside a repo, a non-driving session still gets the plain resume hint"
check "<not-json>loop task-1 can be resumed: /auto-resume task-1" "$(context_of "$(session_start '{"session_id":"sess-other","source":"startup"}' "$REPO")")"

it "while the flag is set, amend-term refuses"
prog amend-term stop_rule only_when_done --prompt "$P_TERM"
check 1 "$CODE"
it "the refusal prints the rules-in-force block"
has "don't fix other teams' breaks" "$OUT"

run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0])
item = ph.new_item("linear:AI-1", "AI-1")
item["deliverables"] = {"merged": {}}
rec["programme"]["items"] = {"linear:AI-1": item}
save(args[0], rec)
EOF
it "while the flag is set, a worker's claim still succeeds"
if "$PY" "$PROG" describe 2>/dev/null | grep -q '"claim"'; then
  OUT="$(CLAUDE_CODE_SESSION_ID=sess-w "$PY" "$PROG" claim --run "$RUN" --item linear:AI-1 --deliverable merged --ref "https://github.com/o/r/pull/1" 2>&1)"
  check 0 "$?"
else
  fail "programme.py has no claim verb yet (written concurrently in another step)"
fi
it "while the flag is set, a watcher-beat still succeeds"
if "$PY" "$PROG" describe 2>/dev/null | grep -q '"watcher-beat"'; then
  prog watcher-beat w1 --process-id 4242
  check 0 "$CODE"
else
  fail "programme.py has no watcher-beat verb yet (written concurrently in another step)"
fi
it "the flag is still set after the exempt verbs"
check present "$([ -e "$FLAG" ] && echo present || echo absent)"

run_py "$RUN" <<'EOF' >/dev/null
rec = load(args[0])
item = ph.new_item("linear:AI-7", "AI-7", state="waiting")
item["matched_rule"] = "r1"
item["owner"] = {"pane": "w2:p1", "terminal_id": None, "session_id": "sess-w"}
item["waiting_on"] = {"who": "team-x", "watcher": None, "reporter": None}
rec["programme"]["items"] = {"linear:AI-7": item}
save(args[0], rec)
EOF
STOP="$( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< '{"session_id":"sess-pm"}' 2>/dev/null )"
REASON="$("$PY" -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("decision","allow") + "|" + d.get("reason",""))' <<< "$STOP" 2>&1)"
it "with the flag set, the next Stop is blocked"
has "block|" "$REASON"
it "the blocked Stop's reason carries the rules-in-force block"
has "<auto-rules>" "$REASON"
it "the Stop's block holds the instruction verbatim"
has "don't fix other teams' breaks" "$REASON"
it "the Stop's block is the real block, not a placeholder"
lacks "not yet available" "$REASON"

it "rules --ack is accepted while the flag is set"
prog rules --ack
check 0 "$CODE"
it "rules --ack clears the flag"
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"
it "after the acknowledgement amend-term is accepted"
prog amend-term stop_rule only_when_done --prompt "$P_TERM"
check 0 "$CODE"

STOP2="$( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< '{"session_id":"sess-pm"}' 2>/dev/null )"
it "without the flag the Stop reason carries no rules block"
lacks "<auto-rules>" "$STOP2"

it "an ended programme takes no flag"
run_py "$RUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "done")
EOF
pre_compact '{"session_id":"sess-pm","trigger":"auto","custom_instructions":null}'
check absent "$([ -e "$FLAG" ] && echo present || echo absent)"

: > "$MARKER_LOG"
EMPTY_DATA="${WORK}/empty-data"
it "with no lease and no repo, SessionStart runs no Python"
( cd "$NOREPO" && CLAUDE_AUTO_DATA_DIR="$EMPTY_DATA" CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-session-start.sh" <<< '{"session_id":"s0","source":"compact"}' )
check "" "$(cat "$MARKER_LOG")"
it "with no lease, PreCompact runs no Python"
( cd "$NOREPO" && CLAUDE_AUTO_DATA_DIR="$EMPTY_DATA" CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pre-compact.sh" <<< '{"session_id":"s0"}' )
check "" "$(cat "$MARKER_LOG")"

it "PreCompact with garbage stdin exits 0"
( cd "$NOREPO" && bash "${HOOKS}/on-pre-compact.sh" <<< 'not json' >/dev/null 2>&1 )
check 0 "$?"

echo
echo "programme-compact.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

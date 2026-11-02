#!/usr/bin/env bash
# auto unit test: the real close-gone-pane verb against a fixture programme and a fake herdr on PATH.
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

echo "programme-gone-panes-verb.test.sh"

WORK="$(mktemp -d -t auto-gone-verb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY AUTO_TEST_HOST 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
SNAP2="${WORK}/snapshot-after.json"
mkdir -p "$FAKES"
export CALLS SNAP SNAP2 PY

# The first snapshot read is the sweep's; every later read is the pre-close re-read and may differ.
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot")
    if [ -f "$SNAP2" ] && [ "$(grep -c '^herdr api snapshot' "$CALLS")" -ge 2 ]; then cat "$SNAP2"; else cat "$SNAP"; fi ;;
esac
exit 0
EOF
for tool in board gh; do
  printf '#!/bin/bash\nexit 1\n' > "${FAKES}/${tool}"
done
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

GONE_DIR="${WORK}/wt/removed"
LIVE_DIR="${WORK}/wt/live"
mkdir -p "$LIVE_DIR"

write_snapshot() {
  "$PY" - "$1" "$GONE_DIR" "$LIVE_DIR" "$2" "$3" <<'PYEOF'
import json, sys
path, gone, live, status, terminal = sys.argv[1:6]
def pane(pid, cwd, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
           "agent": "claude", "agent_status": "idle", "cwd": cwd, "label": None,
           "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
pm = pane("w2:p10", live, label="PM",
          agent_session={"source": "auto", "agent": "claude", "kind": "id", "value": "sess-pm"})
panes = [pm, pane("w2:p31", gone, agent_status=status, terminal_id=terminal), pane("w2:p32", live)]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": panes}}}
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
pa = load_lib_module("programme_authority")
args = sys.argv[2:]
$(cat)
PYEOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>/dev/null)"
  CODE=$?
}
closes() { grep -c '^herdr pane close' "$CALLS" 2>/dev/null || true; }
status_of() { "$PY" -c "import json,sys; print(json.loads(sys.stdin.read()).get('status'))" <<< "$OUT" 2>&1; }

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

write_snapshot "$SNAP" idle term_p31
prog add-item linear:AI-753 --title "Shot kinds" --pane w2:p31 --terminal-id term_p31
run_py "$RUN" <<'EOF'
def confirm(rec):
    merged = rec["programme"]["items"]["linear:AI-753"].setdefault("deliverables", {}).setdefault("merged", {})
    merged.update(result="confirmed", confirmed_at="2026-10-30T00:00:00Z")
pa.write(ph.home_path(args[0]), args[0], confirm)
EOF

journal_rows() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

it "a pane that is not in the sweep's folder_gone list is refused and herdr closes nothing"
: > "$CALLS"
prog close-gone-pane w2:p32 --run "$RUN"
check "refused 0" "$([ "$CODE" -ne 0 ] && echo refused || echo "exit-$CODE") $(closes)"

it "an eligible gone pane is closed: status closed, exactly one 'pane close w2:p31' call"
: > "$CALLS"
prog close-gone-pane w2:p31 --run "$RUN"
check "closed 1 1" "$(status_of) $(closes) $(grep -c '^herdr pane close w2:p31$' "$CALLS")"

it "the close is journaled as gone_pane_closed"
check "1" "$(journal_rows gone_pane_closed)"

it "a pane that began working between the sweep and the close is reported and not closed"
write_snapshot "$SNAP2" working term_p31
: > "$CALLS"
prog close-gone-pane w2:p31 --run "$RUN"
check "reported 0" "$(status_of) $(closes)"
it "the reason given is that the pane changed since the sweep"
has "pane changed since the sweep" "$OUT"

it "a pane that holds a different terminal between the sweep and the close is reported and not closed"
write_snapshot "$SNAP2" idle term_other
: > "$CALLS"
prog close-gone-pane w2:p31 --run "$RUN"
check "reported 0" "$(status_of) $(closes)"

it "the reported answer is journaled as gone_pane_reported"
check "2" "$(journal_rows gone_pane_reported)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

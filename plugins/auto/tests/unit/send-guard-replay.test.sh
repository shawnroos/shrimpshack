#!/usr/bin/env bash
# auto unit test: replays refused commands through the send-guard's literal check, treating each sender as in the programme.
# The real rows hold private work detail and this repo is public, so they stay in a gitignored file. Only synthetic rows are committed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LOCAL_ROWS="${AUTO_ROOT}/tests/fixtures/send-guard-replay.local.jsonl"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "send-guard-replay.test.sh"

WORK="$(mktemp -d -t auto-send-replay.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"

REPLAY_PY="${WORK}/replay.py"
cat > "$REPLAY_PY" <<'PYEOF'
import json, os, sys, hashlib
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
guard = load_lib_module("send_guard")
CUT = 2000
out = {"rows": 0, "allowed": 0, "refused": [], "truncated": 0, "raised": 0}
with open(sys.argv[2]) as fh:
    for line in fh:
        row = json.loads(line)
        command, pane = row["command"], row["pane_id"]
        out["rows"] += 1
        if len(command) >= CUT:
            out["truncated"] += 1
            continue
        driver = {"pane_id": pane, "ids": [pane], "terminal_id": None}
        workspace = pane.split(":", 1)[0] if ":" in pane else None
        try:
            hits = [(host, verb, target) for host, verb, target in guard.host_sends(command, [pane])
                    if guard._targets_pane(target, driver, workspace)]
        except Exception:
            out["raised"] += 1
            continue
        if hits:
            digest = hashlib.sha256(command.encode()).hexdigest()[:10]
            out["refused"].append({"id": digest, "host": hits[0][0], "verb": hits[0][1]})
        else:
            out["allowed"] += 1
print(json.dumps(out))
PYEOF

field() { "$PY" -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(len(v) if isinstance(v, list) else v)' "$1"; }

SYNTH="${WORK}/synthetic.jsonl"
"$PY" - "$SYNTH" <<'PYEOF'
import json, sys
pane = "w2:p9T"
rows = [
    "git show --stat abc123 | head -20",
    "git grep -n osascript tmux",
    "echo herdr pane run w2:p9T ls",
    "rex session rename \"$REX_SESSION\" orient",
    "cat <<'EOF' > notes.md\nherdr pane run w2:p9T ls\nEOF",
    "P=w2:p9T; herdr pane run $P ls",
    "herdr pane run w2:p9T ls",
    "x" * 2000,
]
with open(sys.argv[1], "w") as fh:
    for command in rows:
        fh.write(json.dumps({"command": command, "pane_id": pane}) + "\n")
PYEOF

OUT="$("$PY" "$REPLAY_PY" "$AUTO_ROOT" "$SYNTH")"

it "synthetic rows: the seeded literal send is the only refusal, so this replay can fail"
check "1" "$(printf '%s' "$OUT" | field refused)"

it "synthetic rows: ordinary commands, argument text, heredoc data and a computed target are allowed"
check "6" "$(printf '%s' "$OUT" | field allowed)"

it "synthetic rows: a row cut at the journal's limit is counted apart, not silently passed"
check "1" "$(printf '%s' "$OUT" | field truncated)"

it "synthetic rows: nothing raises"
check "0" "$(printf '%s' "$OUT" | field raised)"

if [ -f "$LOCAL_ROWS" ]; then
  REAL="$("$PY" "$REPLAY_PY" "$AUTO_ROOT" "$LOCAL_ROWS")"
  it "real rows: nothing raises"
  check "0" "$(printf '%s' "$REAL" | field raised)"
  printf '%s' "$REAL" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("  real rows: %d, allowed %d, refused %d, truncated %d" % (d["rows"], d["allowed"], len(d["refused"]), d["truncated"]))
for row in d["refused"]:
    print("    refused %s %s %s" % (row["id"], row["host"], row["verb"]))
'
else
  echo "  real rows: NOT RUN (no ${LOCAL_ROWS#"$AUTO_ROOT"/})"
fi

echo ""
echo "send-guard-replay.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

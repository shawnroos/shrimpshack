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

echo "programme-focus.test.sh"

WORK="$(mktemp -d -t auto-programme-focus.XXXXXX)"
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
  printf '#!/bin/sh\nexit 0\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py w2 <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, origin, text = args
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

FB='prog["agreement"]["terms"]["focus_budget"]'

it "a fresh programme carries focus_budget unlimited with no limits and the default scale"
check '[null, null, {"large": 5, "medium": 3, "small": 1}, "default", "unlimited"]' \
  "$(field "[${FB}['points'], ${FB}['agents'], ${FB}['scale'], ${FB}['set_by'], ${FB}['value']]")"

it "amend-term focus_budget limited stores the points and agents"
P1="$(prompt typed 'focus budget limited, 10 points and 3 agents')"
prog amend-term focus_budget limited --points 10 --agents 3 --prompt "$P1"
check 0 "$CODE"
check '["limited", 10, 3]' "$(field "[${FB}['value'], ${FB}['points'], ${FB}['agents']]")"

it "the terms view shows the points"
prog status --run "$RUN"
has "points 10" "$OUT"
has "agents 3" "$OUT"

it "an amend that sets only the points keeps the agent limit"
P2="$(prompt typed 'focus budget limited, only 6 points')"
prog amend-term focus_budget limited --points 6 --prompt "$P2"
check '[6, 3]' "$(field "[${FB}['points'], ${FB}['agents']]")"

it "a zero point limit is refused with the allowed range"
prog amend-term focus_budget limited --points 0 --prompt "$P1"
check 1 "$CODE"
has "positive whole number" "$OUT"

it "a negative agent limit is refused"
prog amend-term focus_budget limited --agents -2 --prompt "$P1"
check 1 "$CODE"
has "positive whole number" "$OUT"

it "a bare number is refused as fitting no option and names the usable form"
P3="$(prompt typed 'focus budget 10')"
prog amend-term focus_budget 10 --prompt "$P3"
check 1 "$CODE"
has "fits no option" "$OUT"
has "limited --points" "$OUT"

it "limited with neither limit is refused"
prog amend-term focus_budget limited --points none --agents none --prompt "$P1"
check 1 "$CODE"

it "a scale entry with a non-integer value is refused"
prog amend-term focus_budget limited --points 6 --scale small=x --prompt "$P1"
check 1 "$CODE"
has "whole number" "$OUT"

it "a scale entry with a zero value is refused"
prog amend-term focus_budget limited --points 6 --scale small=0 --prompt "$P1"
check 1 "$CODE"

it "a scale replaces the old one"
prog amend-term focus_budget limited --points 6 --scale small=2,large=8 --prompt "$P2"
check 0 "$CODE"
check '{"large": 8, "small": 2}' "$(field "${FB}['scale']")"

it "clearing sets unlimited, drops both limits and keeps the scale"
P4="$(prompt typed 'focus budget unlimited')"
prog amend-term focus_budget unlimited --prompt "$P4"
check 0 "$CODE"
check '["unlimited", null, null, {"large": 8, "small": 2}]' \
  "$(field "[${FB}['value'], ${FB}['points'], ${FB}['agents'], ${FB}['scale']]")"

it "propose-term carries the limits as extras and an amend that matches accepts the proposal"
prog propose-term focus_budget limited --points 9
check 0 "$CODE"
check '{"points": 9}' "$(field "${FB}['proposal']['extras']")"
P5="$(prompt typed 'focus budget limited, 9 points')"
prog amend-term focus_budget limited --points 9 --prompt "$P5"
check '"accepted"' "$(field "${FB}['proposal']['state']")"

it "an old record without focus_budget gains it as unlimited and stays accepted"
check '["unlimited", "default", true]' "$(run_py "$RUN" <<'EOF'
rec = record(args[0])
prog = json.loads(json.dumps(rec["programme"]))
prog["agreement"]["terms"].pop("focus_budget")
prog["agreement"]["accepted"] = {"at": "x", "prompt_id": "p1", "quote": "ok"}
t = ph.normalize_programme(prog)
f = t["agreement"]["terms"]["focus_budget"]
print(json.dumps([f["value"], f["set_by"], bool(t["agreement"]["accepted"])]))
EOF
)"

it "the accept-terms digest ignores an untouched focus_budget and changes once it is set"
FRESH="$(run_py w3 <<'EOF'
print(ph.create_programme([args[0]], "sess-pm2")["run"])
EOF
)"
check '["same", "differs"]' "$(run_py "$FRESH" <<'EOF'
approval = load_lib_module("programme_approval")
block = record(args[0])["programme"]
without = json.loads(json.dumps(block))
without["agreement"]["terms"].pop("focus_budget")
set_ = json.loads(json.dumps(block))
set_["agreement"]["terms"]["focus_budget"].update(value="limited", points=5, set_by="shawn")
print(json.dumps([
    "same" if approval.terms_digest(block) == approval.terms_digest(without) else "differs",
    "differs" if approval.terms_digest(block) != approval.terms_digest(set_) else "same"]))
EOF
)"

it "setup counts a never-set focus_budget as done"
check '"done"' "$(run_py "$FRESH" <<'EOF'
vs = load_lib_module("programme_view_setup")
step = vs._term_step("focus_budget", record(args[0])["programme"]["agreement"]["terms"]["focus_budget"], set())
print(json.dumps(step["state"] if "state" in step else ("done" if step["done"] else "open")))
EOF
)"

# ---- U2: item size ----
P6="$(prompt typed 'focus budget unlimited, scale small 1 medium 3 large 5')"
prog amend-term focus_budget unlimited --scale small=1,medium=3,large=5 --prompt "$P6"
SIZED="mem:one"
prog add-item mem:one --title "one" --size medium --run "$RUN"
[ "$CODE" -eq 0 ] || echo "$OUT"
check 0 "$CODE"
it "add-item --size stores the size and points_of resolves it"
check '["medium", 3]' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
prog = record(args[0])["programme"]
print(json.dumps([prog["items"]["mem:one"]["size"], focus.points_of(prog["items"]["mem:one"], prog["agreement"]["terms"]["focus_budget"]["scale"])]))
EOF
)"

it "add-item with a size outside the scale is refused and lists the valid names"
prog add-item mem:two --title two --size huge --run "$RUN"
check 1 "$CODE"
has "small" "$OUT"
has "large" "$OUT"
check 'false' "$(field '"mem:two" in prog["items"]')"

it "size-item changes the size and records history"
prog add-item mem:two --title two --run "$RUN"
prog size-item mem:two large --run "$RUN"
check 0 "$CODE"
check '["large", "sized"]' "$(field '[prog["items"]["mem:two"]["size"], prog["items"]["mem:two"]["history"][-1]["kind"]]')"

it "size-item with a name outside the scale is refused and lists the valid names"
prog size-item mem:two huge --run "$RUN"
check 1 "$CODE"
has "small" "$OUT"
check '"large"' "$(field 'prog["items"]["mem:two"]["size"]')"

it "size-item on an unknown item is refused"
prog size-item mem:nope small --run "$RUN"
check 1 "$CODE"

it "an item with no size reads as unsized, not zero points"
prog add-item mem:three --title three --run "$RUN"
check 'null' "$(field 'prog["items"]["mem:three"]["size"]')"
check 'null' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
prog = record(args[0])["programme"]
print(json.dumps(focus.points_of(prog["items"]["mem:three"], prog["agreement"]["terms"]["focus_budget"]["scale"])))
EOF
)"

it "a size renamed out of the scale makes the item unsized"
check 'null' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
print(json.dumps(focus.points_of({"size": "large"}, {"small": 1})))
EOF
)"

it "an old item record without a size field normalizes to unsized"
check 'null' "$(run_py "$RUN" <<'EOF'
print(json.dumps(ph.normalize_item({"id": "mem:old", "title": "x"}).get("size", "missing")))
EOF
)"

echo ""
echo "programme-focus.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

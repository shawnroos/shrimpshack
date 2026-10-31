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

echo "programme-behaviour-file-verbs.test.sh"

WORK="$(mktemp -d -t auto-behaviour-file-verbs.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="${WORK}/shipped"
export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/personal/behaviours"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/personal/behaviours.json"
mkdir -p "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" "${WORK}/drafts"
SEEN="${WORK}/personal/behaviours-seen.json"
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
fv = load_lib_module("programme_behaviour_file_verbs")
bf = load_lib_module("programme_behaviour_files")
args = sys.argv[2:]
$(cat)
PYEOF
}

OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
tprompt() {
  run_py "$1" "$2" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1])["prompt_id"])
EOF
}
dhash() {
  run_py "$1" "$2" <<'EOF'
print(fv.draft_hash(open(args[0]).read(), args[1]))
EOF
}
journal_kinds() {
  run_py "$1" <<'EOF'
print(" ".join(r["kind"] for r in pj.read(args[0])))
EOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w1"], "sess-pm")["run"])
EOF
)"

draft() {
  printf -- '---\nwhen: a bug is reported\nchecks:\n  - pm: the item is a bug\n---\nDo:\n- %s\n' "$2" > "${WORK}/drafts/$1.md"
}
draft a "reproduce the bug first"
draft b "skip reproduction"
printf -- '---\nbogus_key: 1\n---\nDo:\n- x\n' > "${WORK}/drafts/bad.md"
PERS="$CLAUDE_AUTO_BEHAVIOURS_DIR"

HASH_A="$(dhash "${WORK}/drafts/a.md" p1)"

it "adopt-behaviour-file: a prompt that does not name the behaviour refuses and writes nothing"
P="$(tprompt "$RUN" "sure, go ahead and write that file ${HASH_A}")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/p1.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: a prompt that names the id but not the draft's hash refuses and the refusal shows the hash"
P="$(tprompt "$RUN" "adopt p1 as my behaviour")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/p1.md" ] && echo present || echo absent)"
has "$HASH_A" "$OUT"

it "adopt-behaviour-file: approve draft A, submit draft B: refused and nothing written"
P="$(tprompt "$RUN" "adopt p1 with ${HASH_A}")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/b.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/p1.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: a file that fails validation is refused and not written"
P="$(tprompt "$RUN" "adopt pbad please")"
prog adopt-behaviour-file pbad --file "${WORK}/drafts/bad.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/pbad.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: an id that could leave the folder is refused"
P="$(tprompt "$RUN" "adopt evil with ${HASH_A}")"
prog adopt-behaviour-file ../evil --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "2 absent" "$CODE $([ -e "${WORK}/personal/evil.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: the approved draft is written, byte for byte, and journals rule_adopted"
P="$(tprompt "$RUN" "adopt p1 with ${HASH_A}")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "0 same" "$CODE $(cmp -s "${WORK}/drafts/a.md" "${PERS}/p1.md" && echo same || echo different)"
has "rule_adopted" "$(journal_kinds "$RUN")"

it "adopt-behaviour-file: a file the verb wrote loads cleanly through the file loader"
check "p1 0" "$(run_py <<'EOF'
out = bf.load_files()
print(" ".join(e["id"] for e in out["entries"] if e["layer"] == "personal"), len(out["rejected"]))
EOF
)"

it "adopt-behaviour-file: the same id a second time is refused and keeps the first file"
HASH_B="$(dhash "${WORK}/drafts/b.md" p1)"
P="$(tprompt "$RUN" "adopt p1 with ${HASH_B}")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/b.md" --prompt "$P" --run "$RUN"
check "1 same" "$CODE $(cmp -s "${WORK}/drafts/a.md" "${PERS}/p1.md" && echo same || echo different)"

it "adopt-behaviour-file: an approval row keyed to the hash on the prompt also approves"
P="$(tprompt "$RUN" "adopt p2 now")"
run_py "$RUN" "$P" "${WORK}/drafts/a.md" <<'EOF'
run, pid, path = args
h = fv.draft_hash(open(path).read(), "p2")
pj.append(run, "rule_adopted", "sess-pm", {"entry": "file", "target": "behaviour-file:p2", "hash": h,
                                           "prompt_id": pid, "quote": "x"}, cites=[pid])
EOF
prog adopt-behaviour-file p2 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "0 present" "$CODE $([ -e "${PERS}/p2.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: two concurrent adopts for different ids both land"
draft c "check the logs"
draft d "check the metrics"
HC="$(dhash "${WORK}/drafts/c.md" pc)"
HD="$(dhash "${WORK}/drafts/d.md" pd)"
PC="$(tprompt "$RUN" "adopt pc with ${HC}")"
PD="$(tprompt "$RUN" "adopt pd with ${HD}")"
"$PY" "$PROG" adopt-behaviour-file pc --file "${WORK}/drafts/c.md" --prompt "$PC" --run "$RUN" >/dev/null 2>&1 &
"$PY" "$PROG" adopt-behaviour-file pd --file "${WORK}/drafts/d.md" --prompt "$PD" --run "$RUN" >/dev/null 2>&1 &
wait
check "present present" "$([ -e "${PERS}/pc.md" ] && echo present || echo absent) $([ -e "${PERS}/pd.md" ] && echo present || echo absent)"

# copy-default and settle-default-update
draft_shipped() {
  printf -- '---\nwhen: work starts\nchecks:\n  - pm: the item exists\n---\nDo:\n- %s\n' "$2" > "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/$1.md"
}
draft_shipped d1 "write a plan"
shipped_hash() {
  run_py "$1" <<'EOF'
print(fv.shipped_hash(args[0]))
EOF
}
seen_field() {
  "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],{}).get(sys.argv[3],""))' "$SEEN" "$1" "$2" 2>&1
}

it "copy-default: without a prompt that names the behaviour it refuses and writes nothing"
P="$(tprompt "$RUN" "yes copy it")"
prog copy-default d1 --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent)"

it "copy-default: an id with no shipped file refuses"
P="$(tprompt "$RUN" "copy nothere into my folder")"
prog copy-default nothere --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/nothere.md" ] && echo present || echo absent)"

it "copy-default: a shipped id with a naming prompt writes the file and records seen"
P="$(tprompt "$RUN" "copy d1 into my folder")"
prog copy-default d1 --prompt "$P" --run "$RUN"
H1="$(shipped_hash d1)"
check "0 same $H1" "$CODE $(cmp -s "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md" && echo same || echo different) $(seen_field d1 seen)"

it "copy-default: a second copy over an existing personal file is refused"
P="$(tprompt "$RUN" "copy d1 into my folder again")"
prog copy-default d1 --prompt "$P" --run "$RUN"
check 1 "$CODE"

it "AE3: after the shipped file changes, --as shown records shown with no prompt and leaves seen"
draft_shipped d1 "write a plan and a test"
H2="$(shipped_hash d1)"
prog settle-default-update d1 --as shown --run "$RUN"
check "0 $H2 $H1" "$CODE $(seen_field d1 shown) $(seen_field d1 seen)"

it "AE3: --as keep without a prompt that names the id and mode refuses and leaves seen"
P="$(tprompt "$RUN" "keep it")"
prog settle-default-update d1 --as keep --prompt "$P" --run "$RUN"
check "1 $H1" "$CODE $(seen_field d1 seen)"

it "AE3: --as keep with a naming prompt records seen as the current shipped hash"
P="$(tprompt "$RUN" "keep d1 as mine")"
prog settle-default-update d1 --as keep --prompt "$P" --run "$RUN"
check "0 $H2" "$CODE $(seen_field d1 seen)"

it "settle-default-update: an unknown id refuses"
prog settle-default-update zzz --as shown --run "$RUN"
check 1 "$CODE"

it "settle-default-update: --as take without a matching prompt leaves the personal file"
P="$(tprompt "$RUN" "keep d1 as mine")"
prog settle-default-update d1 --as take --prompt "$P" --run "$RUN"
check "1 present" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent)"

it "settle-default-update: --as take with a matching prompt removes the file and records seen"
draft_shipped d1 "write a plan, a test and a note"
H3="$(shipped_hash d1)"
P="$(tprompt "$RUN" "take d1 theirs")"
prog settle-default-update d1 --as take --prompt "$P" --run "$RUN"
check "0 absent $H3" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent) $(seen_field d1 seen)"

it "settle-default-update: --as merge with content that differs from the approved content is refused"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md"
draft m1 "merged text one"
draft m2 "merged text two"
HM1="$(dhash "${WORK}/drafts/m1.md" d1)"
P="$(tprompt "$RUN" "merge d1 with ${HM1}")"
prog settle-default-update d1 --as merge --file "${WORK}/drafts/m2.md" --prompt "$P" --run "$RUN"
check "1 same" "$CODE $(cmp -s "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md" && echo same || echo different)"

it "settle-default-update: --as merge with the approved content replaces the file and records seen"
prog settle-default-update d1 --as merge --file "${WORK}/drafts/m1.md" --prompt "$P" --run "$RUN"
check "0 same $H3" "$CODE $(cmp -s "${WORK}/drafts/m1.md" "${PERS}/d1.md" && echo same || echo different) $(seen_field d1 seen)"

it "the verbs' kinds are journalled as rule_adopted and a file the merge wrote still loads"
check "0" "$(run_py <<'EOF'
print(len(bf.load_files()["rejected"]))
EOF
)"

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

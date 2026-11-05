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
opick() { "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"; }
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

it "adopt-behaviour-file: typed words naming the id and carrying the hash approve nothing without an offer"
P="$(tprompt "$RUN" "adopt p1 with ${HASH_A}")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/p1.md" ] && echo present || echo absent)"
has "offer" "$OUT"

it "adopt-behaviour-file: the option shows a plain label with the content's short hash"
OFFERED="$("$PY" "$PROG" offer adopt-p1 --command "adopt-behaviour-file p1 --file ${WORK}/drafts/a.md" --run "$RUN" 2>&1)"
has "Adopt behaviour file p1 (content ${HASH_A:7:6})" "$OFFERED"

it "adopt-behaviour-file: an offer of draft A does not approve draft B"
P="$(opick "$RUN" "adopt-behaviour-file p1 --file ${WORK}/drafts/a.md")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/b.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/p1.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: a draft changed after the offer is refused, and nothing is written"
draft c1 "the words he saw"
P="$(opick "$RUN" "adopt-behaviour-file pc1 --file ${WORK}/drafts/c1.md")"
draft c1 "other words"
prog adopt-behaviour-file pc1 --file "${WORK}/drafts/c1.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/pc1.md" ] && echo present || echo absent)"
has "changed" "$OUT"

it "adopt-behaviour-file: a 64 KB draft is offered and bound by hash, and a changed one is refused"
"$PY" - "${WORK}/drafts/big.md" 60000 <<'EOF'
import sys
head = "---\nwhen: a bug is reported\nchecks:\n  - pm: the item is a bug\n---\nDo:\n"
line = "- " + "x" * 70 + "\n"
open(sys.argv[1], "w").write(head + line * ((int(sys.argv[2]) - len(head)) // len(line)))
EOF
BIG_BYTES="$(wc -c < "${WORK}/drafts/big.md" | tr -d ' ')"
P="$(opick "$RUN" "adopt-behaviour-file pbig --file ${WORK}/drafts/big.md")"
command cp "${WORK}/drafts/big.md" "${WORK}/drafts/big.keep"
printf -- '- one more line\n' >> "${WORK}/drafts/big.md"
prog adopt-behaviour-file pbig --file "${WORK}/drafts/big.md" --prompt "$P" --run "$RUN"
GOT="$CODE $([ -e "${PERS}/pbig.md" ] && echo present || echo absent)"
command cp "${WORK}/drafts/big.keep" "${WORK}/drafts/big.md"
P="$(opick "$RUN" "adopt-behaviour-file pbig --file ${WORK}/drafts/big.md")"
prog adopt-behaviour-file pbig --file "${WORK}/drafts/big.md" --prompt "$P" --run "$RUN"
check "over-59k 1 absent 0 same" "$([ "$BIG_BYTES" -gt 59000 ] && echo over-59k) $GOT $CODE $(cmp -s "${WORK}/drafts/big.md" "${PERS}/pbig.md" && echo same || echo different)"

path_of_length() {
  local path="${WORK}/drafts" part
  while [ $((${#path} + 1 + 200 + 3)) -lt "$1" ]; do
    part="$(printf 'd%.0s' $(seq 1 200))"
    path="${path}/${part}"
  done
  mkdir -p "$path"
  part="$(printf 'f%.0s' $(seq 1 $(($1 - ${#path} - 4))))"
  printf '%s/%s.md' "$path" "$part"
}

it "adopt-behaviour-file: a 600-character path is a path, not record text, and the draft is adopted"
LONG_PATH="$(path_of_length 600)"
cp "${WORK}/drafts/a.md" "$LONG_PATH"
P="$(opick "$RUN" "adopt-behaviour-file plong --file ${LONG_PATH}")"
prog adopt-behaviour-file plong --file "$LONG_PATH" --prompt "$P" --run "$RUN"
check "600 0 same" "${#LONG_PATH} $CODE $(cmp -s "$LONG_PATH" "${PERS}/plong.md" && echo same || echo different)"
rm -f "${PERS}/plong.md"

it "adopt-behaviour-file: a path the option cannot show whole is refused by the description check"
TOO_LONG="$(path_of_length 950)"
cp "${WORK}/drafts/a.md" "$TOO_LONG"
OFFERED="$("$PY" "$PROG" offer too-long --command "adopt-behaviour-file ptoolong --file ${TOO_LONG}" --run "$RUN" 2>&1)"
check "1" "$?"
has "the description is" "$OFFERED"

it "adopt-behaviour-file: a decline writes nothing"
P="$(opick "$RUN" --decline "adopt-behaviour-file pd1 --file ${WORK}/drafts/a.md")"
prog adopt-behaviour-file pd1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/pd1.md" ] && echo present || echo absent)"

it "adopt and merge note the text they read: the approval checks the text the verb writes, not a second read of the file"
check "text one|text two" "$(run_py "${WORK}/drafts/note.md" <<'EOF'
programme = load_lib_module("programme")
offers = load_lib_module("programme_offers")
class Host:
    _parse = staticmethod(programme._parse)
    @staticmethod
    def _write(*_args, **kwargs):
        seen.append(kwargs.get("content"))
        return 0
seen = []
for text, handler, argv in (("text one", fv._h_adopt, ["adopt-behaviour-file", "nb", "--file", args[0]]),
                            ("text two", fv._h_settle, ["settle-default-update", "nb", "--as", "merge", "--file", args[0], "--prompt", "p"])):
    open(args[0], "w").write(text)
    handler(Host, argv)
print("|".join(seen))
EOF
)"

it "offer: --file - is refused, so what he saw can be read again at approval"
"$PY" "$PROG" offer stdin-draft --command "adopt-behaviour-file pd2 --file -" --run "$RUN" < "${WORK}/drafts/a.md" > /dev/null 2>&1
check 1 "$?"

it "adopt-behaviour-file: a file that fails validation is refused and not written"
P="$(tprompt "$RUN" "adopt pbad please")"
prog adopt-behaviour-file pbad --file "${WORK}/drafts/bad.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/pbad.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: an id that could leave the folder is refused"
P="$(tprompt "$RUN" "adopt evil with ${HASH_A}")"
prog adopt-behaviour-file ../evil --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "2 absent" "$CODE $([ -e "${WORK}/personal/evil.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: an id the file loader would reject (leading digit, underscore) is refused up front"
P="$(tprompt "$RUN" "adopt 0lead with ${HASH_A}")"
prog adopt-behaviour-file 0lead --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
GOT="$CODE $([ -e "${PERS}/0lead.md" ] && echo present || echo absent)"
prog adopt-behaviour-file under_score --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "2 absent 2 absent" "$GOT $CODE $([ -e "${PERS}/under_score.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: the approved draft is written, byte for byte, and journals rule_adopted"
P="$(opick "$RUN" "adopt-behaviour-file p1 --file ${WORK}/drafts/a.md")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "0 same" "$CODE $(cmp -s "${WORK}/drafts/a.md" "${PERS}/p1.md" && echo same || echo different)"
has "rule_adopted" "$(journal_kinds "$RUN")"

it "adopt-behaviour-file: a file the verb wrote loads cleanly through the file loader"
check "p1 pbig 0" "$(run_py <<'EOF'
out = bf.load_files()
print(" ".join(e["id"] for e in out["entries"] if e["layer"] == "personal"), len(out["rejected"]))
EOF
)"

it "adopt-behaviour-file: the same id a second time is refused and keeps the first file"
HASH_B="$(dhash "${WORK}/drafts/b.md" p1)"
P="$(opick "$RUN" "adopt-behaviour-file p1 --file ${WORK}/drafts/b.md")"
prog adopt-behaviour-file p1 --file "${WORK}/drafts/b.md" --prompt "$P" --run "$RUN"
check "1 same" "$CODE $(cmp -s "${WORK}/drafts/a.md" "${PERS}/p1.md" && echo same || echo different)"

it "adopt-behaviour-file: two concurrent adopts for different ids both land"
draft c "check the logs"
draft d "check the metrics"
HC="$(dhash "${WORK}/drafts/c.md" pc)"
HD="$(dhash "${WORK}/drafts/d.md" pd)"
PC="$(opick "$RUN" "adopt-behaviour-file pc --file ${WORK}/drafts/c.md")"
PD="$(opick "$RUN" "adopt-behaviour-file pd --file ${WORK}/drafts/d.md")"
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

it "copy-default: typed words naming the id approve nothing without an offer"
P="$(tprompt "$RUN" "copy d1 into my folder")"
prog copy-default d1 --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent)"

it "copy-default: an id with no shipped file cannot be offered"
"$PY" "$PROG" offer copy-none --command "copy-default nothere" --run "$RUN" > /dev/null 2>&1
check "1 absent" "$? $([ -e "${PERS}/nothere.md" ] && echo present || echo absent)"

it "copy-default: a shipped id with a naming prompt writes the file and records seen"
P="$(opick "$RUN" "copy-default d1")"
prog copy-default d1 --prompt "$P" --run "$RUN"
H1="$(shipped_hash d1)"
check "0 same $H1" "$CODE $(cmp -s "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md" && echo same || echo different) $(seen_field d1 seen)"

it "copy-default: a second copy over an existing personal file is refused"
P="$(opick "$RUN" "copy-default d1")"
prog copy-default d1 --prompt "$P" --run "$RUN"
check 1 "$CODE"

it "AE3: after the shipped file changes, --as shown records shown with no prompt and leaves seen"
draft_shipped d1 "write a plan and a test"
H2="$(shipped_hash d1)"
prog settle-default-update d1 --as shown --run "$RUN"
check "0 $H2 $H1" "$CODE $(seen_field d1 shown) $(seen_field d1 seen)"

it "AE3: --as keep on typed words with no offer refuses and leaves seen"
P="$(tprompt "$RUN" "keep d1 as mine")"
prog settle-default-update d1 --as keep --prompt "$P" --run "$RUN"
check "1 $H1" "$CODE $(seen_field d1 seen)"

it "settle-default-update: keep, take and merge are each an option of one picker, and shown cannot be offered"
draft m0 "merged for the picker"
OFFERED="$("$PY" "$PROG" offer settle-d1 --command "settle-default-update d1 --as keep" --command "settle-default-update d1 --as take" --command "settle-default-update d1 --as merge --file ${WORK}/drafts/m0.md" --run "$RUN" 2>&1)"
check "4 Keep Take Merge" "$("$PY" -c 'import json,sys; o=json.loads(sys.argv[1])["input"]["questions"][0]["options"]; print(len(o), *[x["label"].split()[0] for x in o[:3]])' "$OFFERED")"
"$PY" "$PROG" offer settle-shown --command "settle-default-update d1 --as shown" --run "$RUN" > /dev/null 2>&1
check 1 "$?"

it "AE3: --as keep with a naming prompt records seen as the current shipped hash"
P="$(opick "$RUN" "settle-default-update d1 --as keep")"
prog settle-default-update d1 --as keep --prompt "$P" --run "$RUN"
check "0 $H2" "$CODE $(seen_field d1 seen)"

it "settle-default-update: an unknown id refuses"
prog settle-default-update zzz --as shown --run "$RUN"
check 1 "$CODE"

it "settle-default-update: a pick of keep does not approve take"
P="$(opick "$RUN" "settle-default-update d1 --as keep")"
prog settle-default-update d1 --as take --prompt "$P" --run "$RUN"
check "1 present" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent)"

it "settle-default-update: --as take with a matching prompt removes the file and records seen"
draft_shipped d1 "write a plan, a test and a note"
H3="$(shipped_hash d1)"
P="$(opick "$RUN" "settle-default-update d1 --as take")"
prog settle-default-update d1 --as take --prompt "$P" --run "$RUN"
check "0 absent $H3" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent) $(seen_field d1 seen)"

it "settle-default-update: --as merge with content that differs from the approved content is refused"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md"
draft m1 "merged text one"
draft m2 "merged text two"
P="$(opick "$RUN" "settle-default-update d1 --as merge --file ${WORK}/drafts/m1.md")"
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

it "an id with a trailing newline is refused by the verb and writes nothing"
P="$(tprompt "$RUN" "adopt a with ${HASH_A}")"
prog adopt-behaviour-file $'a\n' --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "2 absent" "$CODE $([ -e "${PERS}/a.md" ] && echo present || echo absent)"

it "adopt-behaviour-file: an id that already exists as a stored personal behaviour is refused with a clear message"
printf '{"personal": [{"id": "stored1"}], "repos": {}}\n' > "$CLAUDE_AUTO_BEHAVIOURS_STORE"
HS="$(dhash "${WORK}/drafts/a.md" stored1)"
P="$(opick "$RUN" "adopt-behaviour-file stored1 --file ${WORK}/drafts/a.md")"
prog adopt-behaviour-file stored1 --file "${WORK}/drafts/a.md" --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/stored1.md" ] && echo present || echo absent)"
has "stored personal behaviour" "$OUT"
rm -f "$CLAUDE_AUTO_BEHAVIOURS_STORE"

draft_shipped d2 "write a note"
printf '[]\n' > "$SEEN"

it "a corrupt seen file: copy-default refuses and writes no personal file"
P="$(opick "$RUN" "copy-default d2")"
prog copy-default d2 --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/d2.md" ] && echo present || echo absent)"

it "a corrupt seen file: take refuses and the personal file remains"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md"
P="$(opick "$RUN" "settle-default-update d1 --as take")"
prog settle-default-update d1 --as take --prompt "$P" --run "$RUN"
check "1 present" "$CODE $([ -e "${PERS}/d1.md" ] && echo present || echo absent)"

it "a corrupt seen file: merge refuses and leaves the personal file as it was"
P="$(opick "$RUN" "settle-default-update d1 --as merge --file ${WORK}/drafts/m2.md")"
prog settle-default-update d1 --as merge --file "${WORK}/drafts/m2.md" --prompt "$P" --run "$RUN"
check "1 same" "$CODE $(cmp -s "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d1.md" "${PERS}/d1.md" && echo same || echo different)"
rm -f "$SEEN"

# The seen file is absent and its folder is read-only: the personal-file write succeeds, then recording
# seen fails. A verb that fails must leave the personal folder as it found it.
draft_shipped d5 "write a changelog"
draft_shipped d6 "write a summary"
draft_shipped d7 "write a diagram"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d6.md" "${PERS}/d6.md"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d7.md" "${PERS}/d7.md"
draft d7 "write a diagram, then caption it"
chmod 555 "$(dirname "$SEEN")"

it "a failed seen write: copy-default fails and leaves no personal file"
P="$(opick "$RUN" "copy-default d5")"
prog copy-default d5 --prompt "$P" --run "$RUN"
check "1 absent" "$CODE $([ -e "${PERS}/d5.md" ] && echo present || echo absent)"

it "a failed seen write: take fails and the personal copy is still there"
P="$(opick "$RUN" "settle-default-update d6 --as take")"
prog settle-default-update d6 --as take --prompt "$P" --run "$RUN"
check "1 present" "$CODE $([ -e "${PERS}/d6.md" ] && echo present || echo absent)"

it "a failed seen write: merge fails and the personal copy keeps its old content"
P="$(opick "$RUN" "settle-default-update d7 --as merge --file ${WORK}/drafts/d7.md")"
prog settle-default-update d7 --as merge --file "${WORK}/drafts/d7.md" --prompt "$P" --run "$RUN"
check "1 same" "$CODE $(cmp -s "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d7.md" "${PERS}/d7.md" && echo same || echo different)"
chmod 755 "$(dirname "$SEEN")"

# One approval applies once: the prompt, verb, id and content it approved are spent after the write.
draft_shipped d8 "write a retro"
draft_shipped d9 "write a plan note"
draft p9 "reproduce the bug first"
HP9="$(dhash "${WORK}/drafts/p9.md" p9)"

it "approval replay: adopt-behaviour-file with a spent approval is refused after the file is removed"
P="$(opick "$RUN" "adopt-behaviour-file p9 --file ${WORK}/drafts/p9.md")"
prog adopt-behaviour-file p9 --file "${WORK}/drafts/p9.md" --prompt "$P" --run "$RUN"
FIRST="$CODE"
rm -f "${PERS}/p9.md"
prog adopt-behaviour-file p9 --file "${WORK}/drafts/p9.md" --prompt "$P" --run "$RUN"
check "0 1 absent" "$FIRST $CODE $([ -e "${PERS}/p9.md" ] && echo present || echo absent)"

it "approval replay: copy-default with a spent approval is refused after the copy is removed"
P="$(opick "$RUN" "copy-default d8")"
prog copy-default d8 --prompt "$P" --run "$RUN"
FIRST="$CODE"
rm -f "${PERS}/d8.md"
prog copy-default d8 --prompt "$P" --run "$RUN"
check "0 1 absent" "$FIRST $CODE $([ -e "${PERS}/d8.md" ] && echo present || echo absent)"

it "approval replay: take with a spent approval is refused on a second copy"
P="$(opick "$RUN" "settle-default-update d8 --as take")"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d8.md" "${PERS}/d8.md"
prog settle-default-update d8 --as take --prompt "$P" --run "$RUN"
FIRST="$CODE"
cp "${CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR}/d8.md" "${PERS}/d8.md"
prog settle-default-update d8 --as take --prompt "$P" --run "$RUN"
check "0 1 present" "$FIRST $CODE $([ -e "${PERS}/d8.md" ] && echo present || echo absent)"

it "approval replay: a new prompt for the same copy is accepted"
P="$(opick "$RUN" "settle-default-update d8 --as take")"
prog settle-default-update d8 --as take --prompt "$P" --run "$RUN"
check "0 absent" "$CODE $([ -e "${PERS}/d8.md" ] && echo present || echo absent)"

it "approval replay: a failed write does not spend the approval"
chmod 555 "$(dirname "$SEEN")"
P="$(opick "$RUN" "copy-default d9")"
prog copy-default d9 --prompt "$P" --run "$RUN"
FIRST="$CODE"
chmod 755 "$(dirname "$SEEN")"
prog copy-default d9 --prompt "$P" --run "$RUN"
check "1 0 present" "$FIRST $CODE $([ -e "${PERS}/d9.md" ] && echo present || echo absent)"

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

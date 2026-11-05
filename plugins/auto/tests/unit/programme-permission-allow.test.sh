#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-permission-allow.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-permission-setup.sh"

settings "$USER_SETTINGS" "$PLAIN_USER"
panes "p100=sess-r1=working p110=sess-r10=working p120=sess-r20=idle"

# ---- allow: picking it makes Auto write the rule ----
CASE=0
sha_of() { "$PY" -c 'import hashlib,sys; print("sha256:" + hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# new_case [command]: a fresh repo in this test's temp folder, with one refusal and one open proposal.
new_case() {
  CASE=$((CASE + 1))
  C_REPO="${REPOS}/allow${CASE}"
  C_FILE="${C_REPO}/.claude/settings.local.json"
  C_ITEM="linear:AI-90${CASE}"
  C_SID="sess-a${CASE}"
  mkdir -p "${C_REPO}/.git"
  edit "rec['programme']['remit']['repos'] += [{'path': '${C_REPO}', 'github': None}]"
  register "$C_SID" "${WORK}/wt-a${CASE}"
  prog add-item "$C_ITEM" --title "allow case ${CASE}" --session "$C_SID" --pane "pa${CASE}" --repo "$C_REPO"
  deny "$C_SID" "tu-a${CASE}" "${1:-gh pr checks 12}"
  prog propose-permission --item "$C_ITEM"
  C_P="$(pid_for "$C_REPO")"
}
allow_list() { "$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permissions"]["allow"]))' "$1"; }
USER_BEFORE="$(shasum "$USER_SETTINGS")"

new_case
it "allow: the option shows the rule, the file, all the reach and all the exclusions, in full"
offered "$C_P" allow
OPTION="$("$PY" -c '
import json,sys
printed = json.loads(sys.stdin.read().strip().splitlines()[-1])
options = printed["input"]["questions"][0]["options"]
print(json.dumps({"first": options[0]["label"] == printed["decline"], "label": options[1]["label"], "text": options[1]["description"]}))' <<< "$OUT")"
has "Bash(gh pr checks *)" "$OPTION"
has "$C_FILE" "$OPTION"
for part in "$(pf "$C_P" '["reach"][0]' | tr -d '"')" "$(pf "$C_P" '["reach"][1]' | tr -d '"')" "$(pf "$C_P" '["exclusions"][0]' | tr -d '"')" "$(pf "$C_P" '["exclusions"][3]' | tr -d '"')"; do
  has "$part" "$OPTION"
done
it "allow: the decline comes first and the label says it widens"
has '"first": true' "$OPTION"
has "iden" "$OPTION"

it "allow, file absent: the file is created with the allow list, inside this test's temp folder"
ALLOW_PROMPT="$(shawn_picks)"
prog answer-permission "$C_P" allow --prompt "$ALLOW_PROMPT"
check "0 [\"Bash(gh pr checks *)\"]" "$CODE $(allow_list "$C_FILE")"
case "$C_FILE" in "${WORK}/"*) pass ;; *) fail "wrote outside the temp folder: $C_FILE" ;; esac
it "allow: with no live owner the proposal moves on to retry_unobserved"
check '"retry_unobserved" "allow"' "$(pf "$C_P" '["state"]') $(pf "$C_P" '["answers"][-1]["choice"]')"
it "allow: the journal row holds the rules written, the file and both hashes"
check "[[\"Bash(gh pr checks *)\"], \"${C_FILE}\", null, \"$(sha_of "$C_FILE")\"]" \
  "$(journal_kind permission_verified | "$PY" -c 'import json,sys; w=json.load(sys.stdin)[-1]["payload"]["written"]; print(json.dumps([w["rules_written"], w["file"], w["before_hash"], w["after_hash"]]))')"
it "allow: a new file is private to the user"
check 600 "$("$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$C_FILE")"

new_case
panes "pa${CASE}=${C_SID}=working"
it "allow with a live owner: the rule is written, one retry is reserved and the worker gets the retry text"
answer "$C_P" allow
check "0 \"retrying\" 1 \"${C_ITEM}\"" "$CODE $(pf "$C_P" '["state"]') $(pf "$C_P" '["attempts"]') $(out_key retry_item)"
has "gh pr checks 12" "$(out_key retry_text)"
it "allow: while retrying, a second allow changes nothing"
KEPT="$(shasum "$C_FILE")"
answer "$C_P" allow
check "0 \"retrying\" 1 true ${KEPT}" "$CODE $(pf "$C_P" '["state"]') $(pf "$C_P" '["attempts"]') $(out_key noop) $(shasum "$C_FILE")"
panes "p100=sess-r1=working"

new_case "gh pr view 3"
settings "$C_FILE" '{"zeta": 1, "permissions": {"deny": [], "allow": ["Bash(ls *)"], "ask": []}, "env": {"KEEP": "yes"}, "alpha": [1, 2]}'
chmod 640 "$C_FILE"
it "allow, file with other keys: they stay, in order, and only the new rule is appended"
answer "$C_P" allow
check '0 ["zeta", "permissions", "env", "alpha"] ["deny", "allow", "ask"] ["Bash(ls *)", "Bash(gh pr view *)"] yes' \
  "$CODE $("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(list(d)), json.dumps(list(d["permissions"])), json.dumps(d["permissions"]["allow"]), d["env"]["KEEP"])' "$C_FILE")"
it "allow: the file keeps its mode"
check 640 "$("$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$C_FILE")"
it "allow: the first hash is the file as it was"
has '"before_hash": "sha256:' "$(journal_kind permission_verified | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[-1]["payload"]["written"]))')"

new_case
OTHER_TARGET="${REPOS}/dotfiles-${CASE}/local.json"
settings "$OTHER_TARGET" '{"keep": true}'
mkdir -p "$(dirname "$C_FILE")"
ln -s "$OTHER_TARGET" "$C_FILE"
it "allow, symlinked file: the link stays a link and its target gets the rule"
answer "$C_P" allow
check "0 true [\"Bash(gh pr checks *)\"] true" \
  "$CODE $("$PY" -c 'import json,os,sys; print(json.dumps(os.path.islink(sys.argv[1])), json.dumps(json.load(open(sys.argv[2]))["permissions"]["allow"]), json.dumps(json.load(open(sys.argv[2]))["keep"]))' "$C_FILE" "$OTHER_TARGET")"

for BAD in '{not json' '[1, 2]' '{"permissions": ["Bash(ls *)"]}' '{"permissions": {"allow": "Bash(ls *)"}}'; do
  new_case
  settings "$C_FILE" "$BAD"
  KEPT="$(shasum "$C_FILE")"
  it "allow, file that cannot be merged ($BAD): refused with why, file unchanged, state unchanged"
  answer "$C_P" allow
  check "1 \"open\" ${KEPT}" "$CODE $(pf "$C_P" '["state"]') $(shasum "$C_FILE")"
  has "$C_FILE" "$OUT"
done

new_case
settings "$C_FILE" '{"permissions": {"allow": ["Bash(gh pr checks *)"]}}'
KEPT="$(stat -f '%m %i' "$C_FILE") $(shasum "$C_FILE")"
it "allow, already covered: no write, and the proposal moves on"
answer "$C_P" allow
check "0 \"retry_unobserved\" [] ${KEPT}" \
  "$CODE $(pf "$C_P" '["state"]') $(out_key written | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rules_written"]))') $(stat -f '%m %i' "$C_FILE") $(shasum "$C_FILE")"

new_case
settings "$USER_SETTINGS" '{"permissions": {"deny": ["Bash(gh pr checks *)"]}}'
it "allow, a deny rule blocks it: ineffective and no file written"
answer "$C_P" allow
check '0 "ineffective" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"
has "Bash(gh pr checks *)" "$(pf "$C_P" '["explanation"]')"
settings "$USER_SETTINGS" "$PLAIN_USER"
USER_BEFORE="$(shasum "$USER_SETTINGS")"

new_case
it "allow, own words: Other text is refused and the fix says relay and ask again"
offered "$C_P" allow
ALLOW_OFFER="$OUT"
prog answer-permission "$C_P" allow --prompt "$(OUT="$ALLOW_OFFER" shawn_picks 'text:yes allow it')" \
  --reads-as "$("$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["input"]["questions"][0]["options"][1]["label"])' <<< "$ALLOW_OFFER")"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"
has "relay" "$OUT"
it "allow, own words: a pick with a note is refused"
prog answer-permission "$C_P" allow --prompt "$(OUT="$ALLOW_OFFER" shawn_picks 'note:yes but check it')"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"
it "allow: a typed message that says allow and the id, with no offer in play, writes nothing"
new_case
PROG="${AUTO_ROOT}/lib/programme.py" prog answer-permission "$C_P" allow --prompt "$(prompt typed "allow $C_P")"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"
has "no open offer" "$OUT"
it "allow: a pick on a picker the PM wrote itself, with the old label, writes nothing"
HAND="$(run_py "$RUN" "$C_P" <<'EOF'
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
import permission_picks
label = "Approve answer-permission " + args[1] + " allow"
questions = [{"question": "Allow it?", "header": "Allow", "multiSelect": False,
              "options": [{"label": label, "description": "x"}, {"label": "Later", "description": "y"}]}]
print(permission_picks.pick(args[0], "sess-pm", os.environ["TEST_TRANSCRIPTS"] + "/sess-pm.jsonl", questions, label))
EOF
)"
prog answer-permission "$C_P" allow --prompt "$HAND"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"

new_case
it "allow, the proposal changed after the offer: refused, and nothing is written"
offered "$C_P" allow
ALLOW_OFFER="$OUT"
deny "$C_SID" "tu-a${CASE}b" "gh run view 7"
prog propose-permission --item "$C_ITEM"
prog answer-permission "$C_P" allow --prompt "$(OUT="$ALLOW_OFFER" shawn_picks)"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"
has "changed" "$OUT"
it "allow: the fresh offer shows both rules, and approving it writes both together"
answer "$C_P" allow
check '0 ["Bash(gh pr checks *)", "Bash(gh run view *)"]' "$CODE $(allow_list "$C_FILE")"

new_case
edit "next(p for p in rec['programme']['permission_proposals'] if p['id'] == '${C_P}')['rules'] = ['Bash(*)']"
it "allow: rules come from the catalog, not from the stored text"
answer "$C_P" allow
check '0 ["Bash(gh pr checks *)"]' "$CODE $(allow_list "$C_FILE")"

new_case
edit "next(p for p in rec['programme']['permission_proposals'] if p['id'] == '${C_P}')['operations'] = ['pr_merge']"
it "allow: an operation outside the catalog cannot be offered"
offered "$C_P" allow
check "1 absent" "$CODE $([ -e "$C_FILE" ] && echo present || echo absent)"

new_case
ELSEWHERE="${WORK}/elsewhere/.claude/settings.local.json"
edit "next(p for p in rec['programme']['permission_proposals'] if p['id'] == '${C_P}')['settings_file'] = '${ELSEWHERE}'"
it "allow: a stored file that is not the recomputed destination cannot be offered"
offered "$C_P" allow
check "1 absent" "$CODE $([ -e "$ELSEWHERE" ] && echo present || echo absent)"

new_case
it "allow: a repository removed from the remit after the offer is refused"
offered "$C_P" allow
ALLOW_OFFER="$OUT"
edit "rec['programme']['remit']['repos'] = [r for r in rec['programme']['remit']['repos'] if r['path'] != '${C_REPO}']"
prog answer-permission "$C_P" allow --prompt "$(OUT="$ALLOW_OFFER" shawn_picks)"
check '1 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"

new_case
rm -rf "${C_REPO}/.git"
git -C "$C_REPO" init -q
settings "$C_FILE" '{"permissions": {"allow": []}}'
git -C "$C_REPO" add -f .claude/settings.local.json
KEPT="$(shasum "$C_FILE")"
it "allow, a tracked settings.local.json: refused with the file named, and no write"
answer "$C_P" allow
check "1 \"open\" ${KEPT}" "$CODE $(pf "$C_P" '["state"]') $(shasum "$C_FILE")"
has "$C_FILE" "$OUT"
has "tracked" "$OUT"

new_case
rm -rf "${C_REPO}/.git"
git -C "$C_REPO" init -q
it "allow in a real repository, file untracked: the rule is written"
answer "$C_P" allow
check '0 ["Bash(gh pr checks *)"]' "$CODE $(allow_list "$C_FILE")"

new_case
it "allow, the same answer again: replaying the same --op gives the same result and one rule"
offered "$C_P" allow
ALLOW_PROMPT="$(shawn_picks)"
prog answer-permission "$C_P" allow --prompt "$ALLOW_PROMPT" --op "op-allow-${CASE}"
FIRST_CODE="$CODE"
KEPT="$(shasum "$C_FILE")"
prog answer-permission "$C_P" allow --prompt "$ALLOW_PROMPT" --op "op-allow-${CASE}"
check "0 0 true ${KEPT} 1" "$FIRST_CODE $CODE $(out_key replayed) $(shasum "$C_FILE") $(pf "$C_P" '["answers"]' | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
it "allow, the same pick cited again: refused and nothing changes"
prog answer-permission "$C_P" allow --prompt "$ALLOW_PROMPT"
check "1 ${KEPT} [\"Bash(gh pr checks *)\"]" "$CODE $(shasum "$C_FILE") $(allow_list "$C_FILE")"
it "allow, after a fresh ask on a proposal whose rule is already written: no second copy"
answer "$C_P" allow
check "0 ${KEPT} [\"Bash(gh pr checks *)\"]" "$CODE $(shasum "$C_FILE") $(allow_list "$C_FILE")"

new_case
it "applied never writes: a rule that is not there stays not there"
answer "$C_P" applied
check '0 "open" absent' "$CODE $(pf "$C_P" '["state"]') $([ -e "$C_FILE" ] && echo present || echo absent)"

new_case
it "the notification asks for no typed word"
NOTICE="$(grep "notification" "$CALLS" | tail -1)"
lacks "Answer: applied" "$NOTICE"

it "the settings guard refuses the PM a direct edit and says only this verb writes, after Shawn's pick"
GUARD="$(run_py "$C_FILE" "$C_REPO" <<'EOF'
guard = load_lib_module("programme_settings_guard")
call = {"tool_name": "Write", "session_id": "sess-pm", "cwd": args[1], "tool_input": {"file_path": args[0]}}
found = guard.decision(json.dumps(call))
print(found[0]["hookSpecificOutput"]["permissionDecisionReason"])
EOF
)"
has "answer-permission" "$GUARD"
has "pick" "$GUARD"
lacks "Only Shawn applies" "$GUARD"

it "the allow tests never changed the user settings file"
check "$USER_BEFORE" "$(shasum "$USER_SETTINGS")"

it "no verb call crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-permission-allow.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

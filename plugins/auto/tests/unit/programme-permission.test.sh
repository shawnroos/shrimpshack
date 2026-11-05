#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-permission.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-permission-setup.sh"

it "describe lists the three permission verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
check "answer-permission propose-permission settle-permissions" \
  "$("$PY" -c 'import json,sys; v=json.load(sys.stdin)["verbs"]; print(" ".join(sorted(n for n in v if "permission" in n or n == "report-block")))' <<< "$DESC" 2>&1)"

it "the transition table matches the documented moves, and refuses every answer on resolved"
check "verify verify verify verify verify retrying postponed rejected postponed postponed rejected defer resolved ineffective resolved None None None None" "$(run_py <<'EOF'
st = load_lib_module("programme_permission_state")
pairs = [(s, "applied") for s in ("open", "postponed", "rejected", "ineffective", "retry_unobserved", "retrying")]
pairs += [("open", "not-now"), ("ineffective", "no"), ("retry_unobserved", "not-now"), ("postponed", "no"), ("rejected", "not-now"),
          ("retrying", "no"), ("retrying", "resolved"), ("retrying", "ineffective"), ("open", "resolved"),
          ("resolved", "applied"), ("resolved", "no"), ("open", "ineffective"), ("postponed", "resolved")]
print(*[st.TRANSITIONS.get(p) for p in pairs])
EOF
)"

for n in 1 2 3 4; do
  prog add-item "linear:AI-${n}" --title "item ${n}" --session "sess-w${n}" --repo "$MAIN"
done

it "add-item --repo stores a path that matches a remit repository"
check "\"${MAIN}\"" "$(field 'items["linear:AI-1"]["repo"]')"

it "add-item --repo with a path outside the remit stores no repo and still succeeds"
prog add-item linear:AI-30 --title "outside" --session sess-w30 --repo "$OUTSIDE"
check "0 null" "$CODE $(field 'items["linear:AI-30"]["repo"]')"

it "add-item --repo with a symlinked spelling of a remit path stores the remit's form"
ln -s "$MAIN" "${WORK}/main-link"
prog add-item linear:AI-31 --title "linked" --session sess-w31 --repo "${WORK}/main-link"
check "\"${MAIN}\"" "$(field 'items["linear:AI-31"]["repo"]')"

# ---- AE2: three workers, one proposal, one notification ----
deny sess-w1 tu-1 "gh pr checks 12"
deny sess-w2 tu-2 "gh pr checks 12 --required"
deny sess-w3 tu-3 "gh pr checks 13"

it "propose-permission from a non-driving session is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog propose-permission --run "$RUN" --item linear:AI-1
check 1 "$CODE"
check '[]' "$(field 'list(props)')"

prog propose-permission --item linear:AI-1
it "the first denial opens perm-1"
check "0 [\"perm-1\"]" "$CODE $(field 'sorted(props)')"
prog propose-permission --item linear:AI-2
prog propose-permission --item linear:AI-3

it "AE2: three workers' denials give one proposal with three items"
check '[["perm-1"], ["linear:AI-1", "linear:AI-2", "linear:AI-3"], ["pr_checks"], "open"]' \
  "$(field '[sorted(props), props["perm-1"]["items"], props["perm-1"]["operations"], props["perm-1"]["state"]]')"
it "AE2: Shawn was notified once"
check 1 "$(notices)"
it "notified_at is stamped after the notifier exits 0"
check true "$(field 'bool(props["perm-1"]["notified_at"])')"
it "the proposal names the catalog rule and the main checkout's settings.local.json"
check "[[\"Bash(gh pr checks *)\"], \"${MAIN}\", \"${MAIN}/.claude/settings.local.json\"]" \
  "$(field '[props["perm-1"]["rules"], props["perm-1"]["destination"], props["perm-1"]["settings_file"]]')"
it "the proposal lists exclusions, reach and evidence"
check '[true, true, 3]' "$(field '[any("merge" in e for e in props["perm-1"]["exclusions"]), any("--repo" in r for r in props["perm-1"]["reach"]), len(props["perm-1"]["evidence"])]')"
it "affected items wait on shawn, reported by shawn"
check '["waiting", "shawn", "shawn"]' "$(field '[items["linear:AI-2"]["state"], items["linear:AI-2"]["waiting_on"]["who"], items["linear:AI-2"]["waiting_on"]["reporter"]]')"
it "set-waiting refuses an item waiting on a proposal and keeps the link"
prog set-waiting linear:AI-2 --who ci --reporter ci
check '1 "perm-1"' "$CODE $(field 'items["linear:AI-2"]["waiting_on"].get("permission")')"
has "perm-1" "$OUT"
it "the notification names the rule, not the raw command"
has "Bash(gh pr checks *)" "$(cat "$CALLS")"
lacks "--required" "$(cat "$CALLS")"

it "AE2: after a handover, a fourth denial attaches to perm-1 with no notification"
edit 'rec["driving_session_id"] = "sess-pm2"'
deny sess-w4 tu-4 "gh pr checks 12"
CLAUDE_CODE_SESSION_ID="sess-pm2" prog propose-permission --run "$RUN" --item linear:AI-4
check '0 ["perm-1"] 4 1' "$CODE $(field 'sorted(props)') $(field 'len(props["perm-1"]["items"])') $(notices)"
it "the rules-in-force text lists the proposal with its items"
CLAUDE_CODE_SESSION_ID="sess-pm2" prog rules --run "$RUN"
has "permission perm-1: open" "$OUT"
has "linear:AI-4" "$OUT"
edit 'rec["driving_session_id"] = "sess-pm"'

it "the view lists perm-1 as a decision for Shawn, with the layer that refused it"
prog status --run "$RUN"
has "perm-1" "$OUT"
has "last refused by" "$OUT"

# ---- what counts as a refusal ----
it "a refusal in a session not on the item is never read"
deny sess-stranger tu-x "gh pr checks 12"
EV_BEFORE="$(field 'len(props["perm-1"]["evidence"])')"
prog propose-permission --item linear:AI-1
check "0 ${EV_BEFORE}" "$CODE $(field 'len(props["perm-1"]["evidence"])')"

it "an accepted result is not a refusal"
deny sess-w1 tu-accepted "gh pr checks 12" classifier accept
prog propose-permission --item linear:AI-1
check "${EV_BEFORE}" "$(field 'len(props["perm-1"]["evidence"])')"

it "a result row with no runtime decision is not a refusal"
deny sess-w1 tu-nodecision "gh pr checks 12" mode none
prog propose-permission --item linear:AI-1
check "${EV_BEFORE}" "$(field 'len(props["perm-1"]["evidence"])')"

it "a call still waiting for its result is read once the result is written"
deny sess-w1 tu-pending "gh pr checks 15" classifier pending
prog propose-permission --item linear:AI-1
check "${EV_BEFORE}" "$(field 'len(props["perm-1"]["evidence"])')"
run_py sess-w1 <<'EOF'
path = session(args[0])
with open(path, "a") as fh:
    fh.write(json.dumps({"type": "user", "sessionId": args[0], "timestamp": stamp(),
                         "permissionDecision": {"decision": "reject", "source": "config", "reasonType": "classifier"},
                         "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu-pending",
                                                                  "is_error": True, "content": "denied"}]}}) + "\n")
EOF
prog propose-permission --item linear:AI-1
check "$((EV_BEFORE + 1)) true" "$(field 'len(props["perm-1"]["evidence"])') $(field 'props["perm-1"]["evidence"][-1]["tool_use_id"] == "tu-pending"')"

it "a second scan reads nothing twice"
EV_BEFORE="$(field 'len(props["perm-1"]["evidence"])')"
prog propose-permission --item linear:AI-1
check "${EV_BEFORE}" "$(field 'len(props["perm-1"]["evidence"])')"

it "a refusal ruled before the session joined the item is not replayed"
deny sess-w32 tu-early "gh pr checks 21" classifier reject 600
prog add-item linear:AI-32 --title "late joiner" --session sess-w32 --repo "$MAIN"
prog propose-permission --item linear:AI-32
check '0 false' "$CODE $(field '"linear:AI-32" in props["perm-1"]["items"]')"

it "a built-in segment's arguments never reach evidence"
deny sess-w1 tu-secret "gh pr checks 12 && grep ghp_abcdefghijklmnopqrstuvwxyz0123456789 .env"
prog propose-permission --item linear:AI-1
check '"gh pr checks 12 && grep"' "$(field '[e["command"] for e in props["perm-1"]["evidence"] if e["tool_use_id"] == "tu-secret"][0]')"

it "a transcript over the read cap leaves the cursor in place and says it was not read"
check "None True 7" "$(run_py <<'EOF'
perm = load_lib_module("programme_permission")
path = session("sess-cap")
tx("sess-cap", "tu-cap", "gh pr checks 9", "reject", "mode")
item = {"sessions": [{"session_id": "sess-cap", "at": "2000-01-01T00:00:00Z"}], "permission_scan": {"sess-cap": 7}}
perm.transcript.TRANSCRIPT_CAP = 10
uses, why = perm._refusals(item, "sess-cap")
print(uses, "unreadable" in why, item["permission_scan"]["sess-cap"])
EOF
)"

it "a half-written last line is read again next time, not skipped"
check "1 True True" "$(run_py <<'EOF'
perm = load_lib_module("programme_permission")
path = tx("sess-half", "tu-h1", "gh pr checks 9", "reject", "mode")
partial = os.path.getsize(path)
row = '{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "tu-h2", "name": "Bash", "input": {"command": "gh pr checks 10"}}]}}'
with open(path, "a") as fh:
    fh.write(row[:40])
item = {"sessions": [{"session_id": "sess-half", "at": "2000-01-01T00:00:00Z"}]}
first, _ = perm._refusals(item, "sess-half")
stopped = item["permission_scan"]["sess-half"] == partial
with open(path, "a") as fh:
    fh.write(row[40:] + "\n" + json.dumps({"type": "user", "timestamp": stamp(), "permissionDecision": {"decision": "reject", "reasonType": "mode"},
                                 "message": {"content": [{"type": "tool_result", "tool_use_id": "tu-h2"}]}}) + "\n")
second, _ = perm._refusals(item, "sess-half")
print(len(first), stopped, [u["tool_use_id"] for u in second] == ["tu-h2"])
EOF
)"

it "evidence keeps the layer and reasonType, never the refusal text"
check '["classifier", "classifier", false]' \
  "$(field '[props["perm-1"]["evidence"][0]["layer"], props["perm-1"]["evidence"][0]["reason_type"], "reason" in props["perm-1"]["evidence"][0]]')"

# ---- folding ----
edit 'p = [x for x in rec["programme"]["permission_proposals"] if x["id"] == "perm-1"][0]; p["changed_at"] = "2000-01-01T00:00:00Z"'
it "folding: a pr_view denial folds into open perm-1 and re-notifies once"
deny sess-w1 tu-5 "gh pr view 12 --json state"
prog propose-permission --item linear:AI-1
check '["perm-1"] ["pr_checks", "pr_view"] 2' "$(field 'sorted(props)') $(field 'props["perm-1"]["operations"]') $(notices)"
it "a fold that grows the operations moves the last state change forward"
check false "$(field 'props["perm-1"]["changed_at"] == "2000-01-01T00:00:00Z"')"
it "the folded proposal renders both rules"
check '["Bash(gh pr checks *)", "Bash(gh pr view *)"]' "$(field 'props["perm-1"]["rules"]')"
it "a second pr_view denial folds with no notification"
deny sess-w2 tu-6 "gh pr view 13"
edit 'p = [x for x in rec["programme"]["permission_proposals"] if x["id"] == "perm-1"][0]; p["changed_at"] = "2000-01-01T00:00:00Z"'
prog propose-permission --item linear:AI-2
check '2 "2000-01-01T00:00:00Z"' "$(notices) $(field 'props["perm-1"]["changed_at"]')"
edit 'p = [x for x in rec["programme"]["permission_proposals"] if x["id"] == "perm-1"][0]; p["changed_at"] = core.now_iso()'

# ---- two destinations ----
prog add-item linear:AI-20 --title "main2 a" --session sess-w20 --repo "$MAIN2"
prog add-item linear:AI-21 --title "main2 b" --session sess-w21 --repo "$MAIN2"
it "two proposals for two destinations never fold together"
deny sess-w20 tu-20 "gh pr checks 3"
prog propose-permission --item linear:AI-20
check "[\"perm-1\", \"perm-2\"] \"${MAIN2}\" [\"linear:AI-20\"] 3" \
  "$(field 'sorted(props)') $(field 'props["perm-2"]["destination"]') $(field 'props["perm-2"]["items"]') $(notices)"

# ---- answer-permission gates (AE6) ----
it "AE6: answer-permission citing a non-typed prompt is refused and changes nothing"
P_UNKNOWN="$(prompt unknown 'applied perm-1')"
prog answer-permission perm-1 applied --prompt "$P_UNKNOWN"
check '1 "open"' "$CODE $(field 'props["perm-1"]["state"]')"
has "is not Shawn's words or a verified pick" "$OUT"

it "AE6: a typed answer that names the proposal and the choice, with no offer asked, is refused and the fix names offer"
PROG="${AUTO_ROOT}/lib/programme.py" prog answer-permission perm-1 not-now --prompt "$(prompt typed 'not now perm-1')"
check '1 "open"' "$CODE $(field 'props["perm-1"]["state"]')"
has "no open offer" "$OUT"
has "programme.sh offer" "$OUT"

it "a pick of the old approval label, on a picker Auto did not print, is refused"
HAND="$(run_py "$RUN" <<'EOF'
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
import permission_picks
label = "Approve answer-permission perm-1 no"
questions = [{"question": "Reject it?", "header": "Reject", "multiSelect": False,
              "options": [{"label": label, "description": "x"}, {"label": "Later", "description": "y"}]}]
print(permission_picks.pick(args[0], "sess-pm", os.environ["TEST_TRANSCRIPTS"] + "/sess-pm.jsonl", questions, label))
EOF
)"
prog answer-permission perm-1 no --prompt "$HAND"
check '1 "open"' "$CODE $(field 'props["perm-1"]["state"]')"

it "a pick of this offer's decline runs nothing"
offered perm-1 no
DECLINE_PROMPT="$(shawn_picks decline)"
prog answer-permission perm-1 no --prompt "$DECLINE_PROMPT"
check '1 "open"' "$CODE $(field 'props["perm-1"]["state"]')"

it "a pick made for another answer of the same proposal is refused"
offered perm-1 no
OTHER_ANSWER="$(shawn_picks)"
prog answer-permission perm-1 not-now --prompt "$OTHER_ANSWER"
check '1 "open"' "$CODE $(field 'props["perm-1"]["state"]')"

it "an unknown proposal id cannot be offered"
offered perm-9 no
check 1 "$CODE"

it "no refused answer journaled permission_answered"
check 0 "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "permission_answered"))
EOF
)"

# ---- AE3: not now stays not now ----
it "AE3: picking not now postpones perm-1"
answer perm-1 not-now
P_LATER="$ANSWER_PROMPT"
check '0 "postponed"' "$CODE $(field 'props["perm-1"]["state"]')"
it "the answer is recorded with its prompt id and journaled"
check "[\"${P_LATER}\", \"not-now\"]" "$(field '[props["perm-1"]["answers"][-1]["prompt_id"], props["perm-1"]["answers"][-1]["choice"]]')"

it "AE3: a new denial with the same key attaches evidence, sends nothing, stays postponed"
N_BEFORE="$(notices)"
EV_BEFORE="$(field 'len(props["perm-1"]["evidence"])')"
deny sess-w4 tu-8 "gh pr checks 12"
prog propose-permission --item linear:AI-4
check "\"postponed\" $((EV_BEFORE + 1)) ${N_BEFORE} [\"perm-1\", \"perm-2\"]" \
  "$(field 'props["perm-1"]["state"]') $(field 'len(props["perm-1"]["evidence"])') $(notices) $(field 'sorted(props)')"

it "picking reject on a postponed proposal records the answer and keeps it postponed"
answer perm-1 no
P_REJ="$ANSWER_PROMPT"
check '0 "postponed" 2' "$CODE $(field 'props["perm-1"]["state"]') $(field 'len(props["perm-1"]["answers"])')"

it "re-citing a prompt an earlier answer used is refused"
prog answer-permission perm-1 no --prompt "$P_REJ"
check '1 2' "$CODE $(field 'len(props["perm-1"]["answers"])')"
has "already" "$OUT"

it "a postponed proposal is not a decision for Shawn"
prog status --run "$RUN"
lacks "perm-1:" "$(printf '%s\n' "$OUT" | sed -n '/Decisions for Shawn/,/Just did/p')"

# ---- AE4: broader access is a new decision ----
it "picking reject rejects perm-2"
answer perm-2 no
check '0 "rejected"' "$CODE $(field 'props["perm-2"]["state"]')"

it "AE3: after no, a same-key denial attaches with no notification and stays rejected"
N_BEFORE="$(notices)"
deny sess-w21 tu-21 "gh pr checks 4"
prog add-item linear:AI-21 --session sess-w21
prog propose-permission --item linear:AI-21
check "\"rejected\" ${N_BEFORE} [\"linear:AI-20\", \"linear:AI-21\"]" \
  "$(field 'props["perm-2"]["state"]') $(notices) $(field 'props["perm-2"]["items"]')"

it "AE4: after pr_checks is rejected, a pr_view denial opens perm-3 for pr_view only and notifies once"
N_BEFORE="$(notices)"
deny sess-w20 tu-22 "gh pr view 3"
prog propose-permission --item linear:AI-20
check "[\"pr_view\"] \"open\" $((N_BEFORE + 1))" "$(field 'props["perm-3"]["operations"]') $(field 'props["perm-3"]["state"]') $(notices)"

it "a compound denial needing a rejected op and an open op re-asks neither"
N_BEFORE="$(notices)"
deny sess-w20 tu-23 "gh pr checks 3 && gh pr view 3"
prog propose-permission --item linear:AI-20
check "[\"perm-1\", \"perm-2\", \"perm-3\"] [\"pr_view\"] \"rejected\" ${N_BEFORE}" \
  "$(field 'sorted(props)') $(field 'props["perm-3"]["operations"]') $(field 'props["perm-2"]["state"]') $(notices)"

it "picking not now postpones perm-3"
answer perm-3 not-now
check '0 "postponed"' "$CODE $(field 'props["perm-3"]["state"]')"

# ---- explanations instead of proposals ----
it "an ineligible denied command records an explanation naming jq and no proposal"
prog add-item linear:AI-50 --title "jq" --session sess-w50 --repo "$MAIN4"
deny sess-w50 tu-50 "gh pr view 1 | jq"
prog propose-permission --item linear:AI-50
check '3 "ineligible"' "$(field 'len(props)') $(field 'items["linear:AI-50"]["permission_block"]["cause"]')"
has "jq" "$(field 'items["linear:AI-50"]["permission_block"]["detail"]')"

it "an item with no recorded repo gets an explanation and no proposal"
deny sess-w30 tu-30 "gh pr checks 1"
prog propose-permission --item linear:AI-30
check '0 3 "no_repo"' "$CODE $(field 'len(props)') $(field 'items["linear:AI-30"]["permission_block"]["cause"]')"

it "after the repo is recorded, the same refusal is read again and reaches a proposal"
prog add-item linear:AI-30 --repo "$MAIN2"
prog propose-permission --item linear:AI-30
check '0 true "decided"' "$CODE $(field '"linear:AI-30" in props["perm-2"]["items"]') $(field 'items["linear:AI-30"]["permission_block"]["cause"]')"

it "a remit repo whose .git file points at a common dir outside the remit is refused as a destination"
prog add-item linear:AI-40 --title "rewritten" --session sess-w40 --repo "$MAIN3"
rm -rf "${MAIN3}/.git"
printf 'gitdir: %s\n' "${OUTSIDE}/.git/worktrees/x" > "${MAIN3}/.git"
deny sess-w40 tu-40 "gh pr checks 1"
prog propose-permission --item linear:AI-40
check '3 "bad_destination"' "$(field 'len(props)') $(field 'items["linear:AI-40"]["permission_block"]["cause"]')"

# ---- layers no allow rule lifts, and unknown causes (AE6) ----
prog add-item linear:AI-60 --title "deny rule" --session sess-w60 --repo "$MAIN4"
it "a deny-rule refusal gets an explanation naming the deny rule and no proposal"
deny sess-w60 tu-60 "gh pr checks 77" deny_rule
prog propose-permission --item linear:AI-60
check '0 3 "not_proposable"' "$CODE $(field 'len(props)') $(field 'items["linear:AI-60"]["permission_block"]["cause"]')"
has "deny rule" "$(field 'items["linear:AI-60"]["permission_block"]["detail"]')"

prog add-item linear:AI-61 --title "hook" --session sess-w61 --repo "$MAIN4"
it "a hook refusal gets an explanation and no proposal"
deny sess-w61 tu-61 "gh pr checks 77" hook
prog propose-permission --item linear:AI-61
check '3 "not_proposable"' "$(field 'len(props)') $(field 'items["linear:AI-61"]["permission_block"]["cause"]')"
has "hook" "$(field 'items["linear:AI-61"]["permission_block"]["detail"]')"

prog add-item linear:AI-62 --title "odd layer" --session sess-w62 --repo "$MAIN4"
it "AE6: a refusal whose reasonType names no known layer gets an unknown-cause explanation, no guessed rule"
deny sess-w62 tu-62 "gh pr checks 77" odd
prog propose-permission --item linear:AI-62
check '3 "unknown_cause"' "$(field 'len(props)') $(field 'items["linear:AI-62"]["permission_block"]["cause"]')"
has "somethingNew" "$(field 'items["linear:AI-62"]["permission_block"]["detail"]')"

prog add-item linear:AI-63 --title "no transcript" --session sess-w63 --repo "$MAIN4"
it "AE6: a named item whose session has no registry transcript gets an unknown-cause explanation"
prog propose-permission --item linear:AI-63
check '0 3 "unknown_cause"' "$CODE $(field 'len(props)') $(field 'items["linear:AI-63"]["permission_block"]["cause"]')"
has "sess-w63" "$(field 'items["linear:AI-63"]["permission_block"]["detail"]')"

it "AE6: a registry path not named <session>.jsonl is never read"
run_py sess-w64 "${WORK}/forged.jsonl" <<'EOF'
reg._append(reg.registry_path("default", "w2"),
            {"at": core.now_iso(), "session_id": args[0], "transcript_path": args[1], "interactive": False,
             "server": "default", "workspace": "w2", "pane_id": "w2:" + args[0]})
EOF
prog add-item linear:AI-64 --title "forged path" --session sess-w64 --repo "$MAIN4"
prog propose-permission --item linear:AI-64
check '3 "unknown_cause"' "$(field 'len(props)') $(field 'items["linear:AI-64"]["permission_block"]["cause"]')"

it "AE6: a named item with a readable transcript and no refusal gets an unknown-cause explanation"
prog add-item linear:AI-65 --title "nothing refused" --session sess-w65 --repo "$MAIN4"
deny sess-w65 tu-65 "gh pr checks 77" red accept
prog propose-permission --item linear:AI-65
has "no refusal" "$(field 'items["linear:AI-65"]["permission_block"]["detail"]')"

it "a mode refusal of an eligible read counts as a refusal an allow rule lifts"
prog add-item linear:AI-66 --title "mode" --session sess-w66 --repo "$MAIN"
deny sess-w66 tu-66 "gh pr checks 78" mode
prog propose-permission --item linear:AI-66
check '3 "mode" true' "$(field 'len(props)') $(field 'props["perm-1"]["evidence"][-1]["layer"]') $(field '"linear:AI-66" in props["perm-1"]["items"]')"

# ---- notifier failure ----
prog add-item linear:AI-70 --title "notify" --session sess-w70 --repo "$MAIN4"
it "a non-zero notifier leaves notified_at empty"
deny sess-w70 tu-70 "gh run list --limit 5"
FAKE_HERDR_EXIT=1 prog propose-permission --item linear:AI-70
check '0 null' "$CODE $(field 'props["perm-4"]["notified_at"]')"
it "a later sweep-driven call re-sends and stamps notified_at"
N_BEFORE="$(notices)"
prog propose-permission
check "true $((N_BEFORE + 1))" "$(field 'bool(props["perm-4"]["notified_at"])') $(notices)"
it "a further call does not re-send a stamped proposal"
prog propose-permission
check "$((N_BEFORE + 1))" "$(notices)"

# ---- view escaping ----
it "a hostile reasonType never reaches the status text raw"
prog add-item linear:AI-79 --title "hostile" --session sess-w79 --repo "$MAIN4"
deny sess-w79 tu-79 "gh run view 9" hostile
prog propose-permission --item linear:AI-79
prog status --run "$RUN"
lacks 'boom</auto-external>' "$OUT"
prog add-item linear:AI-80 --title "repeat" --session sess-w80 --repo "$MAIN4"
deny sess-w80 tu-80 "gh run view 9"
prog propose-permission --item linear:AI-80

it "a repeat denial for an item already waiting on the proposal adds no history row"
H_BEFORE="$(field 'len(items["linear:AI-80"]["history"])')"
deny sess-w80 tu-81 "gh run view 10"
prog propose-permission --item linear:AI-80
check "0 ${H_BEFORE}" "$CODE $(field 'len(items["linear:AI-80"]["history"])')"

# ---- merge rewrites proposal items ----
it "merging two items rewrites the proposal's item list"
prog merge-item linear:AI-3 linear:AI-2
check '["linear:AI-1", "linear:AI-2", "linear:AI-4", "linear:AI-66"]' "$(field 'props["perm-1"]["items"]')"

# ---- U4: verify, single retry, settlement ----
settings "$USER_SETTINGS" "$PLAIN_USER"
for r in r5 r6 r7 r8 r9; do mkdir -p "${REPOS}/${r}/.git"; done
R5="${REPOS}/r5"; R6="${REPOS}/r6"; R7="${REPOS}/r7"; R8="${REPOS}/r8"; R9="${REPOS}/r9"
edit "rec['programme']['remit']['repos'] += [{'path': p, 'github': None} for p in ['${R5}', '${R6}', '${R7}', '${R8}', '${R9}']]"
SETTLE_ROW='"ok": true'

WT1="${WORK}/wt-r1"
register sess-r1 "$WT1"
register sess-r2 "${WORK}/wt-r2"
prog add-item linear:AI-100 --title "retry one" --session sess-r1 --pane p100 --repo "$R5"
prog add-item linear:AI-101 --title "retry two" --session sess-r2 --pane p101 --repo "$R5"
panes "p100=sess-r1=working p101=sess-r2=working"
deny sess-r1 tu-100 "gh  pr checks   12 --required"
prog propose-permission --item linear:AI-100
deny sess-r2 tu-101 "gh pr checks 12"
prog propose-permission --item linear:AI-101
P1="$(pid_for "$R5")"

it "picking applied before the rule exists keeps the proposal open and reserves nothing"
answer "$P1" applied
check '0 "open" null' "$CODE $(pf "$P1" '["state"]') $(pf "$P1" '.get("reservation")')"
it "the not-covered explanation names the three settings files read"
EXPL="$(pf "$P1" '["explanation"]')"
has "$USER_SETTINGS" "$EXPL"
has "${R5}/.claude/settings.local.json" "$EXPL"
has "${WT1}/.claude/settings.json" "$EXPL"
it "every verify result names managed settings and --settings as not visible"
has "managed settings" "$OUT"
has "--settings" "$OUT"
it "user settings keys other than permissions and autoMode never reach the result or the journal"
lacks "envsecret" "$OUT"
lacks "helper-cmd" "$OUT"
lacks "envsecret" "$(journal_kind permission_verified)"
lacks "helper-cmd" "$(journal_kind permission_verified)"

settings "${R5}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh pr checks *)"]}}'
LOCAL_HASH="$(shasum "${R5}/.claude/settings.local.json")"
ruled sess-r1 tu-pre "gh pr checks 12" accept red

it "picking applied with the allow present gives retrying and one reservation"
answer "$P1" applied
check '0 "retrying" ["linear:AI-100", "sess-r1", "pr_checks", "12", "gh pr checks 12 --required"] 1' \
  "$CODE $(pf "$P1" '["state"]') $(field '[props["'"$P1"'"]["reservation"][k] for k in ("item", "session_id", "operation", "target", "normalized")]') $(pf "$P1" '["attempts"]')"
it "the result returns the retry item and the catalog rendering as retry text, not the raw denial"
check '"linear:AI-100"' "$(out_key retry_item)"
RETRY_TEXT="$(out_key retry_text | tr -d '"')"
check "Permission ${P1} is applied. Run this once, exactly as written: gh pr checks 12 --required" "$RETRY_TEXT"
it "Programme wrote no settings file"
check "$LOCAL_HASH" "$(shasum "${R5}/.claude/settings.local.json")"

it "a duplicate applied while retrying is a no-op"
RES_AT="$(pf "$P1" '["reservation"]["at"]')"
answer "$P1" applied
check "0 \"retrying\" ${RES_AT} 1 true" "$CODE $(pf "$P1" '["state"]') $(pf "$P1" '["reservation"]["at"]') $(pf "$P1" '["attempts"]') $(out_key noop)"

it "settle-permissions from a non-driving session is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog settle-permissions --run "$RUN"
check 1 "$CODE"

it "a tool run written before the reservation does not settle it, and an unsent retry stays pending"
prog settle-permissions
check '0 "retrying"' "$CODE $(pf "$P1" '["state"]')"
has "prompt-item" "$OUT"

it "a confirmed execution from a non-reserved session does not settle the reservation"
ruled sess-r2 tu-other-session "gh pr checks 12" accept red
prog settle-permissions
check '"retrying"' "$(pf "$P1" '["state"]')"
it "a confirmed execution of a different catalog command does not settle the reservation"
ruled sess-r1 tu-other-op "gh pr view 12" accept classifier
prog settle-permissions
check '"retrying"' "$(pf "$P1" '["state"]')"
it "gh pr checks 13 against a reservation for PR 12 does not settle it"
ruled sess-r1 tu-other-target "gh pr checks 13" accept red
prog settle-permissions
check '"retrying"' "$(pf "$P1" '["state"]')"

it "with the retry sent and the owner working, settle waits"
prog prompt-item linear:AI-100 "$RETRY_TEXT"
check 0 "$CODE"
prog settle-permissions
check '"retrying"' "$(pf "$P1" '["state"]')"

it "a red-CI PostToolUseFailure rerun with a pipe and other --json fields resolves it"
ruled sess-r1 tu-retry "gh pr checks 12 --json name,state | head -5" accept red
prog settle-permissions
check '0 "resolved" true' "$CODE $(pf "$P1" '["state"]') $(pf "$P1" '["confirmed"]')"
it "linked items return to open after resolved"
check '["open", "open"]' "$(field '[items["linear:AI-100"]["state"], items["linear:AI-101"]["state"]]')"
it "the settlement is journaled"
has "\"proposal\": \"${P1}\"" "$(journal_kind permission_settled)"

it "a later denial after resolved attaches as evidence, keeps resolved, notifies nothing"
N_BEFORE="$(notices)"
EV_BEFORE="$(pf "$P1" '["evidence"]' | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
deny sess-r1 tu-late "gh pr checks 12"
prog propose-permission --item linear:AI-100
check "\"resolved\" $((EV_BEFORE + 1)) ${N_BEFORE}" "$(pf "$P1" '["state"]') $(pf "$P1" '["evidence"]' | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))') $(notices)"
it "the re-denied resolved proposal shows in decisions for Shawn"
prog status --run "$RUN"
has "${P1}:" "$(printf '%s\n' "$OUT" | sed -n '/Decisions for Shawn/,/Just did/p')"
it "a resolved proposal's decision asks for no answer, since every answer on it is refused"
has "${P1}: allow Bash(gh pr checks *) in ${R5}/.claude/settings.local.json for linear:AI-100, linear:AI-101 (resolved); no answer needed" "$OUT"

# ---- AE5: another layer still blocks ----
register sess-r10 "${WORK}/wt-r10"
prog add-item linear:AI-110 --title "ae5" --session sess-r10 --pane p110 --repo "$R6"
panes "p100=sess-r1=working p101=sess-r2=working p110=sess-r10=working"
deny sess-r10 tu-110 "gh run view 77"
prog propose-permission --item linear:AI-110
P2="$(pid_for "$R6")"
settings "${R6}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh run view *)"]}}'

it "AE5: a deny rule in user settings gives ineffective naming the rule and file, no reservation, no notification"
settings "$USER_SETTINGS" '{"env": {"SECRET_ENV": "envsecret-123"}, "permissions": {"deny": ["Bash(gh run view *)"]}}'
N_BEFORE="$(notices)"
answer "$P2" applied
check "0 \"ineffective\" null ${N_BEFORE}" "$CODE $(pf "$P2" '["state"]') $(pf "$P2" '.get("reservation")') $(notices)"
has "Bash(gh run view *)" "$(pf "$P2" '["explanation"]')"
has "$USER_SETTINGS" "$(pf "$P2" '["explanation"]')"

it "AE5: autoMode.classifyAllShell in user settings gives ineffective"
settings "$USER_SETTINGS" '{"autoMode": {"classifyAllShell": true}}'
answer "$P2" applied
check '0 "ineffective" null' "$CODE $(pf "$P2" '["state"]') $(pf "$P2" '.get("reservation")')"
has "classifyAllShell" "$(pf "$P2" '["explanation"]')"
settings "$USER_SETTINGS" "$PLAIN_USER"

it "an applied after ineffective re-verifies and arms exactly one attempt"
answer "$P2" applied
check '0 "retrying" 1' "$CODE $(pf "$P2" '["state"]') $(pf "$P2" '["attempts"]')"

it "a reject while retrying is recorded and deferred"
answer "$P2" no
check '0 "retrying" "no"' "$CODE $(pf "$P2" '["state"]') $(pf "$P2" '["pending_answer"]["choice"]')"

it "AE5: a denial row for the reserved session after the reservation gives ineffective with the layer"
deny sess-r10 tu-111 "gh run view 77"
prog settle-permissions
has "classifier" "$(pf "$P2" '["explanation"]')"
it "the deferred reject applies after the outcome, with no second reservation"
check '"rejected" 1 null' "$(pf "$P2" '["state"]') $(pf "$P2" '["attempts"]') $(pf "$P2" '.get("pending_answer")')"

# ---- retry_unobserved, deny-rule and mode refusals ----
register sess-r20 "${WORK}/wt-r20"
prog add-item linear:AI-120 --title "idle" --session sess-r20 --pane p120 --repo "$R7"
panes "p100=sess-r1=working p110=sess-r10=working p120=sess-r20=idle"
deny sess-r20 tu-120 "gh pr view 9"
prog propose-permission --item linear:AI-120
P3="$(pid_for "$R7")"
settings "${R7}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh pr view *)"]}}'
answer "$P3" applied
RETRY3="$(out_key retry_text | tr -d '"')"

it "an idle owner with the retry not yet sent stays retrying"
prog settle-permissions
check '"retrying"' "$(pf "$P3" '["state"]')"
it "an idle owner pane with no record after the retry was sent gives retry_unobserved"
prog prompt-item linear:AI-120 "$RETRY3"
prog settle-permissions
check '"retry_unobserved"' "$(pf "$P3" '["state"]')"
it "a later applied re-arms exactly one attempt"
answer "$P3" applied
check '0 "retrying" 2' "$CODE $(pf "$P3" '["state"]') $(pf "$P3" '["attempts"]')"

it "a deny-rule refusal seen only in the transcript gives ineffective, diagnosed as a deny rule"
ruled sess-r20 tu-121 "gh pr view 9" reject deny_rule
prog settle-permissions
check '"ineffective"' "$(pf "$P3" '["state"]')"
has "deny rule" "$(pf "$P3" '["explanation"]')"
has "permission-rule" "$(pf "$P3" '["explanation"]')"

it "a post-tool row whose transcript records a refusal settles as ineffective, not resolved"
answer "$P3" applied
ruled sess-r20 tu-122 "gh pr view 9" reject mode
prog settle-permissions
check '"ineffective" 3' "$(pf "$P3" '["state"]') $(pf "$P3" '["attempts"]')"
has "mode" "$(pf "$P3" '["explanation"]')"

# ---- folded proposal, partial cover, unconfirmed resolution ----
register sess-r30 "${WORK}/wt-r30"
prog add-item linear:AI-130 --title "folded" --session sess-r30 --pane p130 --repo "$R8"
deny sess-r30 tu-130 "gh pr checks 5"
prog propose-permission --item linear:AI-130
deny sess-r30 tu-131 "gh pr view 5"
prog propose-permission --item linear:AI-130
P4="$(pid_for "$R8")"
settings "${R8}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh pr checks *)"]}}'

it "a folded proposal where the rule covers only pr_checks stays open, names pr_view, reserves nothing"
answer "$P4" applied
check '0 "open" null' "$CODE $(pf "$P4" '["state"]') $(pf "$P4" '.get("reservation")')"
has "pr_view" "$(pf "$P4" '["explanation"]')"

it "an unreadable settings file is named as unknown"
settings "$USER_SETTINGS" '{not json'
answer "$P4" applied
has "unknown" "$(pf "$P4" '["explanation"]')"
has "$USER_SETTINGS" "$(pf "$P4" '["explanation"]')"
settings "$USER_SETTINGS" "$PLAIN_USER"

settings "${R8}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh pr checks *)", "Bash(gh pr view *)"]}}'
it "an execution of only one of an open proposal's operations does not resolve it"
ruled sess-r30 tu-132 "gh pr checks 5" accept red
prog settle-permissions
check '"open"' "$(pf "$P4" '["state"]')"
it "transcript-confirmed executions from an affected session resolve an open proposal unconfirmed"
ANSWERS_BEFORE="$(pf "$P4" '["answers"]' | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
ruled sess-r30 tu-133 "gh pr view 5" accept classifier
prog settle-permissions
check "\"resolved\" false ${ANSWERS_BEFORE} \"open\"" \
  "$(pf "$P4" '["state"]') $(pf "$P4" '["confirmed"]') $(pf "$P4" '["answers"]' | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))') $(field 'items["linear:AI-130"]["state"]')"
it "the unconfirmed resolution is a decision for Shawn naming the covering rule and file"
prog status --run "$RUN"
DECISIONS="$(printf '%s\n' "$OUT" | sed -n '/Decisions for Shawn/,/Just did/p')"
has "${P4}:" "$DECISIONS"
prog status --run "$RUN" --json
has "covered by <auto-external>Bash(gh pr checks *) in ${R8}/.claude/settings.local.json" \
  "$("$PY" -c 'import json,sys; print([d["question"] for d in json.load(sys.stdin)["model"]["decisions_for_shawn"] if d.get("proposal") == sys.argv[1]])' "$P4" <<< "$OUT")"

# ---- no live owner pane ----
register sess-r40 "${WORK}/wt-r40"
prog add-item linear:AI-140 --title "no pane" --session sess-r40 --pane p140 --repo "$R9"
deny sess-r40 tu-140 "gh run list --limit 3"
prog propose-permission --item linear:AI-140
P5="$(pid_for "$R9")"
settings "${R9}/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(gh run list *)"]}}'
it "covered with no live owner pane gives retry_unobserved, no reservation, no retry text"
answer "$P5" applied
check '0 "retry_unobserved" null null' "$CODE $(pf "$P5" '["state"]') $(pf "$P5" '.get("reservation")') $(out_key retry_text)"
has "no linked item" "$(pf "$P5" '["explanation"]')"

it "no verb call crashed with a traceback"
# programme-permission-allow.test.sh counts this check's pass; here a crash still fails the file.
[ -z "$CRASHES" ] || fail "expected [] got [$CRASHES]"

echo ""
echo "programme-permission.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

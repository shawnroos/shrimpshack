#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-behaviours-verbs-and-files.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-behaviours-setup.sh"

it "keep-behaviours: a set larger than one option can show is refused with a fix to split"
fresh_store
RUN="$(new_run one)"
"$PY" "$PROG" offer keep-many --command "keep-behaviours b1 b2 b3 b4 b5 --to repo" --run "$RUN" > "${WORK}/keep-many.out" 2>&1
check 1 "$?"
has "split" "$(cat "${WORK}/keep-many.out")"

it "the verbs moved to offers record who worded a draft: a pick of a proposal is pm_draft, and the view does not credit Shawn"
fresh_store
RUN="$(new_run one)"
prog propose-behaviour --run "$RUN" --when "a draft arrives" --do "read the draft"
DRAFT="$(jfield "$OUT" 'd["behaviour"]')"
PD="$(opick "$RUN" "record-behaviour --from-proposal ${DRAFT}")"
prog record-behaviour --from-proposal "$DRAFT" --prompt "$PD" --run "$RUN"
check "0 pm_draft" "$CODE $(q "$RUN" "beh_of('$DRAFT')['source']['wording']")"
check "pm_draft|source: PM draft Shawn approved by pick" "$(run_py "$RUN" "$DRAFT" <<'EOF'
view = load_lib_module("programme_view")
row = next(b for b in view.behaviours_view(record(args[0]), load_lib_module("programme").prompt_lookup)["behaviours"] if b["id"] == args[1])
print(row["wording"] + "|" + load_lib_module("programme_view_behaviours").source_text(row))
EOF
)"

it "record-behaviour on his own words in answer to its offer is his wording"
PW="$(opick "$RUN" --other "from now on, reproduce every bug first" "record-behaviour --when 'a bug comes in' --do 'reproduce it first'")"
prog record-behaviour --run "$RUN" --prompt "$PW" --reads-as "Record behaviour: a bug comes in" --when "a bug comes in" --do "reproduce it first"
WB="$(jfield "$OUT" 'd["behaviour"]')"
check "0 shawn" "$CODE $(q "$RUN" "beh_of('$WB')['source']['wording']")"

it "retire-behaviour is approved through its offer, and a decline leaves it in force"
PD="$(opick "$RUN" --decline "retire-behaviour ${WB} --as retired")"
prog retire-behaviour "$WB" --as retired --prompt "$PD" --run "$RUN"
GOT="$CODE"
PD="$(opick "$RUN" "retire-behaviour ${WB} --as retired")"
prog retire-behaviour "$WB" --as retired --prompt "$PD" --run "$RUN"
check "1 0 retired" "$GOT $CODE $(q "$RUN" "beh_of('$WB')['state']")"

it "an accepted suggestion approves no behaviour verb"
PS="$(run_py "$RUN" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", "record behaviour with these words", prompt_source="suggestion_accepted")["prompt_id"])
EOF
)"
prog record-behaviour --run "$RUN" --prompt "$PS" --when "a suggestion arrives" --do "ignore it"
check 1 "$CODE"
has "accepted suggestion" "$OUT"

it "older store rows with no wording, and rows with wording, both load"
check "None|None" "$(run_py <<'EOF'
print("|".join(str(pb.verdict(dict(beh("older"), source=source), allow_adoption=False).get("reason"))
               for source in ({"prompt_id": "p1", "quote": "older words"},
                              {"prompt_id": "p2", "quote": "newer words", "wording": "pm_draft"})))
EOF
)"

fresh_store
RUN="$(new_run one)"
B1="$(record_one "$RUN")"
B2="$(record_one "$RUN")"
PK="$(tprompt "$RUN" "keep ${B1} and ${B2} for the repo")"
it "keep-behaviours with a prompt naming two behaviours and repo moves both under the programme's repo key"
prog keep-behaviours "$B1" "$B2" --to repo --prompt "$PK" --run "$RUN"
check "0 acme/alpha acme/alpha ${B1}@repo ${B2}@repo" "$CODE $(q "$RUN" "' '.join([stored('$B1')['repo_key'], stored('$B2')['repo_key']]) + ' ' + ' '.join(sorted(ids(run).split(), key=lambda x: x != '${B1}@repo'))")"
it "the kept entries verify, the programme copies point at the repo, and the verb journals behaviours_kept and two rule_adopted rows"
check "[] repo repo 1 2" "$(q "$RUN" "'%s %s %s %d %d' % (loaded()['rejected'], beh_of('$B1')['moved_to'], beh_of('$B2')['moved_to'], count('behaviours_kept'), len([r for r in pj.read(run) if r['kind'] == 'rule_adopted' and r['payload']['entry'] == 'keep']))")"
it "running it twice does not duplicate entries"
prog keep-behaviours "$B1" "$B2" --to repo --prompt "$PK" --run "$RUN"
check "0 2" "$CODE $(q "$RUN" "len([e for es in pb.read_store()['repos'].values() for e in es])")"
it "the second run still leaves both in force once"
check "${B1}@repo ${B2}@repo" "$(q "$RUN" "' '.join(sorted(ids(run).split(), key=lambda x: x != '${B1}@repo'))")"

fresh_store
RUN="$(new_run one)"
B1="$(record_one "$RUN")"
B2="$(record_one "$RUN")"
PK="$(opick "$RUN" "keep-behaviours ${B1} --to personal")"
it "a pick of one behaviour does not approve a set no option offered, so the PM asks again"
STORE_BEFORE="$(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
prog keep-behaviours "$B1" "$B2" --to personal --prompt "$PK" --run "$RUN"
check "1 ${STORE_BEFORE}" "$CODE $(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
has "different command" "$OUT"
it "a pick of a set keeps exactly that set"
prog keep-behaviours "$B1" --to personal --prompt "$PK" --run "$RUN"
check "0 personal None" "$CODE $(q "$RUN" "'%s %s' % (stored('$B1')['layer'], stored('$B2'))")"

fresh_store
RUN="$(new_run one)"
B1="$(record_one "$RUN")"
B2="$(record_one "$RUN")"
PK="$(tprompt "$RUN" "keep ${B1} globally, all projects")"
it "typed words with no offer keep nothing, whatever they name"
STORE_BEFORE="$(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
PROG="$REAL_PROG" prog keep-behaviours "$B1" "$B2" --to personal --prompt "$PK" --run "$RUN"
check "1 ${STORE_BEFORE}" "$CODE $(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
has "no open offer" "$OUT"
PK3="$(tprompt "$RUN" "do not keep ${B2} in the repo")"
it "typed words with no offer that negate the layer are refused"
PROG="$REAL_PROG" prog keep-behaviours "$B2" --to repo --prompt "$PK3" --run "$RUN"
check 1 "$CODE"
PK4="$(tprompt "$RUN" "keep ${B2} and bnosuch for the repo")"
it "keep-behaviours naming an id that is not an active programme behaviour is refused"
prog keep-behaviours "$B2" bnosuch --to repo --prompt "$PK4" --run "$RUN"
check 1 "$CODE"
it "keep-behaviours --to programme is a usage error"
prog keep-behaviours "$B2" --to programme --prompt "$PK4" --run "$RUN"
check 2 "$CODE"
it "keep-behaviours without a typed prompt is refused"
prog keep-behaviours "$B2" --to repo --run "$RUN"
check 1 "$CODE"

fresh_store
RUN="$(new_run one)"
B1="$(record_one "$RUN")"
raw_store_cmd='raw = open(pb.store_path(), "w"); raw.write("{not json"); raw.close()'
run_py <<EOF >/dev/null
os.makedirs(os.path.dirname(pb.store_path()), exist_ok=True)
${raw_store_cmd}
EOF
PK="$(tprompt "$RUN" "keep ${B1} for the repo")"
it "keep-behaviours with an unreadable store is refused before anything commits"
REC_BEFORE="$(q "$RUN" "json.dumps(prog['behaviours'], sort_keys=True)")"
prog keep-behaviours "$B1" --to repo --prompt "$PK" --run "$RUN"
check "1 ${REC_BEFORE}" "$CODE $(q "$RUN" "json.dumps(prog['behaviours'], sort_keys=True)")"

fresh_store
RUN="$(new_run one)"
B1="$(record_one "$RUN")"
run_py "$RUN" <<'EOF' >/dev/null
def end(rec):
    rec["programme"]["ended"] = {"at": "2026-10-20T00:00:00Z", "reason": "ended_by_shawn"}
core._with_locked_run_record(ph.home_path(args[0]), args[0], end)
EOF
PK="$(tprompt "$RUN" "keep ${B1} for the repo")"
it "after end, keep-behaviours is refused"
prog keep-behaviours "$B1" --to repo --prompt "$PK" --run "$RUN"
check 1 "$CODE"
has "ended" "$OUT"

fresh_store
RUN="$(new_run)"
PT="$(tprompt "$RUN" "when an item merges, always check the deploy")"
it "R1: record-behaviour --trigger merge stores the trigger on the entry and prints it"
prog record-behaviour --run "$RUN" --prompt "$PT" --when "an item merges" --pm-check "the PR merged" \
  --trigger merge --do "read the changelog"
check "0 merge" "$CODE $(jfield "$OUT" 'd["trigger"]')"
TB="$(jfield "$OUT" 'd["behaviour"]')"
it "R1: the stored entry carries when.trigger"
check "merge" "$(q "$RUN" "beh_of('$TB')['when']['trigger']")"
PTM="$(tprompt "$RUN" "make ${TB} global")"
it "R1: a moved behaviour keeps its trigger"
prog move-behaviour "$TB" --to personal --prompt "$PTM" --run "$RUN"
check "0 merge" "$CODE $(q "$RUN" "stored('$TB')['when']['trigger']")"

fresh_store
RUN="$(new_run)"
BID="$(record_one "$RUN")"
it "R5: a behaviour recorded without a trigger stores none and reads as claim"
check "False claim" "$(q "$RUN" "'%s %s' % ('trigger' in beh_of('$BID')['when'], pb.trigger_of(beh_of('$BID')))")"

it "R1: an unknown --trigger is refused, naming the allowed values"
PU="$(tprompt "$RUN" "always check the deploy")"
prog record-behaviour --run "$RUN" --prompt "$PU" --when "an item merges" --trigger weekly --do "read the changelog"
check 2 "$CODE"
has "claim|merge|block|start" "$OUT"

it "R1: an entry with a valid trigger passes and one with trigger never is rejected with bad_value"
check "None|bad_value when.trigger" "$(run_py <<'EOF2'
ok = pb.verdict(beh("g1", when={"text": "x", "checks": [], "trigger": "block"}))
bad = pb.verdict(beh("g1", when={"text": "x", "checks": [], "trigger": "never"}))
print("%s|%s %s" % (ok.get("reason"), bad["reason"], bad["detail"]))
EOF2
)"

it "R1: start is a trigger, and trigger_times reads it from the item's started history row"
check "True 2026-10-30T10:00:00Z" "$(run_py <<'EOF2'
item = {"history": [{"kind": "started", "at": "2026-10-30T10:00:00Z"}, {"kind": "started", "at": "2026-10-30T11:00:00Z"}]}
print("start" in pb.TRIGGERS, pb.trigger_times("no-such-run", "k", item)["start"])
EOF2
)"

fresh_store
RUN="$(new_run)"
BID="$(record_one "$RUN")"
it "R6: skip-behaviour records a skipped delivery with its why and journals one behaviour_skipped row"
prog skip-behaviour linear:AI-1 "$BID" --why "this item is not a bug" --run "$RUN"
check "0 skipped skip-behaviour 1" "$CODE $(q "$RUN" "' '.join([prog['items']['linear:AI-1']['behaviour_deliveries'][-1]['reason'], prog['items']['linear:AI-1']['behaviour_deliveries'][-1]['via'], str(count('behaviour_skipped'))])")"
it "R6: the delivery keeps the why line"
check "this item is not a bug" "$(q "$RUN" "prog['items']['linear:AI-1']['behaviour_deliveries'][-1]['why']")"
it "R6: the other item holds no delivery"
check "[]" "$(q "$RUN" "prog['items']['linear:AI-2'].get('behaviour_deliveries', [])")"

it "R6: skip-behaviour without --why is refused"
prog skip-behaviour linear:AI-2 "$BID" --run "$RUN"
check 2 "$CODE"
it "R6: an unknown behaviour is refused with a fix line"
prog skip-behaviour linear:AI-2 bnope --why "x" --run "$RUN"
check 1 "$CODE"
has "fix:" "$OUT"
it "R6: an unknown item is refused"
prog skip-behaviour linear:AI-9 "$BID" --why "x" --run "$RUN"
check 1 "$CODE"

PM="$(tprompt "$RUN" "the PM always posts the status first")"
prog record-behaviour --run "$RUN" --prompt "$PM" --when "a status is due" --applies-to pm --do "post the status first"
PMB="$(jfield "$OUT" 'd["behaviour"]')"
it "KTD4: a PM-only behaviour is accepted, and --applied records applied_by_pm"
prog skip-behaviour linear:AI-1 "$PMB" --applied --why "posted the status" --run "$RUN"
check "0 applied_by_pm" "$CODE $(q "$RUN" "prog['items']['linear:AI-1']['behaviour_deliveries'][-1]['reason']")"

it "a retired behaviour is refused"
PR="$(tprompt "$RUN" "retire ${BID}")"
prog retire-behaviour "$BID" --as retired --prompt "$PR" --run "$RUN"
prog skip-behaviour linear:AI-2 "$BID" --why "x" --run "$RUN"
check 1 "$CODE"

it "a session that does not drive the programme is refused"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" skip-behaviour linear:AI-2 "$PMB" --why "x" --run "$RUN" 2>&1)"; CODE=$?
check 1 "$CODE"

F=0
fresh_files() {
  F=$((F + 1))
  export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="${WORK}/files/${F}/shipped"
  export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/files/${F}/personal"
  mkdir -p "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" "$CLAUDE_AUTO_BEHAVIOURS_DIR"
}
# wf <dir> <id> <do line> [extra frontmatter line]
wf() {
  printf -- '---\nwhen: when the work is a bug\n%s\n---\nDo:\n- %s\n' "${4:-}" "$3" > "$1/$2.md"
}
reset_files() {
  export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="${WORK}/files/shipped-empty"
  export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/files/personal-empty"
}

# Characterization: pinned before the file layers existed.
fresh_store; fresh_files
it "characterization: programme, repo and personal entries resolve in programme, repo, personal order"
check "g1 r1 p1" "$(run_py <<'EOF'
run = setup([beh("g1")])
keep(run, [beh("p1", "personal"), beh("r1", "repo")])
rec = record(run)
print(" ".join(b["id"] for b in pb.in_force(rec, rec["programme"]["items"]["linear:AI-1"], None)))
EOF
)"

fresh_store; fresh_files
it "characterization: a loaded store has no rejections or notices when both folders are empty"
check "[] [] [] []" "$(run_py <<'EOF'
rec_store = pb.load_store()
print(json.dumps(rec_store["rejected"]), json.dumps(rec_store["notices"]), json.dumps(rec_store["shipped"]), json.dumps(rec_store["files"]))
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
it "AE1: a personal file with a shipped id is in force and the shipped one is not"
wf "$CLAUDE_AUTO_BEHAVIOURS_DIR" ship1 "my own take"
check "ship1@personal|my own take" "$(run_py <<'EOF'
run = setup([])
rec = record(run)
got = pb.in_force(rec, rec["programme"]["items"]["linear:AI-1"], None)
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in got) + "|" + got[0]["do"][0])
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
it "a shipped behaviour alone is in force with layer shipped"
check "ship1@shipped" "$(run_py <<'EOF'
run = setup([])
print(ids(run))
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_BEHAVIOURS_DIR" same "from a file"
it "a repo entry with the same id as a personal file wins over it"
check "same@repo|from a stored repo entry" "$(run_py <<'EOF'
run = setup([])
keep(run, [beh("same", "repo", do=["from a stored repo entry"])])
rec = record(run)
got = pb.in_force(rec, rec["programme"]["items"]["linear:AI-1"], None)
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in got) + "|" + got[0]["do"][0])
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" same "shipped"
wf "$CLAUDE_AUTO_BEHAVIOURS_DIR" same "from a file"
it "a programme entry replaces a personal file and a shipped file of its id, and a stored repo entry still coexists"
check "same@programme same@repo|from the programme" "$(run_py <<'EOF'
run = setup([beh("same", do=["from the programme"])])
keep(run, [beh("same", "repo")])
rec = record(run)
got = pb.in_force(rec, rec["programme"]["items"]["linear:AI-1"], None)
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in got) + "|" + got[0]["do"][0])
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_BEHAVIOURS_DIR" same "from a file"
it "AE5: a stored personal entry and a personal file with one id keep the stored one and report the file shadowed"
check "same@personal|stored|shadowed 1" "$(run_py <<'EOF'
run = setup([])
keep(run, [beh("same", "personal", do=["stored"])])
rec = record(run)
res = pb.resolve(rec, rec["programme"]["items"]["linear:AI-1"], None)
got = res["in_force"]
shadow = [r for r in res["rejected"] if r["reason"] == "shadowed"]
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in got) + "|" + got[0]["do"][0] + "|shadowed " + str(len(shadow)))
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
it "overrides in a personal file remove a shipped entry"
wf "$CLAUDE_AUTO_BEHAVIOURS_DIR" mine "my own take" "overrides:
  - ship1"
check "mine@personal" "$(run_py <<'EOF'
run = setup([])
print(ids(run))
EOF
)"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
RUN="$(new_run)"
P1="$(tprompt "$RUN" "here, do not follow the shipped default")"
it "record-behaviour --conflicts-with a shipped id succeeds and the shipped entry drops out of force"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "the work is a bug" --do "do my own thing" --conflicts-with ship1
BID="$(jfield "$OUT" 'd["behaviour"]')"
check "0 ['ship1'] ${BID}@programme" "$CODE $(q "$RUN" "str(beh_of('$BID')['overrides']) + ' ' + ids(run)")"

fresh_store; fresh_files
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
it "a proposed entry with a shipped id leaves the shipped default in force, in the programme and in the store"
check "ship1@shipped|ship1@shipped" "$(run_py <<'EOF'
run = setup([beh("ship1", state="proposed")])
first = ids(run)
keep(run, [beh("ship1", "repo", state="proposed")])
print(first + "|" + ids(run))
EOF
)"

fresh_store; fresh_files
it "AE2: a broken personal file leaves the shipped default in force and raises one notice naming the file"
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
printf 'not frontmatter\n' > "$CLAUDE_AUTO_BEHAVIOURS_DIR/broken.md"
check "ship1@shipped|1|true" "$(run_py <<'EOF'
run = setup([])
rec = record(run)
res = pb.resolve(rec, rec["programme"]["items"]["linear:AI-1"], None)
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in res["in_force"]) + "|" + str(len(res["notices"])) + "|" + str("broken.md" in res["notices"][0]).lower())
EOF
)"

fresh_store; fresh_files
it "a retired repo entry with a shipped id switches the shipped default off"
wf "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" ship1 "shipped default"
check "" "$(run_py <<'EOF'
run = setup([])
keep(run, [beh("ship1", "repo", state="retired")])
print(ids(run))
EOF
)"

fresh_store; fresh_files
it "a stored entry with layer shipped is refused everywhere it could be stored"
check "programme|store|personal-list|programme-list" "$(run_py <<'EOF'
out = []
for name, fn in (("programme", lambda: pb.put_programme_entry({}, beh("s1", "shipped"))),
                 ("store", lambda: pb.store([beh("s1", "shipped")], None, "r", "s"))):
    try:
        fn()
        out.append("accepted")
    except pb.BehaviourError:
        out.append(name)
raw_store({"format": 1, "personal": [beh("s2", "shipped")], "repos": {}})
loaded = pb.load_store()
out.append("personal-list" if not loaded["personal"] and loaded["rejected"][0]["reason"] == "wrong_layer" else "accepted")
run = setup([beh("s3", "shipped")])
rec = record(run)
res = pb.resolve(rec, rec["programme"]["items"]["linear:AI-1"], None)
out.append("programme-list" if not res["in_force"] and any(r["id"] == "s3" for r in res["rejected"]) else "accepted")
print("|".join(out))
EOF
)"

fresh_store; fresh_files
it "with both folders empty a mixed set resolves exactly as it did before the file layers"
reset_files
check "g1@programme p1@personal r1@repo" "$(run_py <<'EOF'
run = setup([beh("g1")])
keep(run, [beh("p1", "personal"), beh("r1", "repo")])
print(ids(run))
EOF
)"

reset_files
echo ""
echo "programme-behaviours-verbs-and-files.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

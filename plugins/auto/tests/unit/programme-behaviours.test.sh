#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-behaviours.test.sh"

WORK="$(mktemp -d -t auto-programme-behaviours.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset CLAUDE_AUTO_BEHAVIOURS_STORE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

ALPHA="${WORK}/repos/alpha"
BETA="${WORK}/repos/beta"
mkdir -p "$ALPHA" "$BETA"
export ALPHA BETA WORK

N=0
fresh_store() {
  N=$((N + 1))
  export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/stores/${N}/behaviours.json"
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
pb = load_lib_module("programme_behaviours")
args = sys.argv[2:]
ALPHA, BETA = os.environ["ALPHA"], os.environ["BETA"]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def beh(bid, layer="programme", **kw):
    entry = {"id": bid, "layer": layer, "applies_to": "both", "state": "active",
             "when": {"text": "when the work is a bug", "checks": [{"text": "the item is a bug", "by": "pm"}]},
             "do": ["reproduce it first"]}
    if layer == "repo":
        entry["repo_key"] = "acme/alpha"
    entry.update(kw)
    return entry
def setup(behaviours, items=None, repos="two"):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    def mutate(rec):
        prog = rec["programme"]
        prog["remit"]["repos"] = [{"path": ALPHA, "github": "acme/alpha"}] + ([{"path": BETA}] if repos == "two" else [])
        prog["items"] = {"linear:AI-1": ph.new_item("linear:AI-1", "alpha bug"),
                         "linear:AI-2": ph.new_item("linear:AI-2", "beta bug")}
        prog["items"]["linear:AI-1"]["repo"] = ALPHA
        prog["items"]["linear:AI-2"]["repo"] = BETA
        if behaviours is not None:
            prog["behaviours"] = behaviours
    core._with_locked_run_record(ph.home_path(run), run, mutate)
    return run
def prompt_for(run, text):
    row = fixture_prompt(run, "sess-pm", text)
    return {"prompt_id": row["prompt_id"], "quote": text,
            "text_hash": "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()}
def keep(run, entries, text="keep these behaviours"):
    prompt = prompt_for(run, text)
    rec = record(run)
    adopted = [pb.adopt(e, prompt, rec) for e in entries]
    pb.store(adopted, prompt, run, "sess-pm")
    return adopted
def ids(run, item="linear:AI-1", audience=None):
    rec = record(run)
    got = pb.in_force(rec, rec["programme"]["items"][item], None, audience=audience)
    return " ".join(sorted("%s@%s" % (b["id"], b["layer"]) for b in got))
def raw_store(doc):
    path = pb.store_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(doc, fh)
$(cat)
PYEOF
}

fresh_store
it "a personal, a repo and a programme entry all resolve as in force for the item"
check "g1@programme p1@personal r1@repo" "$(run_py <<'EOF'
run = setup([beh("g1")])
keep(run, [beh("p1", "personal"), beh("r1", "repo")])
print(ids(run))
EOF
)"

fresh_store
it "a repo entry for a different repo is not in force"
check "g1@programme p1@personal|g1@programme p1@personal r2@repo" "$(run_py <<'EOF'
run = setup([beh("g1")])
keep(run, [beh("p1", "personal"), beh("r2", "repo", repo_key=os.path.normpath(BETA))])
print(ids(run, "linear:AI-1") + "|" + ids(run, "linear:AI-2"))
EOF
)"

fresh_store
it "AE4: a programme entry that overrides a personal entry hides it"
check "gamp@programme" "$(run_py <<'EOF'
run = setup([beh("gamp", do=["prioritise with Amplitude"], overrides=["pdatadog"])])
keep(run, [beh("pdatadog", "personal", do=["prioritise with Datadog"])])
print(ids(run))
EOF
)"

fresh_store
it "AE4 control: without the overrides link both entries are in force"
check "gamp@programme pdatadog@personal" "$(run_py <<'EOF'
run = setup([beh("gamp", do=["prioritise with Amplitude"])])
keep(run, [beh("pdatadog", "personal", do=["prioritise with Datadog"])])
print(ids(run))
EOF
)"

fresh_store
it "a retired entry's overrides link hides nothing"
check "pdatadog@personal" "$(run_py <<'EOF'
run = setup([beh("gamp", state="retired", overrides=["pdatadog"])])
keep(run, [beh("pdatadog", "personal")])
print(ids(run))
EOF
)"

fresh_store
it "a retired entry and a proposed entry are not in force"
check "g1@programme" "$(run_py <<'EOF'
run = setup([beh("g1"), beh("gret", state="retired"), beh("gprop", state="proposed")])
keep(run, [beh("pret", "personal", state="retired")])
print(ids(run))
EOF
)"

fresh_store
it "an entry for the PM is not returned for workers, and is returned for the PM"
check "gboth@programme gwork@programme|gboth@programme gpm@programme" "$(run_py <<'EOF'
run = setup([beh("gpm", applies_to="pm"), beh("gwork", applies_to="workers"), beh("gboth")])
print(ids(run, audience="workers") + "|" + ids(run, audience="pm"))
EOF
)"

fresh_store
it "a programme entry moved to personal stays in force until the store holds it, then shows once"
check "gmv@programme|gmv@personal" "$(run_py <<'EOF'
run = setup([beh("gmv", moved_to="personal")])
before = ids(run)
keep(run, [beh("gmv", "personal")])
print(before + "|" + ids(run))
EOF
)"

fresh_store
it "a moved programme entry stays in force when the store's copy does not verify"
check "gmv@programme" "$(run_py <<'EOF'
run = setup([beh("gmv", moved_to="personal")])
adopted = keep(run, [beh("gmv", "personal")])
adopted[0]["do"] = ["something else"]
raw_store({"format": 1, "personal": adopted, "repos": {}})
print(ids(run))
EOF
)"

fresh_store
it "AE5: a do line that deploys to production is refused with the protected reason"
check "protected_escalation prod_deploy" "$(run_py <<'EOF'
v = pb.verdict(beh("gdep", do=["deploy it to production yourself"]))
print(v["reason"], v["detail"])
EOF
)"

fresh_store
it "AE5: storing the protected entry raises, writes no store and journals no approval"
check "refused protected_escalation False 0" "$(run_py <<'EOF'
run = setup([])
prompt = prompt_for(run, "keep it")
rec = record(run)
try:
    pb.store([pb.adopt(beh("pdep", "personal", do=["deploy it to production yourself"]), prompt, rec)], prompt, run, "sess-pm")
    out = "stored"
except pb.BehaviourError as exc:
    out = "refused " + ("protected_escalation" if "protected_escalation" in str(exc) else str(exc))
rows = [r for r in pj.read(run) if r.get("kind") == "rule_adopted"]
print(out, os.path.exists(pb.store_path()), len(rows))
EOF
)"

fresh_store
it "AE5: putting the protected entry on the programme raises and leaves the list unchanged"
check "refused 0" "$(run_py <<'EOF'
prog = ph.normalize_programme({})
try:
    pb.put_programme_entry(prog, beh("gdep", do=["deploy it to production yourself"]))
    out = "added"
except pb.BehaviourError:
    out = "refused"
print(out, len(prog["behaviours"]))
EOF
)"

fresh_store
it "a preferred tool or skill naming a release is refused"
check "protected_escalation protected_escalation" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", tools=["the release tool"]))["reason"],
      pb.verdict(beh("g2", skills=["publish the package"]))["reason"])
EOF
)"

fresh_store
it "a stop with cost and time limits and a dont naming publish are accepted"
check "True" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", stop="after \$1 of paid runs or 30 minutes",
                     dont=["never publish without an eval run"]))["ok"])
EOF
)"

fresh_store
it "an entry adopted on another machine loads as in force"
check "pfar@personal" "$(run_py <<'EOF'
run = setup([])
os.environ["CLAUDE_AUTO_MACHINE"] = "laptop"
prompt = {"prompt_id": "pzzzzzz", "quote": "keep it", "text_hash": "sha256:00"}
adopted = pb.adopt(beh("pfar", "personal"), prompt, record(run))
os.environ["CLAUDE_AUTO_MACHINE"] = "studio"
raw_store({"format": 1, "personal": [adopted], "repos": {}})
print(ids(run))
EOF
)"

fresh_store
it "an entry missing when.text is rejected with missing_field"
check "missing_field" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", when={"checks": []}))["reason"])
EOF
)"

it "an entry with an unknown key is rejected with unknown_key"
check "unknown_key colour" "$(run_py <<'EOF'
v = pb.verdict(beh("g1", colour="blue"))
print(v["reason"], v["detail"])
EOF
)"

it "an entry with neither do nor dont is rejected with missing_field"
check "missing_field" "$(run_py <<'EOF'
e = beh("g1")
del e["do"]
print(pb.verdict(e)["reason"])
EOF
)"

it "bad applies_to, state, layer and check owner are each rejected with bad_value"
check "bad_value applies_to|bad_value state|bad_value layer|bad_value when.checks" "$(run_py <<'EOF'
print("|".join("%s %s" % (v["reason"], v["detail"]) for v in (
    pb.verdict(beh("g1", applies_to="everyone")), pb.verdict(beh("g1", state="paused")),
    pb.verdict(beh("g1", layer="team")),
    pb.verdict(beh("g1", when={"text": "x", "checks": [{"text": "y", "by": "robot"}]})))))
EOF
)"

it "a repo entry without a repo key is rejected with missing_field"
check "missing_field repo_key" "$(run_py <<'EOF'
e = beh("r1", "repo")
del e["repo_key"]
v = pb.verdict(e)
print(v["reason"], v["detail"])
EOF
)"

fresh_store
it "an entry adopted here whose hash does not match is rejected on load and not in force"
check "g1@programme|pbad adoption_unverified" "$(run_py <<'EOF'
run = setup([beh("g1")])
adopted = keep(run, [beh("pbad", "personal")])
adopted[0]["do"] = ["plan before reproducing"]
raw_store({"format": 1, "personal": adopted, "repos": {}})
res = pb.resolve(record(run), record(run)["programme"]["items"]["linear:AI-1"], None)
print(ids(run) + "|" + " ".join("%s %s" % (r["id"], r["reason"]) for r in res["rejected"]))
EOF
)"

fresh_store
it "an entry adopted here with no approval row, or no adoption, is rejected"
check "pnoapp adoption_unverified|pnone not_adopted" "$(run_py <<'EOF'
run = setup([])
prompt = prompt_for(run, "keep it")
adopted = pb.adopt(beh("pnoapp", "personal"), prompt, record(run))
raw_store({"format": 1, "personal": [adopted, beh("pnone", "personal")], "repos": {}})
res = pb.resolve(record(run), record(run)["programme"]["items"]["linear:AI-1"], None)
print("|".join("%s %s" % (r["id"], r["reason"]) for r in res["rejected"]))
EOF
)"

fresh_store
it "a repo entry stored under another repo's key is rejected"
check "rmoved wrong_key" "$(run_py <<'EOF'
run = setup([])
adopted = keep(run, [beh("rmoved", "repo")])
raw_store({"format": 1, "personal": [], "repos": {"acme/other": adopted}})
res = pb.load_store()
print(" ".join("%s %s" % (r["id"], r["reason"]) for r in res["rejected"]))
EOF
)"

fresh_store
it "storing an entry again by id replaces it rather than adding a second"
check "1 reproduce twice" "$(run_py <<'EOF'
run = setup([])
keep(run, [beh("p1", "personal")])
keep(run, [beh("p1", "personal", do=["reproduce twice"])], text="keep the new one")
doc = pb.read_store()
print(len(doc["personal"]), doc["personal"][0]["do"][0])
EOF
)"

fresh_store
it "a programme record written before this change reads with an empty list and keeps its fields"
check "[] 7 run-old True" "$(run_py <<'EOF'
blk = {"items": {}, "inbox_offset": 7, "extra": "run-old", "created_at": "2026-10-01T00:00:00Z"}
out = ph.normalize_programme(blk)
print(json.dumps(out["behaviours"]), out["inbox_offset"], out["extra"], "behaviours" in ph.PROGRAMME_FIELDS)
EOF
)"

fresh_store
it "in_force on a record with no behaviours key returns the store's entries only"
check "p1@personal" "$(run_py <<'EOF'
run = setup(None)
keep(run, [beh("p1", "personal")])
def strip(rec):
    rec["programme"].pop("behaviours", None)
core._with_locked_run_record(ph.home_path(run), run, strip)
print(ids(run))
EOF
)"

fresh_store
it "an unreadable behaviours.json is reported and programme entries stay in force"
check "g1@programme|unreadable" "$(run_py <<'EOF'
run = setup([beh("g1")])
os.makedirs(os.path.dirname(pb.store_path()), exist_ok=True)
open(pb.store_path(), "w").write("{not json")
res = pb.resolve(record(run), record(run)["programme"]["items"]["linear:AI-1"], None)
print(ids(run) + "|" + ("unreadable" if any("unreadable" in n for n in res["notices"]) else json.dumps(res["notices"])))
EOF
)"

fresh_store
it "a write refuses to overwrite an unreadable behaviours.json"
check "refused unchanged" "$(run_py <<'EOF'
run = setup([])
os.makedirs(os.path.dirname(pb.store_path()), exist_ok=True)
open(pb.store_path(), "w").write("{not json")
try:
    keep(run, [beh("p1", "personal")])
    out = "wrote"
except pb.BehaviourError:
    out = "refused"
print(out, "unchanged" if open(pb.store_path()).read() == "{not json" else "changed")
EOF
)"

fresh_store
it "a write refuses a store whose shape is wrong"
check "refused" "$(run_py <<'EOF'
run = setup([])
raw_store({"format": 1, "personal": {}, "repos": []})
try:
    keep(run, [beh("p1", "personal")])
    print("wrote")
except pb.BehaviourError:
    print("refused")
EOF
)"

fresh_store
it "the store sits beside the personal protocol unless overridden"
check "${WORK}/personal/behaviours.json" "$(env -u CLAUDE_AUTO_BEHAVIOURS_STORE "$PY" - "$AUTO_ROOT" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
print(load_lib_module("programme_behaviours").store_path())
EOF
)"

fresh_store
it "a do line about reproduction steps is accepted (a stem counts only at a word start)"
check "True" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", do=["attach the reproduction steps"]))["ok"])
EOF
)"

it "a do line that keeps paid runs under a cost is accepted (limits stay in code)"
check "True" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", do=["keep paid runs under \$1 cost"]))["ok"])
EOF
)"

it "AE5: a do line that deploys to production is still refused, and so is merging around the gate"
check "prod_deploy merge_around_gate prod_deploy" "$(run_py <<'EOF'
print(pb.verdict(beh("g1", do=["deploy it to production yourself"]))["detail"],
      pb.verdict(beh("g2", do=["merge around the gate"]))["detail"],
      pb.verdict(beh("g3", do=["it deployed to prod"]))["detail"])
EOF
)"

it "a programme entry moved to a repo needs the repo key it moved to"
check "bad_value moved_repo_key|True" "$(run_py <<'EOF'
v = pb.verdict(beh("g1", moved_to="repo"))
print("%s %s|%s" % (v["reason"], v["detail"], pb.verdict(beh("g1", moved_to="repo", moved_repo_key="acme/alpha"))["ok"]))
EOF
)"

fresh_store
it "a programme entry moved to one repo stays while only another repo's key holds it, then hides"
check "gmv@programme|gmv@repo" "$(run_py <<'EOF'
run = setup([beh("gmv", moved_to="repo", moved_repo_key="acme/alpha")])
keep(run, [beh("gmv", "repo", repo_key=os.path.normpath(BETA))])
before = ids(run, "linear:AI-1")
keep(run, [beh("gmv", "repo")], text="keep it for alpha")
print(before + "|" + ids(run, "linear:AI-1"))
EOF
)"
it "an item with no repo keeps the programme copy of an entry moved to a repo"
check "gmv@programme" "$(run_py <<'EOF'
run = setup([beh("gmv", moved_to="repo", moved_repo_key="acme/alpha")])
keep(run, [beh("gmv", "repo")])
rec = record(run)
print(" ".join("%s@%s" % (b["id"], b["layer"]) for b in pb.in_force(rec, {"repo": None})))
EOF
)"

PROG="${AUTO_ROOT}/lib/programme.py"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
new_run() {
  run_py "${1:-two}" <<'EOF'
print(setup([], repos=args[0]))
EOF
}
tprompt() {
  run_py "$1" "$2" "${3:-typed}" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1], args[2])["prompt_id"])
EOF
}
q() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
def beh_of(bid):
    return next((b for b in prog["behaviours"] if b["id"] == bid), None)
def kinds():
    return [r["kind"] for r in pj.read(run)]
def count(kind):
    return kinds().count(kind)
def stored(bid):
    doc = pb.read_store()
    rows = doc["personal"] + [e for es in doc["repos"].values() for e in es]
    return next((e for e in rows if e["id"] == bid), None)
def loaded():
    return pb.load_store()
print(eval(expr))
EOF
}
jfield() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }
record_one() {
  local p
  p="$(tprompt "$1" "always reproduce a reported bug before planning")"
  prog record-behaviour --run "$1" --prompt "$p" --when "a bug is reported" --pm-check "the item is a bug" \
    --do "reproduce the bug before planning"
  jfield "$OUT" 'd["behaviour"]'
}

fresh_store
RUN="$(new_run)"
P1="$(tprompt "$RUN" "always reproduce a reported bug before planning")"
it "AE1: record-behaviour with a typed prompt succeeds"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "a bug is reported" --pm-check "the item is a bug" \
  --agent-check "the bug reproduces locally" --do "reproduce the bug before planning"
check 0 "$CODE"
BID="$(jfield "$OUT" 'd["behaviour"]')"
it "AE1: its output lists the drafted checks and the undo command"
has "the bug reproduces locally" "$OUT"
has "retire-behaviour ${BID} --as undone" "$OUT"
it "AE1: the record shows it active at the programme layer, sourced from the prompt"
check "active programme ${P1} pm,agent" "$(q "$RUN" "' '.join([beh_of('$BID')['state'], beh_of('$BID')['layer'], beh_of('$BID')['source']['prompt_id'], ','.join(c['by'] for c in beh_of('$BID')['when']['checks'])])")"
it "AE1: one behaviour_recorded row cites the prompt"
check "[['${P1}']]" "$(q "$RUN" "[r.get('cites') for r in pj.read(run) if r['kind'] == 'behaviour_recorded']")"
it "AE1: the recorded behaviour is in force for the programme's items at once"
check "${BID}@programme" "$(q "$RUN" "ids(run)")"

P2="$(tprompt "$RUN" "make ${BID} global")"
it "AE1: move-behaviour --to personal with a prompt saying global succeeds"
prog move-behaviour "$BID" --to personal --prompt "$P2" --run "$RUN"
check 0 "$CODE"
it "AE1: the store holds it as a personal entry whose adoption verifies"
check "1 []" "$(q "$RUN" "'%d %s' % (len(loaded()['personal']), loaded()['rejected'])")"
it "AE1: the programme copy is marked moved and the personal copy is the one in force"
check "personal ${BID}@personal" "$(q "$RUN" "beh_of('$BID')['moved_to'] + ' ' + ids(run)")"
it "AE1: the move journals one rule_adopted row for the personal target and one behaviour_moved row"
check "['behaviour:personal:${BID}'] 1" "$(q "$RUN" "'%s %d' % ([r['payload']['target'] for r in pj.read(run) if r['kind'] == 'rule_adopted'], count('behaviour_moved'))")"

P3="$(tprompt "$RUN" "move ${BID} to the repo")"
it "a personal behaviour moves to a named repo, re-adopted, with the programme copy following"
prog move-behaviour "$BID" --to repo --repo acme/alpha --prompt "$P3" --run "$RUN"
check "0 repo acme/alpha [] acme/alpha ${BID}@repo" "$CODE $(q "$RUN" "' '.join([stored('$BID')['layer'], stored('$BID')['repo_key'], str(loaded()['rejected']), beh_of('$BID')['moved_repo_key'], ids(run)])")"

P4="$(tprompt "$RUN" "retire ${BID}, we do not need it")"
it "retiring a stored behaviour re-adopts it as retired and it stays visible"
prog retire-behaviour "$BID" --as retired --prompt "$P4" --run "$RUN"
check "0 retired [] 3 retired" "$CODE $(q "$RUN" "' '.join([stored('$BID')['state'], str(loaded()['rejected']), str(count('rule_adopted')), beh_of('$BID')['state']])")"
it "a retired stored behaviour is not in force"
check "" "$(q "$RUN" "ids(run)")"

fresh_store
RUN="$(new_run)"
BID="$(record_one "$RUN")"
P2="$(tprompt "$RUN" "make ${BID} global")"
prog move-behaviour "$BID" --to personal --prompt "$P2" --run "$RUN"
P3="$(tprompt "$RUN" "bring ${BID} back to the programme")"
it "a personal behaviour moves back to the programme and leaves the store"
prog move-behaviour "$BID" --to programme --prompt "$P3" --run "$RUN"
check "0 None None ${BID}@programme" "$CODE $(q "$RUN" "' '.join([str(stored('$BID')), str(beh_of('$BID').get('moved_to')), ids(run)])")"
P4="$(tprompt "$RUN" "keep ${BID} in the programme")"
it "moving a behaviour to the layer it is already on is refused"
prog move-behaviour "$BID" --to programme --prompt "$P4" --run "$RUN"
check 1 "$CODE"
has "already" "$OUT"

fresh_store
RUN="$(new_run)"
BID="$(record_one "$RUN")"
mkdir -p "$(dirname "$CLAUDE_AUTO_BEHAVIOURS_STORE")"
printf '{not json' > "$CLAUDE_AUTO_BEHAVIOURS_STORE"
P2="$(tprompt "$RUN" "make ${BID} global")"
BEFORE="$(q "$RUN" "json.dumps(prog['behaviours'], sort_keys=True)")"
it "with an unreadable behaviours.json, move-behaviour --to personal is refused"
prog move-behaviour "$BID" --to personal --prompt "$P2" --run "$RUN"
check 1 "$CODE"
has "unreadable" "$OUT"
it "the refused move leaves the programme entry unmoved and in force, and the store untouched"
check "${BEFORE}|${BID}@programme|{not json" "$(q "$RUN" "json.dumps(prog['behaviours'], sort_keys=True) + '|' + ids(run)")|$(cat "$CLAUDE_AUTO_BEHAVIOURS_STORE")"

fresh_store
RUN="$(new_run one)"
BID="$(record_one "$RUN")"
P2="$(tprompt "$RUN" "keep ${BID} here, not the repo")"
REC_BEFORE="$(q "$RUN" "json.dumps(prog, sort_keys=True)")"
ROWS_BEFORE="$(q "$RUN" "[k for k in kinds() if k != 'approval_refused']")"
REFUSED_BEFORE="$(q "$RUN" "count('approval_refused')")"
it "move-behaviour --to repo with a prompt saying 'not the repo' is refused"
prog move-behaviour "$BID" --to repo --prompt "$P2" --run "$RUN"
check 1 "$CODE"
has "negates" "$OUT"
it "the refused move writes nothing: record and non-refusal rows unchanged, no store file"
check "${REC_BEFORE}|${ROWS_BEFORE}|False" "$(q "$RUN" "json.dumps(prog, sort_keys=True) + '|' + str([k for k in kinds() if k != 'approval_refused']) + '|' + str(os.path.exists(pb.store_path()))")"
it "the refused move journals exactly one approval_refused row"
check "$((REFUSED_BEFORE + 1))" "$(q "$RUN" "count('approval_refused')")"

P3="$(tprompt "$RUN" "make it global")"
it "a move whose prompt does not name the behaviour is refused"
prog move-behaviour "$BID" --to personal --prompt "$P3" --run "$RUN"
check 1 "$CODE"
has "does not name" "$OUT"

P4="$(tprompt "$RUN" "move ${BID} to the repo")"
it "with one repo in the remit, move-behaviour --to repo takes that repo's key"
prog move-behaviour "$BID" --to repo --prompt "$P4" --run "$RUN"
check "0 acme/alpha acme/alpha ${BID}@repo" "$CODE $(q "$RUN" "' '.join([stored('$BID')['repo_key'], beh_of('$BID')['moved_repo_key'], ids(run)])")"

fresh_store
RUN="$(new_run two)"
BID="$(record_one "$RUN")"
P2="$(tprompt "$RUN" "move ${BID} to the repo")"
it "with two repos in the remit, move-behaviour --to repo without --repo is refused"
prog move-behaviour "$BID" --to repo --prompt "$P2" --run "$RUN"
check 1 "$CODE"
has "--repo" "$OUT"
it "a --repo that is not in the remit is refused"
prog move-behaviour "$BID" --to repo --repo acme/other --prompt "$P2" --run "$RUN"
check 1 "$CODE"
it "with --repo naming one, items in that repo get the repo copy and items in the other repo keep the programme copy"
prog move-behaviour "$BID" --to repo --repo acme/alpha --prompt "$P2" --run "$RUN"
check "0 ${BID}@repo|${BID}@programme" "$CODE $(q "$RUN" "ids(run, 'linear:AI-1') + '|' + ids(run, 'linear:AI-2')")"

fresh_store
RUN="$(new_run)"
run_py "$RUN" <<'EOF' >/dev/null
keep(args[0], [beh("pdatadog", "personal", do=["prioritise with Datadog"])])
EOF
P1="$(tprompt "$RUN" "here, prioritise with Amplitude")"
it "AE4: record-behaviour --conflicts-with a personal entry sets the programme entry to override it"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "prioritising the queue" --do "prioritise with Amplitude" \
  --conflicts-with pdatadog
BID="$(jfield "$OUT" 'd["behaviour"]')"
check "0 ['pdatadog'] ${BID}@programme" "$CODE $(q "$RUN" "str(beh_of('$BID')['overrides']) + ' ' + ids(run)")"
it "record-behaviour --conflicts-with an unknown behaviour is refused"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "prioritising" --do "prioritise" --conflicts-with pnope
check 1 "$CODE"
has "pnope" "$OUT"
it "record-behaviour names an in-force behaviour whose when shares words with the new one"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "a bug report comes in" --do "label it"
has "pdatadog" "$(jfield "$OUT" 'd["related"]')"

fresh_store
RUN="$(new_run)"
PC="$(tprompt "$RUN" "wake up and sweep the space" cron)"
it "record-behaviour citing a cron prompt is refused"
prog record-behaviour --run "$RUN" --prompt "$PC" --when "a bug is reported" --do "reproduce it"
check 1 "$CODE"
has "typed" "$OUT"
it "record-behaviour with no prompt is refused"
prog record-behaviour --run "$RUN" --when "a bug is reported" --do "reproduce it"
check 1 "$CODE"
it "the refused records write nothing"
check "[] 0" "$(q "$RUN" "'%s %d' % (prog['behaviours'], count('behaviour_recorded'))")"

P1="$(tprompt "$RUN" "when a fix is ready, deploy it to production yourself")"
it "AE5: record-behaviour naming a production deploy is refused, writes nothing and journals the refusal"
REFUSED_BEFORE="$(q "$RUN" "count('approval_refused')")"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "a fix is ready" --do "deploy it to production yourself"
check "1 [] $((REFUSED_BEFORE + 1))" "$CODE $(q "$RUN" "'%s %d' % (prog['behaviours'], count('approval_refused'))")"
has "protected_escalation" "$OUT"

fresh_store
RUN="$(new_run)"
BID="$(record_one "$RUN")"
P2="$(tprompt "$RUN" "undo that")"
it "retire-behaviour --as undone right after recording succeeds"
prog retire-behaviour "$BID" --as undone --prompt "$P2" --run "$RUN"
check "0 undone" "$CODE $(jfield "$OUT" 'd["as"]')"
it "the undone behaviour is out of force and stays visible as retired"
check "|retired undone" "$(q "$RUN" "ids(run) + '|' + beh_of('$BID')['state'] + ' ' + beh_of('$BID')['history'][-1]['event']")"
it "retiring it again is refused"
prog retire-behaviour "$BID" --as retired --prompt "$P2" --run "$RUN"
check 1 "$CODE"

fresh_store
RUN="$(new_run)"
it "propose-behaviour stores a proposal with no prompt"
prog propose-behaviour --run "$RUN" --when "a PR is opened" --agent-check "the worker opened a PR" \
  --do "request a CodeRabbit review"
PID="$(jfield "$OUT" 'd["behaviour"]')"
check "0 proposed 1 " "$CODE $(q "$RUN" "'%s %d %s' % (beh_of('$PID')['state'], count('behaviour_proposed'), ids(run))")"
it "record-behaviour --from-proposal without a typed prompt is refused"
prog record-behaviour --from-proposal "$PID" --run "$RUN"
check "1 proposed" "$CODE $(q "$RUN" "beh_of('$PID')['state']")"
P1="$(tprompt "$RUN" "yes, apply ${PID}")"
it "record-behaviour --from-proposal with a typed prompt makes it active and leaves the proposals"
prog record-behaviour --from-proposal "$PID" --prompt "$P1" --run "$RUN"
check "0 active [] ${PID}@programme" "$CODE $(q "$RUN" "' '.join([beh_of('$PID')['state'], str([b['id'] for b in prog['behaviours'] if b['state'] == 'proposed']), ids(run)])")"

fresh_store
RUN="$(new_run)"
run_py "$RUN" <<'EOF' >/dev/null
def add_term(rec):
    rec["programme"]["agreement"]["project_terms"] = [
        {"id": "t0a0b0c", "area": "prioritisation", "value": "Amplitude", "source": "x", "set_by": "proposal",
         "at": "2026-10-20T00:00:00Z", "reserved": False, "history": []}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], add_term)
EOF
TERM_BEFORE="$(q "$RUN" "json.dumps(prog['agreement']['project_terms'], sort_keys=True)")"
it "propose-behaviour --from-term copies the term's area and value into the draft"
prog propose-behaviour --from-term t0a0b0c --run "$RUN"
PID="$(jfield "$OUT" 'd["behaviour"]')"
check "0 True ['Amplitude'] proposed" "$CODE $(q "$RUN" "'%s %s %s' % ('prioritisation' in beh_of('$PID')['when']['text'], beh_of('$PID')['tools'], beh_of('$PID')['state'])")"
it "propose-behaviour --from-term leaves the project term unchanged"
check "$TERM_BEFORE" "$(q "$RUN" "json.dumps(prog['agreement']['project_terms'], sort_keys=True)")"
it "propose-behaviour --from-term with an unknown term is refused"
prog propose-behaviour --from-term tffffff --run "$RUN"
check 1 "$CODE"

fresh_store
RUN="$(new_run)"
run_py "$RUN" <<'EOF' >/dev/null
def end(rec):
    rec["programme"]["ended"] = {"at": "2026-10-20T00:00:00Z", "reason": "ended_by_shawn"}
core._with_locked_run_record(ph.home_path(args[0]), args[0], end)
EOF
P1="$(tprompt "$RUN" "always reproduce a reported bug before planning")"
it "a behaviour write on an ended programme is refused"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "a bug is reported" --do "reproduce it"
check 1 "$CODE"
has "ended" "$OUT"

fresh_store
it "the view list keeps a programme copy moved to one repo while another remit repo still reads it"
check "gsplit|gsplit|" "$(run_py <<'EOF'
run = setup([beh("gsplit", moved_to="repo", moved_repo_key="acme/alpha")])
keep(run, [beh("gsplit", "repo")])
prog = record(run)["programme"]
two = " ".join(e["id"] for e in pb.shown_programme_entries(prog, pb.load_store()))
one = setup([beh("gsplit", moved_to="repo", moved_repo_key="acme/alpha")], repos="one")
prog1 = record(one)["programme"]
pers = setup([beh("gper", moved_to="personal")])
keep(pers, [beh("gper", "personal")])
print(two + "|" + " ".join(e["id"] for e in pb.shown_programme_entries(prog1, {"personal": [], "repos": {}, "rejected": [], "notices": []}))
      + "|" + " ".join(e["id"] for e in pb.shown_programme_entries(record(pers)["programme"], pb.load_store())))
EOF
)"

fresh_store
it "the brief takes worker behaviours with no checks or an agent check, and holds back PM-only checks"
check "wag wnone|wpm" "$(run_py <<'EOF'
run = setup([beh("wpm", applies_to="workers"),
             beh("wag", applies_to="workers", when={"text": "UI work", "checks": [{"text": "the diff touches UI", "by": "agent"}]}),
             beh("wnone", applies_to="workers", when={"text": "always", "checks": []}),
             beh("pmonly", applies_to="pm", when={"text": "always", "checks": []})])
rec = record(run)
got, held = pb.brief_entries(rec, rec["programme"]["items"]["linear:AI-1"], lookup=lambda r, p: None)
print(" ".join(e["id"] for e in got) + "|" + " ".join(held))
EOF
)"

it "a PM-checked behaviour the PM names with --behaviour joins the brief"
check "wpm wag" "$(run_py <<'EOF'
run = setup([beh("wpm", applies_to="workers"),
             beh("wag", applies_to="workers", when={"text": "UI work", "checks": [{"text": "the diff touches UI", "by": "agent"}]})])
rec = record(run)
got, held = pb.brief_entries(rec, rec["programme"]["items"]["linear:AI-1"], ["wpm", "wag"], lookup=lambda r, p: None)
print(" ".join(e["id"] for e in got))
EOF
)"

it "a PM-only behaviour, a retired one or an unknown id named for the brief is refused"
check "BehaviourError BehaviourError BehaviourError" "$(run_py <<'EOF'
run = setup([beh("pmonly", applies_to="pm"), beh("gone", applies_to="workers", state="retired")])
rec = record(run)
out = []
for bid in ("pmonly", "gone", "nosuch"):
    try:
        pb.brief_entries(rec, rec["programme"]["items"]["linear:AI-1"], [bid], lookup=lambda r, p: None)
        out.append("accepted")
    except pb.BehaviourError:
        out.append("BehaviourError")
print(" ".join(out))
EOF
)"

it "brief lines carry the heading and each behaviour's id, when, do, don't and evidence"
OUTL="$(run_py <<'EOF'
e = beh("wui", applies_to="workers", do=["record the browser"], dont=["skip the check"], evidence="a browser recording attached",
        when={"text": "the work changes UI", "checks": [{"text": "the diff touches UI", "by": "agent"}]})
print("\n".join(pb.brief_lines([e])))
EOF
)"
has "Behaviours this work follows:" "$OUTL"
has "- wui: when the work changes UI" "$OUTL"
has "do: record the browser" "$OUTL"
has "don't: skip the check" "$OUTL"
has "evidence: a browser recording attached" "$OUTL"
has "you judge: the diff touches UI" "$OUTL"

it "a behaviour's start is its last recorded, moved or kept event, else its at"
check "2026-06-01T00:00:00Z 2026-07-01T00:00:00Z 2026-05-02T00:00:00Z 2026-05-01T00:00:00Z None" "$(run_py <<'EOF'
a = beh("a1", at="2026-05-01T00:00:00Z", history=[{"event": "proposed", "at": "2026-04-01T00:00:00Z"},
                                                  {"event": "recorded", "at": "2026-05-02T00:00:00Z"},
                                                  {"event": "moved", "at": "2026-06-01T00:00:00Z"}])
k = beh("a4", at="2026-05-01T00:00:00Z", history=[{"event": "recorded", "at": "2026-05-02T00:00:00Z"},
                                                  {"event": "kept", "at": "2026-07-01T00:00:00Z"}])
r = beh("a5", at="2026-05-01T00:00:00Z", history=[{"event": "recorded", "at": "2026-05-02T00:00:00Z"},
                                                  {"event": "retired", "at": "2026-07-01T00:00:00Z"}])
print(pb.since(a), pb.since(k), pb.since(r), pb.since(beh("a2", at="2026-05-01T00:00:00Z")), pb.since(beh("a3")))
EOF
)"

it "a behaviour kept after an item's claim can only remind that item, never send it back"
check "remind_only" "$(run_py <<'EOF'
k = beh("a6", at="2026-05-01T00:00:00Z", history=[{"event": "recorded", "at": "2026-05-01T00:00:00Z"},
                                                  {"event": "kept", "at": "2026-05-10T00:00:00Z"}])
print(pb.timing(k, "2026-05-05T00:00:00Z"))
EOF
)"

it "moving an overriding behaviour keeps only links to a broader layer and reports the rest"
check "repo:['pa'] lost:['rb'] personal:- lost:['pa', 'rb'] programme:['pa', 'rb'] lost:[]" "$(run_py <<'EOF'
loaded = {"personal": [beh("pa", "personal")], "repos": {"acme/alpha": [beh("rb", "repo", repo_key="acme/alpha")]},
          "rejected": [], "notices": []}
e = beh("gx", overrides=["pa", "rb"])
rp, rlost = pb._placed(e, "repo", "acme/alpha", loaded)
up, ulost = pb._placed(e, "personal", None, loaded)
pg, plost = pb._placed(dict(e, layer="repo", repo_key="acme/alpha"), "programme", None, loaded)
print("repo:%s lost:%s personal:%s lost:%s programme:%s lost:%s" % (
    rp.get("overrides"), rlost, up.get("overrides", "-"), ulost, pg.get("overrides"), plost))
EOF
)"

it "timing: no trigger yet, a trigger after the behaviour, a trigger before or at it, and an unknown start"
check "before_trigger send_back remind_only remind_only remind_only" "$(run_py <<'EOF'
e = beh("a1", at="2026-05-01T00:00:00Z")
print(pb.timing(e, None), pb.timing(e, "2026-05-02T00:00:00Z"), pb.timing(e, "2026-04-30T00:00:00Z"),
      pb.timing(e, "2026-05-01T00:00:00Z"), pb.timing(beh("a2"), "2026-05-02T00:00:00Z"))
EOF
)"

it "trigger times come from the item's first claim, its merged deliverable and its first wait or hand-off"
check "2026-03-01T00:00:00Z 2026-03-05T00:00:00Z 2026-03-03T00:00:00Z|None None None" "$(run_py <<'EOF'
import datetime
run = setup([])
def claim(item, day):
    pj.append_row(run, pj.entry("claim", "sess-w", {"item": item, "deliverable": "merged", "ref": "pr:1"},
                                now=datetime.datetime(2026, 3, day, tzinfo=datetime.timezone.utc)), channel="claims")
claim("linear:AI-2", 1)
claim("linear:AI-1", 1)
claim("linear:AI-1", 4)
def mutate(rec):
    item = rec["programme"]["items"]["linear:AI-1"]
    item["history"] += [{"at": "2026-03-02T00:00:00Z", "kind": "owner"}, {"at": "2026-03-03T00:00:00Z", "kind": "waiting"},
                        {"at": "2026-03-06T00:00:00Z", "kind": "handed"}]
    item["deliverables"]["merged"] = {"result": "confirmed", "confirmed_at": "2026-03-05T00:00:00Z"}
core._with_locked_run_record(ph.home_path(run), run, mutate)
rec = record(run)
t = pb.trigger_times(run, "linear:AI-1", rec["programme"]["items"]["linear:AI-1"])
u = pb.trigger_times(run, "linear:AI-9", ph.new_item("linear:AI-9"))
print("%s %s %s|%s %s %s" % (t["claim"], t["merge"], t["block"], u["claim"], u["merge"], u["block"]))
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
PK="$(tprompt "$RUN" "keep ${B1} globally, all projects")"
it "a prompt that names only one of two behaviours moves only that one"
prog keep-behaviours "$B1" "$B2" --to personal --prompt "$PK" --run "$RUN"
check "0 personal None" "$CODE $(q "$RUN" "'%s %s' % (stored('$B1')['layer'], stored('$B2'))")"
it "the output names the behaviour the prompt left out"
check "['${B1}'] ['${B2}']" "$(jfield "$OUT" 'str(d["kept"]) + " " + str(d["not_named"])')"

PK2="$(tprompt "$RUN" "keep ${B2} for the repo")"
it "keep-behaviours whose prompt names none of the ids is refused and writes nothing"
STORE_BEFORE="$(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
prog keep-behaviours "$B1" --to repo --prompt "$PK2" --run "$RUN"
check "1 ${STORE_BEFORE}" "$CODE $(q "$RUN" "json.dumps(pb.read_store(), sort_keys=True)")"
PK3="$(tprompt "$RUN" "do not keep ${B2} in the repo")"
it "keep-behaviours with a negated layer is refused"
prog keep-behaviours "$B2" --to repo --prompt "$PK3" --run "$RUN"
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

echo ""
echo "programme-behaviours.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

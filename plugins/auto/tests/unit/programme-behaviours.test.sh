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
def setup(behaviours, items=None):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    def mutate(rec):
        prog = rec["programme"]
        prog["remit"]["repos"] = [{"path": ALPHA, "github": "acme/alpha"}, {"path": BETA}]
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

echo ""
echo "programme-behaviours.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

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
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="${WORK}/files/shipped-empty"
export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/files/personal-empty"
mkdir -p "$CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR" "$CLAUDE_AUTO_BEHAVIOURS_DIR"

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

PROG="${AUTO_ROOT}/tests/fixtures/prog_offered.py"
source "${AUTO_ROOT}/tests/helpers/prog-exit.sh"
REAL_PROG="${AUTO_ROOT}/lib/programme.py"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; prog_exit_check "$@"; }
new_run() {
  run_py "${1:-two}" <<'EOF'
print(setup([], repos=args[0]))
EOF
}
opick() { "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"; }
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

PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
WORK="$(mktemp -d -t auto-programme-rituals.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export TZ=UTC
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_RITUALS_STORE="${WORK}/stores/rituals.json"
unset CLAUDE_AUTO_BEHAVIOURS_STORE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
pr = load_lib_module("programme_rituals")
due = load_lib_module("programme_rituals_due")
args = sys.argv[2:]
UTC = datetime.timezone.utc
def at(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def ritual(rid, layer="programme", **kw):
    entry = {"id": rid, "layer": layer, "state": "active", "at": "2026-11-01T00:00:00Z",
             "when": {"text": "every Monday", "trigger": "calendar",
                      "schedule": {"every": "week", "weekday": 0, "at": "09:00"}},
             "steps": ["report what drifted"]}
    if layer == "repo":
        entry["repo_key"] = "acme/alpha"
    entry.update(kw)
    return entry
def event_ritual(rid, trigger="handover", **kw):
    return ritual(rid, when={"text": "at handover", "trigger": trigger}, **kw)
def setup(rituals, clock=None):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    def mutate(rec):
        rec["programme"]["rituals"] = rituals
        rec["programme"]["ritual_clock"] = clock or {}
    core._with_locked_run_record(ph.home_path(run), run, mutate)
    return run
def jrow(kind, when, **payload):
    return {"kind": kind, "at": when, "payload": payload}
def states(result):
    return sorted("%s:%s" % (r["ritual"], r["state"]) for b in ("due", "missed", "in_flight") for r in result[b])
def prompt_for(run, text):
    row = fixture_prompt(run, "sess-pm", text)
    return {"prompt_id": row["prompt_id"], "quote": text,
            "text_hash": "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()}
$(cat)
PYEOF
}

PROG="${AUTO_ROOT}/tests/fixtures/prog_offered.py"
source "${AUTO_ROOT}/tests/helpers/prog-exit.sh"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; prog_exit_check "$@"; }
new_run() {
  run_py <<'EOF'
print(setup([]))
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
def kinds():
    return [r["kind"] for r in pj.read(run)]
def count(kind):
    return kinds().count(kind)
print(eval(expr))
EOF
}
jfield() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/tests/fixtures/prog_offered.py"
REAL_PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
WORK="$(mktemp -d -t auto-programme-rulings.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_SPINOFF_TIMEOUT=2
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  code=0; [ "$tool" = spinoff ] && code=3
  printf '#!/bin/sh\nexit %s\n' "$code" > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
pc = load_lib_module("programme_context")
pd = load_lib_module("programme_decisions")
core = load_lib_module("run_record_core")
import programme_records
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" <<'EOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
EOF
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}

real() { PROG="$REAL_PROG" prog "$@"; }
opick_in() { "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"; }
opick() { opick_in "$RUN" "$@"; }

pyget() {
  "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); v=eval(sys.argv[2]); print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))' "$1" "$2" 2>&1
}

ctx() { "$PY" "$PROG" context --run "$RUN" 2>&1; }
ruling_state() { pyget "$(ctx)" "d['decisions']['$1']['state']"; }
in_force_rev() { pyget "$(ctx)" "(d['decisions']['$1']['in_force'] or {}).get('rev')"; }

# rulings_for <item> <kind>: the active Rulings the gate reads, as "id:effect:items:baseline" rows.
rulings_for() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, item, kind = args
programme = ph.normalize_programme(programme_records.load(run)["programme"])
rows = pc.rulings_for(programme, item, kind, core.now_iso())
print(" ".join(f"{r['id']}:{r['effect']}:{','.join(r['items'])}:{r['baseline']}" for r in rows))
EOF
}

gate() {
  run_py "$RUN" "$1" "$2" "$3" <<'EOF'
run, item, kind, level = args
programme = ph.normalize_programme(programme_records.load(run)["programme"])
now = core.now_iso()
v = pd.who_decides(kind, item, level=level, rulings=pc.rulings_for(programme, item, kind, now), now=now,
                   accepted=True)
print(v["decider"], v["reason"])
EOF
}

ctx_hash() {
  run_py "$RUN" <<'EOF'
import hashlib
rec = programme_records.load(args[0])
print(hashlib.sha256(json.dumps(rec["programme"].get("context"), sort_keys=True).encode()).hexdigest()[:12])
EOF
}

for item in herdr:a herdr:b herdr:c herdr:d herdr:m1 herdr:m2; do
  prog add-item "$item" --title "$item" --kind fix_only --run "$RUN"
done

state_of() { pyget "$(ctx)" "((d['decisions'].get('$1') or {}).get('state'))"; }

prompt_in() {
  run_py "$1" "$2" <<'EOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
EOF
}

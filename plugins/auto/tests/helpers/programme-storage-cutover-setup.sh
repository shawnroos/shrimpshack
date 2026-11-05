PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LIB="${AUTO_ROOT}/lib"
PROG="${LIB}/programme.py"
OLD_COMMIT="f9934a3"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }
WORK="$(mktemp -d -t auto-storage-cutover.XXXXXX)"
CHILDREN=""
cleanup() {
  for pid in $CHILDREN; do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO LINEAR_API_KEY CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
SECRET="zq-fixture-secret-7731"
printf 'FIXTURE_TOKEN=%s\n' "$SECRET" > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "pane get")
    pane="$3"
    printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"w2:t1"}},"type":"pane_info"}\n' \
      "$pane" "${pane%%:*}" "${pane##*:}" ;;
esac
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"
. "${AUTO_ROOT}/tests/helpers/herdr-pane.sh"

OLD="${WORK}/old/plugins/auto/lib"
mkdir -p "${WORK}/old"
TOP="$(git -C "$AUTO_ROOT" rev-parse --show-toplevel 2>/dev/null)"
OLD_EXTRACTED=no
if [ -n "$TOP" ] && git -C "$TOP" archive "$OLD_COMMIT" plugins/auto/lib plugins/auto/protocol 2>/dev/null | tar -x -C "${WORK}/old" 2>/dev/null \
   && [ -f "${OLD}/programme.py" ]; then
  OLD_EXTRACTED=yes
fi

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
import _bootstrap as boot
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
auth = load_lib_module("programme_authority")
imp = load_lib_module("programme_import")
store = load_lib_module("programme_store")
args = sys.argv[2:]
def home(run):
    return ph.home_path(run)
def export_path(run):
    return core.run_record_path(home(run), run)
def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()
def rev(run):
    return auth.snapshot(run)["revision"]
def kinds(run):
    return [r["kind"] for r in auth.snapshot(run)["journal"]]
$(cat)
PYEOF
}

as() {
  local sid="$1"; shift
  OUT="$(as_pane "$sid" "${WS:-w9}" "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

old_as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" "${OLD}/programme.py" "$@" 2>&1)"
  CODE=$?
}

hook_payload() {
  "$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "prompt": sys.argv[2], "hook_event_name": "UserPromptSubmit"}))' "$1" "$2"
}

prompt_id_of() {
  "$PY" -c '
import json, re, sys
raw = sys.stdin.read().strip()
if not raw:
    print(""); sys.exit()
ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
print(re.search(r"\"prompt_id\": \"(p[0-9a-f]+)\"", ctx).group(1))'
}

old_typed() {
  hook_payload "$1" "$2" | HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" "${OLD}/on-user-prompt.py" | prompt_id_of
}

# Runs the current hook with a transcript row that shows Shawn typed the prompt.
new_typed() {
  register_session "$1" "${WS:-w9}" >/dev/null
  HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" - "$AUTO_ROOT" "$LIB" "$1" "$2" <<'EOF' | prompt_id_of
import json, os, subprocess, sys
root, lib, sid, text = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
from programme_prompts import fixture
payload, _, path, row = fixture(text, sid)
path.write_text(os.environ["TYPED_AFTER"] + "\n" if os.environ.get("TYPED_AFTER") else "")
out = subprocess.run([sys.executable, os.path.join(lib, "on-user-prompt.py")], input=json.dumps(payload),
                     text=True, capture_output=True)
with path.open("a") as stream:
    stream.write(json.dumps(row) + "\n")
sys.stdout.write(out.stdout)
EOF
}

opick() {
  local sid="$1"; shift
  as_pane "$sid" "${WS:-w9}" "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"
}

# The transcript row of the picker this output of `offer` printed, for words typed as its answer.
asked_row() {
  "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps({"type":"assistant","uuid":"ask","sessionId":sys.argv[1],"isSidechain":False,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_open","name":"AskUserQuestion","input":{"questions":d["input"]["questions"]}}]}}))' "$1" <<< "$OUT"
}

json_field() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps($1, sort_keys=True) if not isinstance($1, str) else $1)" <<< "$OUT" 2>&1
}

legacy_programme() {
  local sid="$1" space="$2"
  old_as "$sid" start --space "default.${space}"
  "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["run"])' <<< "$OUT"
}

wait_for() {
  local file="$1" text="$2" i=0
  while [ $i -lt 100 ]; do
    grep -q "$text" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

cat > "${WORK}/pause_shim.py" <<'EOF'
import fcntl, os, runpy, sys
gate, script = sys.argv[1], sys.argv[2]
want = int(os.environ.get("SHIM_PAUSE_AT", "1"))
real = fcntl.flock
seen = {"n": 0}
def flock(fd, op):
    if op & fcntl.LOCK_EX:
        seen["n"] += 1
        if seen["n"] == want:
            print("shim:paused", flush=True)
            while not os.path.exists(gate):
                import time; time.sleep(0.05)
    return real(fd, op)
fcntl.flock = flock
sys.argv = [script] + sys.argv[3:]
sys.path.insert(0, os.path.dirname(script))
runpy.run_path(script, run_name="__main__")
EOF

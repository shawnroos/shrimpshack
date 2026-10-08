#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPERS="${AUTO_ROOT}/tests/helpers"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
RR="${AUTO_ROOT}/lib/run_record.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "task-run-evidence.test.sh"

WORK="$(mktemp -d -t auto-task-run-evidence.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

REPO="${WORK}/repo"
mkdir -p "${REPO}/.claude/auto"
export CLAUDE_AUTO_REPO="$REPO"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-drive"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH GH_TOKEN GITHUB_TOKEN LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FIXTURES="${HELPERS}/fixtures/evidence"
CALLS="${WORK}/calls.log"
FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
cp -f "${HELPERS}/fake-gh.sh" "${FAKES}/gh"
export PATH="${FAKES}:/usr/bin:/bin"
fx() {
  {
    printf 'FAKE_CALLS=%s\nFAKE_FIXTURES=%s\n' "$CALLS" "$FIXTURES"
    printf 'FAKE_GH_VIEW=%s\nFAKE_GH_GRAPHQL=%s\n' "${FIXTURES}/gh-view-merged.json" "${FIXTURES}/${1}"
  } > "${FAKES}/fake.env"
}
fx gh-graphql-pr97-real.json
: > "$CALLS"

run_py() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
repo = sys.argv[2]
args = sys.argv[3:]
$(cat)
PYEOF
}

rr() { "$PY" "$RR" "$@"; }

make_run() {
  run_py "$1" "$2" <<'EOF'
rr = load_lib_module("run_record")
run, terminal = args
rr.init_run_record(repo, run, backend="native", backend_scale="blocker-only",
                   steps=[{"id": "s1"}, {"id": "s2"}], loop_phase="work",
                   driving_session_id="sess-drive")
for step in ("s1", "s2") if terminal == "yes" else ("s1",):
    rr.transition(repo, run, step, "dispatched")
    rr.record_verdict(repo, run, step, [])
print("ok")
EOF
}

predicate_of() {
  run_py "$1" <<'EOF'
rr = load_lib_module("run_record")
print(json.dumps(rr.read_run_record(repo, args[0])["exit_predicate_result"], sort_keys=True))
EOF
}

field() {
  run_py "$1" "$2" <<'EOF'
rr = load_lib_module("run_record")
rec = rr.read_run_record(repo, args[0])
print(json.dumps(eval(args[1]), sort_keys=True))
EOF
}

it "the new verbs are listed by describe"
verbs="$(rr describe | "$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))')"
has "check-deliverable" "$verbs"
it "the journal read verb is listed by describe"
has "evidence-journal" "$verbs"

make_run done-run yes >/dev/null
BEFORE="$(predicate_of done-run)"

it "AE7 baseline: a task run with every step terminal and no gating finding has met true"
check "true" "$(field done-run "rec['exit_predicate_result']['met']")"

it "AE7: the driving session checks a deliverable and the refuted result is stored"
rr check-deliverable done-run merged --ref shawnroos/shrimpshack#97 >"${WORK}/out" 2>&1
CODE=$?
check "0 \"refuted\"" "$CODE $(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['result']")"

it "AE7: the refutation names its miss"
has "no check run succeeded" "$(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['misses']")"

it "AE7: met stays true and the stored predicate is unchanged after a refuted deliverable"
check "$BEFORE" "$(predicate_of done-run)"

it "AE7: the predicate computed without the evidence block equals the stored one"
same="$(run_py done-run <<'EOF'
rr = load_lib_module("run_record")
rec = rr.read_run_record(repo, args[0])
stored = rec["exit_predicate_result"]
rec.pop("task_evidence")
print(rr.recompute_predicate(rec) == stored and stored["met"] is True)
EOF
)"
check "True" "$same"

it "AE7: the run's phase model still reads it as finished in its phase"
check "true" "$(field done-run "rec['exit_predicate_result']['all_steps_terminal']")"

it "the check is journaled under the run's journal subfolder"
JOURNAL="${REPO}/.claude/auto/journal/done-run.jsonl"
row="$(tail -n 1 "$JOURNAL" 2>/dev/null)"
has '"kind": "evidence_checked"' "$row"
it "the journal line carries the result, the session and no run fields"
has '"result": "refuted"' "$row"
has '"session_id": "sess-drive"' "$row"
lacks '"run_id"' "$row"
lacks '"loop' "$row"

it "the journal sits in a subfolder: the worktree sweep still finds exactly one run"
count="$(run_py <<'EOF'
boot = load_lib_module("_bootstrap")
print(len(list(boot.iter_worktree_run_records(repo))))
EOF
)"
check "1" "$count"

it "evidence-journal reads the journaled checks back"
out="$(rr evidence-journal "$REPO" done-run)"
has '"evidence_checked"' "$out"

it "a confirmed check leaves the predicate alone"
fx gh-graphql-clean.json
rr check-deliverable done-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check '"confirmed"' "$(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['result']")"
check "$BEFORE" "$(predicate_of done-run)"

it "a confirmed re-check keeps the first confirmation time"
FIRST="$(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['confirmed_at']")"
sleep 1
rr check-deliverable done-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check "$FIRST" "$(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['confirmed_at']")"

it "a confirmed deliverable cannot finish a run whose steps are not terminal"
make_run open-run no >/dev/null
OPEN_BEFORE="$(predicate_of open-run)"
rr check-deliverable open-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check "false $OPEN_BEFORE" "$(field open-run "rec['exit_predicate_result']['met']") $(predicate_of open-run)"
fx gh-graphql-pr97-real.json

it "a run id with a slash still gets a real merged verdict, not unknown"
make_run feat/slash-run yes >/dev/null
rr check-deliverable feat/slash-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check '"refuted"' "$(field feat/slash-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['result']")"
it "the slash run journals under its slug"
has '"evidence_checked"' "$(cat "${REPO}/.claude/auto/journal/feat-slash-run.jsonl" 2>/dev/null)"

it "a non-driving session is refused before any checker runs"
: > "$CALLS"
CLAUDE_CODE_SESSION_ID="sess-stranger" rr check-deliverable done-run merged --ref shawnroos/shrimpshack#97 >"${WORK}/out" 2>&1
CODE=$?
check "1" "$CODE"
it "the refusal names the driving-session rule"
has "driving session" "$(cat "${WORK}/out")"
it "the refused call runs no gh and writes no evidence or journal line"
check "0 \"confirmed\" 3" "$(grep -c '^gh ' "$CALLS") $(field done-run "rec['task_evidence']['merged']['shawnroos/shrimpshack#97']['result']") $(wc -l < "$JOURNAL" | tr -d ' ')"

it "a call with no session id is refused with exit 2"
env -u CLAUDE_CODE_SESSION_ID "$PY" "$RR" check-deliverable done-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check "2" "$?"

it "a run with no driving session refuses every caller"
run_py <<'EOF' >/dev/null
rr = load_lib_module("run_record")
rr.init_run_record(repo, "orphan-run", backend="native", steps=[{"id": "s1"}], loop_phase="work")
EOF
rr check-deliverable orphan-run merged --ref shawnroos/shrimpshack#97 >/dev/null 2>&1
check "1" "$?"

it "an unknown deliverable is a usage error"
rr check-deliverable done-run shipped --ref x >/dev/null 2>&1
check "2" "$?"

it "a missing reference is a usage error"
rr check-deliverable done-run merged >/dev/null 2>&1
check "2" "$?"

it "a reference with spaces is refused"
rr check-deliverable done-run merged --ref "a b" >/dev/null 2>&1
check "2" "$?"

it "the verb never takes a result as an argument"
rr check-deliverable done-run merged --ref shawnroos/shrimpshack#97 --result confirmed >/dev/null 2>&1
check "2" "$?"

it "the evidence block survives upgrade and downgrade untouched, including a key named like a format term"
rt="$(run_py <<'EOF'
import copy
fc = load_lib_module("format_compat")
ok = True
for old, new in fc._KEY_MAP.items():
    block = {"merged": {old: {"result": "refuted"}, new: {"fields": {old: 1, new: 2}}}}
    rec = {"run_id": "r", "task_evidence": copy.deepcopy(block)}
    ok = ok and fc.upgrade_run_record(copy.deepcopy(rec))["task_evidence"] == block
    ok = ok and fc.downgrade_run_record(copy.deepcopy(rec))["task_evidence"] == block
print(ok and bool(fc._KEY_MAP))
EOF
)"
check "True" "$rt"

it "the predicate never reads the evidence block"
check "0" "$(grep -c 'task_evidence' "${AUTO_ROOT}/lib/run_record_predicate.py")"

it "loading the evidence checker never loads run_record or programme"
topo="$(run_py <<'EOF'
load_lib_module("programme_evidence")
print(sorted(m for m in ("run_record", "programme") if m in sys.modules))
EOF
)"
check "[]" "$topo"

it "loading the task-run evidence module never loads the run_record facade or programme"
topo="$(run_py <<'EOF'
load_lib_module("run_record_evidence")
print(sorted(m for m in ("run_record", "programme") if m in sys.modules))
EOF
)"
check "[]" "$topo"

it "loading run_record does not load the evidence checker until a check runs"
topo="$(run_py <<'EOF'
load_lib_module("run_record")
print(sorted(m for m in ("programme_evidence", "programme_record", "programme") if m in sys.modules))
EOF
)"
check "[]" "$topo"

echo ""
echo "task-run-evidence.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPERS="${AUTO_ROOT}/tests/helpers"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-evidence.test.sh"

WORK="$(mktemp -d -t auto-programme-evidence.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

KEY="lin_api_FAKEKEY0000000000000000000000000000"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO GH_TOKEN GITHUB_TOKEN LINEAR_API_KEY 2>/dev/null || true
printf 'export LINEAR_API_KEY="%s"\nOTHER_SECRET=other-value-123\n' "$KEY" > "$CLAUDE_AUTO_SECRETS_FILE"

FIXTURES="${HELPERS}/fixtures/evidence"
CALLS="${WORK}/calls.log"
FAKES="${WORK}/fakes"
NOGH="${WORK}/nogh"
BOARDS="${WORK}/boards"
mkdir -p "$FAKES" "$NOGH" "$BOARDS" "${WORK}/fx"
cp -f "${HELPERS}/fake-gh.sh" "${FAKES}/gh"
cp -f "${HELPERS}/fake-curl.sh" "${FAKES}/curl"
cp -f "${HELPERS}/fake-curl.sh" "${NOGH}/curl"
cp -f "${HELPERS}/fake-board.sh" "${BOARDS}/board"
BASE_PATH="/usr/bin:/bin"
export PATH="${FAKES}:${BASE_PATH}"
fx() {
  for dir in "$FAKES" "$NOGH" "$BOARDS"; do
    {
      printf 'FAKE_CALLS=%s\nFAKE_FIXTURES=%s\n' "$CALLS" "$FIXTURES"
      printf 'FAKE_GH_VIEW=%s\nFAKE_GH_GRAPHQL=%s\n' "${FIXTURES}/gh-view-merged.json" "${FIXTURES}/gh-graphql-clean.json"
      for kv in "$@"; do printf '%s\n' "$kv"; done
    } > "${dir}/fake.env"
  done
}
fx
: > "$CALLS"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys, datetime
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def ago(seconds):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")
$(cat)
PYEOF
}

variant() {
  run_py "$1" "$2" "$3" <<'EOF'
src, dst, expr = args
g = json.load(open(src))
pr = g.get("data", {}).get("repository", {}).get("pullRequest") if "data" in g else None
exec(expr)
json.dump(g, open(dst, "w"))
EOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
items = prog["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
path = core.run_record_path(ph.home_path(run), run)
with open(path) as fh:
    rec = json.load(fh)
items = rec["programme"]["items"]
exec(expr)
with open(path, "w") as fh:
    json.dump(rec, fh)
EOF
}

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

predicate() {
  run_py "$RUN" <<'EOF'
pp = load_lib_module("programme_predicate")
print(json.dumps(pp.compute(record(args[0])), sort_keys=True))
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

result_of() { field "items['$1']['deliverables']['$2']['result']"; }

prog add-item linear:AI-753 --kind evals_or_docs --title "Docs fix" --pane p1
prog add-item linear:AI-9 --kind evals_or_docs --title "Second"
prog add-item herdr:w2-p4 --kind evals_or_docs --title "No issue"
prog claim --run "$RUN" --item linear:AI-753 --deliverable merged --ref shawnroos/shrimpshack#97

it "the verbs are listed by describe"
prog describe
has '"check-deliverable"' "$OUT"
has '"validate"' "$OUT"

it "every check green on the merged head, merged by a worker, no pin: confirmed"
: > "$CALLS"
prog check-deliverable linear:AI-753 merged
check "0 \"confirmed\"" "$CODE $(result_of linear:AI-753 merged)"

it "the reference comes from the newest claim"
check '"shawnroos/shrimpshack#97"' "$(field "items['linear:AI-753']['deliverables']['merged']['ref']")"

it "parsed fields are stored"
check '["a9fa84f4fb57a66039745e916632b0cdcd33a7dd", 0, "MERGED"]' \
  "$(field "[items['linear:AI-753']['deliverables']['merged']['fields'][k] for k in ('merge_commit', 'unresolved_threads', 'state')]")"

it "the check is journaled"
has '"result": "confirmed"' "$(journal_last evidence_checked)"

it "gh is called with pr view and a GraphQL thread read"
has "gh pr view 97 --repo shawnroos/shrimpshack" "$(cat "$CALLS")"
has "gh api graphql" "$(cat "$CALLS")"
has "reviewThreads(first:100)" "$(cat "$CALLS")"

variant "${FIXTURES}/gh-graphql-clean.json" "${WORK}/fx/thread.json" \
  'pr["reviewThreads"] = {"totalCount": 1, "nodes": [{"isResolved": False}]}'
it "AE4: merged with 1 unresolved thread is refuted"
fx FAKE_GH_GRAPHQL="${WORK}/fx/thread.json"
prog check-deliverable linear:AI-753 merged
fx
check "0 \"refuted\"" "$CODE $(result_of linear:AI-753 merged)"

it "AE4: the deliverable stays open and the claim is journaled unconfirmed"
J="$(journal_last evidence_checked)"
has '"claim": "unconfirmed"' "$J"
has "1 unresolved review threads" "$J"
check '"open"' "$(field "load_lib_module('programme_predicate').effective_state(items['linear:AI-753'])")"

variant "${FIXTURES}/gh-graphql-clean.json" "${WORK}/fx/cancelled.json" \
  'pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"].append({"__typename": "CheckRun", "name": "e2e", "status": "COMPLETED", "conclusion": "CANCELLED", "isRequired": False}); pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["totalCount"] = 3'
it "a check CANCELLED on the merged head is refuted"
fx FAKE_GH_GRAPHQL="${WORK}/fx/cancelled.json"
prog check-deliverable linear:AI-753 merged
fx
check '"refuted"' "$(result_of linear:AI-753 merged)"
has "e2e CANCELLED" "$(journal_last evidence_checked)"

it "a merged PR with no check run on the merged head (real PR #97 shape) is refuted"
fx FAKE_GH_GRAPHQL="${FIXTURES}/gh-graphql-pr97-real.json"
prog check-deliverable linear:AI-753 merged
fx
check '"refuted"' "$(result_of linear:AI-753 merged)"
has "no check run succeeded" "$(journal_last evidence_checked)"

variant "${FIXTURES}/gh-graphql-clean.json" "${WORK}/fx/required.json" \
  'pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"][0]["isRequired"] = False; pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"].append({"__typename": "StatusContext", "context": "deploy", "state": "PENDING", "isRequired": True}); pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["totalCount"] = 3'
it "a required check still pending on the merged head is unknown, not confirmed"
fx FAKE_GH_GRAPHQL="${WORK}/fx/required.json"
prog check-deliverable linear:AI-753 merged
fx
check '"unknown"' "$(result_of linear:AI-753 merged)"

variant "${FIXTURES}/gh-graphql-clean.json" "${WORK}/fx/manythreads.json" \
  'pr["reviewThreads"] = {"totalCount": 150, "nodes": [{"isResolved": True}] * 100}'
it "review threads past the first page are unknown"
prog check-deliverable linear:AI-753 merged
fx FAKE_GH_GRAPHQL="${WORK}/fx/manythreads.json"
prog check-deliverable linear:AI-753 merged
fx
check '"unknown"' "$(result_of linear:AI-753 merged)"

it "gh exits 0 with empty output: unknown"
prog check-deliverable linear:AI-753 merged
fx FAKE_GH_EMPTY=1
prog check-deliverable linear:AI-753 merged
fx
check "0 \"unknown\"" "$CODE $(result_of linear:AI-753 merged)"

it "one unknown does not set the item waiting"
check '["open", 1]' "$(field "[items['linear:AI-753']['state'], items['linear:AI-753']['deliverables']['merged']['unknown_streak']]")"

it "a definite result resets the unknown count"
prog check-deliverable linear:AI-753 merged
check "0" "$(field "items['linear:AI-753']['deliverables']['merged']['unknown_streak']")"

it "gh refused for authentication (real 401 shape): unknown"
fx FAKE_GH_EXIT=1
prog check-deliverable linear:AI-753 merged
fx
check '"unknown"' "$(result_of linear:AI-753 merged)"
has "HTTP 401" "$(journal_last evidence_checked)"
prog check-deliverable linear:AI-753 merged

it "gh not on PATH: unknown, not refuted"
PATH="${NOGH}:${BASE_PATH}" prog check-deliverable linear:AI-753 merged
check '"unknown"' "$(result_of linear:AI-753 merged)"
has "gh is not on PATH" "$(journal_last evidence_checked)"

it "gh times out: unknown"
fx FAKE_GH_SLEEP=3
CLAUDE_AUTO_CHECK_TIMEOUT_SECONDS=1 prog check-deliverable linear:AI-753 merged
fx
check '"unknown"' "$(result_of linear:AI-753 merged)"
has "timed out" "$(journal_last evidence_checked)"

it "two unknowns in a row: the item waits on the system"
check '{"reporter": null, "watcher": "retry-linear-AI-753", "who": "system"}' "$(field "items['linear:AI-753']['waiting_on']")"
check '"waiting"' "$(field "items['linear:AI-753']['state']")"

it "two unknowns in a row: a retry watcher is recorded and queued for arming"
check '["linear:AI-753", "merged"]' "$(field "[prog['watchers']['retry-linear-AI-753']['item'], prog['watchers']['retry-linear-AI-753']['retry']['deliverable']]")"
check '["arm_retry_watcher"]' "$(field "[q['action'] for q in prog['working_model']['queue'] if q['item'] == 'linear:AI-753']")"

it "the predicate holds the stop until the retry watcher is armed"
P="$(predicate)"
has '"kind": "queued_action"' "$P"
has '"kind": "unwatched_wait"' "$P"

it "a definite result clears the system wait and the queued arming"
prog check-deliverable linear:AI-753 merged
check '["open", null, []]' "$(field "[items['linear:AI-753']['state'], items['linear:AI-753']['waiting_on'], [q for q in prog['working_model']['queue'] if q['item'] == 'linear:AI-753']]")"

it "a journaled PM pin that differs from the merged head is refuted"
run_py "$RUN" <<'EOF'
pj.append(args[0], "merge_pinned", "sess-pm", {"item": "linear:AI-753", "ref": "shawnroos/shrimpshack#97", "head": "0" * 40})
EOF
prog check-deliverable linear:AI-753 merged
check '"refuted"' "$(result_of linear:AI-753 merged)"
has "is not the pinned head" "$(journal_last evidence_checked)"

it "a journaled PM pin equal to the merged head is confirmed"
run_py "$RUN" <<'EOF'
pj.append(args[0], "merge_pinned", "sess-pm", {"item": "linear:AI-753", "ref": "shawnroos/shrimpshack#97", "head": "9e265cc6c301071b75921e4a73121701f1b5cebd"})
EOF
prog check-deliverable linear:AI-753 merged
check '"confirmed"' "$(result_of linear:AI-753 merged)"

it "recorded: the target beyond a page of other-team issues is found"
: > "$CALLS"
prog check-deliverable linear:AI-753 recorded
check "0 \"confirmed\"" "$CODE $(result_of linear:AI-753 recorded)"

it "recorded: the team and number filters are inside the query, with a Float number"
C="$(cat "$CALLS")"
has 'issues(first:5,filter:{team:{key:{eq:$team}},number:{eq:$number}})' "$C"
has '$number:Float!' "$C"
has '"number": 753.0' "$C"

it "recorded: the root-cause comment filter is inside the query"
has 'comments(first:50,filter:' "$C"

it "recorded: the root-cause author is stored"
check '"Shawn Roos"' "$(field "items['linear:AI-753']['deliverables']['recorded']['fields']['root_cause_comment']['author']")"

it "with both deliverables confirmed the item is done and done_at is set"
check '["done", true]' "$(field "[load_lib_module('programme_predicate').effective_state(items['linear:AI-753']), bool(items['linear:AI-753']['done_at'])]")"

it "the credential reaches curl through its environment"
has "LINEAR_API_KEY" "$(grep '^curl-env' "$CALLS")"
has "curl-auth-on-stdin" "$C"

it "the credential never appears in any argv, the parent shell's included"
has "curl-parent /bin/sh -c" "$(cat "$CALLS")"
lacks "$KEY" "$(grep -v '^curl-env' "$CALLS")"

it "the child environment is minimal"
lacks "CLAUDE_AUTO_DATA_DIR" "$(grep '^curl-env' "$CALLS")"
lacks "OTHER_SECRET" "$(grep '^curl-env' "$CALLS")"
lacks "HOME" "$(grep '^curl-env' "$CALLS" | tr ' ' '\n' | grep -x HOME)"

it "gh never receives the Linear credential"
lacks "LINEAR_API_KEY" "$(grep '^gh-env' "$CALLS" || true)"
prog check-deliverable linear:AI-753 merged
lacks "LINEAR_API_KEY" "$(grep '^gh-env' "$CALLS")"

it "a key echoed back by the child is scrubbed from stored output and the journal"
fx FAKE_CURL_LEAK=1
prog check-deliverable linear:AI-753 recorded
fx
check '"unknown"' "$(result_of linear:AI-753 recorded)"
has "[redacted]" "$(field "items['linear:AI-753']['deliverables']['recorded']['note']")"
lacks "$KEY" "$(grep -r -- "$KEY" "$HOME_DIR")"
has "redacted" "$(grep -r -- "redacted" "$HOME_DIR")"
lacks "$KEY" "$OUT"

variant "${FIXTURES}/linear-hit.json" "${WORK}/fx/started.json" \
  'g["data"]["issues"]["nodes"][0]["state"] = {"name": "In Progress", "type": "started"}'
it "recorded: an issue not in a done state is refuted"
fx FAKE_LINEAR_HIT="${WORK}/fx/started.json"
prog check-deliverable linear:AI-753 recorded
fx
check '"refuted"' "$(result_of linear:AI-753 recorded)"

variant "${FIXTURES}/linear-hit.json" "${WORK}/fx/bot.json" \
  'g["data"]["issues"]["nodes"][0]["comments"]["nodes"][0]["botActor"] = {"id": "b1", "name": "worker"}'
it "recorded: a root-cause comment only from a bot account is refuted"
fx FAKE_LINEAR_HIT="${WORK}/fx/bot.json"
prog check-deliverable linear:AI-753 recorded
fx
check '"refuted"' "$(result_of linear:AI-753 recorded)"
has '"bot_root_cause_comments": 1' "$(journal_last evidence_checked)"

it "recorded: the issue key comes from a linear item id"
prog check-deliverable linear:AI-9 recorded
check "0 \"unknown\"" "$CODE $(result_of linear:AI-9 recorded)"
has "Linear has no issue AI-9" "$(journal_last evidence_checked)"

it "recorded: a board that cannot read issues falls back to the direct read"
: > "$CALLS"
PATH="${BOARDS}:${FAKES}:${BASE_PATH}" prog check-deliverable linear:AI-753 recorded
check '"confirmed"' "$(result_of linear:AI-753 recorded)"
has "board linear issue AI-753 --json" "$(cat "$CALLS")"
has "curl" "$(cat "$CALLS")"

variant "${FIXTURES}/linear-hit.json" "${WORK}/fx/board.json" 'g = g["data"]["issues"]["nodes"][0]'
it "recorded: a board issue read is used without a direct read"
: > "$CALLS"
fx FAKE_BOARD_FILE="${WORK}/fx/board.json"
PATH="${BOARDS}:${FAKES}:${BASE_PATH}" prog check-deliverable linear:AI-753 recorded
fx
check '"board"' "$(field "items['linear:AI-753']['deliverables']['recorded']['fields']['read_by']")"
lacks "curl" "$(cat "$CALLS")"

it "recorded: no credential and no board is unknown"
printf 'OTHER_SECRET=other-value-123\n' > "${WORK}/nokey"
CLAUDE_AUTO_SECRETS_FILE="${WORK}/nokey" prog check-deliverable linear:AI-753 recorded
check '"unknown"' "$(result_of linear:AI-753 recorded)"

it "a deliverable the item does not require is refused"
prog check-deliverable linear:AI-753 flagged
check 1 "$CODE"

it "an item with no claim, no --ref and no issue key is refused"
prog check-deliverable herdr:w2-p4 merged
check 1 "$CODE"
has "pass --ref" "$OUT"

it "--ref supplies the reference"
prog check-deliverable herdr:w2-p4 merged --ref https://github.com/shawnroos/shrimpshack/pull/97
check "0 \"confirmed\"" "$CODE $(result_of herdr:w2-p4 merged)"

it "no verb accepts a result"
prog check-deliverable herdr:w2-p4 merged confirmed
check 2 "$CODE"

it "a session that does not drive the programme is refused before any check runs"
: > "$CALLS"
CLAUDE_CODE_SESSION_ID=sess-other prog check-deliverable linear:AI-753 merged --run "$RUN"
check 1 "$CODE"
check "" "$(cat "$CALLS")"

prog add-item linear:AI-1 --kind evals_or_docs --title "Done two days ago"
prog add-item linear:AI-2 --kind evals_or_docs --title "Done eight days ago"
prog add-item linear:AI-3 --kind flagged_code --title "Flag rolled out"
edit '
def conf(age, ref):
    return {"result": "confirmed", "ref": ref, "checked_at": ago(age), "confirmed_at": ago(age), "fields": {}}
pr = "shawnroos/shrimpshack#97"
for key, age in (("linear:AI-1", 2 * 86400), ("linear:AI-2", 8 * 86400)):
    items[key]["deliverables"] = {"merged": conf(age, pr), "recorded": conf(age, key.split(":")[1])}
    items[key]["done_at"] = ago(age)
items["linear:AI-3"]["deliverables"] = {"merged": conf(30, pr), "recorded": conf(30, "AI-3"),
    "flagged": conf(2 * 86400, "my-flag"), "verified": conf(2 * 86400, "trace-1")}
items["linear:AI-3"]["done_at"] = ago(2 * 86400)
'

variant "${FIXTURES}/gh-view-merged.json" "${WORK}/fx/closed.json" 'g["state"] = "CLOSED"; g["mergeCommit"] = None'
it "validate: a confirmed merged entry now refuted, on an item done 2 days ago, is refuted"
: > "$CALLS"
fx FAKE_GH_VIEW="${WORK}/fx/closed.json"
prog validate
fx
check "0 \"refuted\"" "$CODE $(result_of linear:AI-1 merged)"

it "validate: the refuted item reopens with a journal entry"
check '["open", null]' "$(field "[items['linear:AI-1']['state'], items['linear:AI-1']['done_at']]")"
J="$(journal_last evidence_refuted)"
has '"item": "linear:AI-1"' "$J"
has '"reopened": true' "$J"
has '"refuted"' "$(journal_last validate_pass)"

it "validate: an unknown re-check does not demote confirmed evidence"
check '"confirmed"' "$(result_of linear:AI-1 recorded)"

it "validate: the same refutation on an item done 8 days ago is not re-checked"
check '"confirmed"' "$(result_of linear:AI-2 merged)"
check "1" "$(grep -c '^gh pr view' "$CALLS")"
has '{"item": "linear:AI-2", "why": "final"}' "$(journal_last validate_pass)"

it "validate: a done item's flagged evidence is frozen and not re-checked"
J="$(journal_last validate_pass)"
has '{"deliverable": "flagged", "item": "linear:AI-3", "why": "frozen"}' "$J"
check '"confirmed"' "$(result_of linear:AI-3 flagged)"

it "validate: evidence checked within one cadence is not re-checked"
has '{"deliverable": "merged", "item": "linear:AI-3", "why": "fresh"}' "$J"

it "validate: a verified re-check with no adopted lookup is unknown and keeps the evidence"
has '{"deliverable": "verified", "item": "linear:AI-3", "result": "unknown"}' "$J"
check '"confirmed"' "$(result_of linear:AI-3 verified)"

it "validate: an open item's stale confirmed evidence is re-checked"
edit 'items["linear:AI-9"]["deliverables"]["merged"] = {"result": "confirmed", "ref": "shawnroos/shrimpshack#97", "checked_at": ago(7200), "confirmed_at": ago(7200), "fields": {}}'
: > "$CALLS"
prog validate
check "1" "$(grep -c '^gh pr view' "$CALLS")"
check '"confirmed"' "$(result_of linear:AI-9 merged)"

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-evidence.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

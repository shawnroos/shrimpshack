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

echo "programme-readiness.test.sh"

WORK="$(mktemp -d -t auto-programme-readiness.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO GH_TOKEN GITHUB_TOKEN LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FIXTURES="${HELPERS}/fixtures/evidence"
READY="${FIXTURES}/gh-graphql-open-ready.json"
CALLS="${WORK}/calls.log"
FAKES="${WORK}/fakes"
mkdir -p "$FAKES" "${WORK}/fx"
cp -f "${HELPERS}/fake-gh.sh" "${FAKES}/gh"
export PATH="${FAKES}:/usr/bin:/bin"
fx() {
  {
    printf 'FAKE_CALLS=%s\nFAKE_GH_VIEW=%s\nFAKE_GH_GRAPHQL=%s\n' "$CALLS" "${FIXTURES}/gh-view-merged.json" "$READY"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "${FAKES}/fake.env"
}
fx

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
$(cat)
PYEOF
}

variant() {
  run_py "$READY" "${WORK}/fx/$1.json" "$2" <<'EOF'
src, dst, expr = args
g = json.load(open(src))
pr = g["data"]["repository"]["pullRequest"]
c = pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]
exec(expr)
c["totalCount"] = len(c["nodes"])
json.dump(g, open(dst, "w"))
EOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

journal_rows() {
  run_py "$RUN" "$1" <<'EOF'
print(json.dumps([r["payload"] for r in pj.read(args[0]) if r["kind"] == args[1]], sort_keys=True))
EOF
}

OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
ready_of() { run_py "$1" <<'EOF'
print(json.loads(args[0])["result"])
EOF
}
readiness() {
  fx FAKE_GH_GRAPHQL="${WORK}/fx/$1.json"
  prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
  fx
}

prog add-item linear:AI-1109 --kind evals_or_docs --title "Editor places missed crop"

it "the verb is listed by describe"
prog describe
has '"check-mergeable"' "$OUT"

it "CLEAN, approved, not draft, required checks met, no open threads: ready"
prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
check "0 ready" "$CODE $(ready_of "$OUT")"

it "the facts name the base branch, head, title and URL"
has '"base": "main"' "$OUT"
has '"head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$OUT"
has '"title": "Editor places missed crop"' "$OUT"
has 'pull/120' "$OUT"
READY_PRINT="$(run_py "$OUT" <<'EOF'
print(json.loads(args[0])["fingerprint"])
EOF
)"

it "a read without --pin writes no journal row"
check "[]" "$(journal_rows merge_pinned)"

it "the same facts give the same fingerprint"
prog check-mergeable https://github.com/shawnroos/shrimpshack/pull/120 --run "$RUN"
has "\"fingerprint\": \"${READY_PRINT}\"" "$OUT"

variant blocked "pr['mergeStateStatus'] = 'BLOCKED'; c['nodes'][0]['conclusion'] = 'FAILURE'"
it "AE8: BLOCKED with a failed required check is not ready and names the gate"
readiness blocked
check "not_ready" "$(ready_of "$OUT")"
has "BLOCKED" "$OUT"
has "plugin tests" "$OUT"

it "a changed check outcome changes the fingerprint"
lacks "\"fingerprint\": \"${READY_PRINT}\"" "$OUT"

variant retarget "pr['baseRefName'] = 'release'"
it "a PR retargeted to another base changes the fingerprint"
readiness retarget
check "ready" "$(ready_of "$OUT")"
lacks "\"fingerprint\": \"${READY_PRINT}\"" "$OUT"

variant draft "pr['isDraft'] = True; pr['mergeStateStatus'] = 'DRAFT'"
it "a draft PR is not ready"
readiness draft
check "not_ready" "$(ready_of "$OUT")"
has "draft" "$OUT"

variant thread "pr['reviewThreads'] = {'totalCount': 2, 'nodes': [{'isResolved': True}, {'isResolved': False}]}"
it "an unresolved review thread makes it not ready and changes the fingerprint"
readiness thread
check "not_ready" "$(ready_of "$OUT")"
has "1 unresolved review threads" "$OUT"
lacks "\"fingerprint\": \"${READY_PRINT}\"" "$OUT"

variant review "pr['reviewDecision'] = 'CHANGES_REQUESTED'"
it "changes requested is not ready"
readiness review
check "not_ready" "$(ready_of "$OUT")"
has "CHANGES_REQUESTED" "$OUT"

variant pending "c['nodes'][0]['status'] = 'IN_PROGRESS'; c['nodes'][0]['conclusion'] = None"
it "a required check still running is not ready"
readiness pending
check "not_ready" "$(ready_of "$OUT")"
has "plugin tests" "$OUT"

variant unknownstate "pr['mergeable'] = 'UNKNOWN'; pr['mergeStateStatus'] = 'UNKNOWN'"
it "AE11: GitHub has not computed the merge state yet: unknown"
readiness unknownstate
check "unknown" "$(ready_of "$OUT")"

variant nullstate "pr['mergeStateStatus'] = None"
it "AE11: a null merge state is unknown"
readiness nullstate
check "unknown" "$(ready_of "$OUT")"

variant nochecks "c['nodes'] = []"
it "AE11: an empty check list is unknown"
readiness nochecks
check "unknown" "$(ready_of "$OUT")"

it "AE11: gh failing is unknown"
fx FAKE_GH_EXIT=1
prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
fx
check "unknown" "$(ready_of "$OUT")"

variant merged "pr['state'] = 'MERGED'"
it "an already merged PR is not ready"
readiness merged
check "not_ready" "$(ready_of "$OUT")"
has "already merged" "$OUT"

it "a bad reference is refused"
prog check-mergeable not-a-pr --run "$RUN"
check "1" "$CODE"

it "--pin without an item is refused"
prog check-mergeable shawnroos/shrimpshack#120 --pin --run "$RUN"
lacks "\"result\": \"ready\"" "$OUT"
check "[]" "$(journal_rows merge_pinned)"

it "--pin with an item writes one merge_pinned row with the canonical ref and head"
prog check-mergeable https://github.com/shawnroos/shrimpshack/pull/120 --pin linear:AI-1109 --run "$RUN"
check "0 ready" "$CODE $(ready_of "$OUT")"
check '[{"head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "item": "linear:AI-1109", "ref": "shawnroos/shrimpshack#120"}]' \
  "$(journal_rows merge_pinned | "$PY" -c 'import json,sys; print(json.dumps([{k: r[k] for k in ("head","item","ref")} for r in json.load(sys.stdin)], sort_keys=True))')"

it "the pin applies to a merged check whose claim uses the owner/repo#N form"
PIN="$(run_py "$RUN" <<'EOF'
ev = load_lib_module("programme_evidence")
print(ev._pin_for(args[0], "linear:AI-1109", "shawnroos/shrimpshack#120"))
EOF
)"
check "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$PIN"

it "the pin also applies when the claim uses the URL form"
PIN="$(run_py "$RUN" <<'EOF'
ev = load_lib_module("programme_evidence")
print(ev._pin_for(args[0], "linear:AI-1109", "https://github.com/shawnroos/shrimpshack/pull/120"))
EOF
)"
check "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$PIN"

it "--pin does not write when the PR is not ready"
fx FAKE_GH_GRAPHQL="${WORK}/fx/blocked.json"
prog check-mergeable shawnroos/shrimpshack#120 --pin linear:AI-1109 --run "$RUN"
fx
check "1" "$(journal_rows merge_pinned | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"

variant noci "c['nodes'] = []; c['totalCount'] = 0"
it "a head with no checks in a repo with CI workflows is unknown"
fx FAKE_GH_GRAPHQL="${WORK}/fx/noci.json" FAKE_GH_WORKFLOWS=1
prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
check "unknown" "$(ready_of "$OUT")"
has "no checks to read" "$OUT"

it "a head with no checks in a repo with no CI is ready and says so"
fx FAKE_GH_GRAPHQL="${WORK}/fx/noci.json" FAKE_GH_WORKFLOWS=0
prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
check "ready" "$(ready_of "$OUT")"
has '"ci": "none"' "$OUT"

it "a repo with no CI can pin the head"
prog check-mergeable shawnroos/shrimpshack#120 --pin linear:AI-1109 --run "$RUN"
check 0 "$CODE"
has "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$(journal_rows merge_pinned)"
fx

run_py "$RUN" <<'EOF' >/dev/null
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
programme_records.edit(args[0], "prog.setdefault('remit', {})['repos'] = [{'github': 'shawnroos/other'}]", globals())
EOF
it "a PR outside the remit repos is refused"
prog check-mergeable shawnroos/shrimpshack#120 --run "$RUN"
check "unknown" "$(ready_of "$OUT")"
has "outside the remit" "$OUT"

echo "programme-readiness.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

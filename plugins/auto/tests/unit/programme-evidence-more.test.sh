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

echo "programme-evidence-more.test.sh"

WORK="$(mktemp -d -t auto-programme-evidence-more.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LDKEY="api-FAKELDTOKEN0000000000000000000000"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO GH_TOKEN GITHUB_TOKEN LINEAR_API_KEY LD_ACCESS_TOKEN BRAINTRUST_API_KEY 2>/dev/null || true
printf 'export LD_ACCESS_TOKEN="%s"\nOTHER_SECRET=other-value-123\n' "$LDKEY" > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"

FIXTURES="${HELPERS}/fixtures/evidence"
CALLS="${WORK}/calls.log"
FAKES="${WORK}/fakes"
mkdir -p "$FAKES" "${WORK}/fx"
cp -f "${HELPERS}/fake-ldcli.sh" "${FAKES}/ldcli"
cp -f "${HELPERS}/fake-npm.sh" "${FAKES}/npm"
cp -f "${HELPERS}/fake-bt.sh" "${FAKES}/bt"
cp -f "${HELPERS}/fake-trace.sh" "${FAKES}/trace-cli"
cp -f "${HELPERS}/fake-trace.sh" "${FAKES}/worker-lookup"
BASE_PATH="/usr/bin:/bin"
export PATH="${FAKES}:${BASE_PATH}"

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

flag_variant() {
  run_py "${FIXTURES}/ld-flag-relight-real.json" "${WORK}/fx/$1.json" "$2" <<'EOF'
src, dst, expr = args
g = json.load(open(src))
envs = g["environments"]
exec(expr)
json.dump(g, open(dst, "w"))
EOF
}

flag_variant dark 'envs["production"].update(on=False, rules=[]); envs["stage"]["rules"] = []'
flag_variant prodon 'envs["production"].update(on=True, rules=[], fallthrough={"variation": 0}); envs["stage"]["rules"] = []'
flag_variant rollout 'envs["production"].update(on=False, rules=[]); envs["stage"].update(rules=[], fallthrough={"rollout": {"variations": [{"variation": 0, "weight": 50000}, {"variation": 1, "weight": 50000}]}})'
flag_variant noprod 'del envs["production"]'
flag_variant devoff 'envs["production"].update(on=False, rules=[]); envs["stage"]["rules"] = []; envs["development"]["on"] = False'
flag_variant swapped 'g["variations"] = list(reversed(g["variations"])); envs["production"].update(on=False, offVariation=0, rules=[]); envs["stage"].update(rules=[], fallthrough={"variation": 1}); envs["development"]["fallthrough"] = {"variation": 1}'

fx() {
  {
    printf 'FAKE_CALLS=%s\nFAKE_FIXTURES=%s\nFAKE_LD_TOKEN=%s\n' "$CALLS" "$FIXTURES" "$LDKEY"
    printf 'FAKE_LD_FLAG=%s\nFAKE_NPM_VIEW=%s\n' "${WORK}/fx/dark.json" "${FIXTURES}/npm-view-real.json"
    printf 'FAKE_DEPLOYED_SHA=%s\n' "${BUILD_SHA:-}"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "${FAKES}/fake.env"
}

git_in() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }
ORIGIN="${WORK}/origin.git"
SEED="${WORK}/seed"
REPO="${WORK}/repo"
git init -q --bare "$ORIGIN"
git init -q "$SEED"
git_in "$SEED" commit -q --allow-empty -m old
OLD_SHA="$(git_in "$SEED" rev-parse HEAD)"
git_in "$SEED" commit -q --allow-empty -m merge
MERGE_SHA="$(git_in "$SEED" rev-parse HEAD)"
git_in "$SEED" commit -q --allow-empty -m later
LATER_SHA="$(git_in "$SEED" rev-parse HEAD)"
git_in "$SEED" push -q "$ORIGIN" HEAD:refs/heads/main 2>/dev/null
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
BUILD_SHA="$LATER_SHA"
fx
: > "$CALLS"

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

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
prog = rec["programme"]
items = prog["items"]
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

personal_checks() {
  run_py "$RUN" "$CLAUDE_AUTO_PERSONAL_PROTOCOL" "$1" "$2" <<'EOF'
run, path, repo, program = args
prog = load_lib_module("programme")
pp = load_lib_module("programme_protocol")
text = "yes, adopt the trace lookup for " + repo
row = pj.append_prompt(run, "sess-pm", text, "typed")
def adopt(entry):
    entry = dict(entry)
    entry["adoption"] = {"machine": "studio", "run_id": run, "prompt_id": row["prompt_id"], "quote": text,
                         "prompt_hash": prog.text_hash(row["payload"]["text"]), "hash": pp.content_hash(entry)}
    return entry
block = {"verified.lookup": adopt({"argv": [program, "show", "{id}"]}),
         "verified.deployed_sha": adopt({"argv": [program, "sha", "{id}", "{sha}"]})}
json.dump({"protocol_format": 1, "checks": {repo: block}}, open(path, "w"))
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
last_note() { field "items['$1']['deliverables']['$2']['note']"; }

prog add-item linear:AI-1 --kind flagged_code --title "Dark flag"
prog add-item linear:AI-2 --kind shared_package --title "Package bump"

it "flagged: prod off and stage and dev on (real flag shape, prod rule removed) is confirmed"
: > "$CALLS"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
check "0 \"confirmed\"" "$CODE $(result_of linear:AI-1 flagged)"

it "flagged: ldcli reads the named project and flag as JSON"
has "ldcli flags get --project default --flag wcs-ai-tool-relight -o json" "$(cat "$CALLS")"

it "flagged: the served value per environment is stored"
check '{"development": true, "production": false, "stage": true}' \
  "$(field "{e: v['served'] for e, v in items['linear:AI-1']['deliverables']['flagged']['fields']['environments'].items()}")"

it "flagged: the token reaches ldcli through its environment only"
has "ldcli-token ok" "$(cat "$CALLS")"
lacks "$LDKEY" "$(grep '^ldcli flags' "$CALLS")"
lacks "CLAUDE_AUTO" "$(grep '^ldcli-env' "$CALLS")"
lacks " HOME " "$(grep '^ldcli-env' "$CALLS")"

it "flagged: the token is never stored or journaled"
lacks "$LDKEY" "$(cat "${CLAUDE_AUTO_DATA_DIR}"/programmes/"$RUN"/* 2>/dev/null)"

it "flagged: a bare flag key reads the default project"
: > "$CALLS"
prog check-deliverable linear:AI-1 flagged --ref wcs-ai-tool-relight
has "--project default --flag wcs-ai-tool-relight" "$(cat "$CALLS")"

it "flagged: prod on, serving true to everyone, is refuted"
fx FAKE_LD_FLAG="${WORK}/fx/prodon.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"refuted"' "$(result_of linear:AI-1 flagged)"
has "production serves true" "$(journal_last evidence_checked)"

it "flagged: the real shape, prod off by fallthrough but a rule serving true, is refuted"
fx FAKE_LD_FLAG="${FIXTURES}/ld-flag-relight-real.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"refuted"' "$(result_of linear:AI-1 flagged)"
has "production has a rule or target serving true" "$(journal_last evidence_checked)"

it "flagged: dev off misses the dev bar"
fx FAKE_LD_FLAG="${WORK}/fx/devoff.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"refuted"' "$(result_of linear:AI-1 flagged)"
has "development serves false" "$(journal_last evidence_checked)"

it "flagged: values resolve through the flag's own variations, not by index"
fx FAKE_LD_FLAG="${WORK}/fx/swapped.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"confirmed"' "$(result_of linear:AI-1 flagged)"

it "flagged: a percentage rollout has no single served value: unknown"
fx FAKE_LD_FLAG="${WORK}/fx/rollout.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"unknown"' "$(result_of linear:AI-1 flagged)"
has "rollout" "$(last_note linear:AI-1 flagged)"

it "flagged: an environment missing from the read is unknown"
fx FAKE_LD_FLAG="${WORK}/fx/noprod.json"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
fx
check '"unknown"' "$(result_of linear:AI-1 flagged)"

it "flagged: a flag LaunchDarkly does not have (real not_found shape) is unknown"
fx FAKE_LD_MISSING=1
prog check-deliverable linear:AI-1 flagged --ref default/no-such-flag
fx
check '"unknown"' "$(result_of linear:AI-1 flagged)"
has "not_found" "$(last_note linear:AI-1 flagged)"

it "flagged: no token in the secrets file is unknown and ldcli never runs"
printf 'OTHER_SECRET=other-value-123\n' > "${WORK}/nokey"
: > "$CALLS"
CLAUDE_AUTO_SECRETS_FILE="${WORK}/nokey" prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
check '"unknown"' "$(result_of linear:AI-1 flagged)"
check "" "$(cat "$CALLS")"

it "flagged: a malformed reference is unknown"
prog check-deliverable linear:AI-1 flagged --ref 'a/b/c'
check '"unknown"' "$(result_of linear:AI-1 flagged)"

edit 'items["linear:AI-1"]["deliverables"]["merged"] = {"result": "confirmed", "ref": "acme/web#5", "checked_at": ago(60), "confirmed_at": ago(60), "fields": {"merge_commit": "'"$MERGE_SHA"'", "pr": "acme/web#5"}}'

it "verified: a trace-shaped claim with no adopted lookup command is unknown"
: > "$CALLS"
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check "0 \"unknown\"" "$CODE $(result_of linear:AI-1 verified)"
has "no adopted verified.lookup" "$(last_note linear:AI-1 verified)"
check "" "$(cat "$CALLS")"

it "verified: a lookup command only in a worker's working tree is not run"
mkdir -p "${REPO}/.claude"
printf '{"protocol_format": 1, "checks": {"verified.lookup": {"argv": ["worker-lookup", "show", "{id}"]}, "verified.deployed_sha": {"argv": ["worker-lookup", "sha", "{id}"]}}}\n' > "${REPO}/.claude/auto-protocol.json"
: > "$CALLS"
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"unknown"' "$(result_of linear:AI-1 verified)"
lacks "worker-lookup" "$(cat "$CALLS")"
rm -rf "${REPO}/.claude"

personal_checks acme/web trace-cli

it "verified: the build sha of the traced run contains the merge commit: confirmed"
: > "$CALLS"
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check "0 \"confirmed\"" "$CODE $(result_of linear:AI-1 verified)"

it "verified: the adopted commands run with the id and the merge sha filled in"
has "trace-cli show trace-abc123" "$(cat "$CALLS")"
has "trace-cli sha trace-abc123 ${MERGE_SHA}" "$(cat "$CALLS")"

it "verified: the build sha, merge commit and lookup are stored"
check "[\"${LATER_SHA}\", \"${MERGE_SHA}\", \"acme/web\"]" \
  "$(field "[items['linear:AI-1']['deliverables']['verified']['fields'][k] for k in ('build_sha', 'merge_commit', 'repo')]")"

it "verified: the lookup shows an older sha: refuted"
BUILD_SHA="$OLD_SHA" fx
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"refuted"' "$(result_of linear:AI-1 verified)"
has "does not contain the merge commit" "$(journal_last evidence_checked)"

it "verified: the merge commit itself is the build: confirmed"
BUILD_SHA="$MERGE_SHA" fx
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"confirmed"' "$(result_of linear:AI-1 verified)"

it "verified: a build sha the local clone does not have is unknown, never refuted"
BUILD_SHA="1111111111111111111111111111111111111111" fx
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"unknown"' "$(result_of linear:AI-1 verified)"

it "verified: no sha in the deployed-sha output is unknown"
BUILD_SHA="not-a-sha" fx
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"unknown"' "$(result_of linear:AI-1 verified)"
BUILD_SHA="$LATER_SHA" fx

it "verified: the lookup failing is unknown"
fx FAKE_TRACE_EXIT=3
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
fx
check '"unknown"' "$(result_of linear:AI-1 verified)"

it "verified: no repo clone named is unknown"
edit 'items["linear:AI-1"]["deliverables"]["verified"] = {"result": "unknown"}'
prog check-deliverable linear:AI-1 verified --ref trace-abc123
check '"unknown"' "$(result_of linear:AI-1 verified)"

it "verified: merged not yet confirmed is unknown"
edit 'items["linear:AI-1"]["deliverables"]["merged"]["result"] = "refuted"'
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"unknown"' "$(result_of linear:AI-1 verified)"
has "merged" "$(last_note linear:AI-1 verified)"
edit 'items["linear:AI-1"]["deliverables"]["merged"]["result"] = "confirmed"'

it "verified: the trace id recorded on a wait is the default reference"
edit 'items["linear:AI-1"]["waiting_on"] = {"who": "system", "watcher": None, "reporter": None, "trace_id": "trace-from-wait"}; items["linear:AI-1"]["deliverables"]["verified"] = {"result": "unknown"}'
: > "$CALLS"
prog check-deliverable linear:AI-1 verified --repo "$REPO"
has "trace-cli show trace-from-wait" "$(cat "$CALLS")"
edit 'items["linear:AI-1"]["waiting_on"] = None'

it "verified: the adopted commands get a minimal environment"
: > "$CALLS"
CLAUDE_AUTO_SNEAKY=1 prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
check '"confirmed"' "$(result_of linear:AI-1 verified)"
has "trace-env" "$(cat "$CALLS")"
lacks "CLAUDE_AUTO_SNEAKY" "$(grep '^trace-env' "$CALLS")"
lacks "LD_ACCESS_TOKEN" "$(grep '^trace-env' "$CALLS")"

prog record-tested-build linear:AI-2 --shasum 6a553d5b73b4fbe9bed59ec84c8ffd37cef9d910 --package @slateteams/scene-detect --version 0.2.0-ai-376.0

it "released: shasum match and an existing eval experiment is confirmed"
: > "$CALLS"
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/cue-ga-run --repo "$REPO"
check "0 \"confirmed\"" "$CODE $(result_of linear:AI-2 released)"

it "released: npm view reads the tested version's shasum from the repo"
has "npm view @slateteams/scene-detect@0.2.0-ai-376.0 dist.shasum dist.integrity version --json" "$(cat "$CALLS")"
check "npm-cwd $(cd "$REPO" && pwd -P)" "$(grep '^npm-cwd' "$CALLS")"
has "bt experiments view cue-ga-run --project ai-chat --json --no-input" "$(cat "$CALLS")"

it "released: the registry and tested shasums are stored"
check '["6a553d5b73b4fbe9bed59ec84c8ffd37cef9d910", "6a553d5b73b4fbe9bed59ec84c8ffd37cef9d910", "cue-ga-run"]' \
  "$(field "[items['linear:AI-2']['deliverables']['released']['fields'][k] for k in ('registry_shasum', 'tested_shasum', 'experiment')]")"

it "released: a shasum mismatch is refuted"
prog record-tested-build linear:AI-2 --shasum 0000000000000000000000000000000000000000 --package @slateteams/scene-detect --version 0.2.0-ai-376.0
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/cue-ga-run --repo "$REPO"
check '"refuted"' "$(result_of linear:AI-2 released)"
has "shasum" "$(journal_last evidence_checked)"

it "released: a shasum mismatch stays refuted when bt cannot be read"
fx FAKE_BT_NOAUTH=1
: > "$CALLS"
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/cue-ga-run --repo "$REPO"
fx
check '"refuted"' "$(result_of linear:AI-2 released)"
lacks "bt experiments" "$(cat "$CALLS")"
prog record-tested-build linear:AI-2 --shasum 6a553d5b73b4fbe9bed59ec84c8ffd37cef9d910 --package @slateteams/scene-detect --version 0.2.0-ai-376.0

it "released: a match with no experiment named and no waiver is refuted"
: > "$CALLS"
prog check-deliverable linear:AI-2 released --ref @slateteams/scene-detect@0.2.0-ai-376.0 --repo "$REPO"
check '"refuted"' "$(result_of linear:AI-2 released)"
has "no eval experiment and no active waiver" "$(journal_last evidence_checked)"
lacks "bt experiments" "$(cat "$CALLS")"

it "released: a match whose named experiment does not exist is refuted"
fx FAKE_BT_MISSING=1
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/never-ran --repo "$REPO"
fx
check '"refuted"' "$(result_of linear:AI-2 released)"

it "released: bt with no credential (real refusal shape) is unknown"
fx FAKE_BT_NOAUTH=1
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/cue-ga-run --repo "$REPO"
fx
check '"unknown"' "$(result_of linear:AI-2 released)"
has "keychain" "$(last_note linear:AI-2 released)"

it "released: a closed waiver does not count"
edit 'items["linear:AI-2"]["deliverables"]["released"] = {"result": "unknown"}'
edit 'prog["instructions"].append({"id": "iaaaaaa", "state": "withdrawn", "at": ago(60), "applies_to": "linear:AI-2", "until": None, "why": None, "prompt_id": "p1", "quote": "waive the eval for AI-2", "closed": None})'
prog check-deliverable linear:AI-2 released --repo "$REPO"
check '"refuted"' "$(result_of linear:AI-2 released)"

it "released: an active waiver for another item does not count"
edit 'prog["instructions"].append({"id": "ibbbbbb", "state": "active", "at": ago(60), "applies_to": "linear:AI-1", "until": None, "why": None, "prompt_id": "p2", "quote": "waive the eval", "closed": None})'
prog check-deliverable linear:AI-2 released --repo "$REPO"
check '"refuted"' "$(result_of linear:AI-2 released)"

it "released: a match with an active waiver instruction naming the item is confirmed"
edit 'prog["instructions"].append({"id": "icccccc", "state": "active", "at": ago(60), "applies_to": "linear:AI-2", "until": None, "why": None, "prompt_id": "p3", "quote": "ship it, waive the eval for this one", "closed": None})'
: > "$CALLS"
prog check-deliverable linear:AI-2 released --repo "$REPO"
check '"confirmed"' "$(result_of linear:AI-2 released)"
check '"icccccc"' "$(field "items['linear:AI-2']['deliverables']['released']['fields']['waiver']")"

it "released: with no reference the tested package and version are the reference"
check '"@slateteams/scene-detect@0.2.0-ai-376.0"' "$(field "items['linear:AI-2']['deliverables']['released']['ref']")"

it "released: a version the registry does not have is refuted"
fx FAKE_NPM_404=1
prog check-deliverable linear:AI-2 released --repo "$REPO"
fx
check '"refuted"' "$(result_of linear:AI-2 released)"

it "released: a 404 with no repo named is unknown, since the scope may use another registry"
edit 'items["linear:AI-2"]["deliverables"]["released"] = {"result": "unknown"}'
fx FAKE_NPM_404=1
prog check-deliverable linear:AI-2 released
fx
check '"unknown"' "$(result_of linear:AI-2 released)"

it "released: npm failing is unknown"
fx FAKE_NPM_EXIT=1
prog check-deliverable linear:AI-2 released --repo "$REPO"
fx
check '"unknown"' "$(result_of linear:AI-2 released)"

it "released: no tested build recorded is unknown"
edit 'items["linear:AI-2"]["tested_build"] = None'
prog check-deliverable linear:AI-2 released --ref bt:ai-chat/cue-ga-run --repo "$REPO"
check '"unknown"' "$(result_of linear:AI-2 released)"
has "record-tested-build" "$(last_note linear:AI-2 released)"

it "validate: stale confirmed verified evidence is re-checked with its stored repo"
prog check-deliverable linear:AI-1 verified --ref trace-abc123 --repo "$REPO"
edit 'items["linear:AI-1"]["deliverables"]["verified"]["checked_at"] = ago(7200)'
BUILD_SHA="$OLD_SHA" fx
: > "$CALLS"
prog validate
BUILD_SHA="$LATER_SHA" fx
has "trace-cli show trace-abc123" "$(cat "$CALLS")"
check '"refuted"' "$(result_of linear:AI-1 verified)"
has '"deliverable": "verified"' "$(journal_last evidence_refuted)"

it "validate: stale confirmed flagged evidence on an open item is re-checked"
prog check-deliverable linear:AI-1 flagged --ref default/wcs-ai-tool-relight
edit 'items["linear:AI-1"]["deliverables"]["flagged"]["checked_at"] = ago(7200)'
fx FAKE_LD_FLAG="${WORK}/fx/prodon.json"
prog validate
fx
check '"refuted"' "$(result_of linear:AI-1 flagged)"

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-evidence-more.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

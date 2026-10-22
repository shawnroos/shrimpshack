#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
FIX="${AUTO_ROOT}/tests/fixtures/agreement-legacy"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "agreement-legacy-fixtures.test.sh"

WORK="$(cd "$(mktemp -d -t auto-agreement-legacy.XXXXXX)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

manifest() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${FIX}/manifest.json" "$1"; }
RUN="$(manifest 'd["run"]')"

export HOME="${WORK}/home"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="$(manifest 'd["machine"]')"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="$(manifest 'd["session"]')"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export PYTHONDONTWRITEBYTECODE=1
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
mkdir -p "$HOME"
: > "$CLAUDE_AUTO_SECRETS_FILE"

fixture_digest() {
  (cd "$FIX" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)
}
DIGEST_BEFORE="$(fixture_digest)"

it "the fixtures restore into a temp root with every root path rewritten"
RESTORED="$("$PY" - "$FIX" "$WORK" <<'PYEOF' 2>&1
import json, os, sqlite3, sys
fix, work = sys.argv[1:]
m = json.load(open(os.path.join(fix, "manifest.json")))
sql = open(os.path.join(fix, "programme.sql")).read()
found = sql.count(m["sentinel"])
home = os.path.join(work, "data", "programmes", m["run"])
os.makedirs(home)
con = sqlite3.connect(os.path.join(home, "programme.db"))
con.executescript(sql.replace(m["sentinel"], work))
con.close()
for rel in m["files"]:
    os.makedirs(os.path.dirname(os.path.join(work, rel)), exist_ok=True)
    with open(os.path.join(fix, rel)) as src, open(os.path.join(work, rel), "w") as dst:
        dst.write(src.read().replace(m["sentinel"], work))
print(found == m["sentinel_count_in_sql"] > 0)
PYEOF
)"
check "True" "$RESTORED"

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}

prog rules --run "$RUN"
RULES="$OUT"
it "the rules view reads the fixture programme"
check "0" "$CODE"
it "the rules view shows the accepted agreement and the default autonomy term"
has "agreement: accepted" "$RULES"
has "autonomy: protocol" "$RULES"
it "the rules view shows the contract stamp"
has "operating contract v1" "$RULES"

PLAIN="$(manifest 'd["instructions"]["plain"]')"
WAIVER="$(manifest 'd["instructions"]["waiver"]')"
it "the rules view lists the programme-wide instruction"
has "$PLAIN" "$RULES"
has '"keep every PR under 300 lines"' "$RULES"
it "the rules view lists the waiver instruction for its item"
has "$WAIVER" "$RULES"
has '"waive the full eval for herdr:docs-page"' "$RULES"
has "applies to herdr:docs-page, until merged" "$RULES"

it "the rules view lists the accepted decision record"
has 'decision:d-browser@1 accepted: scope "ship the browser fix"' "$RULES"
it "the rules view lists the decision with a pending widening revision"
has 'decision:d-docs@1 accepted: scope "fix the docs page"' "$RULES"
has "decision:d-docs@2 pending_acceptance" "$RULES"
has "applies to herdr:docs-page, herdr:linux-probe" "$RULES"

it "the rules view lists the open project term"
has "project term $(manifest 'd["project_terms"]["open"]') crop defaults: PM picks the crop default" "$RULES"
it "the rules view lists the reserved project term"
has "reserved for Shawn $(manifest 'd["project_terms"]["reserved"]') pricing copy: Shawn writes every price string" "$RULES"

it "the rules view keeps the preferred-tool project term readable"
has "project term $(manifest 'd["project_terms"]["preferred_tool"]') prioritisation: use Amplitude" "$RULES"
it "the rules view keeps every watched source on"
has "tools_of_record: tracker, tasks, plans" "$RULES"

it "the recorded tracker source reads as available through its provider"
check "board None None" "$("$PY" - "$AUTO_ROOT" "$RUN" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
s = programme_records.load(sys.argv[2])["programme"]["sources"]["tracker"]
print(s.get("provider"), s.get("unavailable_since"), s.get("unsupported_since"))
PYEOF
)"

it "the item assignment still binds to the decision revision"
has "assignment herdr:browser-e2e: decision d-browser revision 1" "$RULES"

prog context --run "$RUN"
CONTEXT="$OUT"
it "the requirement still links to its decision"
check "0 d-browser [\"herdr:browser-e2e=verified\"]" "$CODE $("$PY" -c '
import json, sys
d = json.loads(sys.argv[1])
rev = d["requirements"]["r-browser"]["in_force"]
print(rev.get("decision_id"), json.dumps(rev["checks"]))' "$CONTEXT" 2>&1)"

PERSONAL="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
prog = load_lib_module("programme")
pp = load_lib_module("programme_protocol")
p = pp.load(prompt_lookup=prog.prompt_lookup)
rule = p["rules"].get("docs-verified") or {}
auto = p["autonomy"].get("prod_deploy") or {}
print(json.dumps([p["rejected"], rule.get("layer"), rule.get("adopted_on"), rule.get("autonomy"),
                  auto.get("level"), auto.get("layer"), auto.get("adopted_on")]))
PYEOF
)"
it "the personal protocol rejects only its adopted entry on a protected kind"
check '[["personal", "prod_deploy", "protected_kind"]]' "$("$PY" -c 'import json,sys; print(json.dumps([[r.get("layer"), r.get("id"), r.get("reason")] for r in json.loads(sys.argv[1])[0]]))' "$PERSONAL" 2>&1)"
it "the adopted rule carrying legacy autonomy verifies on this machine and the merged rule drops it"
check '["personal", null, null]' "$("$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[1:4]))' "$PERSONAL" 2>&1)"
it "a protected kind has no level in any layer: the adopted personal entry is not merged"
check '[null, null, null]' "$("$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[4:7]))' "$PERSONAL" 2>&1)"

it "no read crashed with a traceback"
check "" "$CRASHES"

it "the committed fixtures are unchanged by the run"
check "$DIGEST_BEFORE" "$(fixture_digest)"

echo
echo "agreement-legacy-fixtures.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

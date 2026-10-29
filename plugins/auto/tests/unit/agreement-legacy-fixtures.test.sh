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
it "the rules view shows the accepted agreement and drops the old autonomy term"
has "agreement: accepted" "$RULES"
lacks "autonomy: protocol" "$RULES"
it "the rules view shows the contract stamp"
has "operating contract v1" "$RULES"

PLAIN="$(manifest 'd["instructions"]["plain"]')"
WAIVER="$(manifest 'd["instructions"]["waiver"]')"
it "the rules view lists the programme-wide instruction"
has "$PLAIN" "$RULES"
has '"keep every PR under 300 lines"' "$RULES"
it "the rules view lists the waiver instruction as a Ruling for its item"
has "$WAIVER" "$RULES"
has '"waive the full eval for herdr:docs-page"' "$RULES"
has "applies to herdr:docs-page, until merged" "$RULES"

it "the rules view lists the accepted decision record"
has 'decision:d-browser@1 accepted: scope "ship the browser fix"' "$RULES"
it "the rules view lists the decision with a pending widening revision"
has 'decision:d-docs@1 accepted: scope "fix the docs page"' "$RULES"
has "decision:d-docs@2 pending_acceptance" "$RULES"
has "applies to herdr:docs-page, herdr:linux-probe" "$RULES"

it "the rules view lists the open project term as preferred-tool text"
has "preferred tool $(manifest 'd["project_terms"]["open"]') crop defaults: PM picks the crop default" "$RULES"
it "the rules view lists the reserved project term only as a legacy restrict Ruling"
lacks "reserved for Shawn" "$RULES"
has "ruling $(manifest 'd["project_terms"]["reserved"]'): restrict, no kind (legacy project term) \"Shawn writes every price string\"" "$RULES"

it "the rules view keeps the preferred-tool project term readable"
has "preferred tool $(manifest 'd["project_terms"]["preferred_tool"]') prioritisation: use Amplitude" "$RULES"
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

prog status --run "$RUN" --agreement
AGREE="$OUT"
it "AE5: the agreement page reads the fixture programme"
check "0" "$CODE"
it "AE5: the agreement page shows the old instructions and decision records as Rulings"
has "active ${PLAIN}: decided, no kind (legacy instruction) \"keep every PR under 300 lines\" (applies to programme)" "$AGREE"
has "active ${WAIVER}: decided, no kind (legacy instruction) \"waive the full eval for herdr:docs-page\" (applies to herdr:docs-page, until merged)" "$AGREE"
has "active d-browser: decided, no kind (legacy decision record)" "$AGREE"
has "active d-docs: decided, no kind (legacy decision record) \"fix the docs page\" (applies to herdr:docs-page; revision 2 pending)" "$AGREE"
it "AE5: the agreement page shows no autonomy row and keeps every source watched"
lacks "autonomy" "$AGREE"
has "sources watched: tracker, tasks, plans" "$AGREE"
it "AE5: the agreement page keeps the preferred-tool text readable"
has "preferred tool $(manifest 'd["project_terms"]["preferred_tool"]') prioritisation: use Amplitude" "$AGREE"
it "AE5: the agreement page shows no instruction, correction or project-term label"
lacks "nstruction " "$(printf '%s\n' "$AGREE" | grep -v 'legacy instruction')"
lacks "orrection" "$AGREE"
lacks "project term $(manifest 'd["project_terms"]["open"]')" "$AGREE"

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

PT_RESERVED="$(manifest 'd["project_terms"]["reserved"]')"
it "AE5: the context view shows each old instruction as a kind-less decided legacy Ruling"
check "$PLAIN decided None instruction accepted keep every PR under 300 lines | $WAIVER decided None instruction accepted merged" "$("$PY" -c '
import json, sys
d = json.loads(sys.argv[1])["decisions"]
out = []
for rid, last in ((sys.argv[2], "scope"), (sys.argv[3], "until")):
    rev = d[rid]["in_force"]
    out.append(" ".join(str(x) for x in (rid, rev["effect"], rev["kind"], rev["legacy"], d[rid]["state"] == "active" and rev["state"], rev[last])))
print(" | ".join(out))' "$CONTEXT" "$PLAIN" "$WAIVER" 2>&1)"
it "AE5: the reserved project term shows as a kind-less legacy restrict carrying its area"
check "restrict None project_term pricing copy [\"programme\"]" "$("$PY" -c '
import json, sys
rev = json.loads(sys.argv[1])["decisions"][sys.argv[2]]["in_force"]
print(rev["effect"], rev["kind"], rev["legacy"], rev["area"], json.dumps(rev["applies_to"]))' "$CONTEXT" "$PT_RESERVED" 2>&1)"
it "AE5: an open project term does not become a Ruling"
check "False False" "$("$PY" -c '
import json, sys
d = json.loads(sys.argv[1])["decisions"]
print(sys.argv[2] in d, sys.argv[3] in d)' "$CONTEXT" "$(manifest 'd["project_terms"]["open"]')" "$(manifest 'd["project_terms"]["preferred_tool"]')" 2>&1)"
it "AE5: the recovery packet lists the old instructions as Rulings"
has "decision:${PLAIN}@1 accepted: scope \"keep every PR under 300 lines\"" "$RULES"
it "the rules view asks Shawn to re-record the reserved term as a Ruling with a kind"
has "legacy restrict ${PT_RESERVED} pricing copy has no decision kind" "$RULES"

it "a legacy Ruling never reaches the gate for any kind"
check "[]" "$("$PY" - "$AUTO_ROOT" "$RUN" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import programme_records
ph = load_lib_module("programme_home")
pc = load_lib_module("programme_context")
pd = load_lib_module("programme_decisions")
programme = ph.normalize_programme(programme_records.load(sys.argv[2])["programme"])
hits = [r["id"] for kind in list(pd.DECISION_KINDS) + [None] for item in ("herdr:docs-page", "programme")
        for r in pc.rulings_for(programme, item, kind, "2026-10-22T08:00:00Z")]
print(json.dumps(hits))
PYEOF
)"

prog beat --run "$RUN"
it "a write after the upgrade keeps exactly one revision per legacy Ruling"
check "0 1 1 1" "$CODE $("$PY" - "$AUTO_ROOT" "$RUN" "$PLAIN" "$WAIVER" "$PT_RESERVED" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import programme_records
ph = load_lib_module("programme_home")
stored = programme_records.load(sys.argv[2])["programme"]
again = ph.normalize_programme(stored)["context"]["decisions"]
print(" ".join(str(len(again[i])) for i in sys.argv[3:]))
PYEOF
)"

prog recover --run "$RUN"
it "the recovery packet's binding section names every legacy Ruling with its effect"
check "$("$PY" -c 'import json,sys; print(json.dumps(sorted([["ruling:"+sys.argv[1], "decided"], ["ruling:"+sys.argv[2], "decided"], ["ruling:"+sys.argv[3], "restrict"]])))' "$PLAIN" "$WAIVER" "$PT_RESERVED")" \
  "$("$PY" -c 'import json,sys; print(json.dumps(sorted([r["id"], r["effect"]] for r in json.loads(sys.argv[1])["binding"]["rulings"])))' "$OUT" 2>&1)"
it "the recovery packet still lists both old decision records as decision rows"
check '["decision:d-browser@1", "decision:d-docs@1", "decision:d-docs@2"]' "$("$PY" -c 'import json,sys; print(json.dumps(sorted(r["id"] for r in json.loads(sys.argv[1])["decisions"] if r["decision_id"].startswith("d-"))))' "$OUT" 2>&1)"
resolved() { prog recover --run "$RUN" --get "$1"; "$PY" -c 'import json,sys; print(sys.argv[2], json.loads(sys.argv[1])["entry"]["scope"])' "$OUT" "$CODE" 2>&1; }
it "every old reference still resolves through recover --get"
check "0 keep every PR under 300 lines" "$(resolved "instruction:${PLAIN}")"
check "0 keep every PR under 300 lines" "$(resolved "ruling:${PLAIN}")"
check "0 ship the browser fix" "$(resolved "decision:d-browser@1")"
check "0 fix the docs page" "$(resolved "decision:d-docs@1")"
check "0 Shawn writes every price string" "$(resolved "ruling:${PT_RESERVED}")"

release_waivers() {
  "$PY" - "$AUTO_ROOT" "$RUN" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import programme_records
prog = load_lib_module("programme")
ph = load_lib_module("programme_home")
pe = load_lib_module("programme_evidence")
programme = ph.normalize_programme(programme_records.load(sys.argv[2])["programme"])
print(json.dumps([r["id"] for r in pe._context(prog, programme, "herdr:docs-page", "released", None)["waivers"]]))
PYEOF
}
it "the release check reads the fixture's legacy waiver instruction as a waiver for its item"
check "[\"$WAIVER\"]" "$(release_waivers)"

it "an old instruction whose waive wording sits only in its why still counts as a waiver, as before Rulings"
check '["i-why"]' "$("$PY" - "$AUTO_ROOT" "$RUN" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import programme_records
prog = load_lib_module("programme")
ph = load_lib_module("programme_home")
pe = load_lib_module("programme_evidence")
raw = programme_records.load(sys.argv[2])["programme"]
raw.setdefault("instructions", []).append(
    {"id": "i-why", "applies_to": "herdr:browser-e2e", "at": "2026-10-22T07:41:35Z", "closed": None,
     "prompt_id": None, "quote": "skip the full eval for the browser fix", "state": "active", "until": None,
     "why": "Shawn waived the eval for this hotfix"})
programme = ph.normalize_programme(raw)
print(json.dumps([r["id"] for r in pe._context(prog, programme, "herdr:browser-e2e", "released", None)["waivers"]]))
PYEOF
)"

P_WITHDRAW="$("$PY" - "$AUTO_ROOT" "$RUN" "$WAIVER" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from programme_prompts import append_prompt
print(append_prompt(sys.argv[2], os.environ["CLAUDE_CODE_SESSION_ID"], f"withdraw {sys.argv[3]}, run the eval")["prompt_id"])
PYEOF
)"
prog close-ruling "$WAIVER" --as withdrawn --prompt "$P_WITHDRAW" --run "$RUN"
it "close-ruling on the legacy waiver closes it and the release check stops counting it"
check "0 []" "$CODE $(release_waivers)"
it "the closed legacy waiver leaves the rules in force though the old instruction list said active"
prog rules --run "$RUN"
lacks "applies to herdr:docs-page, until merged" "$OUT"
has "decision:${WAIVER}@1 closed" "$OUT"
it "the closed legacy waiver leaves the recovery packet's binding section"
lacks "binding ruling:${WAIVER}" "$OUT"
has "binding ruling:${PLAIN} (legacy instruction, decided)" "$OUT"

it "no read crashed with a traceback"
check "" "$CRASHES"

it "the committed fixtures are unchanged by the run"
check "$DIGEST_BEFORE" "$(fixture_digest)"

echo
echo "agreement-legacy-fixtures.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

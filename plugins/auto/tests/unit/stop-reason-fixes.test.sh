#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then pass; else fail "missing [$1] in: $2"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$1"; then fail "unexpected [$1] in: $2"; else pass; fi; }

echo "stop-reason-fixes.test.sh"

WORK="$(mktemp -d -t auto-stop-fixes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"

# reasons JSON (+ optional actionable reasons JSON) -> the programme stop message
msg() {
  "$PY" - "$AUTO_ROOT" "$WORK" "$1" "${2:-[]}" <<'PYEOF'
import importlib.util, json, os, sys
root, home, reasons, actionable = sys.argv[1:5]
sys.path.insert(0, os.path.join(root, "lib"))
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(root, "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
hold = {"run": "prog-x", "home": home,
        "status": {"reasons": json.loads(reasons), "actionable_reasons": json.loads(actionable)}}
print(mod._programme_reason_for(hold))
PYEOF
}

it "no_rule_proposed names propose-rule and the shawn wait for that item"
OUT="$(msg '[{"kind":"no_rule_proposed","item":"linear:AI-1153"}]')"
has "programme.sh propose-rule" "$OUT"
it "no_rule_proposed names the set-waiting call for that item"
has "set-waiting linear:AI-1153 --who shawn --reporter shawn" "$OUT"
it "a fully hinted hold drops the generic watcher advice"
lacks "give each wait a live watcher" "$OUT"
it "a fully hinted hold drops the generic act line"
lacks "Act on your next step" "$OUT"

it "a reason with no fix keeps the generic act line"
OUT="$(msg '[{"kind":"made_up_kind"}]')"
has "Act on your next step." "$OUT"

it "until_time names the time it holds until and the sweep"
OUT="$(msg '[{"kind":"until_time","until":"2026-10-28T09:00:00Z"}]')"
has 'holds until 2026-10-28T09:00:00Z: run `programme.sh sweep`' "$OUT"

it "never_stop also shows the actionable reasons it would otherwise hide"
OUT="$(msg '[{"kind":"never_stop"}]' '[{"kind":"open_item","item":"linear:A-9"}]')"
has "never_stop; open_item linear:A-9" "$OUT"
it "never_stop fixes the hidden reason"
has "linear:A-9 is open" "$OUT"
it "never_stop sends a rule change to Shawn through a picker"
has "AskUserQuestion picker" "$OUT"

it "an authority hold carries its fix line"
OUT="$("$PY" - "$AUTO_ROOT" "$WORK" <<'PYEOF'
import importlib.util, os, sys
root, home = sys.argv[1:3]
sys.path.insert(0, os.path.join(root, "lib"))
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(root, "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
held = mod._held_status({"outcome": "corrupt", "detail": "bad db"})
print(mod._programme_reason_for({"run": "prog-x", "home": home, "status": held}))
PYEOF
)"
has '`programme.sh recover` reports what it can rebuild' "$OUT"

it "a source outage names the source"
OUT="$(msg '[{"kind":"source_unavailable","system":"tracker"}]')"
has "set-source tracker --unavailable" "$OUT"

it "two items with the same reason each get their own line"
OUT="$(msg '[{"kind":"open_item","item":"linear:A-1"},{"kind":"open_item","item":"linear:A-2"}]')"
check "2" "$(printf '%s\n' "$OUT" | grep -c '^- .* is open')"

it "every reason kind and authority hold has a fix, and no fix names a kind nothing reports"
GOT="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import importlib.util, os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
from _bootstrap import load_lib_module
kinds = set(load_lib_module("programme_predicate").REASON_KINDS)
kinds |= {"authority_" + h for h in load_lib_module("programme_home").AUTHORITY_HOLDS}
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(root, "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(" ".join(sorted(kinds - set(mod._REASON_FIXES))), "|", " ".join(sorted(set(mod._REASON_FIXES) - kinds)))
PYEOF
)"
check " | " "$GOT"

it "every programme.sh verb a fix names is a real verb"
VERBS="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import importlib.util, os, re, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(root, "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(" ".join(sorted({v for f in mod._REASON_FIXES.values() for v in re.findall(r"programme\.sh ([a-z-]+)", f)})))
PYEOF
)"
BAD=""
for v in $VERBS; do
  ERR="$(bash "${AUTO_ROOT}/lib/programme.sh" "$v" 2>&1)"
  case "$ERR" in *"unknown subcommand"*) BAD="$BAD $v" ;; esac
done
if [ -n "$VERBS" ] && [ -z "$BAD" ]; then pass; else fail "verbs: [$VERBS] unknown: [$BAD]"; fi

echo ""
echo "stop-reason-fixes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

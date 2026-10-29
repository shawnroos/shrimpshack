#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

echo "programme-proposals.test.sh"

WORK="$(mktemp -d -t auto-programme-proposals.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def raw(run):
    with open(core.run_record_path(ph.home_path(run), run)) as fh:
        return json.load(fh)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

prompt() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, origin, text = args
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

raw_field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = raw(run)["programme"]
rec = raw(run)
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
programme_records.edit(run, expr, globals())
EOF
}

journal_kinds() {
  run_py "$RUN" <<'EOF'
print(" ".join(row["kind"] for row in pj.read(args[0])))
EOF
}

last_row() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1]["payload"] if rows else None, sort_keys=True))
EOF
}

count_kind() {
  run_py "$RUN" "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == args[1]))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

T='prog["agreement"]["terms"]'

it "a new programme carries tools_of_record with all three tools and no sources term"
check '[["tracker", "tasks", "plans"], false]' "$(field "[${T}[\"tools_of_record\"][\"value\"], \"sources\" in ${T}]")"

it "every term and every built-in option has a description, and every term has a binding"
check 'ok' "$(run_py <<'EOF'
terms = ph.default_terms("2026-10-19T00:00:00Z")
guide = ph.TERM_GUIDE
bad = []
for key, term in terms.items():
    entry = guide.get(key) or {}
    if not (entry.get("description") or "").strip():
        bad.append(f"{key}: no description")
    if entry.get("binding") not in ("code", "guidance", "none"):
        bad.append(f"{key}: binding {entry.get('binding')!r}")
    for option in term["options"]:
        if not ((entry.get("options") or {}).get(option) or "").strip():
            bad.append(f"{key}.{option}: no description")
print("ok" if not bad and set(guide) == set(terms) else bad or sorted(guide))
EOF
)"

it "a record from the old code reads back with its sources term renamed to tools_of_record"
edit 'rec["programme"]["agreement"]["terms"].pop("tools_of_record", None); rec["programme"]["agreement"]["terms"]["sources"] = {"key": "sources", "options": ["tracker", "tasks", "plans"], "default": ["tracker", "tasks", "plans"], "value": ["tracker"], "set_by": "shawn", "set_at": "2026-10-01T10:00:00Z", "why": "focus", "prompt_id": "p111111", "quote": "only the tracker"}; rec["programme"]["sources"] = {"tracker": {"unavailable_since": "2026-10-02T00:00:00Z", "provider": "board"}}'
check '[["tracker"], "shawn", "2026-10-01T10:00:00Z", "focus", "p111111", "only the tracker", "tools_of_record", false]' \
  "$(field "[ph.normalize_programme(prog)[\"agreement\"][\"terms\"][\"tools_of_record\"][k] for k in (\"value\", \"set_by\", \"set_at\", \"why\", \"prompt_id\", \"quote\", \"key\")] + [\"sources\" in ph.normalize_programme(prog)[\"agreement\"][\"terms\"]]")"
it "the availability block programme[\"sources\"] survives the rename untouched"
check '{"tracker": {"provider": "board", "unavailable_since": "2026-10-02T00:00:00Z"}}' "$(field 'prog["sources"]')"
it "enabled_sources on an un-normalised old record reads the old term"
check '["tracker"]' "$(raw_field 'sorted(ph.enabled_sources(prog))')"
it "the stop predicate on an un-normalised old record treats a source the old term turns off as off"
check '[["tracker"], []]' "$(run_py "$RUN" <<'EOF'
out = []
for value in (["tracker"], ["tasks", "plans"]):
    rec = raw(args[0])
    rec["programme"]["agreement"]["terms"]["sources"]["value"] = value
    status = load_lib_module("programme_predicate").compute(rec)
    held = [r.get("system") for r in status["reasons"] if r["kind"] == "source_unavailable"]
    out.append(held + [w["system"] for w in status["waits"] if w.get("system") == "tracker"])
print(json.dumps(out))
EOF
)"
prog note-term remit "first write"
it "the first write stores the renamed term and drops the old one"
check '[["tracker"], false]' "$(raw_field "[prog[\"agreement\"][\"terms\"][\"tools_of_record\"][\"value\"], \"sources\" in prog[\"agreement\"][\"terms\"]]")"
edit 'rec["programme"]["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "tasks", "plans"]; rec["programme"]["sources"] = {}'

it "propose-term cadence fixed --seconds 900 succeeds"
prog propose-term cadence fixed --seconds 900
check 0 "$CODE"
it "the proposal is pending with the value and seconds, and the value is unchanged"
check '["fixed", {"seconds": 900}, "pending", "on_change", 3600]' \
  "$(field "[${T}[\"cadence\"][\"proposal\"][k] for k in (\"value\", \"extras\", \"state\")] + [${T}[\"cadence\"][\"value\"], ${T}[\"cadence\"][\"seconds\"]]")"
it "propose-term journals term_proposed"
check '{"extras": {"seconds": 900}, "origin": "pm", "term": "cadence", "value": "fixed"}' "$(last_row term_proposed)"

it "a second propose-term replaces the first"
prog propose-term cadence fixed --seconds 1800 --origin ui
check '[1800, "ui", "pending"]' "$(field "[${T}[\"cadence\"][\"proposal\"][\"extras\"][\"seconds\"], ${T}[\"cadence\"][\"proposal\"][\"origin\"], ${T}[\"cadence\"][\"proposal\"][\"state\"]]")"
it "the UI label rides on the journal row"
check '"ui"' "$(run_py "$RUN" <<'EOF'
print(json.dumps([r for r in pj.read(args[0]) if r["kind"] == "term_proposed"][-1]["payload"]["origin"]))
EOF
)"

it "rules_in_force carries no proposal for a term with a pending proposal"
check '[false, true]' "$(run_py "$RUN" <<'EOF'
rules = load_lib_module("programme").rules_in_force(record(args[0]))
terms = rules["agreement"]["terms"]
print(json.dumps(["proposal" in terms["cadence"], "value" in terms["cadence"]]))
EOF
)"
it "the rules block does not mention the proposal"
lacks "1800" "$("$PY" "$PROG" rules --run "$RUN" 2>&1)"

it "propose-term autonomy is refused: the agreement has no autonomy term"
prog propose-term autonomy protocol
check 1 "$CODE"
check 'false' "$(field "\"autonomy\" in ${T}")"
it "propose-term remit other is refused: the value is not an option"
prog propose-term remit other
check 1 "$CODE"
check 'false' "$(field "\"proposal\" in ${T}[\"remit\"] and ${T}[\"remit\"][\"proposal\"][\"value\"] == \"other\"")"
it "propose-term on an unknown term is refused"
prog propose-term nonsense x
check 1 "$CODE"
it "propose-term cadence fixed with a bad --seconds is refused"
prog propose-term cadence fixed --seconds soon
check 1 "$CODE"

it "AE4: a refused amend leaves the value and the pending proposal unchanged"
prog propose-term cadence fixed --seconds 900
P_CRON="$(prompt cron 'cadence fixed every 15 minutes')"
REFUSED_BEFORE="$(count_kind approval_refused)"
prog amend-term cadence fixed --seconds 900 --prompt "$P_CRON"
check 1 "$CODE"
check '["on_change", "pending", 900]' "$(field "[${T}[\"cadence\"][\"value\"], ${T}[\"cadence\"][\"proposal\"][\"state\"], ${T}[\"cadence\"][\"proposal\"][\"extras\"][\"seconds\"]]")"
it "the refused amend writes one approval_refused row with the reason"
check "$((REFUSED_BEFORE + 1))" "$(count_kind approval_refused)"
has "typed" "$(last_row approval_refused)"

it "AE9: an accepted amend to 1800s with a pending 900s proposal marks it superseded"
P_1800="$(prompt typed 'cadence fixed, every 30 minutes')"
prog amend-term cadence fixed --seconds 1800 --prompt "$P_1800"
check 0 "$CODE"
check '["fixed", 1800, "superseded"]' "$(field "[${T}[\"cadence\"][\"value\"], ${T}[\"cadence\"][\"seconds\"], ${T}[\"cadence\"][\"proposal\"][\"state\"]]")"
it "an amend that matches the proposal marks it accepted"
prog propose-term cadence fixed --seconds 900
P_900="$(prompt typed 'cadence fixed, every 15 minutes')"
prog amend-term cadence fixed --seconds 900 --prompt "$P_900"
check 0 "$CODE"
check '[900, "accepted"]' "$(field "[${T}[\"cadence\"][\"seconds\"], ${T}[\"cadence\"][\"proposal\"][\"state\"]]")"

it "a stop time proposed from the view is accepted by the reply the view tells Shawn to type"
prog propose-term stop_rule until_time --until 2026-10-20T18:00:00Z --origin ui
check 0 "$CODE"
P_UNTIL="$(prompt typed 'amend stop rule to until time until 2026-10-20T18:00:00Z')"
prog amend-term stop_rule until_time --until 2026-10-20T18:00:00Z --prompt "$P_UNTIL"
check 0 "$CODE"
check '["until_time", "2026-10-20T18:00:00Z", "accepted"]' "$(field "[${T}[\"stop_rule\"][\"value\"], ${T}[\"stop_rule\"][\"until\"], ${T}[\"stop_rule\"][\"proposal\"][\"state\"]]")"

it "clear-proposal removes the proposal and journals proposal_cleared"
prog propose-term stop_rule only_when_done
prog clear-proposal stop_rule --origin ui
check 0 "$CODE"
check 'false' "$(field "\"proposal\" in ${T}[\"stop_rule\"]")"
check '{"origin": "ui", "term": "stop_rule"}' "$(last_row proposal_cleared)"
it "clear-proposal on a term without one is refused"
prog clear-proposal stop_rule
check 1 "$CODE"

it "propose-term tools_of_record --add sentry stores the tool as a pending proposal"
prog propose-term tools_of_record --add sentry --description "Error reports"
check 0 "$CODE"
check '[["tracker", "tasks", "plans", "sentry"], {"add": "sentry", "description": "Error reports"}, "pending", false]' \
  "$(field "[${T}[\"tools_of_record\"][\"proposal\"][k] for k in (\"value\", \"extras\", \"state\")] + [\"sentry\" in ${T}[\"tools_of_record\"][\"options\"]]")"
it "--add without --description is refused"
prog propose-term tools_of_record --add rollbar
check 1 "$CODE"
it "a tool list naming an unknown tool is refused"
prog propose-term tools_of_record tracker,rollbar
check 1 "$CODE"
it "after an accepted amend the added tool is in the options with its description"
P_SENTRY="$(prompt typed 'tools of record: add sentry')"
prog amend-term tools_of_record tracker,tasks,plans,sentry --prompt "$P_SENTRY"
check 0 "$CODE"
check '[["tracker", "tasks", "plans", "sentry"], true, "Error reports", "accepted"]' \
  "$(field "[${T}[\"tools_of_record\"][\"value\"], \"sentry\" in ${T}[\"tools_of_record\"][\"options\"], ${T}[\"tools_of_record\"][\"option_descriptions\"][\"sentry\"], ${T}[\"tools_of_record\"][\"proposal\"][\"state\"]]")"
it "a hyphenated tool can be proposed and approved by naming it as written"
prog propose-term tools_of_record tracker,tasks,plans,sentry,linear-board --add linear-board --description "The herdr board"
check 0 "$CODE"
P_BOARD="$(prompt typed 'widen tools of record to tracker, tasks, plans, sentry, linear-board')"
prog amend-term tools_of_record tracker,tasks,plans,sentry,linear-board --prompt "$P_BOARD"
check 0 "$CODE"
check '"accepted"' "$(field "${T}[\"tools_of_record\"][\"proposal\"][\"state\"]")"
it "a custom tool in the value does not change the sweep tools"
check '["plans", "tasks", "tracker"]' "$(field 'sorted(ph.enabled_sources(prog))')"
it "amend-term tools_of_record refuses a tool that is neither an option nor proposed"
P_ROLL="$(prompt typed 'tools of record: add rollbar')"
prog amend-term tools_of_record tracker,rollbar --prompt "$P_ROLL"
check 1 "$CODE"

it "propose-term remit --add proposes a new herdr space without changing the remit"
prog propose-term remit --add w9
check 0 "$CODE"
check '[{"add": "default.w9"}, "pending", ["w2"]]' "$(field "[${T}[\"remit\"][\"proposal\"][\"extras\"], ${T}[\"remit\"][\"proposal\"][\"state\"], [s[\"workspace\"] for s in prog[\"remit\"][\"spaces\"]]]")"
it "propose-term remit --add refuses a bad space name"
prog propose-term remit --add "../x"
check 1 "$CODE"
it "set-remit that adds the proposed space marks the proposal accepted"
OUT="$(printf '%s' '{"spaces": ["w2", "w9"]}' | "$PY" "$PROG" set-remit 2>&1)"; CODE=$?
check 0 "$CODE"
check '"accepted"' "$(field "${T}[\"remit\"][\"proposal\"][\"state\"]")"
it "set-remit that does not add the proposed space marks the proposal superseded"
prog propose-term remit --add w8
OUT="$(printf '%s' '{"spaces": ["w2"]}' | "$PY" "$PROG" set-remit 2>&1)"; CODE=$?
check 0 "$CODE"
check '"superseded"' "$(field "${T}[\"remit\"][\"proposal\"][\"state\"]")"

it "note-term stores the note and journals term_noted"
prog note-term remit "revisit after week 1" --origin ui
check 0 "$CODE"
check '"revisit after week 1"' "$(field "${T}[\"remit\"][\"notes\"][-1][\"text\"]")"
check '{"note": "revisit after week 1", "origin": "ui", "term": "remit"}' "$(last_row term_noted)"
it "note-term --clear removes the notes"
prog note-term remit --clear
check 0 "$CODE"
check 'false' "$(field "\"notes\" in ${T}[\"remit\"]")"
it "note-term with no text and no --clear is a usage error"
prog note-term remit
check 2 "$CODE"

it "note-term does not move loop.last_beat_at"
edit 'rec.setdefault("loop", {})["last_beat_at"] = "2026-01-01T00:00:00Z"'
prog note-term cadence "check this"
check '"2026-01-01T00:00:00Z"' "$(raw_field 'rec["loop"]["last_beat_at"]')"
it "propose-term and clear-proposal do not move loop.last_beat_at"
prog propose-term stop_rule only_when_done
prog clear-proposal stop_rule
check '"2026-01-01T00:00:00Z"' "$(raw_field 'rec["loop"]["last_beat_at"]')"
it "an ordinary write still moves loop.last_beat_at (the check above can fail)"
prog set-now --clear
check 0 "$CODE"
lacks '2026-01-01T00:00:00Z' "$(raw_field 'rec["loop"]["last_beat_at"]')"

touch "${HOME_DIR}/.compact-flag"
it "note-term succeeds while the compact flag is set"
prog note-term remit "after compaction"
check 0 "$CODE"
it "propose-term and clear-proposal succeed while the compact flag is set"
prog propose-term stop_rule only_when_done
check 0 "$CODE"
prog clear-proposal stop_rule
check 0 "$CODE"
it "close-ruling --as fulfilled is refused while the compact flag is set"
rm -f "${HOME_DIR}/.compact-flag"
P_RULING="$(prompt typed 'r-suite: run the auto suite first, tool choice across the programme is your call')"
prog record-ruling r-suite --kind tool_choice --effect grant --scope "run the auto suite first" --prompt "$P_RULING"
touch "${HOME_DIR}/.compact-flag"
prog close-ruling r-suite --as fulfilled --why "done"
check 1 "$CODE"
has "compacted" "$OUT"
check '"accepted"' "$(field 'prog["context"]["decisions"]["r-suite"][-1]["state"]')"
rm -f "${HOME_DIR}/.compact-flag"
it "close-ruling --as fulfilled does not move loop.last_beat_at and records its origin"
edit 'rec.setdefault("loop", {})["last_beat_at"] = "2026-01-01T00:00:00Z"'
prog close-ruling r-suite --as fulfilled --why "done" --origin ui
check 0 "$CODE"
check '"2026-01-01T00:00:00Z"' "$(raw_field 'rec["loop"]["last_beat_at"]')"
check '"ui"' "$(run_py "$RUN" <<'PY'
print(json.dumps([r for r in pj.read(args[0]) if r["kind"] == "ruling_closed"][-1]["payload"].get("origin")))
PY
)"

touch "${HOME_DIR}/.compact-flag"
it "request-reread succeeds while the compact flag is set and journals reread_requested"
prog request-reread --origin ui
check 0 "$CODE"
GOT="$(run_py "$RUN" <<'PY'
rows = [r for r in pj.read(args[0]) if r["kind"] == "reread_requested"]
print(len(rows), rows[-1]["payload"].get("origin") if rows else None)
PY
)"
check "1 ui" "$GOT"
it "request-reread leaves the compact flag in place"
check yes "$([ -f "${HOME_DIR}/.compact-flag" ] && echo yes || echo no)"
rm -f "${HOME_DIR}/.compact-flag"
it "request-reread does not move loop.last_beat_at"
edit 'rec.setdefault("loop", {})["last_beat_at"] = "2026-01-01T00:00:00Z"'
prog request-reread
check '"2026-01-01T00:00:00Z"' "$(raw_field 'rec["loop"]["last_beat_at"]')"

it "a stranger session cannot propose, note or clear"
CLAUDE_CODE_SESSION_ID="sess-other" prog note-term remit "hi" --run "$RUN"
check 1 "$CODE"
CLAUDE_CODE_SESSION_ID="sess-other" prog propose-term stop_rule only_when_done --run "$RUN"
check 1 "$CODE"

it "no shipped code reads the agreement term under its old key outside the fallback"
LEAKS="$(cd "$AUTO_ROOT" && grep -rnE \
  -e 'terms("\])?\["sources"\]' -e 'terms\.get\("sources"' -e 'term\("sources"' -e '== "sources"' \
  -e 'amend-term sources' -e 'sources term' -e 'sources=' \
  lib skills commands docs/contracts .claude/hooks 2>&1)"
check "1 " "$? ${LEAKS}"

echo ""
echo "programme-proposals.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

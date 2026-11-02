#!/usr/bin/env bash
# The real end and handover verbs refuse while a ritual for their trigger is unanswered in the
# tenure, and --without-rituals goes ahead. The unit test covers the gate function; this drives the verbs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-programme-ritual-gates.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/closure-fixture.sh"
export CLAUDE_AUTO_RITUALS_STORE="${WORK}/stores/rituals.json"

echo "programme-ritual-gates.test.sh"
write_snapshot base

add_ritual() {
  run_py "$1" "$2" "$3" <<'EOF'
run, rid, trigger = args
def mutate(rec):
    rec["programme"]["rituals"].append({
        "id": rid, "layer": "programme", "state": "active", "at": "2026-11-01T00:00:00Z",
        "when": {"text": "at " + trigger, "trigger": trigger}, "steps": ["write the note"]})
core._with_locked_run_record(ph.home_path(run), run, mutate)
EOF
}

# typed_request <run> <session> <verb> <text>: a typed slash command the lifecycle verbs accept.
typed_request() {
  local pid
  pid="$(typed_in "$1" "$2" "$4")"
  run_py "$1" "$2" "$pid" "$3" "$4" <<'EOF' >/dev/null
run, sid, pid, verb, text = args
pj.append(run, verb + "_request", sid, {"verb": verb, "text": text, "origin": "typed", "driving": True,
                                         "lease_status": "live",
                                         "source": pj.find_prompt(run, pid)["payload"]["source"]},
          cites=[pid])
EOF
}

RUN="$(new_programme w2)"
add_ritual "$RUN" wrapup end
typed_request "$RUN" sess-pm end "/auto:programme-end"

it "end refuses while an end ritual has not run, names it, and the programme stays live"
CLAUDE_CODE_SESSION_ID=sess-pm prog end --run "$RUN"
check 1 "$CODE"
has "wrapup" "$OUT"
has "--without-rituals" "$OUT"
check "0" "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "programme_ended"))
EOF
)"

it "end goes ahead with --without-rituals"
CLAUDE_CODE_SESSION_ID=sess-pm prog end --without-rituals --run "$RUN"
check 0 "$CODE"
check "1" "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "programme_ended"))
EOF
)"

RUN2="$(new_programme w3)"
add_ritual "$RUN2" brief handover
typed_request "$RUN2" sess-pm handover "/auto:programme-handover sess-b"

it "handover refuses while a handover ritual has not run, and the driver does not move"
CLAUDE_CODE_SESSION_ID=sess-pm prog handover sess-b --run "$RUN2"
check 1 "$CODE"
has "brief" "$OUT"
has "--without-rituals" "$OUT"
check "0" "$(run_py "$RUN2" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "handed_over"))
EOF
)"

it "handover passes once the ritual ran"
CLAUDE_CODE_SESSION_ID=sess-pm prog run-ritual brief --run "$RUN2"
check 0 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-pm prog handover sess-b --run "$RUN2"
check 0 "$CODE"

RUN3="$(new_programme w4)"
add_ritual "$RUN3" brief handover
typed_request "$RUN3" sess-pm handover "/auto:programme-handover sess-b"

it "handover goes ahead with --without-rituals and leaves the ritual for the incoming PM"
CLAUDE_CODE_SESSION_ID=sess-pm prog handover sess-b --without-rituals --run "$RUN3"
check 0 "$CODE"
check "brief" "$(run_py "$RUN3" <<'EOF'
due = load_lib_module("programme_rituals_due")
rec = record(args[0])
print(" ".join(r["ritual"] for r in due.due(rec, args[0])["due"] + due.due(rec, args[0])["missed"]))
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

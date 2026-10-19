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

echo "programme-corrections.test.sh"

WORK="$(mktemp -d -t auto-programme-corrections.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr; do
  printf '#!/bin/sh\nexit 0\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="$(run_py "$RUN" <<'EOF'
print(ph.home_path(args[0]))
EOF
)"

prompt() {
  local sid="${3:-sess-pm}"
  run_py "$RUN" "$1" "$2" "$sid" <<'EOF'
run, origin, text, sid = args
print(pj.append_prompt(run, sid, text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(sum(1 for row in pj.read(args[0]) if row["kind"] == args[1]))
EOF
}

state_hash() {
  "$PY" - "$HOME_DIR" <<'EOF'
import hashlib, json, os, sys
home = sys.argv[1]
out = []
for name in sorted(os.listdir(home)):
    path = os.path.join(home, name)
    if os.path.isfile(path) and not name.startswith("."):
        out.append(name + ":" + hashlib.sha256(open(path, "rb").read()).hexdigest())
print(hashlib.sha256("\n".join(out).encode()).hexdigest())
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

# The switch is a module constant with no environment override, so tests turn it on
# by patching it inside the process that runs the verb. MUTATE patches one check out.
prog_on() {
  OUT="$(MUTATE="${MUTATE:-}" run_py "$@" <<'EOF'
pt = load_lib_module("programme_terms")
pt.CORRECTIONS_ON = True
programme = load_lib_module("programme")
mutate = os.environ.get("MUTATE")
if mutate == "typed":
    def typed(run_id, rec, prompt_id):
        row = pj.find_prompt(run_id, prompt_id)
        if row is None:
            raise programme.ProgrammeError(f"no prompt {prompt_id!r}")
        text = row["payload"].get("text") or ""
        return {"prompt_id": prompt_id, "quote": text, "text_hash": programme.text_hash(text)}
    programme._typed_prompt = typed
elif mutate == "order":
    pt._check_anchor_order = lambda *a: None
elif mutate == "closed":
    pt._check_correctable = lambda *a: None
elif mutate == "reuse":
    pt._check_prompt_unused = lambda *a: None
sys.exit(programme._cli(args))
EOF
)"
  CODE=$?
}

refused_unchanged() {
  local want="$1"; shift
  local before after
  before="$(state_hash)"
  prog_on "$@"
  after="$(state_hash)"
  if [ "$CODE" = 1 ] && [ "$before" = "$after" ]; then
    case "$OUT" in *"$want"*) pass ;; *) fail "expected [$want] in [$OUT]" ;; esac
  else
    fail "code [$CODE] changed [$([ "$before" = "$after" ] && echo no || echo yes)] out [$OUT]"
  fi
}

# Proves the named check is what refuses: with it patched out the same call is accepted.
mutation_accepts() {
  local name="$1"; shift
  rm -rf "${WORK}/home.bak"
  /bin/cp -Rp "$HOME_DIR" "${WORK}/home.bak"
  MUTATE="$name" prog_on "$@"
  local got="$CODE"
  rm -rf "$HOME_DIR"
  /bin/cp -Rp "${WORK}/home.bak" "$HOME_DIR"
  check 0 "$got"
}

ask_id() { field "prog['items']['$1']['handed']['id']" | tr -d '"'; }

prog add-item linear:AI-1 --title "Crop approach" --kind product_question
run_py "$RUN" <<'EOF' >/dev/null
def mutate(rec):
    rec["programme"]["agreement"]["contract_version"] = 1
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
prog add-item linear:AI-2 --title "Scope call" --kind fix_only
prog add-item linear:AI-3 --title "Spend call" --kind fix_only
prog add-item linear:AI-4 --title "Later ask" --kind fix_only
prog hand-item linear:AI-1 --question "Crop on the client or the server?" --kind technical_approach
prog hand-item linear:AI-2 --question "Is crop in scope?" --kind product_scope
prog hand-item linear:AI-3 --question "Go over the cap?" --kind spend_over_cap
prog record-decision programme --kind tool_choice --silent --why "pillow is already a dependency"
ASK1="$(ask_id linear:AI-1)"
ASK2="$(ask_id linear:AI-2)"
ASK3="$(ask_id linear:AI-3)"
DEC1="$(field 'prog["decisions"][-1]["id"]' | tr -d '"')"

P_EARLY="$(prompt typed "that one did not need me either")"
prog hand-item linear:AI-4 --question "Which queue first?" --kind work_sequencing
ASK4="$(ask_id linear:AI-4)"
P1="$(prompt typed "that didn't need me")"
P_CRON="$(prompt cron "that didn't need me")"
P_OTHER="$(prompt typed "that didn't need me" sess-other)"

it "the fixture asks and the choice have ids"
case "$ASK1 $ASK2 $ASK3 $ASK4 $DEC1" in a??????" "a??????" "a??????" "a??????" "d??????) pass ;; *) fail "$ASK1 $ASK2 $ASK3 $ASK4 $DEC1" ;; esac

it "the correctable kinds are exactly the five settled kinds"
check '["optimisation_depth", "technical_approach", "tool_choice", "work_sequencing", "worker_coordination"]' \
  "$(run_py <<'EOF'
print(json.dumps(sorted(load_lib_module("programme_terms").CORRECTABLE_KINDS)))
EOF
)"

it "the shipped switch is off"
check "False" "$(run_py <<'EOF'
print(load_lib_module("programme_terms").CORRECTIONS_ON)
EOF
)"

for verb in correct-term undo-correction; do
  it "with the switch off, ${verb} refuses and writes nothing"
  BEFORE="$(state_hash)"
  if [ "$verb" = correct-term ]; then
    prog correct-term --prompt "$P1" --replies-to "$ASK1" --to pm --reading "technical choices are mine"
  else
    prog undo-correction c000000 --prompt "$P1"
  fi
  if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(state_hash)" ]; then has "corrections are not on yet" "$OUT"; else fail "code $CODE out $OUT"; fi
done

it "the test harness and hatch variables do not turn corrections on"
BEFORE="$(state_hash)"
OUT="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 CLAUDE_AUTO_TEST_CORRECTIONS=1 \
  CLAUDE_AUTO_CORRECTIONS=1 bash "${AUTO_ROOT}/lib/programme.sh" correct-term --prompt "$P1" \
  --replies-to "$ASK1" --to pm --reading "technical choices are mine" 2>&1)"
CODE=$?
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(state_hash)" ]; then has "corrections are not on yet" "$OUT"; else fail "code $CODE out $OUT"; fi

it "a cron-origin prompt refuses and writes nothing"
refused_unchanged "is not typed" correct-term --prompt "$P_CRON" --replies-to "$ASK1" --to pm --reading r
it "mutation: with the typed-origin check patched out the cron prompt is accepted"
mutation_accepts typed correct-term --prompt "$P_CRON" --replies-to "$ASK1" --to pm --reading r
it "another session's prompt refuses and writes nothing"
refused_unchanged "not typed in the driving session" correct-term --prompt "$P_OTHER" --replies-to "$ASK1" --to pm --reading r
it "an unknown prompt id refuses and writes nothing"
refused_unchanged "no prompt 'p000000'" correct-term --prompt p000000 --replies-to "$ASK1" --to pm --reading r
it "no prompt refuses and writes nothing"
refused_unchanged "needs --prompt" correct-term --replies-to "$ASK1" --to pm --reading r

it "a product-scope ask is not correctable"
refused_unchanged "'product_scope' is not correctable" correct-term --prompt "$P1" --replies-to "$ASK2" --to pm --reading r
it "mutation: with the closed list patched out the product-scope ask is accepted"
mutation_accepts closed correct-term --prompt "$P1" --replies-to "$ASK2" --to pm --reading r
it "a risk-or-cost ask is not correctable"
refused_unchanged "'spend_over_cap' is not correctable" correct-term --prompt "$P1" --replies-to "$ASK3" --to worker --reading r

it "an anchor recorded after the prompt refuses"
refused_unchanged "was not recorded before prompt" correct-term --prompt "$P_EARLY" --replies-to "$ASK4" --to pm --reading r
it "mutation: with the anchor-order check patched out the later anchor is accepted"
mutation_accepts order correct-term --prompt "$P_EARLY" --replies-to "$ASK4" --to pm --reading r

it "an unknown anchor refuses"
refused_unchanged "no ask or recorded choice 'a000000'" correct-term --prompt "$P1" --replies-to a000000 --to pm --reading r
it "an owner outside pm, worker and shawn refuses"
prog_on correct-term --prompt "$P1" --replies-to "$ASK1" --to everyone --reading r
check 2 "$CODE"
it "an empty reading refuses"
prog_on correct-term --prompt "$P1" --replies-to "$ASK1" --to pm --reading " "
check 2 "$CODE"

it "before the correction the PM cannot record a choice on the handed item"
prog record-decision linear:AI-1 --kind technical_approach --silent --why x
check "1 is handed" "$CODE $(printf '%s' "$OUT" | grep -o 'is handed' | head -1)"

it "AE6: a typed reply to a technical-approach ask moves that kind to the PM"
prog_on correct-term --prompt "$P1" --replies-to "$ASK1" --to pm --reading "technical choices are mine to make"
check 0 "$CODE"
CID1="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["correction"])')"
it "the correction prints one line holding the notice with the quote and the reading"
check "1 True True True" "$(printf '%s' "$OUT" | "$PY" -c '
import json, sys
raw = sys.stdin.read()
n = json.loads(raw)["notice"]
print(len(raw.strip().splitlines()), "technical_approach now decided by pm (was the contract default)" in n,
      "Shawn said \"that didn'"'"'t need me\"" in n, "reading: \"technical choices are mine to make\"" in n)')"
it "the record keeps the quote from the journal, the PM's reading, anchor, kind, owner and previous value"
check "[\"technical_approach\", \"${ASK1}\", \"pm\", null, \"${P1}\", \"that didn't need me\", \"technical choices are mine to make\", null]" \
  "$(field '[prog["agreement"]["corrections"][0][k] for k in ("kind", "anchor", "to", "previous", "prompt_id", "quote", "pm_reading", "undone")]')"
it "the correction journals term_corrected citing the prompt"
check "1 True" "$(run_py "$RUN" "$P1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "term_corrected"]
print(len(rows), rows[-1].get("cites") == [args[1]])
EOF
)"
it "the anchored handed ask is open again"
check '"open"' "$(field 'prog["items"]["linear:AI-1"]["state"]')"
it "the rules block lists the active correction"
prog rules
has "correction ${CID1}: technical_approach decided by pm (Shawn: \"that didn't need me\"; PM's reading: \"technical choices are mine to make\")" "$OUT"

it "after the correction the PM records its choice on the reopened item without answer-handed"
prog record-decision linear:AI-1 --kind technical_approach --term "$CID1" --why "server crop keeps the client small"
check 0 "$CODE"
DEC2="$(field 'prog["decisions"][-1]["id"]' | tr -d '"')"

it "a prompt that already drove a correction refuses a second one"
refused_unchanged "already drove correction '${CID1}'" correct-term --prompt "$P1" --replies-to "$DEC1" --to pm --reading r
it "mutation: with the prompt-reuse check patched out the second correction is accepted"
mutation_accepts reuse correct-term --prompt "$P1" --replies-to "$DEC1" --to pm --reading r

P2="$(prompt typed "workers can pick that themselves")"
it "a later correction of the same kind records the previous owner"
prog_on correct-term --prompt "$P2" --replies-to "$ASK1" --to worker --reading "workers choose the approach"
check 0 "$CODE"
CID2="$(field 'prog["agreement"]["corrections"][-1]["id"]' | tr -d '"')"
check '"pm"' "$(field 'prog["agreement"]["corrections"][-1]["previous"]')"

P3="$(prompt typed "undo the first one")"
it "undo refuses when a later correction of the same kind exists and names it"
refused_unchanged "correction '${CID2}' changed technical_approach later" undo-correction "$CID1" --prompt "$P3"
it "undo with a prompt not later than the correction's refuses"
refused_unchanged "is not later than the correction's prompt" undo-correction "$CID2" --prompt "$P2"
it "undo of an unknown correction refuses"
refused_unchanged "no correction 'c000000'" undo-correction c000000 --prompt "$P3"

it "AE8: undo with a later typed prompt restores the previous value"
prog_on undo-correction "$CID2" --prompt "$P3"
check 0 "$CODE"
check '"pm"' "$(field '[c["to"] for c in prog["agreement"]["corrections"] if not c.get("undone")][-1]')"
it "the undo journals correction_undone"
check 1 "$(journal_count correction_undone)"

P4="$(prompt typed "undo that too")"
it "undoing the first correction lists the choices made under it"
prog_on undo-correction "$CID1" --prompt "$P4"
check "0 [\"${DEC2}\"] null" "$CODE $(printf '%s' "$OUT" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d["made_under"]), json.dumps(d["restored"]))')"
has "choices made under it stand: ${DEC2}" "$OUT"
it "a prompt that drove an undo cannot drive a correction"
refused_unchanged "already drove correction" correct-term --prompt "$P4" --replies-to "$DEC1" --to pm --reading r
it "an undone correction cannot be undone again"
P5="$(prompt typed "again")"
refused_unchanged "already undone" undo-correction "$CID1" --prompt "$P5"
it "with every correction undone the rules block lists none"
prog rules
case "$OUT" in *"correction c"*) fail "$OUT" ;; *) pass ;; esac

echo ""
echo "programme-corrections.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

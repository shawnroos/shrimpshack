#!/usr/bin/env bash
# Carry-over of Rulings: the offer (carry-rulings and end), the offer-made marker the stop predicate
# reads, the per-machine store, and the pending arrival in the next programme on the project.
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

echo "programme-carryover.test.sh"

WORK="$(mktemp -d -t auto-programme-carryover.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_SPINOFF_TIMEOUT=2
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
STORE="$CLAUDE_AUTO_CARRYOVER_STORE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  code=0; [ "$tool" = spinoff ] && code=3
  printf '#!/bin/sh\nexit %s\n' "$code" > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

ALPHA="${WORK}/repos/alpha"
ALPHA2="${WORK}/repos/alpha-two"
BETA="${WORK}/repos/beta"
GAMMA="${WORK}/repos/gamma"
mkdir -p "$ALPHA" "$ALPHA2" "$BETA" "$GAMMA"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
pc = load_lib_module("programme_context")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

new_programme() {
  run_py "$1" <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
}

prompt() {
  run_py "$1" "$2" <<'EOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
EOF
}

field() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

# may_stop and the reason kinds the stop predicate gives now.
stop_state() {
  run_py "$1" <<'EOF'
pred = load_lib_module("programme_predicate")
status = pred.compute(record(args[0]), inbox_size=0)
print(status["may_stop"], ",".join(r["kind"] for r in status["reasons"]))
EOF
}

set_stop_rule() {
  run_py "$1" "$2" <<'EOF' >/dev/null
def mutate(rec):
    rec["programme"]["agreement"]["terms"]["stop_rule"]["value"] = args[1]
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
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

MUT_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
load_lib_module("programme_protocol")._verify_adoption = lambda *a, **k: None
sys.exit(programme._cli(sys.argv[1:]))
'
prog_mutated() {
  OUT="$(AUTO_ROOT="$AUTO_ROOT" "$PY" -c "$MUT_PY" "$@" 2>&1)"
  CODE=$?
}

remit() {
  local run="$1"; shift
  local doc="$1"; shift
  OUT="$(printf '%s' "$doc" | "$PY" "$PROG" set-remit --run "$run" "$@" 2>&1)"
  CODE=$?
}

end_programme() {
  local run="$1" p
  p="$(prompt "$run" '/auto:programme-end')"
  run_py "$run" "$p" <<'EOF' >/dev/null
source = pj.find_prompt(args[0], args[1])["payload"]["source"]
pj.append(args[0], "end_request", "sess-pm",
          {"verb": "end", "text": "/auto:programme-end", "origin": "typed", "space": "x",
           "lease_status": "live", "driving": True, "source": source}, cites=[args[1]])
EOF
  prog end --run "$run"
}

carried_rulings() {
  field "$1" 'sorted([rid, revs[-1]["kind"], revs[-1]["effect"], revs[-1]["state"], revs[-1]["applies_to"], revs[-1]["carried"]["from"]] for rid, revs in (prog.get("context") or {}).get("decisions", {}).items() if revs[-1].get("carried"))'
}

REMIT_A="{\"spaces\":[\"w2\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"},{\"path\":\"${ALPHA2}\"}]}"

# ── the stop predicate and the offer-made marker ─────────────────────────
RUN_P="$(new_programme w9)"
it "a programme with nothing to act on and no Ruling may stop"
check "True " "$(stop_state "$RUN_P")"
P_PW="$(prompt "$RUN_P" 'pw: worker coordination across the programme is yours')"
prog record-ruling pw --kind worker_coordination --effect grant --scope "PM coordinates workers" --prompt "$P_PW" --run "$RUN_P"
it "an active Ruling with no offer-made marker holds the stop"
check "0 False carryover_unoffered" "$CODE $(stop_state "$RUN_P")"
it "the hold applies under only_when_done too, where other reasons do not"
set_stop_rule "$RUN_P" only_when_done
check "False carryover_unoffered" "$(stop_state "$RUN_P")"
it "carry-rulings with no ids makes the offer, lists the Ruling and records the marker"
prog carry-rulings --run "$RUN_P"
check '0 ["pw"]' "$CODE $(field "$RUN_P" 'prog["carryover_offer"]["offered"]')"
has '"pw"' "$OUT"
it "making the offer releases the stop with no answer from Shawn"
check "True " "$(stop_state "$RUN_P")"
it "the offer is journaled"
has "carryover_offered" "$(run_py "$RUN_P" <<'EOF'
print(" ".join(r["kind"] for r in pj.read(args[0])))
EOF
)"
P_PX="$(prompt "$RUN_P" 'px: you pick the optimisation depth across the programme yourself')"
prog record-ruling px --kind optimisation_depth --effect grant --scope "PM picks depth" --prompt "$P_PX" --run "$RUN_P"
it "a Ruling recorded after the offer holds the stop again until it is offered"
check "False carryover_unoffered" "$(stop_state "$RUN_P")"
prog carry-rulings --run "$RUN_P"
check "True " "$(stop_state "$RUN_P")"
P_PE="$(prompt "$RUN_P" 'pe: acceptance across the programme until 2000')"
prog close-ruling px --as fulfilled --why "done" --run "$RUN_P"
prog record-ruling pe --kind acceptance --effect grant --scope "old" --until 2000-01-01T00:00:00Z --prompt "$P_PE" --run "$RUN_P"
it "an expired Ruling does not hold the stop"
check "True " "$(stop_state "$RUN_P")"

# ── offer and store ───────────────────────────────────────────────────────
RUN_A="$(new_programme w2)"
remit "$RUN_A" "$REMIT_A"
prog add-item herdr:a --title "a" --kind fix_only --run "$RUN_A"
P_G1="$(prompt "$RUN_A" 'g1: tool choice for herdr:a is yours')"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:a \
  --limit "no paid tools" --prompt "$P_G1" --run "$RUN_A"
P_R1="$(prompt "$RUN_A" 'r1: I pick the technical approach on herdr:a')"
prog record-ruling r1 --kind technical_approach --effect restrict --scope "Shawn picks approach" \
  --applies-to herdr:a --prompt "$P_R1" --run "$RUN_A"
P_EARLY="$(prompt "$RUN_A" 'carry g1 to the next programme')"

it "carry-rulings with ids needs a typed prompt"
prog carry-rulings g1 --run "$RUN_A"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
it "carry-rulings refuses a prompt typed before any offer"
prog carry-rulings g1 --prompt "$P_EARLY" --run "$RUN_A"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "offer" "$OUT"
it "carry-rulings with no ids offers every active Ruling"
prog carry-rulings --run "$RUN_A"
check '0 ["g1", "r1"]' "$CODE $(field "$RUN_A" 'prog["carryover_offer"]["offered"]')"
it "carry-rulings refuses a prompt that does not name the Ruling"
P_VAGUE="$(prompt "$RUN_A" 'yes carry that one')"
prog carry-rulings g1 --prompt "$P_VAGUE" --run "$RUN_A"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
it "carry-rulings refuses an id that is not an active Ruling"
P_NONE="$(prompt "$RUN_A" 'carry zz to the next programme')"
prog carry-rulings zz --prompt "$P_NONE" --run "$RUN_A"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
it "carry-rulings with a prompt after the offer naming the Ruling stores it under each remit repo key"
P_KEEP="$(prompt "$RUN_A" 'carry g1 to the next programme')"
prog carry-rulings g1 --prompt "$P_KEEP" --run "$RUN_A"
check '0 [["'"${ALPHA2}"'", "g1", "tool_choice", "grant"], ["shawn/alpha", "g1", "tool_choice", "grant"]]' "$CODE $("$PY" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(json.dumps(sorted([k, e["ruling"], e["kind"], e["effect"]] for k, v in doc["keys"].items() for e in v)))' "$STORE")"
it "the stored entry keeps the scope, limits and Shawn's words, and no items"
check '["PM picks tools", ["no paid tools"], "g1: tool choice for herdr:a is yours", false]' "$("$PY" -c '
import json, sys
e = json.load(open(sys.argv[1]))["keys"]["shawn/alpha"][0]
print(json.dumps([e["scope"], e["limits"], e["quote"], "applies_to" in e]))' "$STORE")"
it "the programme's prompt lookup approves every stored entry"
check "True" "$(run_py "$RUN_A" "$STORE" <<'EOF'
programme = load_lib_module("programme")
proto = load_lib_module("programme_protocol")
doc = json.load(open(args[1]))
print(all(proto.approval_key(f"carryover:{k}:{e['id']}", e["adoption"]["hash"])
          in programme.prompt_lookup(args[0], e["adoption"]["prompt_id"])["approved"]
          for k, v in doc["keys"].items() for e in v))
EOF
)"

prog carry-rulings --run "$RUN_A"
P_PRE_END="$(prompt "$RUN_A" 'carry r1 over')"
it "end lists the active Rulings for carry-over"
end_programme "$RUN_A"
check 0 "$CODE"
has "carry-over offer" "$OUT"
has "g1" "$OUT"
has "r1" "$OUT"
it "end journals the offer with the programme_ended row"
check '["g1", "r1"]' "$(run_py "$RUN_A" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "programme_ended"][-1]
print(json.dumps([e["id"] for e in row["payload"]["carryover"]]))
EOF
)"
it "after end, a prompt typed after the earlier offer and before the end offer still stores the pick"
prog carry-rulings r1 --prompt "$P_PRE_END" --run "$RUN_A"
check "0 2" "$CODE $("$PY" -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["keys"]["shawn/alpha"]))' "$STORE")"
it "after end, carry-rulings with a prompt typed after the end offer still stores the pick"
P_KEEP_R1="$(prompt "$RUN_A" 'carry r1 as well')"
prog carry-rulings r1 --prompt "$P_KEEP_R1" --run "$RUN_A"
check "0 2" "$CODE $("$PY" -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["keys"]["shawn/alpha"]))' "$STORE")"

# ── arrival in the next programme on the project ─────────────────────────
RUN_B="$(new_programme w3)"
prog propose-agreement --run "$RUN_B" --project-term "naming=kebab case files" --source "repo README"
remit "$RUN_B" "$REMIT_A"
it "set-remit on an unaccepted agreement brings each carried Ruling in pending, with no items"
check 0 "$CODE"
check '[["g1", "tool_choice", "grant", "pending_acceptance", [], "shawn/alpha"], ["r1", "technical_approach", "restrict", "pending_acceptance", [], "shawn/alpha"]]' "$(carried_rulings "$RUN_B")"
has '"carried_over"' "$OUT"
it "the pre-fill writes no project term, reserved or not"
check "[]" "$(field "$RUN_B" '[t["area"] for t in prog["agreement"].get("project_terms") or [] if t.get("origin") or t.get("reserved")]')"
it "the carried revision keeps the scope, limits and Shawn's old words apart from its own quote"
check '["PM picks tools", ["no paid tools"], null, "g1: tool choice for herdr:a is yours"]' \
  "$(field "$RUN_B" '[prog["context"]["decisions"]["g1"][-1][k] for k in ("scope", "limits", "quote")] + [prog["context"]["decisions"]["g1"][-1]["carried"]["quote"]]')"
it "set-remit again adds no second revision"
remit "$RUN_B" "$REMIT_A"
check "1 1" "$(field "$RUN_B" 'len(prog["context"]["decisions"]["g1"])') $(field "$RUN_B" 'len(prog["context"]["decisions"]["r1"])')"

prog add-item herdr:x --title "x" --kind fix_only --run "$RUN_B"
it "a pending carried Ruling reaches no gate"
check "" "$(run_py "$RUN_B" <<'EOF'
print(" ".join(r["id"] for r in pc.rulings_for(ph.normalize_programme(record(args[0])["programme"]), "herdr:x", "tool_choice", core.now_iso())))
EOF
)"
it "a typed prompt naming only the Ruling does not bind it to new items"
P_ID="$(prompt "$RUN_B" 'yes, g1 again')"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --limit "no paid tools" \
  --applies-to herdr:x --prompt "$P_ID" --run "$RUN_B"
check "nonzero pending" "$([ "$CODE" -ne 0 ] && echo nonzero) $(field "$RUN_B" 'prog["context"]["decisions"]["g1"][-1]["state"]' | tr -d '"' | sed 's/_acceptance//')"
it "a typed prompt naming the Ruling and its new items binds it, with a fresh baseline"
P_ITEMS="$(prompt "$RUN_B" 'g1 tool choice applies to herdr:x now')"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --limit "no paid tools" \
  --applies-to herdr:x --prompt "$P_ITEMS" --run "$RUN_B"
check '0 "accepted" ["herdr:x"] "act"' "$CODE $(field "$RUN_B" 'prog["context"]["decisions"]["g1"][-1]["state"]') $(field "$RUN_B" 'prog["context"]["decisions"]["g1"][-1]["applies_to"]') $(field "$RUN_B" 'prog["context"]["decisions"]["g1"][-1]["baseline"]')"
it "a carried restrict proposed with items but no prompt stays pending"
prog record-ruling r1 --kind technical_approach --effect restrict --scope "Shawn picks approach" \
  --applies-to herdr:x --run "$RUN_B"
check '0 "pending_acceptance"' "$CODE $(field "$RUN_B" 'prog["context"]["decisions"]["r1"][-1]["state"]')"
it "accept-context refuses a prompt that names the carried Ruling but not its new items"
P_ACC="$(prompt "$RUN_B" 'accept r1')"
prog accept-context r1 --prompt "$P_ACC" --run "$RUN_B"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
it "accept-context with a prompt naming the new items binds it"
P_ACC2="$(prompt "$RUN_B" 'accept r1 for herdr:x')"
prog accept-context r1 --prompt "$P_ACC2" --run "$RUN_B"
check '0 "accepted"' "$CODE $(field "$RUN_B" 'prog["context"]["decisions"]["r1"][-1]["state"]')"
it "once bound, set-remit brings no second copy"
remit "$RUN_B" "$REMIT_A"
check "2 2" "$(field "$RUN_B" 'len(prog["context"]["decisions"]["g1"])') $(field "$RUN_B" 'len(prog["context"]["decisions"]["r1"])')"

it "set-remit on an accepted agreement never reads the store"
RUN_E="$(new_programme w6)"
prog propose-agreement --run "$RUN_E" --term cadence=fixed
P_ACCEPT_E="$(prompt "$RUN_E" 'yes, I accept the agreement')"
prog accept-agreement --run "$RUN_E" --prompt "$P_ACCEPT_E"
P_ADD="$(prompt "$RUN_E" "add repo alpha to the remit")"
remit "$RUN_E" "{\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"}]}" --prompt "$P_ADD"
check "0 []" "$CODE $(carried_rulings "$RUN_E")"

it "a carried Ruling whose id is taken is skipped with a notice"
RUN_T="$(new_programme w7)"
P_T="$(prompt "$RUN_T" 'g1: I decided the tool choice for the programme myself')"
prog record-ruling g1 --kind tool_choice --effect decided --scope "Shawn's tools" --prompt "$P_T" --run "$RUN_T"
remit "$RUN_T" "{\"spaces\":[\"w7\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"}]}"
check "0 decided" "$CODE $(field "$RUN_T" 'prog["context"]["decisions"]["g1"][-1]["effect"]' | tr -d '"')"
has "g1" "$(printf '%s' "$OUT" | grep -o '"notices".*')"

# ── another repo ──────────────────────────────────────────────────────────
RUN_C="$(new_programme w4)"
remit "$RUN_C" "{\"spaces\":[\"w4\"],\"repos\":[{\"path\":\"${BETA}\"}]}"
it "a programme on another repo gets no carried Ruling"
check "0 []" "$CODE $(carried_rulings "$RUN_C")"

# Hand-written store entries for gamma: none has a valid adoption.
"$PY" - "$STORE" "$GAMMA" "$AUTO_ROOT" <<'EOF'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[3], "lib"))
from _bootstrap import load_lib_module
proto = load_lib_module("programme_protocol")
doc = json.load(open(sys.argv[1]))
base = dict(doc["keys"]["shawn/alpha"][0])
def forged(entry_id, ruling, adoption, **extra):
    entry = {k: v for k, v in base.items() if k != "adoption"}
    entry.update(id=entry_id, key=sys.argv[2], ruling=ruling, **extra)
    if adoption is not None:
        entry["adoption"] = dict(base["adoption"], **adoption)
        if adoption.get("hash") is None:
            entry["adoption"]["hash"] = proto.content_hash(entry)
    return entry
doc["keys"][sys.argv[2]] = [
    forged("kbare00", "fa", None),
    forged("kmach00", "fb", {"machine": "elsewhere"}),
    forged("khash00", "fc", {"hash": base["adoption"]["hash"]}),
    forged("kuntil0", "fd", {"hash": None}, until="tomorrow"),
]
json.dump(doc, open(sys.argv[1], "w"))
EOF

RUN_D="$(new_programme w5)"
prog propose-agreement --run "$RUN_D" --term cadence=fixed
rm -rf "${WORK}/data.bak"
/bin/cp -Rp "$CLAUDE_AUTO_DATA_DIR" "${WORK}/data.bak"
it "mutation: with the adoption check patched out the forged entries arrive"
prog_mutated set-remit --run "$RUN_D" < <(printf '%s' "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}")
check "0 3" "$CODE $(field "$RUN_D" 'len([r for r, v in (prog.get("context") or {}).get("decisions", {}).items() if v[-1].get("carried")])')"
it "a carried entry whose end date is not ISO time is dropped with a notice, not carried"
has "dropped carried-over entry kuntil0" "$OUT"
check "false" "$(field "$RUN_D" '"fd" in (prog.get("context") or {}).get("decisions", {})')"
rm -rf "$CLAUDE_AUTO_DATA_DIR"
/bin/cp -Rp "${WORK}/data.bak" "$CLAUDE_AUTO_DATA_DIR"

remit "$RUN_D" "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}"
it "store entries that do not verify bring nothing in"
check "0 []" "$CODE $(carried_rulings "$RUN_D")"
it "a store entry with no adoption block is dropped with a notice naming it"
has "kbare00" "$OUT"
it "a store entry adopted on another machine is dropped with a notice naming it"
has "kmach00" "$OUT"
it "a store entry whose content no longer matches its hash is dropped with a notice naming it"
has "khash00" "$OUT"

# ── a stale offer ─────────────────────────────────────────────────────────
RUN_F="$(new_programme w8)"
PHI="${WORK}/repos/phi"
mkdir -p "$PHI"
remit "$RUN_F" "{\"spaces\":[\"w8\"],\"repos\":[{\"path\":\"${PHI}\"}]}"
prog add-item herdr:f --title "f" --kind fix_only --run "$RUN_F"
P_F1="$(prompt "$RUN_F" 'f1: tool choice for herdr:f is yours, no paid tools')"
prog record-ruling f1 --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:f \
  --limit "no paid tools" --prompt "$P_F1" --run "$RUN_F"
prog carry-rulings --run "$RUN_F"
it "the offer records the revision of each Ruling it lists"
check '[["f1", 1]]' "$(run_py "$RUN_F" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "carryover_offered"][-1]
print(json.dumps([[e["id"], e.get("rev")] for e in row["payload"]["carryover"] if e.get("source") == "ruling"]))
EOF
)"
prog record-ruling f1 --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:f --run "$RUN_F"
P_F2="$(prompt "$RUN_F" 'accept f1, drop the no paid tools limit')"
prog accept-context f1 --prompt "$P_F2" --run "$RUN_F"
it "carry-rulings refuses a Ruling that changed after the offer Shawn answered"
P_FC="$(prompt "$RUN_F" 'carry f1 to the next programme')"
prog carry-rulings f1 --prompt "$P_FC" --run "$RUN_F"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "changed after the offer" "$OUT"
it "after a fresh offer, a prompt typed after it carries the new revision"
prog carry-rulings --run "$RUN_F"
P_FC2="$(prompt "$RUN_F" 'carry f1 to the next programme')"
prog carry-rulings f1 --prompt "$P_FC2" --run "$RUN_F"
check "0" "$CODE"
it "a prompt that already carried a Ruling cannot approve another Ruling change"
prog record-ruling f2 --kind technical_approach --effect restrict --scope "x" --applies-to herdr:f \
  --prompt "$P_FC2" --run "$RUN_F"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "already approved" "$OUT"

# ── which rows the carry checks read ──────────────────────────────────────
it "carry-rulings refuses a prompt that already approved a record-ruling"
prog carry-rulings --run "$RUN_F"
P_FU="$(prompt "$RUN_F" 'carry f1, and f3: I pick the technical approach on herdr:f')"
prog record-ruling f3 --kind technical_approach --effect restrict --scope "f3" --applies-to herdr:f \
  --prompt "$P_FU" --run "$RUN_F"
K1="$CODE"
prog carry-rulings f1 --prompt "$P_FU" --run "$RUN_F"
check "0 nonzero" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero)"
has "already approved" "$OUT"

it "carry-rulings refuses a prompt when Shawn typed a later prompt nothing has cited"
prog carry-rulings --run "$RUN_F"
P_FL1="$(prompt "$RUN_F" 'carry f1 to the next programme')"
P_FL2="$(prompt "$RUN_F" "no, don't carry f1")"
prog carry-rulings f1 --prompt "$P_FL1" --run "$RUN_F"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "newest typed prompt" "$OUT"

it "carry-rulings refuses an offer that did not record the Ruling's revision"
run_py "$RUN_F" <<'EOF' >/dev/null
pj.append(args[0], "carryover_offered", "sess-pm",
          {"carryover": [{"source": "ruling", "id": "f1", "kind": "tool_choice", "effect": "grant", "scope": "x",
                          "items": ["herdr:f"]}]})
EOF
P_FN="$(prompt "$RUN_F" 'carry f1 to the next programme')"
prog carry-rulings f1 --prompt "$P_FN" --run "$RUN_F"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "changed after the offer" "$OUT"

it "a prompt typed before set-remit brought a carried Ruling in cannot bind it"
RUN_G="$(new_programme w10)"
prog propose-agreement --run "$RUN_G" --project-term "naming=kebab case files" --source "repo README"
P_GPRE="$(prompt "$RUN_G" 'g1 tool choice applies to herdr:y now')"
remit "$RUN_G" "{\"spaces\":[\"w10\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"}]}"
prog add-item herdr:y --title "y" --kind fix_only --run "$RUN_G"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --limit "no paid tools" \
  --applies-to herdr:y --prompt "$P_GPRE" --run "$RUN_G"
check "nonzero pending_acceptance" "$([ "$CODE" -ne 0 ] && echo nonzero) $(field "$RUN_G" 'prog["context"]["decisions"]["g1"][-1]["state"]' | tr -d '"')"
has "typed before the latest change" "$OUT"

# ── a carry is checked and journaled under the programme's write lock ─────
home_of() {
  run_py "$1" <<'EOF'
print(ph.home_path(args[0]))
EOF
}
wait_for() { local i; for i in $(seq 1 200); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
# race <home> <first verb args> -- <second command>: the first writer pauses after its checks, before its
# approval row reaches the journal; the second command runs during that pause.
race() {
  local home="$1" first=()
  shift
  while [ "$1" != "--" ]; do first+=("$1"); shift; done
  shift
  rm -f "${WORK}/race1.out" "${WORK}/race2.out"
  CLAUDE_AUTO_TEST_WRITE_PAUSE_BEFORE_JOURNAL=1 "$PY" "$PROG" "${first[@]}" > "${WORK}/race1.out" 2>&1 &
  local p1=$!
  PAUSED="never paused"; wait_for "${WORK}/race1.out" "paused:write_before_journal" && PAUSED="paused"
  "$@" > "${WORK}/race2.out" 2>&1 &
  local p2=$!
  sleep 1
  # A second writer that never waited on the lock has finished or printed by now.
  BLOCKED="not blocked"; kill -0 "$p2" 2>/dev/null && [ ! -s "${WORK}/race2.out" ] && BLOCKED="blocked"
  touch "${home}/.test-resume-write"
  wait "$p1"; C1=$?
  wait "$p2"; C2=$?
  OUT2="$(cat "${WORK}/race2.out")"
}
RUN_Q="$(new_programme w12)"
R="$RUN_Q"
REPO_R="${WORK}/repos/race-promoted"
mkdir -p "$REPO_R"
remit "$R" "{\"spaces\":[\"w12\"],\"repos\":[{\"path\":\"${REPO_R}\"}]}"
prog add-item herdr:q --title "q" --kind fix_only --run "$R"
P_Q1="$(prompt "$R" 'q1: I pick the technical approach on herdr:q')"
prog record-ruling q1 --kind technical_approach --effect restrict --scope "q1" --applies-to herdr:q \
  --prompt "$P_Q1" --run "$R"
prog carry-rulings --run "$R"
it "a carry racing a record-ruling on the same prompt is refused once the record-ruling journals"
P_QR="$(prompt "$R" 'carry q1, and q2: I pick the work sequencing on herdr:q')"
race "$(home_of "$R")" record-ruling q2 --kind work_sequencing --effect restrict --scope "q2" \
  --applies-to herdr:q --prompt "$P_QR" --run "$R" -- "$PY" "$PROG" carry-rulings q1 --prompt "$P_QR" --run "$R"
check "paused blocked 0 nonzero" "$PAUSED $BLOCKED $C1 $([ "$C2" -ne 0 ] && echo nonzero)"
has "already approved" "$OUT2"

it "a carry racing a change to the Ruling re-reads its revision and refuses the stale offer"
prog record-ruling q1 --kind technical_approach --effect restrict --scope "q1" --run "$R"
prog carry-rulings --run "$R"
P_QC="$(prompt "$R" 'carry q1 to the next programme')"
P_QA="$(prompt "$R" 'accept q1 for herdr:q')"
race "$(home_of "$R")" accept-context q1 --prompt "$P_QA" --run "$R" -- \
  "$PY" "$PROG" carry-rulings q1 --prompt "$P_QC" --run "$R"
check "paused blocked 0 nonzero" "$PAUSED $BLOCKED $C1 $([ "$C2" -ne 0 ] && echo nonzero)"
has "changed after the offer" "$OUT2"

it "a rulings_carried row approves each stored entry; a foreign row or one citing another prompt first approves nothing"
check "True" "$(run_py <<'EOF'
programme = load_lib_module("programme")
pp = programme.programme_protocol
def carried(cites, prompt_id, stored, **extra):
    return dict({"kind": "rulings_carried", "cites": cites, "payload": {"prompt_id": prompt_id, "stored": stored}}, **extra)
rows = [
    carried(["pa1"], "pa1", [{"key": "/r/a", "id": "k1", "hash": "h1"}, {"key": "/r/b", "id": "k2", "hash": "h2"}]),
    carried(["pa1"], "pa1", [{"key": "/r/c", "id": "k3", "hash": "h3"}], provenance=programme.programme_authority.FOREIGN),
    carried(["pb2", "pa1"], "pa1", [{"key": "/r/d", "id": "k4", "hash": "h4"}]),
    carried(["pa1"], "pb2", [{"key": "/r/e", "id": "k5", "hash": "h5"}]),
]
want = [pp.approval_key(pp.carryover_target("/r/a", "k1"), "h1"), pp.approval_key(pp.carryover_target("/r/b", "k2"), "h2")]
print(programme._approved(rows, "pa1") == want and programme._approved(rows, "pb2") == [])
EOF
)"

# ── a carry that dies right after its write still arrives ─────────────────
CRASH_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
authority = programme.programme_authority
write = authority.write
def write_then_die(*a, **k):
    write(*a, **k)
    os._exit(9)
authority.write = write_then_die
sys.exit(programme._cli(sys.argv[1:]))
'
REPO_K="${WORK}/repos/crash-promoted"
mkdir -p "$REPO_K"
remit "$R" "{\"spaces\":[\"w12\"],\"repos\":[{\"path\":\"${REPO_K}\"}]}"
prog carry-rulings --run "$R"
P_K="$(prompt "$R" 'carry q2 to the next programme')"
OUT="$(AUTO_ROOT="$AUTO_ROOT" "$PY" -c "$CRASH_PY" carry-rulings q2 --prompt "$P_K" --run "$R" 2>&1)"
CODE=$?
it "a carry killed straight after its locked write leaves its entry in the store"
check "9 1" "$CODE $("$PY" -c '
import json, sys
print(len([e for e in json.load(open(sys.argv[1]))["keys"].get(sys.argv[2], []) if e["ruling"] == "q2"]))' "$STORE" "$REPO_K")"
it "the next programme's pre-fill verifies that entry from the rulings_carried row alone"
RUN_K="$(new_programme w13)"
prog propose-agreement --run "$RUN_K" --project-term "naming=kebab case files" --source "repo README"
remit "$RUN_K" "{\"spaces\":[\"w13\"],\"repos\":[{\"path\":\"${REPO_K}\"}]}"
check "0 q2" "$CODE $(field "$RUN_K" '" ".join(r for r, v in (prog.get("context") or {}).get("decisions", {}).items() if v[-1].get("carried"))' | tr -d '"')"
lacks "dropped carried-over entry" "$OUT"

# ── the store is a cache of the rulings_carried rows ─────────────────────
# DIE_AT=put kills the carry after its row and record commit, before the store write.
DIE_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
load_lib_module("programme_carryover")._put = lambda adopted: os._exit(9)
sys.exit(programme._cli(sys.argv[1:]))
'
stored_under() {
  "$PY" -c '
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except OSError:
    doc = {"keys": {}}
print(len([e for e in doc["keys"].get(sys.argv[2], []) if e["ruling"] == sys.argv[3]]))' "$STORE" "$1" "$2"
}
carried_rows() {
  run_py "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "rulings_carried" and r["payload"].get("adopted")))
EOF
}
# heal_case <run> <label> <die-at> <space> <next-space> [--op <id>]
heal_case() {
  local run="$1" label="$2" at="$3" space="$4" next="$5"
  shift 5
  local repo="${WORK}/repos/heal-${label}-${at}"
  mkdir -p "$repo"
  remit "$run" "{\"spaces\":[\"${space}\"],\"repos\":[{\"path\":\"${repo}\"}]}"
  prog carry-rulings --run "$run"
  local p
  p="$(prompt "$run" 'carry q2 to the next programme')"
  N_ROWS="$(carried_rows "$run")"
  OUT="$(AUTO_ROOT="$AUTO_ROOT" DIE_AT="$at" "$PY" -c "$DIE_PY" carry-rulings q2 --prompt "$p" --run "$run" "$@" 2>&1)"
  CODE=$?
  it "$label ($at): a carry killed after its row stores nothing yet, and its row holds the adopted entries"
  check "9 0 $((N_ROWS + 1))" "$CODE $(stored_under "$repo" q2) $(carried_rows "$run")"
  it "$label ($at): the spent prompt cannot carry again"
  prog carry-rulings q2 --prompt "$p" --run "$run"
  check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
  if [ "$#" -gt 0 ]; then
    it "$label ($at): a replay of the same operation id reports the carry and still stores nothing"
    prog carry-rulings q2 --prompt "$p" --run "$run" "$@"
    check "0 true 0" "$CODE $(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(str(json.load(sys.stdin).get("replayed")).lower())' 2>&1) $(stored_under "$repo" q2)"
  fi
  it "$label ($at): the next programme's pre-fill refills the store from the row and brings the Ruling in"
  local next_run
  next_run="$(new_programme "$next")"
  prog propose-agreement --run "$next_run" --project-term "naming=kebab case files" --source "repo README"
  remit "$next_run" "{\"spaces\":[\"${next}\"],\"repos\":[{\"path\":\"${repo}\"}]}"
  check "0 q2 1" "$CODE $(field "$next_run" '" ".join(r for r, v in (prog.get("context") or {}).get("decisions", {}).items() if v[-1].get("carried"))' | tr -d '"') $(stored_under "$repo" q2)"
  lacks "dropped carried-over entry" "$OUT"
  it "$label ($at): a second pre-fill stores nothing twice"
  remit "$next_run" "{\"spaces\":[\"${next}\"],\"repos\":[{\"path\":\"${repo}\"}]}"
  check "0 1" "$CODE $(stored_under "$repo" q2)"
}
heal_case "$RUN_Q" promoted put w12 w15
heal_case "$RUN_Q" promoted-replay put w12 w18 --op carry-heal-1

it "a refill never overwrites a later carry of the same Ruling"
check "kept-newer" "$(run_py "$RUN_Q" <<'EOF'
carry = load_lib_module("programme_carryover")
row = next(r for r in reversed(pj.read(args[0])) if r["kind"] == "rulings_carried" and r["payload"].get("adopted"))
entry = row["payload"]["adopted"][0]
doc = {"format": 1, "keys": {entry["key"]: [dict(entry, id="knewer0", at="2999-01-01T00:00:00Z")]}}
print("kept-newer" if not carry._missing(doc, entry) else "overwrote")
EOF
)"

it "a refill skips an adopted entry its row does not approve: nothing is stored or carried"
REPO_FORGE="${WORK}/repos/heal-forged"
mkdir -p "$REPO_FORGE"
run_py "$RUN_Q" "$REPO_FORGE" <<'EOF' >/dev/null
import copy
proto = load_lib_module("programme_protocol")
row = next(r for r in reversed(pj.read(args[0])) if r["kind"] == "rulings_carried" and r["payload"].get("adopted"))
forged = copy.deepcopy(row["payload"]["adopted"][0])
forged.update(id="kforge0", key=args[1], scope="widened by hand")
forged["adoption"]["hash"] = proto.content_hash(forged)
pj.append(args[0], "rulings_carried", "sess-pm", dict(row["payload"], adopted=[forged]), cites=row["cites"])
EOF
RUN_FG="$(new_programme w19)"
prog propose-agreement --run "$RUN_FG" --project-term "naming=kebab case files" --source "repo README"
remit "$RUN_FG" "{\"spaces\":[\"w19\"],\"repos\":[{\"path\":\"${REPO_FORGE}\"}]}"
check "0 0 []" "$CODE $(stored_under "$REPO_FORGE" q2) $(carried_rulings "$RUN_FG")"

# ── a carry or pre-fill on a legacy home moves it to programme.db first ───
new_legacy() {
  run_py "$1" <<'EOF'
load_lib_module("programme_authority").home_for = lambda *a: None
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
}
is_promoted() {
  run_py "$1" <<'EOF'
print(load_lib_module("programme_authority").promoted(ph.home_path(args[0]), args[0]))
EOF
}
# copy_into <legacy run> <source run> <ruling id>: the source's remit repos and that Ruling, written into the
# legacy record, as a home written by an earlier build of this branch could hold them.
copy_into() {
  run_py "$1" "$2" "$3" <<'EOF' >/dev/null
src = record(args[1])["programme"]
def change(rec):
    rec["programme"].setdefault("remit", {})["repos"] = src["remit"]["repos"]
    rec["programme"].setdefault("context", {}).setdefault("decisions", {})[args[2]] = src["context"]["decisions"][args[2]]
core._with_locked_run_record(ph.home_path(args[0]), args[0], change)
EOF
}
stored_field() {
  "$PY" -c '
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except OSError:
    doc = {"keys": {}}
print(" ".join(str(e.get(sys.argv[4])) for e in doc["keys"].get(sys.argv[2], []) if e["ruling"] == sys.argv[3]))' \
    "$STORE" "$1" "$2" "$3"
}
LREPO="${WORK}/repos/legacy-carry"
mkdir -p "$LREPO"
RUN_S="$(new_programme w20)"
remit "$RUN_S" "{\"spaces\":[\"w20\"],\"repos\":[{\"path\":\"${LREPO}\"}]}"
prog add-item herdr:l --title "l" --kind fix_only --run "$RUN_S"
P_L1="$(prompt "$RUN_S" 'l1: I pick the technical approach on herdr:l')"
prog record-ruling l1 --kind technical_approach --effect restrict --scope "l1" --applies-to herdr:l \
  --prompt "$P_L1" --run "$RUN_S"
RUN_LC="$(new_legacy w21)"
prog add-item herdr:l --title "l" --kind fix_only --run "$RUN_LC"
copy_into "$RUN_LC" "$RUN_S" l1
end_programme "$RUN_LC"
it "legacy: end is no Ruling change and keeps the JSON files"
check "0 False" "$CODE $(is_promoted "$RUN_LC")"
it "legacy, ended: carry-rulings moves the home, then refuses a prompt typed before the move"
prog carry-rulings l1 --prompt "$(prompt "$RUN_LC" 'carry l1 to the next programme')" --run "$RUN_LC"
check "nonzero True" "$([ "$CODE" -ne 0 ] && echo nonzero) $(is_promoted "$RUN_LC")"
has "imported from a legacy journal" "$OUT"
it "legacy, ended: a prompt typed after the move stores the pick from the moved home"
prog carry-rulings l1 --prompt "$(prompt "$RUN_LC" 'carry l1 to the next programme')" --run "$RUN_LC"
check "0 $RUN_LC" "$CODE $(stored_field "$LREPO" l1 run_id)"

RUN_LN="$(new_legacy w22)"
RUN_QN="$(new_programme w23)"
for R in "$RUN_LN" "$RUN_QN"; do
  prog propose-agreement --run "$R" --project-term "naming=kebab case files" --source "repo README"
done
it "legacy, unaccepted: set-remit moves the home first, then brings the carried Ruling in as a promoted run does"
remit "$RUN_LN" "{\"spaces\":[\"w22\"],\"repos\":[{\"path\":\"${LREPO}\"}]}"
K1="$CODE $(is_promoted "$RUN_LN")"
remit "$RUN_QN" "{\"spaces\":[\"w23\"],\"repos\":[{\"path\":\"${LREPO}\"}]}"
check "0 True 0" "$K1 $CODE"
has '"l1", "technical_approach", "restrict", "pending_acceptance"' "$(carried_rulings "$RUN_LN")"
check "$(carried_rulings "$RUN_QN")" "$(carried_rulings "$RUN_LN")"

RUN_LA="$(new_legacy w24)"
run_py "$RUN_LA" <<'EOF' >/dev/null
core._with_locked_run_record(ph.home_path(args[0]), args[0], lambda rec: rec["programme"]["agreement"].update(
    accepted={"at": core.now_iso(), "prompt_id": "p-accepted"}))
EOF
it "legacy, accepted: set-remit cannot carry a Ruling in, so it keeps the JSON files"
remit "$RUN_LA" "$(field "$RUN_LA" 'prog["remit"]')" --prompt "$(prompt "$RUN_LA" 'keep the remit as it is')"
check "0 False" "$CODE $(is_promoted "$RUN_LA")"

# The wrapper spies on the legacy write path; PROMOTE_MODE=lie makes promotion report success without
# moving anything, so the legacy write's own refusal is what stops the change.
SPY_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
auth = programme.programme_authority
if os.environ.get("PROMOTE_MODE") == "lie":
    load_lib_module("programme_import").promote = lambda run_id: {"status": "promoted"}
legacy_write = auth._legacy_write
def spied(*a, **k):
    open(os.environ["SPY"], "a").write("entered\n")
    return legacy_write(*a, **k)
auth._legacy_write = spied
sys.exit(programme._cli(sys.argv[1:]))
'
spy_prog() {
  local mode="$1" input="$2"
  shift 2
  rm -f "${WORK}/spy"
  OUT="$(printf '%s' "$input" | AUTO_ROOT="$AUTO_ROOT" PROMOTE_MODE="$mode" SPY="${WORK}/spy" "$PY" -c "$SPY_PY" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
  ENTERED="$([ -e "${WORK}/spy" ] && echo entered || echo skipped)"
}
# home_hash <run> [store]: the legacy record and journal bytes (and the carry-over store's), and whether a
# programme.db or an import marker exists.
home_hash() {
  run_py "$1" "${2:-}" <<'EOF'
import hashlib
home = ph.home_path(args[0])
paths = [core.run_record_path(home, args[0]), os.path.join(home, "journal.jsonl")]
paths += [load_lib_module("programme_carryover").store_path()] if args[1] else []
def digest(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12]
    except FileNotFoundError:
        return "absent"
print(" ".join(digest(p) for p in paths), os.path.exists(os.path.join(home, "programme.db")),
      os.path.exists(os.path.join(home, ".import-in-progress")))
EOF
}
CS="zq-carry-secret-5582"
printf 'CARRY_TOKEN=%s\n' "$CS" >> "$CLAUDE_AUTO_SECRETS_FILE"
hold_secret() {
  run_py "$1" "$CS" <<'EOF' >/dev/null
core._with_locked_run_record(ph.home_path(args[0]), args[0], lambda rec: rec["programme"]["working_model"].update(
    doing="deploy using " + args[1]))
EOF
}
RUN_LF="$(new_legacy w25)"
prog add-item herdr:l --title "l" --kind fix_only --run "$RUN_LF"
copy_into "$RUN_LF" "$RUN_S" l1
end_programme "$RUN_LF"
P_LF="$(prompt "$RUN_LF" 'carry l1 to the next programme')"
hold_secret "$RUN_LF"
H_LF="$(home_hash "$RUN_LF" store)"
it "legacy, promotion declined: carry-rulings refuses, never takes the legacy write path, home and store byte-identical"
spy_prog none "" carry-rulings l1 --prompt "$P_LF" --run "$RUN_LF"
check "nonzero skipped False False" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(echo "$H_LF" | awk '{print $4, $5}')"
check "$H_LF" "$(home_hash "$RUN_LF" store)"
has "Moving it to programme.db failed: privacy admission is" "$OUT"
it "legacy, promotion reporting success without moving: the legacy write refuses the rulings_carried row, store unchanged"
spy_prog lie "" carry-rulings l1 --prompt "$P_LF" --run "$RUN_LF"
check "nonzero entered $H_LF" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$RUN_LF" store)"
has "never take a rulings_carried row" "$OUT"

RUN_LG="$(new_legacy w33)"
prog propose-agreement --run "$RUN_LG" --project-term "naming=kebab case files" --source "repo README"
hold_secret "$RUN_LG"
H_LG="$(home_hash "$RUN_LG")"
REMIT_LG="{\"spaces\":[\"w33\"],\"repos\":[{\"path\":\"${LREPO}\"}]}"
it "legacy, promotion declined: set-remit on an unaccepted agreement refuses before anything is written"
spy_prog none "$REMIT_LG" set-remit --run "$RUN_LG"
check "nonzero skipped $H_LG" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$RUN_LG")"
has "set-remit can change a Ruling" "$OUT"
it "legacy, promotion reporting success without moving: the legacy write refuses a remit_set row that carried a Ruling in"
spy_prog lie "$REMIT_LG" set-remit --run "$RUN_LG"
check "nonzero entered $H_LG" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$RUN_LG")"
has "never take a remit_set row" "$OUT"

# ── what pre-fill refills from the rulings_carried rows ───────────────────
# die_carry <run> <ruling>: a fresh offer and prompt, then a carry killed before its store write. It sets no
# remit, since a set-remit would refill the store first.
die_carry() {
  local run="$1" rid="$2"
  prog carry-rulings --run "$run"
  OUT="$(AUTO_ROOT="$AUTO_ROOT" DIE_AT=put "$PY" -c "$DIE_PY" carry-rulings "$rid" \
    --prompt "$(prompt "$run" "carry ${rid} to the next programme")" --run "$run" 2>&1)"
  CODE=$?
}
next_programme() {
  local space="$1" repo="$2" run
  run="$(new_programme "$space")"
  prog propose-agreement --run "$run" --project-term "naming=kebab case files" --source "repo README"
  remit "$run" "{\"spaces\":[\"${space}\"],\"repos\":[{\"path\":\"${repo}\"}]}"
}

REPO_V1="${WORK}/repos/refill-v1"; REPO_V2="${WORK}/repos/refill-v2"
mkdir -p "$REPO_V1" "$REPO_V2"
remit "$RUN_Q" "{\"spaces\":[\"w12\"],\"repos\":[{\"path\":\"${REPO_V1}\"},{\"path\":\"${REPO_V2}\"}]}"
die_carry "$RUN_Q" q2
it "a carry to two repos killed before its store write stores neither"
check "9  " "$CODE $(stored_field "$REPO_V1" q2 id) $(stored_field "$REPO_V2" q2 id)"
it "a refill writes only the carried rows for the next programme's own remit repos"
next_programme w34 "$REPO_V1"
check "0 1 0" "$CODE $(stored_under "$REPO_V1" q2) $(stored_under "$REPO_V2" q2)"

REPO_W="${WORK}/repos/refill-older"
mkdir -p "$REPO_W"
remit "$RUN_Q" "{\"spaces\":[\"w12\"],\"repos\":[{\"path\":\"${REPO_W}\"}]}"
prog carry-rulings --run "$RUN_Q"
prog carry-rulings q2 --prompt "$(prompt "$RUN_Q" 'carry q2 to the next programme')" --run "$RUN_Q"
OLD_ID="$(stored_field "$REPO_W" q2 id)"
sleep 1
die_carry "$RUN_Q" q2
NEW_ID="$(run_py "$RUN_Q" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "rulings_carried"][-1]
print(row["payload"]["adopted"][0]["id"])
EOF
)"
it "a refill replaces an older stored entry for the same Ruling with the newer carried one"
K1="$CODE $([ -n "$OLD_ID" ] && [ "$OLD_ID" != "$NEW_ID" ] && echo distinct) $(stored_field "$REPO_W" q2 id)"
next_programme w35 "$REPO_W"
check "9 distinct $OLD_ID 0 $NEW_ID" "$K1 $CODE $(stored_field "$REPO_W" q2 id)"

REPO_N="${WORK}/repos/refill-newest"
mkdir -p "$REPO_N"
RUN_N1="$(new_programme w36)"
RUN_N2="$(new_programme w37)"
FIRST="$(printf '%s\n%s\n' "$RUN_N1" "$RUN_N2" | LC_ALL=C sort | head -1)"
SECOND="$(printf '%s\n%s\n' "$RUN_N1" "$RUN_N2" | LC_ALL=C sort | tail -1)"
for R in "$SECOND" "$FIRST"; do
  remit "$R" "{\"spaces\":[\"$([ "$R" = "$RUN_N1" ] && echo w36 || echo w37)\"],\"repos\":[{\"path\":\"${REPO_N}\"}]}"
  prog add-item herdr:n --title "n" --kind fix_only --run "$R"
  prog record-ruling n1 --kind technical_approach --effect restrict --scope "n1 from $R" --applies-to herdr:n \
    --prompt "$(prompt "$R" 'n1: I pick the technical approach on herdr:n')" --run "$R"
done
# The run the refill scans second carries first, so the scan meets the newer carry before the older one.
die_carry "$SECOND" n1
K1="$CODE"
sleep 1
die_carry "$FIRST" n1
K1="$K1 $CODE"
it "across programmes, a refill keeps the newest carry of a Ruling whichever run it scans first"
next_programme w38 "$REPO_N"
check "9 9 0 1 $FIRST" "$K1 $CODE $(stored_under "$REPO_N" n1) $(stored_field "$REPO_N" n1 run_id)"

REPO_U="${WORK}/repos/refill-unreadable"
mkdir -p "$REPO_U"
remit "$RUN_Q" "{\"spaces\":[\"w12\"],\"repos\":[{\"path\":\"${REPO_U}\"}]}"
die_carry "$RUN_Q" q2
RUN_BAD="$(new_programme w39)"
BAD_DB="$(run_py "$RUN_BAD" <<'EOF'
print(os.path.join(ph.home_path(args[0]), "programme.db"))
EOF
)"
command cp "$BAD_DB" "${WORK}/bad.db.bak"
printf 'not a database' > "$BAD_DB"
it "a programme journal that cannot be read gives a notice, not a failure, and readable homes still refill"
next_programme w40 "$REPO_U"
check "0 1" "$CODE $(stored_under "$REPO_U" q2)"
has "carry-over rows of ${RUN_BAD} unreadable" "$OUT"
command cp "${WORK}/bad.db.bak" "$BAD_DB"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-carryover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

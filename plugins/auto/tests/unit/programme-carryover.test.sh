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
RUN_L="$(run_py <<'EOF'
load_lib_module("programme_authority").home_for = lambda *a: None
print(ph.create_programme(["w11"], "sess-pm")["run"])
EOF
)"
RUN_Q="$(new_programme w12)"
for R in "$RUN_Q" "$RUN_L"; do
  [ "$R" = "$RUN_Q" ] && { LABEL=promoted; SPACE=w12; } || { LABEL=legacy; SPACE=w11; }
  REPO_R="${WORK}/repos/race-${LABEL}"
  mkdir -p "$REPO_R"
  remit "$R" "{\"spaces\":[\"${SPACE}\"],\"repos\":[{\"path\":\"${REPO_R}\"}]}"
  prog add-item herdr:q --title "q" --kind fix_only --run "$R"
  P_Q1="$(prompt "$R" 'q1: I pick the technical approach on herdr:q')"
  prog record-ruling q1 --kind technical_approach --effect restrict --scope "q1" --applies-to herdr:q \
    --prompt "$P_Q1" --run "$R"
  prog carry-rulings --run "$R"
  it "$LABEL: a carry racing a record-ruling on the same prompt is refused once the record-ruling journals"
  P_QR="$(prompt "$R" 'carry q1, and q2: I pick the work sequencing on herdr:q')"
  race "$(home_of "$R")" record-ruling q2 --kind work_sequencing --effect restrict --scope "q2" \
    --applies-to herdr:q --prompt "$P_QR" --run "$R" -- "$PY" "$PROG" carry-rulings q1 --prompt "$P_QR" --run "$R"
  check "paused blocked 0 nonzero" "$PAUSED $BLOCKED $C1 $([ "$C2" -ne 0 ] && echo nonzero)"
  has "already approved" "$OUT2"
done

for R in "$RUN_Q" "$RUN_L"; do
  [ "$R" = "$RUN_Q" ] && LABEL=promoted || LABEL=legacy
  it "$LABEL: a carry racing a change to the Ruling re-reads its revision and refuses the stale offer"
  prog record-ruling q1 --kind technical_approach --effect restrict --scope "q1" --run "$R"
  prog carry-rulings --run "$R"
  P_QC="$(prompt "$R" 'carry q1 to the next programme')"
  P_QA="$(prompt "$R" 'accept q1 for herdr:q')"
  race "$(home_of "$R")" accept-context q1 --prompt "$P_QA" --run "$R" -- \
    "$PY" "$PROG" carry-rulings q1 --prompt "$P_QC" --run "$R"
  check "paused blocked 0 nonzero" "$PAUSED $BLOCKED $C1 $([ "$C2" -ne 0 ] && echo nonzero)"
  has "changed after the offer" "$OUT2"
done

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
for R in "$RUN_Q" "$RUN_L"; do
  [ "$R" = "$RUN_Q" ] && { LABEL=promoted; SPACE=w12; NEXT=w13; } || { LABEL=legacy; SPACE=w11; NEXT=w14; }
  REPO_K="${WORK}/repos/crash-${LABEL}"
  mkdir -p "$REPO_K"
  remit "$R" "{\"spaces\":[\"${SPACE}\"],\"repos\":[{\"path\":\"${REPO_K}\"}]}"
  prog carry-rulings --run "$R"
  P_K="$(prompt "$R" 'carry q2 to the next programme')"
  OUT="$(AUTO_ROOT="$AUTO_ROOT" "$PY" -c "$CRASH_PY" carry-rulings q2 --prompt "$P_K" --run "$R" 2>&1)"
  CODE=$?
  it "$LABEL: a carry killed straight after its locked write leaves its entry in the store"
  check "9 1" "$CODE $("$PY" -c '
import json, sys
print(len([e for e in json.load(open(sys.argv[1]))["keys"].get(sys.argv[2], []) if e["ruling"] == "q2"]))' "$STORE" "$REPO_K")"
  it "$LABEL: the next programme's pre-fill verifies that entry from the rulings_carried row alone"
  RUN_K="$(new_programme "$NEXT")"
  prog propose-agreement --run "$RUN_K" --project-term "naming=kebab case files" --source "repo README"
  remit "$RUN_K" "{\"spaces\":[\"${NEXT}\"],\"repos\":[{\"path\":\"${REPO_K}\"}]}"
  check "0 q2" "$CODE $(field "$RUN_K" '" ".join(r for r, v in (prog.get("context") or {}).get("decisions", {}).items() if v[-1].get("carried"))' | tr -d '"')"
  lacks "dropped carried-over entry" "$OUT"
done

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-carryover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

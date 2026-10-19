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
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
STORE="$CLAUDE_AUTO_CARRYOVER_STORE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr; do
  printf '#!/bin/sh\nexit 0\n' > "${FAKES}/${tool}"
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
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
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
  run_py "$1" "$2" "$3" <<'EOF'
run, origin, text = args
print(pj.append_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

stamp_contract() {
  run_py "$1" <<'EOF' >/dev/null
def mutate(rec):
    rec["programme"]["agreement"]["contract_version"] = 1
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}

hashes() {
  "$PY" - "$CLAUDE_AUTO_DATA_DIR" "$STORE" <<'EOF'
import hashlib, os, sys
out = []
for root, _, names in os.walk(sys.argv[1]):
    for name in sorted(names):
        if name.startswith("."):
            continue
        path = os.path.join(root, name)
        out.append(path + ":" + hashlib.sha256(open(path, "rb").read()).hexdigest())
store = sys.argv[2]
out.append("store:" + (hashlib.sha256(open(store, "rb").read()).hexdigest() if os.path.exists(store) else "none"))
print(hashlib.sha256("\n".join(sorted(out)).encode()).hexdigest())
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

# The switch is a module constant with no environment override, so tests turn it on
# inside the process that runs the verb. MUTATE patches one check out.
ON_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
load_lib_module("programme_terms").CORRECTIONS_ON = True
programme = load_lib_module("programme")
if os.environ.get("MUTATE") == "adoption":
    load_lib_module("programme_protocol")._verify_adoption = lambda *a, **k: None
sys.exit(programme._cli(sys.argv[1:]))
'
prog_on() {
  OUT="$(AUTO_ROOT="$AUTO_ROOT" MUTATE="${MUTATE:-}" "$PY" -c "$ON_PY" "$@" 2>&1)"
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
  p="$(prompt "$run" typed '/auto:programme-end')"
  run_py "$run" "$p" <<'EOF' >/dev/null
pj.append(args[0], "end_request", "sess-pm",
          {"verb": "end", "text": "/auto:programme-end", "origin": "typed", "space": "x",
           "lease_status": "live", "driving": True}, cites=[args[1]])
EOF
  if [ "${2:-}" = on ]; then prog_on end --run "$run"; else prog end --run "$run"; fi
}

correct() {
  local run="$1" item="$2" kind="$3" to="$4" text="$5"
  prog add-item "$item" --title "$item" --kind fix_only --run "$run"
  prog hand-item "$item" --question "who picks?" --kind "$kind" --run "$run"
  local ask p
  ask="$(field "$run" "prog['items']['$item']['handed']['id']" | tr -d '"')"
  p="$(prompt "$run" typed "$text")"
  prog_on correct-term --run "$run" --prompt "$p" --replies-to "$ask" --to "$to" --reading "$text"
  field "$run" 'prog["agreement"]["corrections"][-1]["id"]' | tr -d '"'
}

terms_by_origin() {
  field "$1" '[[t["area"], t.get("origin")] for t in prog["agreement"].get("project_terms") or [] if t.get("origin")]'
}

REMIT_A="{\"spaces\":[\"w2\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"},{\"path\":\"${ALPHA2}\"}]}"

# Programme A on alpha and alpha-two applies two corrections.
RUN_A="$(new_programme w2)"
remit "$RUN_A" "$REMIT_A"
stamp_contract "$RUN_A"
P_BEFORE="$(prompt "$RUN_A" typed "keep whatever you correct today")"
C1="$(correct "$RUN_A" linear:A-1 technical_approach pm "that did not need me")"
C2="$(correct "$RUN_A" linear:A-2 work_sequencing worker "workers can order that")"

it "the fixture applied two corrections"
case "$C1 $C2" in c??????" "c??????) pass ;; *) fail "$C1 $C2" ;; esac

it "with the switch off, keep-corrections refuses and writes nothing"
P_KEEP_OFF="$(prompt "$RUN_A" typed "keep the first correction")"
BEFORE="$(hashes)"
prog keep-corrections --run "$RUN_A" --prompt "$P_KEEP_OFF" "$C1"
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(hashes)" ]; then has "corrections are not on yet" "$OUT"; else fail "code $CODE out $OUT"; fi
it "with the switch off, promote-correction refuses and writes nothing"
P_ALL_OFF="$(prompt "$RUN_A" typed "apply that to all projects")"
BEFORE="$(hashes)"
prog promote-correction --run "$RUN_A" --prompt "$P_ALL_OFF" "$C1"
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(hashes)" ]; then has "corrections are not on yet" "$OUT"; else fail "code $CODE out $OUT"; fi

it "keep-corrections with an unknown correction refuses and writes nothing"
BEFORE="$(hashes)"
prog_on keep-corrections --run "$RUN_A" --prompt "$P_KEEP_OFF" c000000
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(hashes)" ]; then has "no active correction 'c000000'" "$OUT"; else fail "code $CODE out $OUT"; fi

it "keep-corrections citing a prompt older than the correction refuses and writes nothing"
BEFORE="$(hashes)"
prog_on keep-corrections --run "$RUN_A" --prompt "$P_BEFORE" "$C1"
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(hashes)" ]; then has "is not later than the correction's prompt" "$OUT"; else fail "code $CODE out $OUT"; fi
it "keep-corrections citing a later prompt that does not name the correction refuses and writes nothing"
prog_on keep-corrections --run "$RUN_A" --prompt "$P_KEEP_OFF" "$C1"
if [ "$CODE" = 1 ] && [ "$BEFORE" = "$(hashes)" ]; then has "does not name what it approves" "$OUT"; else fail "code $CODE out $OUT"; fi

it "AE9: Shawn keeps one of the two corrections for this project"
P_KEEP="$(prompt "$RUN_A" typed "keep ${C1} for this project")"
prog_on keep-corrections --run "$RUN_A" --prompt "$P_KEEP" "$C1"
check 0 "$CODE"
it "the kept correction is stored under each remit repo key and not under all"
check '[["'"${ALPHA2}"'", "'"${C1}"'"], ["shawn/alpha", "'"${C1}"'"]]' "$("$PY" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(json.dumps([[k, e["correction"]] for k, v in doc["keys"].items() for e in v], sort_keys=True))' "$STORE" | "$PY" -c '
import json, sys
print(json.dumps(sorted(json.load(sys.stdin))))')"
it "every stored entry carries an adoption block bound to the prompt"
check "True" "$("$PY" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(all(e["adoption"]["prompt_id"] == sys.argv[2] and e["adoption"]["machine"] == "studio"
          for v in doc["keys"].values() for e in v))' "$STORE" "$P_KEEP")"
it "the keep journals one approval row per stored entry, citing the prompt"
check "2 True" "$(run_py "$RUN_A" "$P_KEEP" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "rule_adopted" and r["payload"].get("entry") == "carryover"]
print(len(rows), all(r["cites"] == [args[1]] for r in rows))
EOF
)"
it "the programme's prompt lookup approves every stored entry"
check "True" "$(run_py "$RUN_A" "$P_KEEP" "$STORE" <<'EOF'
programme = load_lib_module("programme")
proto = load_lib_module("programme_protocol")
doc = json.load(open(args[2]))
approved = programme.prompt_lookup(args[0], args[1])["approved"]
print(all(proto.approval_key(f"carryover:{k}:{e['id']}", e["adoption"]["hash"]) in approved
          for k, v in doc["keys"].items() for e in v))
EOF
)"

it "end lists the corrections the programme applied while the switch is on"
end_programme "$RUN_A" on
check 0 "$CODE"
has "correction ${C1}: technical_approach decided by pm" "$OUT"
has "correction ${C2}: work_sequencing decided by worker" "$OUT"

# Programme B on the same repos, in the real startup order: propose, then set-remit.
RUN_B="$(new_programme w3)"
prog propose-agreement --run "$RUN_B" --project-term "naming=kebab case files" --source "repo README"
P_EARLY_B="$(prompt "$RUN_B" typed "yes, I accept the agreement")"
it "before set-remit the next programme has no carried-over term"
check "[]" "$(terms_by_origin "$RUN_B")"
remit "$RUN_B" "$REMIT_A"
it "AE9: after set-remit the next programme pre-fills the kept correction once, marked with its origin"
check 0 "$CODE"
check '[["technical approach", "shawn/alpha"]]' "$(terms_by_origin "$RUN_B")"
it "the carried-over term says it was carried over"
check '["carried_over", "decided by the PM"]' "$(field "$RUN_B" '[[t["set_by"], t["value"]] for t in prog["agreement"]["project_terms"] if t.get("origin")][0]')"
it "the correction that was not kept is not pre-filled"
lacks "work sequencing" "$(field "$RUN_B" 'prog["agreement"]["project_terms"]')"
it "set-remit again on the unaccepted agreement adds no duplicate"
remit "$RUN_B" "$REMIT_A"
check 1 "$(field "$RUN_B" 'len([t for t in prog["agreement"]["project_terms"] if t.get("origin")])')"
it "accepting with a prompt typed before the pre-fill refuses"
prog accept-agreement --run "$RUN_B" --prompt "$P_EARLY_B"
check 1 "$CODE"
has "older than" "$OUT"
P_ACCEPT_B="$(prompt "$RUN_B" typed "yes, I accept the agreement")"
prog accept-agreement --run "$RUN_B" --prompt "$P_ACCEPT_B"
it "accepting with a prompt typed after the pre-fill accepts"
check 0 "$CODE"
TERMS_B="$(field "$RUN_B" 'prog["agreement"]["project_terms"]')"

# Programme C on another repo.
RUN_C="$(new_programme w4)"
prog propose-agreement --run "$RUN_C" --term cadence=fixed
remit "$RUN_C" "{\"spaces\":[\"w4\"],\"repos\":[{\"path\":\"${BETA}\"}]}"
it "a programme on another repo does not see a project-keyed correction"
check 0 "$CODE"
check "[]" "$(terms_by_origin "$RUN_C")"

stamp_contract "$RUN_C"
P_EARLY_ALL="$(prompt "$RUN_C" typed "apply that to all projects")"
C3="$(correct "$RUN_C" linear:C-1 tool_choice pm "pick the tools yourself")"
C4="$(correct "$RUN_C" linear:C-2 optimisation_depth worker "workers decide how deep")"

refused() {
  local want="$1"; shift
  local before
  before="$(hashes)"
  prog_on "$@"
  if [ "$CODE" = 1 ] && [ "$before" = "$(hashes)" ]; then has "$want" "$OUT"; else fail "code $CODE out $OUT"; fi
}

it "promote-correction without all projects in the prompt refuses and writes nothing"
P_NONE="$(prompt "$RUN_C" typed "keep that one everywhere")"
refused "all projects" promote-correction --run "$RUN_C" --prompt "$P_NONE" "$C3"
it "a negated all projects refuses"
P_NEG="$(prompt "$RUN_C" typed "don't apply that to all projects")"
refused "negates" promote-correction --run "$RUN_C" --prompt "$P_NEG" "$C3"
it "a prompt not later than the correction's own prompt refuses"
refused "is not later than" promote-correction --run "$RUN_C" --prompt "$P_EARLY_ALL" "$C3"

P_ALL="$(prompt "$RUN_C" typed "yes, apply that to all projects")"
it "a typed prompt naming all projects promotes the correction"
prog_on promote-correction --run "$RUN_C" --prompt "$P_ALL" "$C3"
check 0 "$CODE"
check '["tool_choice"]' "$("$PY" -c '
import json, sys
print(json.dumps([e["kind"] for e in json.load(open(sys.argv[1]))["keys"]["all"]]))' "$STORE")"
it "a reused promotion prompt refuses"
refused "already drove a promotion" promote-correction --run "$RUN_C" --prompt "$P_ALL" "$C4"

it "a promotion does not change a programme that is already running"
check "$TERMS_B" "$(field "$RUN_B" 'prog["agreement"]["project_terms"]')"
P_ADD="$(prompt "$RUN_B" typed "add repo beta to the remit")"
remit "$RUN_B" "{\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"},{\"path\":\"${ALPHA2}\"},{\"path\":\"${BETA}\"}]}" --prompt "$P_ADD"
it "set-remit on an accepted agreement never reads the store"
check 0 "$CODE"
check "$TERMS_B" "$(field "$RUN_B" 'prog["agreement"]["project_terms"]')"
lacks "carried_over" "$OUT"

# Hand-written store entries for gamma: none has a valid adoption.
"$PY" - "$STORE" "$GAMMA" "$AUTO_ROOT" <<'EOF'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[3], "lib"))
from _bootstrap import load_lib_module
proto = load_lib_module("programme_protocol")
doc = json.load(open(sys.argv[1]))
base = dict(doc["keys"]["all"][0])
def forged(entry_id, kind, adoption):
    entry = {k: v for k, v in base.items() if k != "adoption"}
    entry.update(id=entry_id, key=sys.argv[2], kind=kind, area=kind.replace("_", " "))
    if adoption is not None:
        entry["adoption"] = dict(base["adoption"], **adoption)
        if adoption.get("hash") is None:
            entry["adoption"]["hash"] = proto.content_hash(entry)
    return entry
doc["keys"][sys.argv[2]] = [
    forged("kbare00", "work_sequencing", None),
    forged("kmach00", "worker_coordination", {"machine": "elsewhere"}),
    forged("khash00", "optimisation_depth", {"hash": base["adoption"]["hash"]}),
]
json.dump(doc, open(sys.argv[1], "w"))
EOF

RUN_D="$(new_programme w5)"
prog propose-agreement --run "$RUN_D" --term cadence=fixed
rm -rf "${WORK}/data.bak"
/bin/cp -Rp "$CLAUDE_AUTO_DATA_DIR" "${WORK}/data.bak"
it "mutation: with the adoption check patched out the forged entries are pre-filled"
MUTATE=adoption prog_on set-remit --run "$RUN_D" < <(printf '%s' "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}")
check "0 3" "$CODE $(field "$RUN_D" 'len([t for t in prog["agreement"].get("project_terms") or [] if t.get("origin") == "'"${GAMMA}"'"])')"
rm -rf "$CLAUDE_AUTO_DATA_DIR"
/bin/cp -Rp "${WORK}/data.bak" "$CLAUDE_AUTO_DATA_DIR"

remit "$RUN_D" "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}"
it "a programme on a third repo pre-fills only the all-projects correction"
check 0 "$CODE"
check '[["tool choice", "all"]]' "$(terms_by_origin "$RUN_D")"
it "a store entry with no adoption block is dropped with a notice naming it"
has "kbare00" "$OUT"
it "a store entry adopted on another machine is dropped with a notice naming it"
has "kmach00" "$OUT"
it "a store entry whose content no longer matches its hash is dropped with a notice naming it"
has "khash00" "$OUT"

echo ""
echo "programme-carryover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

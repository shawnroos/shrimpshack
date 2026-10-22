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
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
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
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
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

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
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
  p="$(prompt "$run" typed '/auto:programme-end')"
  run_py "$run" "$p" <<'EOF' >/dev/null
source = pj.find_prompt(args[0], args[1])["payload"]["source"]
pj.append(args[0], "end_request", "sess-pm",
          {"verb": "end", "text": "/auto:programme-end", "origin": "typed", "space": "x",
           "lease_status": "live", "driving": True, "source": source}, cites=[args[1]])
EOF
  prog end --run "$run"
}

# The keep and promote verbs are gone; the store is seeded the way they wrote it, through a
# typed prompt in the programme's journal, so the pre-fill still verifies each entry.
seed_store() {
  local run="$1" key="$2" kind="$3" to="$4" text="$5" p
  p="$(prompt "$run" typed "$text")"
  run_py "$run" "$key" "$kind" "$to" "$p" <<'EOF' >/dev/null
run, key, kind, to, pid = args
programme = load_lib_module("programme")
co = load_lib_module("programme_carryover")
rec = record(run)
prompt = programme._typed_prompt(run, rec, pid)
keys = co.repo_keys(rec["programme"]) if key == "repos" else [key]
correction = {"id": "c" + kind[:6], "kind": kind, "to": to, "quote": prompt["quote"], "pm_reading": prompt["quote"]}
co.store(co.prepare([co.entry_for(correction, k, rec) for k in keys], prompt, rec), prompt, run, "sess-pm", "carryover")
EOF
}

terms_by_origin() {
  field "$1" '[[t["area"], t.get("origin")] for t in prog["agreement"].get("project_terms") or [] if t.get("origin")]'
}

REMIT_A="{\"spaces\":[\"w2\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"},{\"path\":\"${ALPHA2}\"}]}"

RUN_A="$(new_programme w2)"
remit "$RUN_A" "$REMIT_A"
stamp_contract "$RUN_A"
seed_store "$RUN_A" repos technical_approach pm "keep that technical approach call for this project"

it "the seeded entry is stored under each remit repo key and not under all"
check '[["'"${ALPHA2}"'", "technical_approach"], ["shawn/alpha", "technical_approach"]]' "$("$PY" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(json.dumps(sorted([k, e["kind"]] for k, v in doc["keys"].items() for e in v)))' "$STORE")"
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

it "end prints no corrections: the corrections switch is gone"
end_programme "$RUN_A"
check 0 "$CODE"
lacks "correction" "$OUT"

# Programme B on the same repos, in the real startup order: propose, then set-remit.
RUN_B="$(new_programme w3)"
prog propose-agreement --run "$RUN_B" --project-term "naming=kebab case files" --source "repo README"
P_EARLY_B="$(prompt "$RUN_B" typed "yes, I accept the agreement")"
it "before set-remit the next programme has no carried-over term"
check "[]" "$(terms_by_origin "$RUN_B")"
remit "$RUN_B" "$REMIT_A"
it "after set-remit the next programme pre-fills the stored entry once, marked with its origin"
check 0 "$CODE"
check '[["technical approach", "shawn/alpha"]]' "$(terms_by_origin "$RUN_B")"
it "the carried-over term says it was carried over"
check '["carried_over", "decided by the PM"]' "$(field "$RUN_B" '[[t["set_by"], t["value"]] for t in prog["agreement"]["project_terms"] if t.get("origin")][0]')"
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
it "a programme on another repo does not see a project-keyed entry"
check 0 "$CODE"
check "[]" "$(terms_by_origin "$RUN_C")"

seed_store "$RUN_C" all tool_choice pm "pick the tools yourself, for all projects"

it "an all-projects entry does not change a programme that is already running"
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
prog_mutated set-remit --run "$RUN_D" < <(printf '%s' "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}")
check "0 3" "$CODE $(field "$RUN_D" 'len([t for t in prog["agreement"].get("project_terms") or [] if t.get("origin") == "'"${GAMMA}"'"])')"
rm -rf "$CLAUDE_AUTO_DATA_DIR"
/bin/cp -Rp "${WORK}/data.bak" "$CLAUDE_AUTO_DATA_DIR"

remit "$RUN_D" "{\"spaces\":[\"w5\"],\"repos\":[{\"path\":\"${GAMMA}\"}]}"
it "a programme on a third repo pre-fills only the all-projects entry"
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

#!/usr/bin/env bash
# Moving a legacy JSON home to programme.db: adoptions approved on the JSON home stay in force after the
# move, a Ruling verb moves the home only once its own checks pass, an interrupted move is finished by the
# next write, and a prompt typed while a move holds the home is reported, never dropped silently.
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

echo "programme-legacy-move.test.sh"

WORK="$(mktemp -d -t auto-programme-legacy-move.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/personal/behaviours.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_SPINOFF_TIMEOUT=2
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  code=0; [ "$tool" = spinoff ] && code=3
  printf '#!/bin/sh\nexit %s\n' "$code" > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
auth = load_lib_module("programme_authority")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
# An earlier build of this branch wrote Ruling changes and carries straight onto a legacy home; this
# wrapper is that build, so the tests can hold what such a home held.
OLD_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
programme.programme_rulings.changes_ruling = lambda row: False
programme.upgrade_legacy = lambda *a, **k: None
sys.exit(programme._cli(sys.argv[1:]))
'
old_prog() {
  OUT="$(AUTO_ROOT="$AUTO_ROOT" "$PY" -c "$OLD_PY" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}old $* | " ;; esac
}
old_remit() {
  local run="$1" doc="$2"
  OUT="$(printf '%s' "$doc" | AUTO_ROOT="$AUTO_ROOT" "$PY" -c "$OLD_PY" set-remit --run "$run" 2>&1)"
  CODE=$?
}
remit() {
  local run="$1" doc="$2"
  OUT="$(printf '%s' "$doc" | "$PY" "$PROG" set-remit --run "$run" 2>&1)"
  CODE=$?
}
pyget() {
  "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); v=eval(sys.argv[2]); print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))' "$1" "$2" 2>&1
}
prompt_in() {
  run_py "$1" "$2" "${3:-sess-pm}" <<'EOF'
print(fixture_prompt(args[0], args[2], args[1], "typed")["prompt_id"])
EOF
}
new_legacy() {
  run_py "$1" "${2:-sess-pm}" <<'EOF'
auth.home_for = lambda *a: None
print(ph.create_programme([args[0]], args[1])["run"])
EOF
}
new_programme() {
  run_py "$1" <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
}
is_promoted() {
  run_py "$1" <<'EOF'
print(auth.promoted(ph.home_path(args[0]), args[0]))
EOF
}
# home_hash <run>: the legacy record, journal and claims bytes, the carry-over store, the leases, and whether
# a programme.db or an import marker exists.
home_hash() {
  run_py "$1" <<'EOF'
home = ph.home_path(args[0])
paths = [core.run_record_path(home, args[0]), os.path.join(home, "journal.jsonl"), os.path.join(home, "claims.jsonl"),
         load_lib_module("programme_carryover").store_path()]
def digest(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12]
    except FileNotFoundError:
        return "absent"
leases = sorted(os.listdir(ph.leases_dir())) if os.path.isdir(ph.leases_dir()) else []
print(" ".join(digest(p) for p in paths), hashlib.sha256("|".join(leases).encode()).hexdigest()[:8],
      os.path.exists(os.path.join(home, "programme.db")), os.path.exists(os.path.join(home, auth.IMPORT_MARKER)))
EOF
}

RULE_A='{"id":"docs-a","applies_when":{"change_kinds":["evals_or_docs"]},"requires":["merged"],"evidence_bar":{"merged":"merged at the gate"},"caveat":"","autonomy":"act_and_tell","added_by":"pm","added_at":"2026-10-06T10:00:00Z","why":"docs need a merge"}'

# adopted_home <space> <repo> <suffix>: a legacy home on which Shawn adopted a personal behaviour, a protocol
# rule and a carried Ruling, with one more proposed rule and a prompt naming it left for after the move.
# Prints "<run> <behaviour id>".
adopted_home() {
  local space="$1" repo="$2" s="$3" run bid
  run="$(new_legacy "$space")"
  prog propose-agreement --run "$run" --project-term "naming=kebab case files" --source "repo README"
  old_remit "$run" "{\"spaces\":[\"${space}\"],\"repos\":[{\"path\":\"${repo}\"}]}"
  prog add-item herdr:x --title "x" --kind fix_only --run "$run"
  old_prog record-ruling "c${s}" --kind technical_approach --effect restrict --scope "c${s}" --applies-to herdr:x \
    --prompt "$(prompt_in "$run" "c${s}: I pick the technical approach on herdr:x")" --run "$run"
  old_prog carry-rulings --run "$run"
  old_prog carry-rulings "c${s}" --prompt "$(prompt_in "$run" "carry c${s} to the next programme")" --run "$run"
  prog record-behaviour --run "$run" --prompt "$(prompt_in "$run" "always reproduce a reported bug ${s}")" \
    --when "a bug ${s} is reported" --pm-check "the item is a bug" --do "reproduce the bug ${s} first"
  bid="$(pyget "$OUT" 'd["behaviour"]')"
  prog move-behaviour "$bid" --to personal --prompt "$(prompt_in "$run" "make ${bid} global")" --run "$run"
  prog propose-rule "${RULE_A//docs-a/docs-${s}}" --run "$run"
  prog adopt-rule "docs-${s}" --prompt "$(prompt_in "$run" "adopt docs-${s}")" --run "$run"
  prog propose-rule "${RULE_A//docs-a/late-${s}}" --run "$run"
  prompt_in "$run" "adopt late-${s}" > "${WORK}/late-${s}"
  printf '%s %s' "$run" "$bid"
}
# in_force <bid> <rule> <ruling> <repo>: whether the stored behaviour loads, the rule is in the personal layer,
# and the carry-over entry verifies, each read through programme.prompt_lookup.
in_force() {
  run_py "$@" <<'EOF'
_, bid, rule, ruling, repo = args
programme = load_lib_module("programme")
pb = load_lib_module("programme_behaviours")
pco = load_lib_module("programme_carryover")
proto = load_lib_module("programme_protocol")
journals = {}
lookup = lambda run, p: programme.prompt_lookup(run, p, journals)
behaviour = any(e["id"] == bid for e in pb.load_store(lookup)["personal"])
rules = rule in proto.load(prompt_lookup=lookup)["rules"]
entries = [e for e in pco.entries_under(pco.read_store(), repo) if e.get("ruling") == ruling]
carry = bool(entries) and all(pco._verified(e, repo, lookup) is None for e in entries)
print(behaviour, rules, carry)
EOF
}

# ── 1. adoptions approved on the JSON home survive the move ────────────────
REPO1="${WORK}/repos/one"; REPO2="${WORK}/repos/two"
mkdir -p "$REPO1" "$REPO2"
read -r LA BA <<<"$(adopted_home w41 "$REPO1" 1)"
read -r LB BB <<<"$(adopted_home w42 "$REPO2" 2)"
it "the fixture: both homes are legacy and every adoption is in force on the JSON files"
check "False False True True True True True True" \
  "$(is_promoted "$LA") $(is_promoted "$LB") $(in_force "$LA" "$BA" docs-1 c1 "$REPO1") $(in_force "$LB" "$BB" docs-2 c2 "$REPO2")"

prog promote --run "$LA"
it "an explicit promote moves the home"
check "0 True" "$CODE $(is_promoted "$LA")"
it "after an explicit promote the behaviour, the protocol rule and the carry-over entry are still in force"
check "True True True" "$(in_force "$LA" "$BA" docs-1 c1 "$REPO1")"

prog record-ruling z9 --kind tool_choice --effect restrict --scope "z" --applies-to herdr:x --run "$LB"
it "a Ruling verb moves the second home"
check "0 True" "$CODE $(is_promoted "$LB")"
it "after a Ruling verb moved the home the behaviour, the protocol rule and the carry-over entry are still in force"
check "True True True" "$(in_force "$LB" "$BB" docs-2 c2 "$REPO2")"

it "the next programme on each project pre-fills the Ruling carried on the JSON home"
NA="$(new_programme w43)"; NB="$(new_programme w44)"
prog propose-agreement --run "$NA" --project-term "naming=kebab case files" --source "repo README"
prog propose-agreement --run "$NB" --project-term "naming=kebab case files" --source "repo README"
remit "$NA" "{\"spaces\":[\"w43\"],\"repos\":[{\"path\":\"${REPO1}\"}]}"
K1="$CODE $(pyget "$OUT" '[c["ruling"] for c in d.get("carried_over") or []]')"
remit "$NB" "{\"spaces\":[\"w44\"],\"repos\":[{\"path\":\"${REPO2}\"}]}"
check "0 [\"c1\"] 0 [\"c2\"]" "$K1 $CODE $(pyget "$OUT" '[c["ruling"] for c in d.get("carried_over") or []]')"

it "a new adoption citing a prompt typed before the move is still refused"
prog adopt-rule late-1 --prompt "$(cat "${WORK}/late-1")" --run "$LA"
K1="$CODE"
prog adopt-rule late-2 --prompt "$(cat "${WORK}/late-2")" --run "$LB"
check "1 1" "$K1 $CODE"
has "imported from a legacy journal" "$OUT"

it "an imported prompt verifies only the approvals imported with it"
check "True False" "$(run_py "$LA" "$(cat "${WORK}/late-1")" <<'EOF'
programme = load_lib_module("programme")
proto = load_lib_module("programme_protocol")
rows = pj.read(args[0])
p = next(r for r in rows if r.get("kind") == "rule_adopted" and r["payload"].get("target") == proto.target_of("rules", "docs-1"))
key = proto.approval_key(p["payload"]["target"], p["payload"]["hash"])
forged = dict(p, provenance=None)
forged["cites"] = [p["cites"][0]]
with_forged = [r for r in rows if r is not p] + [forged]
print(key in programme.prompt_lookup(args[0], p["cites"][0])["approved"],
      key in programme.prompt_lookup(args[0], p["cites"][0], {args[0]: with_forged})["approved"])
EOF
)"

# ── 2. a Ruling verb its own checks refuse leaves the legacy home alone ────
LR="$(new_legacy w45)"
prog add-item herdr:x --title "x" --kind fix_only --run "$LR"
HR="$(home_hash "$LR")"
it "legacy: close-ruling of an unknown id refuses, does not move the home, and changes nothing"
prog close-ruling nope --as fulfilled --why "done" --run "$LR"
check "1 $HR" "$CODE $(home_hash "$LR")"
has "no Ruling 'nope'" "$OUT"
it "legacy: record-ruling from a session that does not drive the programme refuses and changes nothing"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" record-ruling r1 --kind tool_choice --effect restrict \
  --scope s --applies-to herdr:x --run "$LR" 2>&1)"; CODE=$?
check "1 $HR" "$CODE $(home_hash "$LR")"
has "driving session" "$OUT"
it "legacy: record-ruling citing a prompt that does not name the id refuses without moving; only the refusal is journaled"
P_LR="$(prompt_in "$LR" 'I pick the tool choice on herdr:x')"
prog record-ruling r1 --kind tool_choice --effect restrict --scope s --applies-to herdr:x --prompt "$P_LR" --run "$LR"
check "1 False approval_refused" "$CODE $(is_promoted "$LR") $(run_py "$LR" <<'EOF'
print(pj.read(args[0])[-1]["kind"])
EOF
)"
has "does not name" "$OUT"
it "legacy: a set-remit adding a space another live programme leases refuses without moving or writing a lease"
LS="$(new_legacy w46)"
OTHER="$(new_programme w47)"
prog propose-agreement --run "$LS" --project-term "naming=kebab case files" --source "repo README"
HS="$(home_hash "$LS")"
remit "$LS" "{\"spaces\":[\"w46\",\"w47\"],\"repos\":[{\"path\":\"${REPO1}\"}]}"
check "1 $HS" "$CODE $(home_hash "$LS")"
it "legacy: the same set-remit without the held space moves the home and brings the carried Ruling in"
remit "$LS" "{\"spaces\":[\"w46\"],\"repos\":[{\"path\":\"${REPO1}\"}]}"
check "0 True [\"c1\"]" "$CODE $(is_promoted "$LS") $(pyget "$OUT" '[c["ruling"] for c in d.get("carried_over") or []]')"

# A secrets-file value makes promotion decline, so the only thing that could change the home is the verb.
SECRET="zq-move-secret-8813"
printf 'MOVE_TOKEN=%s\n' "$SECRET" >> "$CLAUDE_AUTO_SECRETS_FILE"
LD="$(new_legacy w48)"
prog propose-agreement --run "$LD" --project-term "naming=kebab case files" --source "repo README"
run_py "$LD" "$SECRET" <<'EOF' >/dev/null
core._with_locked_run_record(ph.home_path(args[0]), args[0], lambda rec: rec["programme"]["working_model"].update(
    doing="deploy using " + args[1]))
EOF
HD="$(home_hash "$LD")"
it "legacy, promotion declined: a set-remit that would carry a Ruling in and add a space writes no lease and no store entry"
remit "$LD" "{\"spaces\":[\"w48\",\"w49\"],\"repos\":[{\"path\":\"${REPO1}\"}]}"
check "1 $HD" "$CODE $(home_hash "$LD")"
has "Moving it to programme.db failed" "$OUT"

# ── 4. a successful withdrawal on a legacy home; another process moving it first ──
LW="$(new_legacy w50)"
prog add-item herdr:x --title "x" --kind fix_only --run "$LW"
old_prog record-ruling rw --kind tool_choice --effect restrict --scope "w" --applies-to herdr:x \
  --prompt "$(prompt_in "$LW" 'rw: I pick the tool choice on herdr:x')" --run "$LW"
it "legacy: close-ruling --as withdrawn citing a prompt typed before the move moves the home, then refuses that prompt"
prog close-ruling rw --as withdrawn --prompt "$(prompt_in "$LW" 'withdraw rw')" --run "$LW"
check "1 True" "$CODE $(is_promoted "$LW")"
has "imported from a legacy journal" "$OUT"
it "legacy: a prompt typed after the move withdraws the Ruling on the moved home"
prog close-ruling rw --as withdrawn --prompt "$(prompt_in "$LW" 'withdraw rw')" --run "$LW"
check "0 closed withdrawn" "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["as"]')"

LP="$(new_legacy w51)"
prog add-item herdr:x --title "x" --kind fix_only --run "$LP"
it "legacy: when another process moves the home first, the verb reads already_promoted and applies on the moved home"
OUT="$("$PY" - 2>&1 <<EOF
import os, sys
sys.path.insert(0, os.path.join("$AUTO_ROOT", "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
auth = programme.programme_authority
imp = load_lib_module("programme_import")
real_promote, legacy_write = imp.promote, auth._legacy_write
statuses = []
def raced(*a, **k):
    try:
        return legacy_write(*a, **k)
    finally:
        real_promote(a[1])
def counted(run_id):
    statuses.append(real_promote(run_id)["status"])
    return {"status": statuses[-1], "reason": None}
auth._legacy_write = raced
imp.promote = counted
code = programme._cli(["record-ruling", "rp", "--kind", "tool_choice", "--effect", "restrict", "--scope", "p",
                       "--applies-to", "herdr:x", "--run", "$LP"])
print("RESULT", code, statuses)
EOF
)"
has "RESULT 0 ['already_promoted']" "$OUT"
has '"state": "pending_acceptance"' "$(run_py "$LP" <<'EOF'
print(json.dumps(record(args[0])["programme"]["context"]["decisions"]["rp"]))
EOF
)"

# ── 3. an interrupted move ─────────────────────────────────────────────────
LM="$(new_legacy w52)"
prog add-item herdr:x --title "x" --kind fix_only --run "$LM"
run_py "$LM" <<'EOF' >/dev/null
open(os.path.join(ph.home_path(args[0]), auth.IMPORT_MARKER), "w").write(json.dumps({"import_id": "imp-nothing"}) + "\n")
EOF
it "a move cut off after its marker and before its commit: the next Ruling verb redoes the move and applies"
prog record-ruling rm --kind tool_choice --effect restrict --scope "m" --applies-to herdr:x --run "$LM"
check "0 pending_acceptance False" "$CODE $(pyget "$OUT" 'd["state"]') $(run_py "$LM" <<'EOF'
print(os.path.exists(os.path.join(ph.home_path(args[0]), auth.IMPORT_MARKER)))
EOF
)"

LK="$(new_legacy w53)"
prog add-item herdr:x --title "x" --kind fix_only --run "$LK"
it "a move cut off after its commit and before it finished: the home is held"
check "unavailable" "$(run_py "$LK" <<'EOF'
imp = load_lib_module("programme_import")
def cut(*a, **k):
    raise OSError("killed")
imp._finish = cut
try:
    imp.promote(args[0])
except OSError:
    pass
print(auth.outcome(args[0])["outcome"])
EOF
)"
it "the next Ruling verb finishes that move, sets the old files aside and applies"
prog record-ruling rk --kind tool_choice --effect restrict --scope "k" --applies-to herdr:x --run "$LK"
check "0 pending_acceptance False True supported" "$CODE $(pyget "$OUT" 'd["state"]') $(run_py "$LK" <<'EOF'
home = ph.home_path(args[0])
print(os.path.exists(os.path.join(home, auth.IMPORT_MARKER)),
      any(n.startswith("journal.jsonl.imported-") for n in os.listdir(home)), auth.outcome(args[0])["outcome"])
EOF
)"

# hook <run> <driving|closing> <session>: the UserPromptSubmit hook, reading the home before the marker lands and appending
# after it, as a prompt typed while a move starts does.
hook() {
  run_py "$1" "$2" "$3" <<'EOF'
hook = load_lib_module("on-user-prompt")
run, ended, sid = args
marker = os.path.join(ph.home_path(run), auth.IMPORT_MARKER)
if ended == "driving":
    found = hook._driving_run(sid)
    hook._driving_run = lambda sid: found
else:
    found = hook._closing_runs(sid)
    hook._closing_runs = lambda sid: found
open(marker, "w").write("")
try:
    out = hook.handle(json.dumps({"session_id": sid, "prompt": "yes, go ahead"}), os.environ)
    print(json.dumps(out))
except Exception as exc:
    print("raised", type(exc).__name__)
os.unlink(marker)
EOF
}
LH="$(new_legacy w54 sess-h)"
it "a prompt the hook cannot journal while a move holds the home is reported to the PM, not dropped silently"
OUT="$(hook "$LH" driving sess-h)"
has "did not journal this prompt" "$OUT"
has "$LH" "$OUT"
LE="$(new_legacy w55 sess-e)"
P_END="$(prompt_in "$LE" '/auto:programme-end' sess-e)"
run_py "$LE" "$P_END" <<'EOF' >/dev/null
source = pj.find_prompt(args[0], args[1])["payload"]["source"]
pj.append(args[0], "end_request", "sess-e",
          {"verb": "end", "text": "/auto:programme-end", "origin": "typed", "space": "x",
           "lease_status": "live", "driving": True, "source": source}, cites=[args[1]])
EOF
CLAUDE_CODE_SESSION_ID=sess-e prog end --run "$LE"
it "the ended fixture: end succeeded on the JSON files"
check "0 False" "$CODE $(is_promoted "$LE")"
it "a prompt for an ended programme the hook cannot journal while a move holds it is reported too"
OUT="$(hook "$LE" closing sess-e)"
has "did not journal this prompt" "$OUT"
has "$LE" "$OUT"
it "a held closing home found before the hook runs is reported rather than skipped"
check "True" "$(run_py "$LE" <<'EOF'
hook = load_lib_module("on-user-prompt")
marker = os.path.join(ph.home_path(args[0]), auth.IMPORT_MARKER)
open(marker, "w").write("")
out = hook.handle(json.dumps({"session_id": "sess-e", "prompt": "yes, go ahead"}), os.environ)
os.unlink(marker)
print(out is not None and "did not journal" in json.dumps(out) and args[0] in json.dumps(out))
EOF
)"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo
echo "programme-legacy-move.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

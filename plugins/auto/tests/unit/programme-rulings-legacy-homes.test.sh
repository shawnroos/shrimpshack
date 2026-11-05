#!/usr/bin/env bash
# Rulings: record-ruling, close-ruling, the effect-aware widening delta, the grant baseline
# and the read-time view the who-decides gate reads.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-rulings-legacy-homes.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-rulings-setup.sh"

# ── a Ruling change on a legacy home moves it to programme.db first ───────
# new_run <space> [legacy]: a programme with item herdr:b; legacy keeps a JSON record and journal with no
# programme.db, as an older auto left it.
new_run() {
  local run
  run="$(run_py "$1" "${2:-}" <<'EOF'
if args[1] == "legacy":
    load_lib_module("programme_authority").home_for = lambda *a: None
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
)"
  "$PY" "$PROG" add-item herdr:b --title "herdr:b" --kind fix_only --run "$run" >/dev/null 2>&1
  printf '%s' "$run"
}
is_promoted() {
  run_py "$1" <<'EOF'
print(load_lib_module("programme_authority").promoted(ph.home_path(args[0]), args[0]))
EOF
}
# ruling_doc <run> <id> and row_doc <run> <kind>: a Ruling's revisions and the newest row of a kind, without
# the times and prompt ids that differ between two runs.
STRIP_PY='
def strip(node):
    if isinstance(node, dict):
        return {k: strip(v) for k, v in node.items() if k not in ("at", "prompt_id", "session_id", "cites", "offer_id")}
    return [strip(v) for v in node] if isinstance(node, list) else node
'
ruling_doc() {
  run_py "$1" "$2" "$STRIP_PY" <<'EOF'
exec(args[2])
decisions = ((programme_records.load(args[0])["programme"].get("context") or {}).get("decisions") or {})
print(json.dumps(strip(decisions.get(args[1])), sort_keys=True))
EOF
}
row_doc() {
  run_py "$1" "$2" "$STRIP_PY" <<'EOF'
exec(args[2])
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(strip(rows[-1]) if rows else None, sort_keys=True))
EOF
}
# inject <legacy run> <source run> <id>: copy a Ruling from a promoted run into a legacy record, as a home
# written by an earlier build of this branch could hold one.
inject() {
  run_py "$1" "$2" "$3" <<'EOF'
src = programme_records.load(args[1])["programme"]["context"]["decisions"][args[2]]
programme_records.edit(args[0], "prog.setdefault('context', {}).setdefault('decisions', {})[cid] = src",
                       {"src": src, "cid": args[2]})
EOF
}

L1="$(new_run w31 legacy)"; Q1="$(new_run w32)"
it "the legacy fixture has no programme.db; the promoted one has"
check "False True" "$(is_promoted "$L1") $(is_promoted "$Q1")"

it "legacy: a record-ruling with no prompt moves the home to programme.db, then records the proposal there"
prog record-ruling r-up --kind tool_choice --effect restrict --scope "up" --applies-to herdr:b --run "$L1"
K1="$CODE"
prog record-ruling r-up --kind tool_choice --effect restrict --scope "up" --applies-to herdr:b --run "$Q1"
check "0 0 True" "$K1 $CODE $(is_promoted "$L1")"
has '"state": "pending_acceptance"' "$(ruling_doc "$L1" r-up)"
it "legacy: the moved home holds the same pending Ruling and row as a promoted run"
check "$(ruling_doc "$Q1" r-up) $(row_doc "$Q1" ruling_recorded)" "$(ruling_doc "$L1" r-up) $(row_doc "$L1" ruling_recorded)"
it "legacy: the move sets the old files aside and reads the old journal into programme.db"
check "True True" "$(run_py "$L1" <<'EOF'
names = os.listdir(ph.home_path(args[0]))
print(any(n.startswith("journal.jsonl.imported-") for n in names), any(r["kind"] == "item_added" for r in pj.read(args[0])))
EOF
)"

L2="$(new_run w33 legacy)"; Q2="$(new_run w34)"
it "legacy: a record-ruling citing a prompt typed before the move moves the home, then refuses that prompt"
P_L2="$(prompt_in "$L2" 'r-up2: I pick the tool choice on herdr:b')"
prog record-ruling r-up2 --kind tool_choice --effect restrict --scope "up2" --applies-to herdr:b --prompt "$P_L2" \
  --run "$L2"
check "nonzero True null" "$([ "$CODE" -ne 0 ] && echo nonzero) $(is_promoted "$L2") $(ruling_doc "$L2" r-up2)"
has "imported from a legacy journal" "$OUT"
it "legacy: the same record-ruling on a pick made after the move matches a promoted run"
P_L2B="$(prompt_in "$L2" 'r-up2: I pick the tool choice on herdr:b')"
prog record-ruling r-up2 --kind tool_choice --effect restrict --scope "up2" --applies-to herdr:b --prompt "$P_L2B" \
  --run "$L2"
K1="$CODE"
P_Q2="$(prompt_in "$Q2" 'r-up2: I pick the tool choice on herdr:b')"
prog record-ruling r-up2 --kind tool_choice --effect restrict --scope "up2" --applies-to herdr:b --prompt "$P_Q2" \
  --run "$Q2"
check "0 0" "$K1 $CODE"
has '"state": "accepted"' "$(ruling_doc "$L2" r-up2)"
check "$(ruling_doc "$Q2" r-up2) $(row_doc "$Q2" ruling_recorded)" "$(ruling_doc "$L2" r-up2) $(row_doc "$L2" ruling_recorded)"

P_QG="$(prompt_in "$Q1" 'r-gr: tool choice on herdr:b is yours')"
prog record-ruling r-gr --kind tool_choice --effect grant --scope "gr" --applies-to herdr:b --prompt "$P_QG" --run "$Q1"
L3="$(new_run w35 legacy)"; L4="$(new_run w36 legacy)"; Q3="$(new_run w37)"
inject "$L3" "$Q1" r-up
inject "$Q3" "$Q1" r-up
inject "$L4" "$Q1" r-gr
it "legacy: accept-context of a Ruling moves the home, and a pick made after the move accepts it as a promoted run does"
prog accept-context r-up --prompt "$(prompt_in "$L3" 'accept r-up')" --run "$L3"
K1="$CODE $(is_promoted "$L3")"
prog accept-context r-up --prompt "$(prompt_in "$L3" 'accept r-up')" --run "$L3"
K2="$CODE"
prog accept-context r-up --prompt "$(prompt_in "$Q3" 'accept r-up')" --run "$Q3"
check "1 True 0 0" "$K1 $K2 $CODE"
has '"state": "accepted"' "$(ruling_doc "$L3" r-up)"
check "$(ruling_doc "$Q3" r-up) $(row_doc "$Q3" context_accepted)" "$(ruling_doc "$L3" r-up) $(row_doc "$L3" context_accepted)"
it "legacy: a prompt-less close-ruling of a grant moves the home and closes it there as a promoted run does"
prog close-ruling r-gr --as fulfilled --why "done" --run "$L4"
K1="$CODE $(is_promoted "$L4")"
prog close-ruling r-gr --as fulfilled --why "done" --run "$Q1"
check "0 True 0" "$K1 $CODE"
has '"state": "closed"' "$(ruling_doc "$L4" r-gr)"
check "$(ruling_doc "$Q1" r-gr) $(row_doc "$Q1" ruling_closed)" "$(ruling_doc "$L4" r-gr) $(row_doc "$L4" ruling_closed)"

L5="$(new_run w38 legacy)"
prog hand-item herdr:b --question "Which crop library?" --kind tool_choice --run "$L5"
ASK5="$(pyget "$OUT" 'd["ask"]')"
it "legacy: a --replies-to correction moves the home; a reply typed after the move applies at once"
prog record-ruling r-cr5 --replies-to "$ASK5" --effect grant --scope "crop lib" \
  --prompt "$(prompt_in "$L5" 'that one did not need me')" --run "$L5"
K1="$CODE $(is_promoted "$L5")"
prog record-ruling r-cr5 --replies-to "$ASK5" --effect grant --scope "crop lib" \
  --prompt "$(prompt_in "$L5" 'that one did not need me')" --run "$L5"
check "1 True 0 herdr:b" "$K1 $CODE $(pyget "$OUT" 'd["reopened"]')"

L6="$(new_run w39 legacy)"
prog define-requirement q6 --text "b merged" --check herdr:b=merged --run "$L6"
it "legacy: accept-context of a requirement is not a Ruling change and keeps the JSON files"
prog accept-context q6 --prompt "$(prompt_in "$L6" 'requirement q6: herdr:b is merged')" --run "$L6"
check "0 False accepted" "$CODE $(is_promoted "$L6") $(pyget "$OUT" 'd["state"]')"

# ── a legacy home that cannot be moved refuses every Ruling change ────────
# The wrapper spies on the legacy write path; PROMOTE_MODE=raise makes promotion raise, lie makes it report
# success without moving anything, so the legacy write's own refusal is what stops the change.
SPY_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
auth = programme.programme_authority
imp = load_lib_module("programme_import")
mode = os.environ.get("PROMOTE_MODE")
def failing(run_id):
    raise OSError("disk unavailable")
if mode == "raise":
    imp.promote = failing
elif mode == "lie":
    imp.promote = lambda run_id: {"status": "promoted"}
legacy_write = auth._legacy_write
def spied(*a, **k):
    open(os.environ["SPY"], "a").write("entered\n")
    return legacy_write(*a, **k)
auth._legacy_write = spied
sys.exit(programme._cli(sys.argv[1:]))
'
spy_prog() {
  local mode="$1"
  shift
  rm -f "${WORK}/spy"
  OUT="$(AUTO_ROOT="$AUTO_ROOT" PROMOTE_MODE="$mode" SPY="${WORK}/spy" "$PY" -c "$SPY_PY" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
  ENTERED="$([ -e "${WORK}/spy" ] && echo entered || echo skipped)"
}
# home_hash <run>: the legacy record, journal and claims bytes, the carry-over store, and whether a
# programme.db or an import marker exists.
home_hash() {
  run_py "$1" <<'EOF'
import hashlib
home = ph.home_path(args[0])
paths = [core.run_record_path(home, args[0]), os.path.join(home, "journal.jsonl"), os.path.join(home, "claims.jsonl"),
         load_lib_module("programme_carryover").store_path()]
def digest(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12]
    except FileNotFoundError:
        return "absent"
print(" ".join(digest(p) for p in paths), os.path.exists(os.path.join(home, "programme.db")),
      os.path.exists(os.path.join(home, ".import-in-progress")))
EOF
}
LS="zq-ruling-secret-4471"
printf 'RULING_TOKEN=%s\n' "$LS" >> "$CLAUDE_AUTO_SECRETS_FILE"
L7="$(new_run w40 legacy)"
inject "$L7" "$Q1" r-up
P_QG2="$(prompt_in "$Q1" 'r-gs: tool choice on herdr:b is yours')"
prog record-ruling r-gs --kind tool_choice --effect grant --scope "gs" --applies-to herdr:b --prompt "$P_QG2" --run "$Q1"
inject "$L7" "$Q1" r-gs
prog hand-item herdr:b --question "Which crop library?" --kind tool_choice --run "$L7"
ASK7="$(pyget "$OUT" 'd["ask"]')"
run_py "$L7" "$LS" <<'EOF' >/dev/null
programme_records.edit(args[0], "prog['working_model']['doing'] = 'deploy using ' + secret", {"secret": args[1]})
EOF
H7="$(home_hash "$L7")"
it "a legacy home holding a secrets-file value is hashed before the refusals"
check "hashed False False" "$([ "${H7%% *}" != absent ] && echo hashed) $(echo "$H7" | awk '{print $5, $6}')"
# A pick older than an uncited pick is stale, so each verb gets its own, and its offer row goes into the hash.
for verb in "record-ruling r-l7 --kind tool_choice --effect restrict --scope l7 --applies-to herdr:b" \
            "pick record-ruling r-l7 --kind tool_choice --effect restrict --scope l7 --applies-to herdr:b" \
            "pick record-ruling r-l7c --replies-to $ASK7 --effect grant --scope crop" \
            "close-ruling r-gs --as fulfilled --why done" "pick accept-context r-up"; do
  case "$verb" in
    "pick "*) verb="${verb#pick }"; verb="$verb --prompt $(opick_in "$L7" "$verb")"; H7="$(home_hash "$L7")" ;;
  esac
  # shellcheck disable=SC2086
  set -- $verb
  it "legacy, promotion declined: $1 runs its checks on the JSON files, refuses the move, and leaves the home byte-identical"
  spy_prog none "$@" --run "$L7"
  check "nonzero entered $H7" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$L7")"
  has "Moving it to programme.db failed: privacy admission is" "$OUT"
done
it "legacy, promotion raising: record-ruling refuses with the cause, no traceback, home byte-identical"
spy_prog raise record-ruling r-l7 --kind tool_choice --effect restrict --scope l7 --applies-to herdr:b --run "$L7"
check "nonzero entered $H7" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$L7")"
has "failed: disk unavailable. Nothing was changed" "$OUT"
# A pending proposal on a legacy home is the change round 8 found a crash could cut from its row.
for verb in "record-ruling r-l7 --kind tool_choice --effect restrict --scope l7 --applies-to herdr:b|ruling_recorded" \
            "close-ruling r-gs --as fulfilled --why done|ruling_closed" \
            "pick accept-context r-up|context_accepted"; do
  kind="${verb##*|}"
  verb="${verb%|*}"
  case "$verb" in
    "pick "*) verb="${verb#pick }"; verb="$verb --prompt $(opick_in "$L7" "$verb")"; H7="$(home_hash "$L7")" ;;
  esac
  # shellcheck disable=SC2086
  set -- $verb
  it "legacy, promotion reporting success without moving: the legacy write refuses the $kind row before the record"
  spy_prog lie "$@" --run "$L7"
  check "nonzero entered $H7" "$([ "$CODE" -ne 0 ] && echo nonzero) $ENTERED $(home_hash "$L7")"
  has "never take a $kind row" "$OUT"
done

# ── which journal rows approve, and which change a Ruling ─────────────────
it "a pick that closed one Ruling cannot close a second"
prog record-ruling r-ca --kind technical_approach --effect restrict --scope "a" --applies-to herdr:c --run "$RUN"
prog record-ruling r-cb --kind technical_approach --effect restrict --scope "b" --applies-to herdr:c --run "$RUN"
P_CAB="$(opick 'close-ruling r-ca --as withdrawn')"
prog close-ruling r-ca --as withdrawn --prompt "$P_CAB" --run "$RUN"
K1="$CODE"
real close-ruling r-cb --as withdrawn --prompt "$P_CAB" --run "$RUN"
check "0 nonzero pending" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-cb)"
has "was already used" "$OUT"

it "a record-ruling that changes nothing does not use up its pick"
P_UC1="$(prompt 'r-uc: I pick the technical approach on herdr:d')"
prog record-ruling r-uc --kind technical_approach --effect restrict --scope "d" --applies-to herdr:d \
  --prompt "$P_UC1" --run "$RUN"
P_UC2="$(opick 'record-ruling r-uc --kind technical_approach --effect restrict --scope d --applies-to herdr:d')"
real record-ruling r-uc --kind technical_approach --effect restrict --scope "d" --applies-to herdr:d \
  --prompt "$P_UC2" --run "$RUN"
K1="$CODE $(pyget "$OUT" 'd["unchanged"]')"
real record-ruling r-uc --kind technical_approach --effect restrict --scope "d" --applies-to herdr:d \
  --prompt "$P_UC2" --run "$RUN"
check "0 true 0" "$K1 $CODE"
it "the one-change check does not count a row that changed nothing"
check "unused" "$(run_py "$RUN" "$P_UC2" <<'EOF'
load_lib_module("programme_rulings").check_prompt_unused(pj.read(args[0]), args[1])
print("unused")
EOF
)"

it "an accept-context row is a change: a pick made before it cannot close the Ruling"
prog record-ruling r-dx --kind technical_approach --effect restrict --scope "dx" --applies-to herdr:a --run "$RUN"
P_DX_OLD="$(opick 'close-ruling r-dx --as withdrawn')"
P_DX="$(opick 'accept-context r-dx')"
prog accept-context r-dx --prompt "$P_DX" --run "$RUN"
K1="$CODE"
real close-ruling r-dx --as withdrawn --prompt "$P_DX_OLD" --run "$RUN"
check "0 nonzero active" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-dx)"
has "changed since the offer" "$OUT"
it "the freshness check itself refuses a prompt from before the Ruling's latest change"
has "came before the latest change" "$(run_py "$RUN" "$P_DX_OLD" <<'EOF'
try:
    load_lib_module("programme_rulings").check_fresh(pj.read(args[0]), "r-dx", args[1])
except Exception as exc:
    print(exc)
EOF
)"

it "a later typed reply voids an earlier approval of a change to an existing Ruling"
P_KW1="$(prompt 'r-kw: I pick the tool choice on herdr:c')"
prog record-ruling r-kw --kind tool_choice --effect restrict --scope "c" --applies-to herdr:c --prompt "$P_KW1" --run "$RUN"
P_KW_W="$(opick 'close-ruling r-kw --as withdrawn')"
P_KW_K="$(prompt "no, keep r-kw, don't")"
real close-ruling r-kw --as withdrawn --prompt "$P_KW_W" --run "$RUN"
check "nonzero active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-kw)"
has "newest words" "$OUT"

it "an assign-item and a requirement citing a Ruling between Shawn's reply and accept-context leave the reply fresh"
P_AS1="$(prompt 'r-as: tool choice on herdr:a is yours')"
prog record-ruling r-as --kind tool_choice --effect grant --scope "as" --applies-to herdr:a --prompt "$P_AS1" --run "$RUN"
prog record-ruling r-as --kind tool_choice --effect grant --scope "as" --applies-to herdr:a --applies-to herdr:b --run "$RUN"
P_AS2="$(opick 'accept-context r-as')"
prog assign-item herdr:a --decision-id r-as --run "$RUN"
K1="$CODE"
prog define-requirement q-as --text "as holds" --check herdr:a=merged --decision-id r-as --run "$RUN"
K2="$CODE"
real accept-context r-as --prompt "$P_AS2" --run "$RUN"
check "0 0 0 2" "$K1 $K2 $CODE $(in_force_rev r-as)"

# ── --replies-to corrections under the journal checks ─────────────────────
prog add-item herdr:e --title "herdr:e" --kind fix_only --run "$RUN"
prog hand-item herdr:e --question "Which crop library?" --kind tool_choice --run "$RUN"
ASK3="$(pyget "$OUT" 'd["ask"]')"
it "a correction is refused when Shawn typed a later prompt nothing has cited"
P_CR="$(opick "record-ruling r-cr --replies-to $ASK3 --effect grant --scope \"crop lib\"")"
P_CR_LATER="$(prompt 'how is herdr:a going')"
real record-ruling r-cr --replies-to "$ASK3" --effect grant --scope "crop lib" --prompt "$P_CR" --run "$RUN"
check "nonzero null" "$([ "$CODE" -ne 0 ] && echo nonzero) $(state_of r-cr)"
has "newest words" "$OUT"
it "a second correction from the same pick is refused"
P_CR2="$(opick "record-ruling r-cr --replies-to $ASK3 --effect grant --scope \"crop lib\"")"
prog record-ruling r-cr --replies-to "$ASK3" --effect grant --scope "crop lib" --prompt "$P_CR2" --run "$RUN"
K1="$CODE"
real record-ruling r-cr2 --replies-to "$ASK3" --effect restrict --scope "again" --prompt "$P_CR2" --run "$RUN"
check "0 nonzero null" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(state_of r-cr2)"
has "was already used" "$OUT"

it "promoted: authority.write's own recheck refuses a stale prompt and a used one, and commits nothing"
check "newest committed already True" "$(run_py "$RUN" <<'EOF'
auth = load_lib_module("programme_authority")
rulings = load_lib_module("programme_rulings")
run = args[0]
home = ph.home_path(run)
def attempt(prompt_id):
    before = auth.head(run)["revision"]
    compose = lambda result, rec: pj.entry("ruling_recorded", "sess-pm",
                                           {"ruling_id": "r-direct", "state": "accepted", "rev": 1},
                                           cites=[prompt_id])
    try:
        auth.write(home, run, lambda rec: None, compose, recheck=rulings.recheck_approval)
        return "committed", True
    except rulings.RulingError as exc:
        return ("newest" if "newest words" in str(exc) else "already" if "already approved" in str(exc)
                else str(exc)), auth.head(run)["revision"] == before
stale = fixture_prompt(run, "sess-pm", "r-direct: I pick the tool choice", "typed")["prompt_id"]
fixture_prompt(run, "sess-pm", "how is it going", "typed")
first = attempt(stale)
once = fixture_prompt(run, "sess-pm", "r-direct: I pick the tool choice", "typed")["prompt_id"]
middle = attempt(once)
again = attempt(once)
print(first[0], middle[0], again[0], first[1] and again[1])
EOF
)"

# ── a legacy write killed around its journal append, then the move ────────
# DIE_KIND names the row; DIE_WHEN=before kills just before it is appended, after just after it lands.
DIE_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
pj = programme.programme_journal
append_row = pj.append_row
def dying(run_id, row, *a, **k):
    hit = isinstance(row, dict) and row.get("kind") == os.environ["DIE_KIND"]
    if hit and os.environ["DIE_WHEN"] == "before":
        os._exit(9)
    out = append_row(run_id, row, *a, **k)
    if hit:
        os._exit(9)
    return out
pj.append_row = dying
sys.exit(programme._cli(sys.argv[1:]))
'
prog_dying() {
  local kind="$1" when="$2"
  shift 2
  OUT="$(AUTO_ROOT="$AUTO_ROOT" DIE_KIND="$kind" DIE_WHEN="$when" "$PY" -c "$DIE_PY" "$@" 2>&1)"
  CODE=$?
}
RUN_X="$(run_py <<'EOF'
load_lib_module("programme_authority").home_for = lambda *a: None
print(ph.create_programme(["w8"], "sess-pm")["run"])
EOF
)"
x_rows() {
  run_py "$RUN_X" "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == args[1]))
EOF
}
x_field() {
  run_py "$RUN_X" "$1" <<'EOF'
prog = ph.normalize_programme(programme_records.load(args[0])["programme"])
print(json.dumps(eval(args[1]), sort_keys=True))
EOF
}
x_state() { pyget "$("$PY" "$PROG" context --run "$RUN_X" 2>&1)" "((d['decisions'].get('$1') or {}).get('state'))"; }
prog add-item herdr:x --title "herdr:x" --kind fix_only --run "$RUN_X"
prog add-item herdr:y --title "herdr:y" --kind fix_only --run "$RUN_X"
P_XQ="$(prompt_in "$RUN_X" 'requirement qx: herdr:x is merged')"
prog define-requirement qx --text "x merged" --check herdr:x=merged --prompt "$P_XQ" --run "$RUN_X"

it "legacy: a blocker_raised killed just after its row lands has its blocker in the record already"
prog_dying blocker_raised after raise-blocker bx --requirement qx --check herdr:x=merged --dependency herdr:y \
  --evidence trace:t-x1 --unblock "herdr:y lands" --run "$RUN_X"
check '9 1 "open"' "$CODE $(x_rows blocker_raised) $(x_field '(prog["context"]["blockers"].get("bx") or {}).get("state")')"
it "legacy: a blocker_raised killed just before its row lands leaves only the record change"
prog_dying blocker_raised before raise-blocker bz --requirement qx --check herdr:x=merged --dependency herdr:y \
  --evidence trace:t-x2 --unblock "herdr:y lands" --run "$RUN_X"
check '9 1 "open"' "$CODE $(x_rows blocker_raised) $(x_field '(prog["context"]["blockers"].get("bz") or {}).get("state")')"

it "legacy: the first Ruling verb moves the home; the import lists the record-only blocker and nothing for the blocker written whole"
prog record-ruling rp --kind technical_approach --effect restrict --scope "rp" --applies-to herdr:x --run "$RUN_X"
x_gaps() {
  run_py "$RUN_X" <<'EOF'
auth = load_lib_module("programme_authority")
event = next(e for e in auth.snapshot(args[0])["events"] if e["kind"] == auth.IMPORT_KIND)
gaps = event["payload"]["gaps"]
print(json.dumps(sorted([g["kind"], g.get("blocker") or ""] for g in gaps if g.get("blocker")), sort_keys=True))
EOF
}
check '0 [["record_only_update", "bz"]]' "$CODE $(x_gaps)"
it "after the move both blockers are open in the authority"
check '["open", "open"]' "$(x_field '[prog["context"]["blockers"][b]["state"] for b in ("bx", "bz")]')"

# ── a promoted Ruling write killed around its commit ──────────────────────
# The record change and its row are one commit, so a crash leaves both or neither.
DIE_COMMIT_PY='
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
programme = load_lib_module("programme")
auth = programme.programme_authority
commit = auth.commit
def dying(store, run_id, operation_id, base, state, event, *a, **k):
    hit = ((event.get("payload") or {}).get("row") or {}).get("kind") == os.environ["DIE_KIND"]
    if hit and os.environ["DIE_WHEN"] == "before":
        os._exit(9)
    out = commit(store, run_id, operation_id, base, state, event, *a, **k)
    if hit:
        os._exit(9)
    return out
auth.commit = dying
sys.exit(programme._cli(sys.argv[1:]))
'
commit_dying() {
  local kind="$1" when="$2"
  shift 2
  OUT="$(AUTO_ROOT="$AUTO_ROOT" DIE_KIND="$kind" DIE_WHEN="$when" "$PY" -c "$DIE_COMMIT_PY" "$@" 2>&1)"
  CODE=$?
}
x_ruling_rows() {
  run_py "$RUN_X" "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if (r.get("payload") or {}).get("ruling_id") == args[1]
          or (r.get("payload") or {}).get("decision_id") == args[1]))
EOF
}
P_XO="$(prompt_in "$RUN_X" 'accept rq')"
it "a proposal killed before its commit leaves no revision and no row"
commit_dying ruling_recorded before record-ruling rq --kind work_sequencing --effect restrict --scope "rq" \
  --applies-to herdr:x --run "$RUN_X"
check "9 0 null" "$CODE $(x_ruling_rows rq) $(x_state rq)"
it "a proposal killed after its commit has its revision and its row, so a prompt typed before it cannot accept it"
commit_dying ruling_recorded after record-ruling rq --kind work_sequencing --effect restrict --scope "rq" \
  --applies-to herdr:x --run "$RUN_X"
K1="$CODE $(x_ruling_rows rq) $(x_state rq)"
real accept-context rq --prompt "$P_XO" --run "$RUN_X"
check "9 1 pending nonzero pending" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(x_state rq)"
has "no open offer" "$OUT"

P_XR="$(opick_in "$RUN_X" 'record-ruling rx --kind technical_approach --effect restrict --scope rx --applies-to herdr:x')"
it "a record-ruling killed before its commit leaves the Ruling out of force and its prompt unused"
commit_dying ruling_recorded before record-ruling rx --kind technical_approach --effect restrict --scope "rx" \
  --applies-to herdr:x --prompt "$P_XR" --run "$RUN_X"
K1="$CODE $(x_ruling_rows rx) $(x_state rx)"
prog record-ruling rx --kind technical_approach --effect restrict --scope "rx" --applies-to herdr:x \
  --prompt "$P_XR" --run "$RUN_X"
check "9 0 null 0 active" "$K1 $CODE $(x_state rx)"
P_XRW="$(opick_in "$RUN_X" 'close-ruling rx --as withdrawn')"
it "a close-ruling killed before its commit leaves the Ruling in force"
commit_dying ruling_closed before close-ruling rx --as withdrawn --prompt "$P_XRW" --run "$RUN_X"
check "9 1 active" "$CODE $(x_ruling_rows rx) $(x_state rx)"
P_XA="$(opick_in "$RUN_X" 'accept-context rq')"
it "an accept-context killed before its commit leaves the revision pending"
commit_dying context_accepted before accept-context rq --prompt "$P_XA" --run "$RUN_X"
check "9 1 pending" "$CODE $(x_ruling_rows rq) $(x_state rq)"

it "programme_context still loads no protocol or journal module"
if grep -nE 'load_lib_module\("(programme_protocol|programme_journal|programme_record|programme)"\)' \
    "${AUTO_ROOT}/lib/programme_context.py" >/dev/null; then fail "programme_context loads a forbidden module"; else pass; fi

it "describe lists record-ruling and close-ruling"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
check "true true" "$(pyget "$DESC" '"record-ruling" in d["verbs"]') $(pyget "$DESC" '"close-ruling" in d["verbs"]')"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo
echo "programme-rulings-legacy-homes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Rulings: record-ruling, close-ruling, the effect-aware widening delta, the grant baseline
# and the read-time view the who-decides gate reads.
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

echo "programme-rulings.test.sh"

WORK="$(mktemp -d -t auto-programme-rulings.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
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
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
pc = load_lib_module("programme_context")
pd = load_lib_module("programme_decisions")
core = load_lib_module("run_record_core")
import programme_records
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" <<'EOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
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

pyget() {
  "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); v=eval(sys.argv[2]); print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))' "$1" "$2" 2>&1
}

ctx() { "$PY" "$PROG" context --run "$RUN" 2>&1; }
ruling_state() { pyget "$(ctx)" "d['decisions']['$1']['state']"; }
in_force_rev() { pyget "$(ctx)" "(d['decisions']['$1']['in_force'] or {}).get('rev')"; }

# rulings_for <item> <kind>: the active Rulings the gate reads, as "id:effect:items:baseline" rows.
rulings_for() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, item, kind = args
programme = ph.normalize_programme(programme_records.load(run)["programme"])
rows = pc.rulings_for(programme, item, kind, core.now_iso())
print(" ".join(f"{r['id']}:{r['effect']}:{','.join(r['items'])}:{r['baseline']}" for r in rows))
EOF
}

gate() {
  run_py "$RUN" "$1" "$2" "$3" <<'EOF'
run, item, kind, level = args
programme = ph.normalize_programme(programme_records.load(run)["programme"])
now = core.now_iso()
v = pd.who_decides(kind, item, level=level, rulings=pc.rulings_for(programme, item, kind, now), now=now,
                   accepted=True)
print(v["decider"], v["reason"])
EOF
}

ctx_hash() {
  run_py "$RUN" <<'EOF'
import hashlib
rec = programme_records.load(args[0])
print(hashlib.sha256(json.dumps(rec["programme"].get("context"), sort_keys=True).encode()).hexdigest()[:12])
EOF
}

for item in herdr:a herdr:b herdr:c herdr:d herdr:m1 herdr:m2; do
  prog add-item "$item" --title "$item" --kind fix_only --run "$RUN"
done

# ── active and pending ────────────────────────────────────────────────────
P1="$(prompt 'r-tools: you pick the tools for herdr:a and herdr:b yourself, tool choice is yours')"
it "a Ruling recorded with a typed prompt is active"
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to herdr:a --applies-to herdr:b --prompt "$P1" --run "$RUN"
check "0 accepted active" "$CODE $(pyget "$OUT" 'd["state"]') $(ruling_state r-tools)"

it "the Ruling keeps Shawn's words, its kind and its effect"
REV="$(pyget "$(ctx)" "d['decisions']['r-tools']['in_force']")"
check "r-tools: you pick the tools for herdr:a and herdr:b yourself, tool choice is yours tool_choice grant" \
  "$(pyget "$REV" 'd["quote"]') $(pyget "$REV" 'd["kind"]') $(pyget "$REV" 'd["effect"]')"

it "a Ruling recorded without a typed prompt is pending"
prog record-ruling r-later --kind work_sequencing --effect grant --scope "PM orders the queue" \
  --applies-to herdr:a --run "$RUN"
check "0 pending_acceptance pending" "$CODE $(pyget "$OUT" 'd["state"]') $(ruling_state r-later)"

it "a pending Ruling is not in the gate's view"
check "" "$(rulings_for herdr:a work_sequencing)"

state_of() { pyget "$(ctx)" "((d['decisions'].get('$1') or {}).get('state'))"; }

# ── a first grant or decided Ruling names its kind and items ──────────────
it "a first grant whose prompt names only its id is refused and does not bind"
P_BARE="$(prompt 'r-new yes go ahead')"
prog record-ruling r-new --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:c \
  --prompt "$P_BARE" --run "$RUN"
check "nonzero inactive " "$([ "$CODE" -ne 0 ] && echo nonzero) $([ "$(state_of r-new)" != active ] && echo inactive) $(rulings_for herdr:c tool_choice)"
has "tool_choice" "$OUT"

it "a first grant whose prompt names its id, kind and items binds"
P_FULL="$(prompt 'r-new: tool choice on herdr:c is yours')"
prog record-ruling r-new --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:c \
  --prompt "$P_FULL" --run "$RUN"
check "0 accepted r-new:grant:herdr:c:act" "$CODE $(pyget "$OUT" 'd["state"]') $(rulings_for herdr:c tool_choice)"

it "a first decided eval_waiver whose prompt names only its id is refused"
P_WV="$(prompt 'r-wv yes')"
prog record-ruling r-wv --kind eval_waiver --effect decided --scope "no eval" --applies-to herdr:d \
  --prompt "$P_WV" --run "$RUN"
check "nonzero inactive " "$([ "$CODE" -ne 0 ] && echo nonzero) $([ "$(state_of r-wv)" != active ] && echo inactive) $(rulings_for herdr:d eval_waiver)"

it "a first restrict whose prompt names only its id still binds"
P_RS="$(prompt 'r-rs yes')"
prog record-ruling r-rs --kind technical_approach --effect restrict --scope "Shawn accepts" --applies-to herdr:d \
  --prompt "$P_RS" --run "$RUN"
check "0 accepted" "$CODE $(pyget "$OUT" 'd["state"]')"

it "accept-context on a first grant recorded without a prompt needs its kind and items named"
prog record-ruling r-wait --kind work_sequencing --effect grant --scope "PM orders" --applies-to herdr:d --run "$RUN"
P_WA1="$(prompt 'accept r-wait')"
prog accept-context r-wait --prompt "$P_WA1" --run "$RUN"
K1="$CODE"
P_WA2="$(prompt 'accept r-wait: work sequencing on herdr:d')"
prog accept-context r-wait --prompt "$P_WA2" --run "$RUN"
check "nonzero 0 active" "$([ "$K1" -ne 0 ] && echo nonzero) $CODE $(state_of r-wait)"

# ── a carried Ruling with no items, and what reads an empty applies_to ────
it "accept-context refuses a carried Ruling that still has no items"
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
revs = rec["programme"]["context"]["decisions"].setdefault("r-car", [])
pc._append(revs, {"scope": "carried", "reason": None, "limits": [], "applies_to": [], "requirements": [],
                  "kind": "optimisation_depth", "effect": "grant", "until": None}, None, accept=False, delta=None)
revs[-1].update(quote=None, baseline=None, carried={"from": "shawn/alpha", "entry": "e1"})
programme_records.save(args[0], rec)
EOF
P_CAR="$(prompt 'accept r-car')"
prog accept-context r-car --prompt "$P_CAR" --run "$RUN"
check "nonzero pending" "$([ "$CODE" -ne 0 ] && echo nonzero) $(state_of r-car)"
has "bind carried Ruling r-car with record-ruling naming its items" "$OUT"

it "an accepted Ruling with an empty applies_to covers nothing in the rules view, the brief and the gate"
check "[] [] []" "$(run_py "$RUN" <<'EOF'
programme_mod = load_lib_module("programme")
rec = programme_records.load(args[0])
revs = rec["programme"]["context"]["decisions"]["r-car"]
pc._accept(revs, revs[-1], {"prompt_id": "p-x", "quote": "x"})
programme_records.save(args[0], rec)
programme = ph.normalize_programme(programme_records.load(args[0])["programme"])
now = core.now_iso()
shown = [r["id"] for r in programme_mod.active_rulings(programme, now) if r["id"] == "r-car"]
gate = [r["id"] for t in ("herdr:a", pc.PROGRAMME_SCOPE) for r in pc.rulings_for(programme, t, "optimisation_depth", now)
        if r["id"] == "r-car"]
rules = [r["id"] for r in programme_mod.rules_in_force(programme_records.load(args[0]))["rulings"] if r["id"] == "r-car"]
print(json.dumps(shown), json.dumps(gate), json.dumps(rules))
EOF
)"
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
del rec["programme"]["context"]["decisions"]["r-car"]
programme_records.save(args[0], rec)
EOF

it "an active grant reaches the gate as a grant for its item"
check "r-tools:grant:herdr:a,herdr:b:act" "$(rulings_for herdr:a tool_choice)"

it "unknown kind and unknown effect are refused"
prog record-ruling r-bad --kind made_up --effect grant --scope x --run "$RUN"
K1="$CODE"
prog record-ruling r-bad --kind tool_choice --effect maybe --scope x --run "$RUN"
check "nonzero nonzero" "$([ "$K1" -ne 0 ] && echo nonzero) $([ "$CODE" -ne 0 ] && echo nonzero)"

it "an end date that is not ISO Z time is refused"
prog record-ruling r-bad --kind tool_choice --effect grant --scope x --until tomorrow --run "$RUN"
check "2" "$([ "$CODE" -ne 0 ] && echo 2)"

# ── AE2: widening a grant ─────────────────────────────────────────────────
P2="$(prompt 'r-eval: eval waiver, skip full eval for herdr:a')"
prog record-ruling r-eval --kind eval_waiver --effect grant --scope "skip full eval" \
  --applies-to herdr:a --prompt "$P2" --run "$RUN"
P3="$(prompt 'r-eval: widen it')"
it "Covers AE2. Widening an accepted grant to more items stays pending even with a typed prompt"
prog record-ruling r-eval --kind eval_waiver --effect grant --scope "skip full eval" \
  --applies-to herdr:a --applies-to herdr:c --prompt "$P3" --run "$RUN"
check "0 pending_acceptance [\"herdr:c\"]" "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["delta"]["names"]')"

it "Covers AE2. The prior revision stays in force while the widening waits"
check "1 active" "$(in_force_rev r-eval) $(ruling_state r-eval)"

it "Covers AE2. The gate does not see the added item yet"
check "" "$(rulings_for herdr:c eval_waiver)"

it "Covers AE2. accept-context refuses a prompt that does not name the added item"
P4="$(prompt 'accept r-eval')"
prog accept-context r-eval --prompt "$P4" --run "$RUN"
has "herdr:c" "$OUT"

it "Covers AE2. accept-context with a prompt naming the added item makes the wider revision bind"
P5="$(prompt 'accept r-eval for herdr:c too')"
prog accept-context r-eval --prompt "$P5" --run "$RUN"
check "0 2 r-eval:grant:herdr:a,herdr:c:propose" "$CODE $(in_force_rev r-eval) $(rulings_for herdr:c eval_waiver)"

# ── narrowing ─────────────────────────────────────────────────────────────
it "narrowing a grant to fewer items applies at once"
P6="$(prompt 'r-eval: only herdr:a now')"
prog record-ruling r-eval --kind eval_waiver --effect grant --scope "skip full eval" \
  --applies-to herdr:a --prompt "$P6" --run "$RUN"
check "0 accepted 3" "$CODE $(pyget "$OUT" 'd["state"]') $(in_force_rev r-eval)"

P7="$(prompt 'r-hold: I pick the approach on herdr:a and herdr:b')"
prog record-ruling r-hold --kind technical_approach --effect restrict --scope "Shawn picks approach" \
  --applies-to herdr:a --applies-to herdr:b --prompt "$P7" --run "$RUN"
it "narrowing a restrict to fewer items is a widening and waits"
P8="$(prompt 'r-hold: only herdr:a')"
prog record-ruling r-hold --kind technical_approach --effect restrict --scope "Shawn picks approach" \
  --applies-to herdr:a --prompt "$P8" --run "$RUN"
check "0 pending_acceptance [\"herdr:b\"] 1" \
  "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["delta"]["names"]') $(in_force_rev r-hold)"

it "the restrict still holds herdr:b at the gate while its loss waits"
check "shawn restrict" "$(gate herdr:b technical_approach act)"

it "extending a grant's end date is a widening and waits"
P9="$(prompt 'r-until: optimisation depth on herdr:d until new year')"
prog record-ruling r-until --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d \
  --until 2099-01-01T00:00:00Z --prompt "$P9" --run "$RUN"
P10="$(prompt 'r-until: longer')"
prog record-ruling r-until --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d \
  --until 2100-01-01T00:00:00Z --prompt "$P10" --run "$RUN"
check "pending_acceptance" "$(pyget "$OUT" 'd["state"]')"

it "a revision may not change a Ruling's kind or effect"
P11="$(prompt 'r-tools: make it a restrict')"
prog record-ruling r-tools --kind tool_choice --effect restrict --scope "PM picks tools" \
  --applies-to herdr:a --prompt "$P11" --run "$RUN"
has "effect" "$([ "$CODE" -ne 0 ] && echo "$OUT")"

# ── AE4: protected kinds ──────────────────────────────────────────────────
it "Covers AE4. A Ruling that grants prod_deploy is refused and nothing is written"
BEFORE="$(ctx_hash)"
P12="$(prompt 'r-deploy: you can deploy herdr:a to production yourself')"
prog record-ruling r-deploy --kind prod_deploy --effect grant --scope "deploy" --applies-to herdr:a \
  --prompt "$P12" --run "$RUN"
REFUSED="$CODE"
check "nonzero protected $BEFORE null" "$([ "$REFUSED" -ne 0 ] && echo nonzero) $(case "$OUT" in *protected*) echo protected ;; esac) $(ctx_hash) $(pyget "$(ctx)" "d['decisions'].get('r-deploy')")"

it "Covers AE4. A decided Ruling on a protected kind is refused too"
prog record-ruling r-deploy --kind full_release --effect decided --scope "release" --applies-to herdr:a \
  --prompt "$P12" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"

it "Covers AE4. Every production deploy still goes to Shawn"
check "shawn protected" "$(gate herdr:a prod_deploy act)"

# ── reply-to casual corrections ───────────────────────────────────────────
P_EARLY="$(prompt 'that one did not need me')"
prog hand-item herdr:c --question "Crop on client or server?" --kind technical_approach --run "$RUN"
ASK="$(pyget "$OUT" 'd["ask"]')"
it "a correction whose prompt predates the anchor is refused"
prog record-ruling r-fix --replies-to "$ASK" --effect grant --scope "PM picks crop" --prompt "$P_EARLY" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "before prompt" "$OUT"

P_FIX="$(prompt "that didn't need me")"
it "a reply-to correction on a handed ask binds to its item and kind and applies at once"
prog record-ruling r-fix --replies-to "$ASK" --effect grant --scope "PM picks crop" --prompt "$P_FIX" --run "$RUN"
check "0 accepted technical_approach [\"herdr:c\"]" \
  "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["kind"]') $(pyget "$OUT" 'd["applies_to"]')"

it "the correction prints a one-line notice"
has "r-fix" "$(pyget "$OUT" 'd["notice"]')"

it "a granting correction reopens the handed item"
check "open" "$(run_py "$RUN" <<'EOF'
print(programme_records.load(args[0])["programme"]["items"]["herdr:c"]["state"])
EOF
)"

it "one typed prompt makes one correction"
prog record-ruling r-fix2 --replies-to "$ASK" --effect restrict --scope "again" --prompt "$P_FIX" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"

it "a correction anchored on a decision id takes that decision's item and kind"
prog log-decision herdr:b --kind work_sequencing --silent --why "b first" --run "$RUN"
DID="$(pyget "$OUT" 'd["decision_id"]')"
P_D="$(prompt 'ask me about ordering next time')"
prog record-ruling r-order --replies-to "$DID" --effect restrict --scope "Shawn orders" --prompt "$P_D" --run "$RUN"
check "0 accepted work_sequencing [\"herdr:b\"]" \
  "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["kind"]') $(pyget "$OUT" 'd["applies_to"]')"

it "a correction granting a protected kind is refused"
prog hand-item herdr:d --question "Over the cap?" --kind spend_over_cap --run "$RUN"
ASK2="$(pyget "$OUT" 'd["ask"]')"
P_S="$(prompt 'you can just spend it')"
prog record-ruling r-spend --replies-to "$ASK2" --effect grant --scope "spend" --prompt "$P_S" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"

it "a correction needs a typed prompt"
prog record-ruling r-nop --replies-to "$ASK2" --effect restrict --scope "x" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"

# ── expiry ────────────────────────────────────────────────────────────────
it "a Ruling whose end date has passed reads as expired and leaves the gate"
P_OLD="$(prompt 'r-old: acceptance on herdr:d')"
prog record-ruling r-old --kind acceptance --effect grant --scope "old" --applies-to herdr:d \
  --until 2000-01-01T00:00:00Z --prompt "$P_OLD" --run "$RUN"
check "expired " "$(ruling_state r-old) $(rulings_for herdr:d acceptance)"

# ── baseline ──────────────────────────────────────────────────────────────
it "a grant that becomes active records the Authority level in force for its kind"
check "act" "$(pyget "$(ctx)" "d['decisions']['r-tools']['in_force']['baseline']")"

printf '{"autonomy": {"tool_choice": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
it "a later narrowing revision keeps that baseline"
P_N="$(prompt 'r-tools: just herdr:a')"
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to herdr:a --prompt "$P_N" --run "$RUN"
check "accepted act" "$(pyget "$OUT" 'd["state"]') $(pyget "$(ctx)" "d['decisions']['r-tools']['in_force']['baseline']")"

it "a newly accepted revision records a fresh baseline"
P_W="$(prompt 'r-tools: add herdr:d')"
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to herdr:a --applies-to herdr:d --prompt "$P_W" --run "$RUN"
P_WA="$(prompt 'accept r-tools for herdr:d')"
prog accept-context r-tools --prompt "$P_WA" --run "$RUN"
check "0 propose" "$CODE $(pyget "$(ctx)" "d['decisions']['r-tools']['in_force']['baseline']")"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

# ── close-ruling ──────────────────────────────────────────────────────────
it "close-ruling --as withdrawn needs a typed prompt"
prog close-ruling r-eval --as withdrawn --run "$RUN"
check "nonzero active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-eval)"

it "close-ruling --as fulfilled needs a reason"
prog close-ruling r-eval --as fulfilled --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"

it "close-ruling --as fulfilled with a reason closes a grant"
prog close-ruling r-eval --as fulfilled --why "the eval ran after all" --run "$RUN"
check "0 closed " "$CODE $(ruling_state r-eval) $(rulings_for herdr:a eval_waiver)"

it "close-ruling --as withdrawn with a typed prompt naming it closes the Ruling"
P_C="$(prompt 'withdraw r-later')"
prog close-ruling r-later --as withdrawn --prompt "$P_C" --run "$RUN"
check "0 closed" "$CODE $(ruling_state r-later)"

it "closing a restrict needs a typed prompt even as fulfilled: it hands the kind back to the PM"
prog close-ruling r-order --as fulfilled --why "done" --run "$RUN"
check "nonzero active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-order)"

# ── decided Rulings ───────────────────────────────────────────────────────
P_DEC="$(prompt 'r-call: server-side crop on herdr:a, my call on the technical approach')"
prog record-ruling r-call --kind technical_approach --effect decided --scope "server crop" \
  --applies-to herdr:a --prompt "$P_DEC" --run "$RUN"
it "changing a decided Ruling without a typed prompt is refused, not parked"
prog record-ruling r-call --kind technical_approach --effect decided --scope "client crop" \
  --applies-to herdr:a --run "$RUN"
check "nonzero 1 active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-call) $(ruling_state r-call)"

it "changing a decided Ruling with a typed prompt that names it applies"
P_DEC2="$(prompt 'r-call: client crop after all')"
prog record-ruling r-call --kind technical_approach --effect decided --scope "client crop" \
  --applies-to herdr:a --prompt "$P_DEC2" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-call)"

it "closing a decided Ruling as fulfilled needs a typed prompt naming it"
prog close-ruling r-call --as fulfilled --why "shipped" --run "$RUN"
K1="$CODE"
P_DEC3="$(prompt 'r-call is done')"
prog close-ruling r-call --as fulfilled --why "shipped" --prompt "$P_DEC3" --run "$RUN"
check "nonzero 0 closed" "$([ "$K1" -ne 0 ] && echo nonzero) $CODE $(ruling_state r-call)"

# ── merges and programme scope ────────────────────────────────────────────
P_M="$(prompt 'r-merge: herdr:m1 worker coordination is yours')"
prog record-ruling r-merge --kind worker_coordination --effect grant --scope "m1" --applies-to herdr:m1 \
  --prompt "$P_M" --run "$RUN"
prog merge-item herdr:m1 herdr:m2 --run "$RUN"
it "after an item merge, a Ruling naming the old id still applies to the merged item"
check "r-merge:grant:herdr:m2:act grant" "$(rulings_for herdr:m2 worker_coordination) $(gate herdr:m2 worker_coordination act | cut -d' ' -f2)"

it "a programme-wide grant reaches an item-level decision at the gate"
P_P="$(prompt 'r-prog: optimisation depth is yours across the programme')"
prog record-ruling r-prog --kind optimisation_depth --effect grant --scope "depth" --prompt "$P_P" --run "$RUN"
check "pm grant" "$(gate herdr:b optimisation_depth act)"


it "programme_context still loads no protocol or journal module"
if grep -nE 'load_lib_module\("(programme_protocol|programme_journal|programme_record|programme)"\)' \
    "${AUTO_ROOT}/lib/programme_context.py" >/dev/null; then fail "programme_context loads a forbidden module"; else pass; fi

it "describe lists record-ruling and close-ruling"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
check "true true" "$(pyget "$DESC" '"record-ruling" in d["verbs"]') $(pyget "$DESC" '"close-ruling" in d["verbs"]')"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo
echo "programme-rulings.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

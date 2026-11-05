#!/usr/bin/env bash
# Rulings: record-ruling, close-ruling, the effect-aware widening delta, the grant baseline
# and the read-time view the who-decides gate reads.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-rulings.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-rulings-setup.sh"

# ── active and pending ────────────────────────────────────────────────────
P1="$(prompt 'r-tools: you pick the tools for herdr:a and herdr:b yourself, tool choice is yours')"
it "a Ruling recorded on a pick is active"
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to herdr:a --applies-to herdr:b --prompt "$P1" --run "$RUN"
check "0 accepted active" "$CODE $(pyget "$OUT" 'd["state"]') $(ruling_state r-tools)"

it "the Ruling keeps the text Shawn picked, its kind and its effect"
REV="$(pyget "$(ctx)" "d['decisions']['r-tools']['in_force']")"
check "PM picks tools tool_choice grant" \
  "$(pyget "$REV" 'd["quote"]') $(pyget "$REV" 'd["kind"]') $(pyget "$REV" 'd["effect"]')"

it "a Ruling recorded without a typed prompt is pending"
prog record-ruling r-later --kind work_sequencing --effect grant --scope "PM orders the queue" \
  --applies-to herdr:a --run "$RUN"
check "0 pending_acceptance pending" "$CODE $(pyget "$OUT" 'd["state"]') $(ruling_state r-later)"

it "a pending Ruling is not in the gate's view"
check "" "$(rulings_for herdr:a work_sequencing)"


# ── a first grant or decided Ruling names its kind and items ──────────────
it "a first grant on typed words with no open offer is refused and does not bind"
P_BARE="$(prompt 'r-new yes go ahead')"
real record-ruling r-new --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:c \
  --prompt "$P_BARE" --run "$RUN"
check "nonzero inactive " "$([ "$CODE" -ne 0 ] && echo nonzero) $([ "$(state_of r-new)" != active ] && echo inactive) $(rulings_for herdr:c tool_choice)"
has "no open offer" "$OUT"

it "a first grant on a pick binds"
P_FULL="$(prompt 'r-new: tool choice on herdr:c is yours')"
prog record-ruling r-new --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:c \
  --prompt "$P_FULL" --run "$RUN"
check "0 accepted r-new:grant:herdr:c:act" "$CODE $(pyget "$OUT" 'd["state"]') $(rulings_for herdr:c tool_choice)"

it "a first decided eval_waiver on typed words with no open offer is refused"
P_WV="$(prompt 'r-wv yes')"
real record-ruling r-wv --kind eval_waiver --effect decided --scope "no eval" --applies-to herdr:d \
  --prompt "$P_WV" --run "$RUN"
check "nonzero inactive " "$([ "$CODE" -ne 0 ] && echo nonzero) $([ "$(state_of r-wv)" != active ] && echo inactive) $(rulings_for herdr:d eval_waiver)"
has "no open offer" "$OUT"

it "a first restrict on a pick binds"
P_RS="$(prompt 'r-rs yes')"
prog record-ruling r-rs --kind technical_approach --effect restrict --scope "Shawn accepts" --applies-to herdr:d \
  --prompt "$P_RS" --run "$RUN"
check "0 accepted" "$CODE $(pyget "$OUT" 'd["state"]')"

it "accept-context on a first grant recorded without a prompt refuses typed words and takes a pick"
prog record-ruling r-wait --kind work_sequencing --effect grant --scope "PM orders" --applies-to herdr:d --run "$RUN"
P_WA1="$(prompt 'accept r-wait')"
real accept-context r-wait --prompt "$P_WA1" --run "$RUN"
K1="$CODE"
P_WA2="$(opick 'accept-context r-wait')"
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
it "Covers AE2. Widening an accepted grant on typed words with no open offer is refused"
real record-ruling r-eval --kind eval_waiver --effect grant --scope "skip full eval" \
  --applies-to herdr:a --applies-to herdr:c --prompt "$P3" --run "$RUN"
check "1 1" "$CODE $(in_force_rev r-eval)"
has "no open offer" "$OUT"
it "Covers AE2. Widening an accepted grant to more items with no prompt stays pending"
prog record-ruling r-eval --kind eval_waiver --effect grant --scope "skip full eval" \
  --applies-to herdr:a --applies-to herdr:c --run "$RUN"
check "0 pending_acceptance [\"herdr:c\"]" "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["delta"]["names"]')"

it "Covers AE2. The prior revision stays in force while the widening waits"
check "1 active" "$(in_force_rev r-eval) $(ruling_state r-eval)"

it "Covers AE2. The gate does not see the added item yet"
check "" "$(rulings_for herdr:c eval_waiver)"

it "Covers AE2. accept-context refuses typed words with no open offer"
P4="$(prompt 'accept r-eval for herdr:c too')"
real accept-context r-eval --prompt "$P4" --run "$RUN"
has "no open offer" "$OUT"

it "Covers AE2. accept-context on a pick makes the wider revision bind"
P5="$(opick 'accept-context r-eval')"
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
prog record-ruling r-hold --kind technical_approach --effect restrict --scope "Shawn picks approach" \
  --applies-to herdr:a --run "$RUN"
check "0 pending_acceptance [\"herdr:b\"] 1" \
  "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["delta"]["names"]') $(in_force_rev r-hold)"

it "the restrict still holds herdr:b at the gate while its loss waits"
check "shawn restrict" "$(gate herdr:b technical_approach act)"

it "extending a grant's end date is a widening and waits"
P9="$(prompt 'r-until: optimisation depth on herdr:d until new year')"
prog record-ruling r-until --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d \
  --until 2099-01-01T00:00:00Z --prompt "$P9" --run "$RUN"
prog record-ruling r-until --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d \
  --until 2100-01-01T00:00:00Z --run "$RUN"
check "pending_acceptance" "$(pyget "$OUT" 'd["state"]')"

it "accept-context refuses a later end date on typed words with no open offer"
P_U1="$(prompt 'accept r-until, it runs until 2100-01-01')"
real accept-context r-until --prompt "$P_U1" --run "$RUN"
check "nonzero 1" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-until)"
has "no open offer" "$OUT"

it "accept-context on a pick makes the later end date bind"
P_U2="$(opick 'accept-context r-until')"
prog accept-context r-until --prompt "$P_U2" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-until)"

it "dropping the end date altogether waits for a pick"
prog record-ruling r-until --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d --run "$RUN"
P_U4="$(prompt 'accept r-until with no end date')"
real accept-context r-until --prompt "$P_U4" --run "$RUN"
K1="$CODE"
P_U5="$(opick 'accept-context r-until')"
prog accept-context r-until --prompt "$P_U5" --run "$RUN"
check "nonzero 0 3" "$([ "$K1" -ne 0 ] && echo nonzero) $CODE $(in_force_rev r-until)"

it "dropping a limit from a grant is a widening and waits"
P_L1="$(prompt 'r-lim: file issue on herdr:d is yours, no major versions')"
prog record-ruling r-lim --kind file_issue --effect grant --scope "bumps" --applies-to herdr:d \
  --limit "no major versions" --prompt "$P_L1" --run "$RUN"
prog record-ruling r-lim --kind file_issue --effect grant --scope "bumps" --applies-to herdr:d --run "$RUN"
check "pending_acceptance 1" "$(pyget "$OUT" 'd["state"]') $(in_force_rev r-lim)"

it "accept-context refuses a dropped limit on typed words with no open offer"
P_L3="$(prompt 'accept r-lim, drop the no major versions limit')"
real accept-context r-lim --prompt "$P_L3" --run "$RUN"
check "nonzero 1" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-lim)"
has "no open offer" "$OUT"

it "accept-context on a pick makes the wider grant bind"
P_L4="$(opick 'accept-context r-lim')"
prog accept-context r-lim --prompt "$P_L4" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-lim)"

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
it "a correction whose prompt predates the anchor is refused: no offer of it was open"
real record-ruling r-fix --replies-to "$ASK" --effect grant --scope "PM picks crop" --prompt "$P_EARLY" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "no open offer" "$OUT"
it "the anchor-order check itself refuses a prompt from before the anchor"
has "before prompt" "$(run_py "$RUN" "$ASK" "$P_EARLY" <<'EOF'
try:
    load_lib_module("programme_rulings").check_anchor_order(pj.read(args[0]), args[1], args[2])
except Exception as exc:
    print(exc)
EOF
)"

P_FIX="$(opick "record-ruling r-fix --replies-to $ASK --effect grant --scope \"PM picks crop\"")"
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

it "one pick makes one correction"
real record-ruling r-fix2 --replies-to "$ASK" --effect restrict --scope "again" --prompt "$P_FIX" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
has "was already used" "$OUT"

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
P_OLD="$(prompt 'r-old: acceptance on herdr:a')"
prog record-ruling r-old --kind acceptance --effect grant --scope "old" --applies-to herdr:a \
  --until 2000-01-01T00:00:00Z --prompt "$P_OLD" --run "$RUN"
check "expired " "$(ruling_state r-old) $(rulings_for herdr:a acceptance)"

it "an accepted Ruling past its end date is absent from the rules in force"
check "[]" "$(run_py "$RUN" <<'EOF'
programme_mod = load_lib_module("programme")
print(json.dumps([r["id"] for r in programme_mod.rules_in_force(programme_records.load(args[0]))["rulings"]
                  if r["id"] == "r-old"]))
EOF
)"

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
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to herdr:a --applies-to herdr:d --run "$RUN"
P_WA="$(opick 'accept-context r-tools')"
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

it "close-ruling --as withdrawn on a pick closes the Ruling"
P_C="$(prompt 'withdraw r-later')"
prog close-ruling r-later --as withdrawn --prompt "$P_C" --run "$RUN"
check "0 closed" "$CODE $(ruling_state r-later)"

it "closing a restrict needs a typed prompt even as fulfilled: it hands the kind back to the PM"
prog close-ruling r-order --as fulfilled --why "done" --run "$RUN"
check "nonzero active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-order)"

# ── record-ruling refusals that write nothing ─────────────────────────────
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
decisions = rec["programme"]["context"]["decisions"]
decisions["t-legacy"] = [{"rev": 1, "state": "accepted", "kind": None, "effect": "restrict", "legacy": "project_term",
                          "scope": "Shawn writes prices", "applies_to": ["programme"], "limits": [], "requirements": []}]
decisions["d-plain"] = [{"rev": 1, "state": "accepted", "scope": "crop only", "reason": None, "limits": [],
                         "applies_to": ["herdr:a"], "requirements": []}]
programme_records.save(args[0], rec)
EOF
refused_unchanged() {
  local before; before="$(ctx_hash)"
  local p; p="$(prompt "$1: $2 tool choice on herdr:a")"
  prog record-ruling "$1" --kind tool_choice --effect "$2" --scope "x" --applies-to herdr:a --prompt "$p" --run "$RUN"
  RESULT="$([ "$CODE" -ne 0 ] && echo nonzero) $([ "$(ctx_hash)" = "$before" ] && echo unchanged)"
}
it "record-ruling refuses to revise a closed Ruling and writes nothing"
refused_unchanged r-eval grant
check "nonzero unchanged" "$RESULT"
has "Ruling 'r-eval' is closed; record a new Ruling instead" "$OUT"
it "record-ruling refuses to revise an old project term and writes nothing"
refused_unchanged t-legacy restrict
check "nonzero unchanged" "$RESULT"
has "'t-legacy' is an old project term with no decision kind" "$OUT"
it "record-ruling refuses to revise a decision record without a kind and writes nothing"
refused_unchanged d-plain grant
check "nonzero unchanged" "$RESULT"
has "'d-plain' is a decision record without a kind" "$OUT"

# ── decided Rulings ───────────────────────────────────────────────────────
P_DEC="$(prompt 'r-call: server-side crop on herdr:a, my call on the technical approach')"
prog record-ruling r-call --kind technical_approach --effect decided --scope "server crop" \
  --applies-to herdr:a --prompt "$P_DEC" --run "$RUN"
it "changing a decided Ruling without a typed prompt is refused, not parked"
prog record-ruling r-call --kind technical_approach --effect decided --scope "client crop" \
  --applies-to herdr:a --run "$RUN"
check "nonzero 1 active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-call) $(ruling_state r-call)"

it "changing a decided Ruling on a pick applies"
P_DEC2="$(prompt 'r-call: client crop after all')"
prog record-ruling r-call --kind technical_approach --effect decided --scope "client crop" \
  --applies-to herdr:a --prompt "$P_DEC2" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-call)"

it "closing a decided Ruling as fulfilled needs a pick"
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

it "dropping the end date is accepted on a pick"
P_OE1="$(prompt 'r-oe: optimisation depth on herdr:d until new year')"
prog record-ruling r-oe --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d \
  --until 2099-01-01T00:00:00Z --prompt "$P_OE1" --run "$RUN"
prog record-ruling r-oe --kind optimisation_depth --effect grant --scope "depth" --applies-to herdr:d --run "$RUN"
P_OE2="$(prompt 'accept r-oe, it is open-ended now')"
prog accept-context r-oe --prompt "$P_OE2" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-oe)"

it "a Ruling conflict is false for a restrict and for a grant with no kind"
check "False False" "$(run_py "$RUN" <<'EOF'
host = load_lib_module("programme")
programme = ph.normalize_programme(programme_records.load(args[0])["programme"])
levels = load_lib_module("programme_protocol").AuthorityLevels(host.prompt_lookup)
repos = load_lib_module("programme_rulings").repos_for(programme, ["herdr:a"])
print(levels.conflicted({"effect": "restrict", "kind": "tool_choice", "baseline": "act"}, repos),
      levels.conflicted({"effect": "grant", "kind": None, "baseline": "act"}, repos))
EOF
)"

# ── a Ruling approval prompt is typed after the proposal and used once ────
P_A1="$(opick 'record-ruling r-lim2 --kind file_issue --effect grant --scope bumps --applies-to herdr:d --limit "no major versions"')"
prog record-ruling r-lim2 --kind file_issue --effect grant --scope "bumps" --applies-to herdr:d \
  --limit "no major versions" --prompt "$P_A1" --run "$RUN"
P_PRE="$(prompt 'accept r-lim2, drop the no major versions limit')"
prog record-ruling r-lim2 --kind file_issue --effect grant --scope "bumps" --applies-to herdr:d --run "$RUN"
it "the pick that imposed a limit cannot approve that limit's removal"
real accept-context r-lim2 --prompt "$P_A1" --run "$RUN"
check "nonzero 1" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-lim2)"
has "was already used" "$OUT"

it "words typed before the offer of the pending revision cannot accept it"
P_A2="$(opick 'accept-context r-lim2')"
real accept-context r-lim2 --prompt "$P_PRE" --run "$RUN"
check "nonzero 1" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-lim2)"
has "came before the offer" "$OUT"

it "a pick on that offer accepts it"
prog accept-context r-lim2 --prompt "$P_A2" --run "$RUN"
check "0 2" "$CODE $(in_force_rev r-lim2)"

it "a pick that approved one Ruling cannot approve a second through record-ruling"
P_RU="$(opick 'record-ruling r-ua --kind worker_coordination --effect grant --scope b --applies-to herdr:b')"
prog record-ruling r-ua --kind worker_coordination --effect grant --scope "b" --applies-to herdr:b \
  --prompt "$P_RU" --run "$RUN"
K1="$CODE"
real record-ruling r-ub --kind worker_coordination --effect grant --scope "b" --applies-to herdr:b \
  --prompt "$P_RU" --run "$RUN"
check "0 nonzero null" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(state_of r-ub)"
has "was already used" "$OUT"

it "a pick that accepted one Ruling cannot accept a second"
prog record-ruling r-pa --kind technical_approach --effect restrict --scope "a" --applies-to herdr:b --run "$RUN"
prog record-ruling r-pb --kind technical_approach --effect restrict --scope "b" --applies-to herdr:b --run "$RUN"
P_PAB="$(opick 'accept-context r-pa')"
prog accept-context r-pa --prompt "$P_PAB" --run "$RUN"
K1="$CODE"
real accept-context r-pb --prompt "$P_PAB" --run "$RUN"
check "0 nonzero pending" "$K1 $([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-pb)"
has "was already used" "$OUT"

it "a new Ruling does not bind on a pick Shawn has typed past"
P_STALE="$(opick 'record-ruling r-fst --kind technical_approach --effect restrict --scope "Shawn picks" --applies-to herdr:b')"
P_LATER="$(prompt 'what is the status of herdr:a')"
real record-ruling r-fst --kind technical_approach --effect restrict --scope "Shawn picks" --applies-to herdr:b \
  --prompt "$P_STALE" --run "$RUN"
check "nonzero null" "$([ "$CODE" -ne 0 ] && echo nonzero) $(state_of r-fst)"
has "newest words" "$OUT"

it "close-ruling refuses a withdrawal picked before the Ruling's latest change"
P_WOLD="$(opick 'close-ruling r-ua --as withdrawn')"
P_NL="$(prompt 'r-ua: add the limit no new workers')"
prog record-ruling r-ua --kind worker_coordination --effect grant --scope "b" --applies-to herdr:b \
  --limit "no new workers" --prompt "$P_NL" --run "$RUN"
real close-ruling r-ua --as withdrawn --prompt "$P_WOLD" --run "$RUN"
check "nonzero active" "$([ "$CODE" -ne 0 ] && echo nonzero) $(ruling_state r-ua)"
has "changed since the offer" "$OUT"
P_WNEW="$(prompt 'withdraw r-ua')"
prog close-ruling r-ua --as withdrawn --prompt "$P_WNEW" --run "$RUN"
check "0 closed" "$CODE $(ruling_state r-ua)"

it "accepting a narrowing grant revision keeps the old baseline, so the Ruling conflict stays"
P_GN="$(prompt 'g-nar: tool choice on herdr:a and herdr:b is yours')"
prog record-ruling g-nar --kind tool_choice --effect grant --scope "tools" --applies-to herdr:a \
  --applies-to herdr:b --prompt "$P_GN" --run "$RUN"
printf '{"autonomy": {"tool_choice": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
prog record-ruling g-nar --kind tool_choice --effect grant --scope "tools" --applies-to herdr:a --run "$RUN"
P_GNA="$(prompt 'accept g-nar')"
prog accept-context g-nar --prompt "$P_GNA" --run "$RUN"
check "0 act conflict" "$CODE $(pyget "$(ctx)" "d['decisions']['g-nar']['in_force']['baseline']") $(gate herdr:a tool_choice propose | cut -d' ' -f2)"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

it "accept-context refuses a pending wider grant stored without its words and asks to re-record it"
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
revs = rec["programme"]["context"]["decisions"].setdefault("r-oldw", [])
base = {"scope": "bumps", "reason": None, "applies_to": ["herdr:d"], "requirements": [], "kind": "file_issue",
        "effect": "grant", "until": None}
pc._append(revs, dict(base, limits=["no majors"]), {"prompt_id": "p-old", "quote": "x", "origin": "typed"}, accept=True, delta=None)
revs[-1].update(quote="x", baseline="act")
pc._append(revs, dict(base, limits=[]), None, accept=False,
           delta={"added": [], "removed": [], "removed_limits": ["no majors"], "until": None, "names": [], "wider": True})
revs[-1].update(quote=None, baseline=None)
programme_records.save(args[0], rec)
EOF
P_OW="$(prompt 'accept r-oldw, drop no majors')"
prog accept-context r-oldw --prompt "$P_OW" --run "$RUN"
check "nonzero 1" "$([ "$CODE" -ne 0 ] && echo nonzero) $(in_force_rev r-oldw)"
has "re-record" "$OUT"

# ── a Ruling approval is checked and journaled under one lock ─────────────
home_of() {
  run_py "$1" <<'EOF'
print(ph.home_path(args[0]))
EOF
}
wait_for() { local i; for i in $(seq 1 200); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
# race <home> <first verb args> -- <second command>: the first writer pauses after its checks, before its
# approval row is committed; the second command runs during that pause.
race() {
  local home="$1" first=()
  shift
  while [ "$1" != "--" ]; do first+=("$1"); shift; done
  shift
  rm -f "${WORK}/race1.out" "${WORK}/race2.out"
  CLAUDE_AUTO_TEST_WRITE_PAUSE_BEFORE_JOURNAL=1 "$PY" "$REAL_PROG" "${first[@]}" > "${WORK}/race1.out" 2>&1 &
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
it "two writers racing on one pick: the second is refused once the first journals its approval"
P_RACE="$(opick 'record-ruling r-ra --kind worker_coordination --effect restrict --scope a --applies-to herdr:b')"
race "$(home_of "$RUN")" record-ruling r-ra --kind worker_coordination --effect restrict --scope "a" \
  --applies-to herdr:b --prompt "$P_RACE" --run "$RUN" -- "$PY" "$REAL_PROG" record-ruling r-rb --kind worker_coordination \
  --effect restrict --scope "b" --applies-to herdr:b --prompt "$P_RACE" --run "$RUN"
check "paused blocked 0 nonzero" "$PAUSED $BLOCKED $C1 $([ "$C2" -ne 0 ] && echo nonzero)"
has "was already used" "$OUT2"

it "a prompt typed while a Ruling change is checked waits, and lands after the change's approval row"
P_PV1="$(prompt_in "$RUN" 'r-pv: I pick the tool choice on herdr:b')"
prog record-ruling r-pv --kind tool_choice --effect restrict --scope "pv" --applies-to herdr:b \
  --prompt "$P_PV1" --run "$RUN"
P_PVW="$(opick 'close-ruling r-pv --as withdrawn')"
race "$(home_of "$RUN")" close-ruling r-pv --as withdrawn --prompt "$P_PVW" --run "$RUN" -- \
  prompt_in "$RUN" "no, keep r-pv"
P_PVK="$(printf '%s' "$OUT2" | tail -1)"
check "paused blocked 0 0" "$PAUSED $BLOCKED $C1 $C2"
check "True" "$(run_py "$RUN" "$P_PVK" <<'EOF'
rows = pj.read(args[0])
closed = next(i for i, r in enumerate(rows) if r["kind"] == "ruling_closed" and r["payload"].get("ruling_id") == "r-pv")
typed = next((i for i, r in enumerate(rows) if r.get("prompt_id") == args[1]), None)
print(typed is not None and closed < typed)
EOF
)"

it "no verb crashed with a traceback"
# programme-rulings-legacy-homes.test.sh counts this check's pass; here a crash still fails the file.
[ -z "$CRASHES" ] || fail "expected [] got [$CRASHES]"

echo
echo "programme-rulings.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

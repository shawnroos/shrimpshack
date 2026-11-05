#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-rituals-offers-and-checks.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-rituals-setup.sh"

# ---- ritual improvements: U1 refusal detail, U2 offers, U3 first-due report ----
RUN_I="$(new_run)"
PI="$(tprompt "$RUN_I" "record the version check ritual")"

it "U1: a refusal names the step number and the word that matched"
check "protected_escalation full_release: step 2" "$(run_py <<'EOF'
v = pr.verdict(ritual("r1", steps=["check every plugin version", "publish the plugin now"]))
print(v["reason"], v["detail"][:len("full_release: step 2")])
EOF
)"
has 'publish' "$(run_py <<'EOF'
print(pr.verdict(ritual("r1", steps=["check it", "publish the plugin now"]))["detail"])
EOF
)"

it "U1: record-ritual output names the step and tells the PM to reword, not to ask for an approval"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --step "publish the plugin"
check 1 "$CODE"
has "step 2" "$OUT"
has "reword" "$OUT"
case "$OUT" in *"type the approval"*) fail "fix still tells the PM to ask for a typed approval: $OUT" ;; *) pass ;; esac

it "U2: an offer line may name a protected action while the same text as a step is refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --offer "ask Shawn whether to publish the plugin now"
check 0 "$CODE"
OFFER_ID="$(jfield "$OUT" 'd["ritual"]')"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "ask Shawn whether to publish the plugin now"
check 1 "$CODE"
has "protected_escalation" "$OUT"

it "U2: offers alone, without a step, are refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --offer "ask whether to publish"
check 2 "$CODE"
has "at least one --step" "$OUT"

it "U2: the stored ritual keeps its offers and an offer never changes the step scan"
check "['ask Shawn whether to publish the plugin now']" "$(q "$RUN_I" "[e for e in prog['rituals'] if e['id'] == '$OFFER_ID'][0]['offers']")"
check "None" "$(run_py "$RUN_I" "$OFFER_ID" <<'EOF'
e = [e for e in record(args[0])["programme"]["rituals"] if e["id"] == args[1]][0]
print(pr.protected_kind(e))
EOF
)"

it "U2: a due row and the Programme view show the offer"
check "['ask Shawn whether to publish the plugin now']" "$(run_py <<'EOF'
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": "2026-11-02T09:00:00Z"}})
got = due.due(record(run), run, now=at("2026-11-02T09:30:00Z"), store={"personal": [], "repos": {}, "rejected": [], "notices": []}, rows=[])
print(got["due"][0]["offers"])
EOF
)"

it "U2: an offers value that is not a list of non-empty strings is rejected"
check "bad_value offers" "$(run_py <<'EOF'
v = pr.verdict(ritual("r1", offers=["ok", ""]))
print(v["reason"], v["detail"])
EOF
)"

it "U3: record-ritual reports the first due time and the clock it reads"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions"
check 0 "$CODE"
has "first_due_at" "$OUT"
has "clock" "$OUT"

it "U3: first due time is strictly after now for a slot already passed today"
check "2026-11-03T09:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
print(iso(pr.next_after({"every": "day", "at": "09:00"}, at("2026-11-02T09:30:00Z"))))
EOF
)"

it "U3: --ran-now recorded before the slot moves the first due time to tomorrow"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --ran-now --outcome "all versions bumped"
check 0 "$CODE"
check "True" "$(jfield "$OUT" 'd["ran_now"]')"
check "True" "$(jfield "$OUT" 'd["first_due_at"] > __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")')"

it "U3: --ran-now on an event ritual is refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "at start" --trigger start --step "read the journal" --ran-now
check 1 "$CODE"
has "ran-now" "$OUT"

it "U4: the Programme view shows the next due time in local time with the zone, whatever the machine zone"
view_text() {
  run_py "$1" <<'EOF'
import time, datetime
from zoneinfo import ZoneInfo
zone = args[0]
os.environ["TZ"] = zone; time.tzset()
due_at = (datetime.datetime.now(UTC) + datetime.timedelta(days=3)).replace(second=0, microsecond=0)
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": iso(due_at)}})
pv = load_lib_module("programme_view")
text = pv._ritual_text(pv.rituals_view(record(run), [])[0])
local = due_at.astimezone(ZoneInfo(zone)).strftime("%Y-%m-%d %H:%M %Z")
print("next " + iso(due_at) + " = " + local + " machine local time" in text, "offers (ask Shawn, never act)" in text)
EOF
}
check "True True" "$(view_text UTC)"
check "True True" "$(view_text America/New_York)"
check "True True" "$(view_text Africa/Johannesburg)"

it "U4: daily 09:00 stays 09:00 local across spring-forward and fall-back"
check "2026-03-08T13:00:00Z 2026-11-01T14:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "America/New_York"; time.tzset()
sched = {"every": "day", "at": "09:00"}
print(iso(pr.next_after(sched, at("2026-03-07T15:00:00Z"))), iso(pr.next_after(sched, at("2026-10-31T14:00:00Z"))))
EOF
)"

it "U3: the clock sentence names the zone"
has "machine local time (UTC)" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
print(pr.describe_clock())
EOF
)"

it "review: --ran-now before today's slot skips that slot, and after it does not skip tomorrow's"
check "2026-11-03T09:00:00Z 2026-11-03T09:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
daily = ritual("rd", when={"text": "daily", "trigger": "calendar", "schedule": {"every": "day", "at": "09:00"}})
def first(now_text):
    programme = {}
    pr.advance_clock(programme, daily, now=at(now_text), first_slot_done=True)
    return programme["ritual_clock"]["rd"]["next_due_at"]
print(first("2026-11-02T08:00:00Z"), first("2026-11-02T09:30:00Z"))
EOF
)"

it "review: the zone label belongs to the due time, not to today"
has "09:00 EDT" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "America/New_York"; time.tzset()
print(pr.local_text(at("2026-07-01T13:00:00Z")))
EOF
)"

it "review: --outcome without --ran-now is refused instead of dropped"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --outcome "all bumped"
check 2 "$CODE"
has "--outcome" "$OUT"

it "review: --from-proposal accepts --ran-now, as the skill tells the PM"
prog propose-ritual --run "$RUN_I" --when "daily check" --schedule "daily 09:00" --step "check versions" --offer "ask whether to publish"
check 0 "$CODE"
has "ask whether to publish" "$OUT"
PROP_I="$(jfield "$OUT" 'd["ritual"]')"
PI2="$(opick "$RUN_I" "record-ritual --from-proposal ${PROP_I} --ran-now --outcome 'all bumped'")"
prog record-ritual --run "$RUN_I" --from-proposal "$PROP_I" --prompt "$PI2" --ran-now --outcome "all bumped"
check 0 "$CODE"
check "True" "$(jfield "$OUT" 'd["ran_now"]')"

it "review: start-ritual and a due row carry offers with the rule that they are questions"
has "never actions" "$(run_py <<'EOF'
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": "2026-11-02T09:00:00Z"}})
got = due.due(record(run), run, now=at("2026-11-02T09:30:00Z"), store={"personal": [], "repos": {}, "rejected": [], "notices": []}, rows=[])
print(got["due"][0]["offers_rule"])
EOF
)"

# ---- ritual checks: C1 the check field ----
def_check='{"name": "versions-bumped", "repo_key": "acme/alpha"}'
run_chk() {
  local extra="${2-}"; [ -n "$extra" ] || extra='{}'
  run_py "$1" "$extra" <<'EOF'
import json
c = json.loads(args[0]); extra = json.loads(args[1])
e = ritual("rc", **extra); e["check"] = c
v = pr.verdict(e)
print(v["reason"], v["detail"])
EOF
}

it "C1: a known check on a calendar programme-layer ritual with a remit repo is accepted"
check "None None" "$(run_chk "$def_check")"

it "C1: an unknown check name, an unknown key and a base with .. are refused"
check "bad_value check.name" "$(run_chk '{"name": "rm-everything", "repo_key": "acme/alpha"}')"
check "unknown_key" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "cmd": "ls"}' | cut -d' ' -f1)"
check "bad_value check.base" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "base": "a..b"}')"
check "bad_value check.base" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "base": "--upload-pack=x"}')"

it "C1: a check on the personal layer, or on an event ritual, is refused"
check "bad_value check.layer" "$(run_chk "$def_check" '{"layer": "personal"}')"
check "bad_value check.trigger" "$(run_chk "$def_check" '{"when": {"text": "at start", "trigger": "start"}}')"

it "C1: a programme-layer check must carry a repo key, and a repo-layer check must not"
check "missing_field check.repo_key" "$(run_chk '{"name": "versions-bumped"}')"
check "bad_value check.repo_key" "$(run_chk "$def_check" '{"layer": "repo"}')"
check "None None" "$(run_chk '{"name": "versions-bumped"}' '{"layer": "repo"}')"

it "C1: a hand-edited store entry with a bad check is rejected at load"
check "check.layer" "$(run_py <<'EOF'
store = os.environ["CLAUDE_AUTO_RITUALS_STORE"]
os.makedirs(os.path.dirname(store), exist_ok=True)
e = ritual("rbad", layer="personal"); e["check"] = {"name": "versions-bumped"}
json.dump({"format": 1, "personal": [e], "repos": {}}, open(store, "w"))
print(pr.load_store()["rejected"][0]["detail"] if pr.load_store()["rejected"] else "none rejected")
EOF
)"
rm -f "$CLAUDE_AUTO_RITUALS_STORE"

RUN_C="$(new_run)"
run_py "$RUN_C" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": os.path.join(os.environ["WORK"], "alpha"), "github": "acme/alpha"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
PC="$(tprompt "$RUN_C" "record the versions bumped check")"
PCX="$(tprompt "$RUN_C" "record the weekly report")"

it "C1: record-ritual --check shows the check in its offer, typed words with no offer approve nothing, and the repo defaults from a one-repo remit"
C_BEFORE="$(q "$RUN_C" "len(prog['rituals'])")"
PROG="${AUTO_ROOT}/lib/programme.py" prog record-ritual --run "$RUN_C" --prompt "$PCX" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 1 "$CODE"
has "no open offer" "$OUT"
check "$C_BEFORE" "$(q "$RUN_C" "len(prog['rituals'])")"
has "Check: versions-bumped" "$("$PY" "$PROG" offer ritual-check --command "record-ritual --when 'daily, shown' --schedule 'daily 09:00' --step 'check versions' --check versions-bumped" --run "$RUN_C" 2>&1)"
prog record-ritual --run "$RUN_C" --prompt "$PC" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 0 "$CODE"
CK="$(jfield "$OUT" 'd["ritual"]')"
check "{'name': 'versions-bumped', 'repo_key': 'acme/alpha'}" "$(q "$RUN_C" "[e for e in prog['rituals'] if e['id'] == '$CK'][0]['check']")"

it "C1: --check-base .. is refused and a missing remit repo is a clear refusal"
prog record-ritual --run "$RUN_C" --prompt "$PC" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped --check-base "a..b"
check 1 "$CODE"
RUN_C0="$(new_run)"
PC0="$(tprompt "$RUN_C0" "record the versions bumped check")"
prog record-ritual --run "$RUN_C0" --prompt "$PC0" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 1 "$CODE"
has "--check-repo" "$OUT"

it "C1: propose-ritual --check stores a proposal without a prompt"
prog propose-ritual --run "$RUN_C" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 0 "$CODE"
check "proposed" "$(jfield "$OUT" 'd["state"]')"

it "C1: move-ritual and keep-rituals refuse a ritual that carries a check"
PM1="$(tprompt "$RUN_C" "move ${CK} to personal use everywhere")"
prog move-ritual "$CK" --to personal --prompt "$PM1" --run "$RUN_C"
check 1 "$CODE"
has "check" "$OUT"

# ---- ritual checks: C3 the run-ritual-checks verb ----
mkrepo() {
  local d="${WORK}/$1"
  mkdir -p "$d/plugins/foo/.claude-plugin" "$d/plugins/foo/lib" "$d/.claude-plugin"
  git -C "$d" init -q -b main
  printf '{"name": "foo", "version": "1.0.0"}' > "$d/plugins/foo/.claude-plugin/plugin.json"
  printf '{"plugins": [{"name": "foo", "version": "1.0.0", "source": "./plugins/foo"}]}' > "$d/.claude-plugin/marketplace.json"
  printf 'x = 1\n' > "$d/plugins/foo/lib/code.py"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m initial
  if [ "${2:-ok}" = "unbumped" ]; then
    printf 'x = 2\n' > "$d/plugins/foo/lib/code.py"
    git -C "$d" -c user.name=t -c user.email=t@t commit -q -am "change code, no bump"
  fi
}
check_run() {
  run_py "$1" "$2" "$3" "$4" <<'EOF'
run_name, repo_dir, minutes_ago, key = args[0], args[1], int(args[2]), args[3]
entry = ritual("rchk", check={"name": "versions-bumped", "repo_key": key, "base": "main"})
due_at = datetime.datetime.now(UTC) - datetime.timedelta(minutes=minutes_ago)
run = setup([entry], clock={"rchk": {"next_due_at": iso(due_at)}})
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": repo_dir, "github": "acme/gamma"}]
core._with_locked_run_record(ph.home_path(run), run, mutate)
print(run)
EOF
}

mkrepo good ok
mkrepo bad unbumped

it "C3: a due ritual whose check passes is answered without the PM: clock moves, one row, counts recorded"
RUNP="$(check_run x "${WORK}/good" 5 acme/gamma)"
prog run-ritual-checks --run "$RUNP"
check 0 "$CODE"
check "1 pass 1" "$(q "$RUNP" "' '.join([str(count('ritual_checked')), [r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['result'], str([r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['checked'])])")"
check "[]" "$(run_py "$RUNP" <<'EOF'
rec = record(args[0])
print([r["ritual"] for r in due.due(rec, args[0])["due"]])
EOF
)"

it "C3: a failing check leaves the ritual due with the result in its row, and does not run again for the same slot"
RUNF="$(check_run x "${WORK}/bad" 5 acme/gamma)"
prog run-ritual-checks --run "$RUNF"
check 0 "$CODE"
prog run-ritual-checks --run "$RUNF"
check "1" "$(q "$RUNF" "count('ritual_checked')")"
check "rchk fail foo" "$(run_py "$RUNF" <<'EOF'
rec = record(args[0])
row = due.due(rec, args[0])["due"][0]
print(row["ritual"], row["check"]["result"], row["check"]["failed"][0]["plugin"])
EOF
)"

it "C3: --ritual re-runs a check that already ran for the slot"
prog run-ritual-checks --run "$RUNF" --ritual rchk
check "2" "$(q "$RUNF" "count('ritual_checked')")"

it "C3: a check whose repo is not in the remit is an error row and the ritual stays due"
RUNE="$(check_run x "${WORK}/good" 5 acme/elsewhere)"
prog run-ritual-checks --run "$RUNE"
check "error repo_not_in_remit" "$(q "$RUNE" "' '.join([[r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload'][k] for k in ('result','reason')])")"

it "C3: a missed slot is checked too, and a pass moves the clock and marks it late"
RUNM="$(check_run x "${WORK}/good" 300 acme/gamma)"
prog run-ritual-checks --run "$RUNM"
check "pass True" "$(q "$RUNM" "' '.join([[r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['result'], str([r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['late'])])")"

it "C3: a session that is not the driver writes nothing and the ritual stays due"
RUNN="$(check_run x "${WORK}/good" 5 acme/gamma)"
CLAUDE_CODE_SESSION_ID=sess-other prog run-ritual-checks --run "$RUNN"
check 0 "$CODE"
has '"not_recorded": ["rchk"]' "$OUT"
check "0" "$(q "$RUNN" "count('ritual_checked')")"

it "C3: a pass row is quiet bookkeeping for the sweep and a fail row is not"
check "True False" "$(run_py <<'EOF'
psi = load_lib_module("programme_sweep_inputs")
print(psi._quiet_row({"kind": "ritual_checked", "payload": {"result": "pass"}}),
      psi._quiet_row({"kind": "ritual_checked", "payload": {"result": "fail"}}))
EOF
)"

it "C3: a ritual with no check is never run by the verb"
RUNQ="$(run_py <<'EOF'
print(setup([ritual("rplain")], clock={"rplain": {"next_due_at": iso(datetime.datetime.now(UTC) - datetime.timedelta(minutes=5))}}))
EOF
)"
prog run-ritual-checks --run "$RUNQ"
check 0 "$CODE"
has '"ran": 0' "$OUT"
check "0" "$(q "$RUNQ" "count('ritual_checked')")"

it "C4: the Programme view shows the last check result, the failed plugins and the age of the clone"
has "check versions-bumped: fail (shipped_changed), failed: foo" "$(run_py "$RUNF" <<'EOF'
pv = load_lib_module("programme_view")
rec = record(args[0])
rows = pv.rituals_view(rec, pj.read(args[0]))
print(pv._ritual_text(rows[0]))
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

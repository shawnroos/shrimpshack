#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-sources-behaviours.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-sources-setup.sh"

BRIEF="${WORK}/brief.md"
printf 'Build shot kinds.\n' > "$BRIEF"
write_snapshot base
seed_behaviours '[{"id": "bpm", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "the item changes the editor", "checks": [{"text": "the item is an editor change", "by": "pm"}]},
  "do": ["run the editor smoke test"]},
 {"id": "bpmself", "layer": "programme", "applies_to": "pm", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "always", "checks": []}, "do": ["post a tracker note"]}]'

rebuilt() { [ "$CODE" -eq 0 ] || fail "setup: $OUT"; }
prog add-item linear:AI-753 --title "Shot kinds"
rebuilt
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 -- --name shot-kinds --handoff "$BRIEF"
rebuilt
prog add-item herdr:w2/p31 --title "issueless pane"
rebuilt
prog add-item herdr:w2/p31 --pane w2:p31 --terminal-id term_p31
rebuilt
prog add-item linear:AI-773 --title "no pane"
rebuilt

write_snapshot base
seed_behaviours '[{"id": "bui", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "the work changes UI", "checks": [{"text": "the diff touches UI files", "by": "agent"}]},
  "do": ["browser-verify the change"], "evidence": "a browser recording attached"}]'
prog add-item linear:AI-793 --title "UI change"
: > "$CALLS"
prog start-worker linear:AI-793 -- --name ui --target tab
it "start-worker with a matching worker behaviour and no --handoff is refused with the existing message"
check 2 "$CODE"
has "needs --handoff" "$OUT"
lacks "spinoff" "$(calls)"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-793 -- --name ui --handoff "$BRIEF"
it "F2: start-worker with a matching behaviour writes a brief copy carrying the behaviours block"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "Behaviours this work follows:" "$COPY"
has "- bui: when the work changes UI. do: browser-verify the change. evidence: a browser recording attached" "$COPY"
it "a PM-only behaviour and an unnamed PM-checked behaviour stay out of the brief"
lacks "bpmself" "$COPY"
lacks "- bpm:" "$COPY"
it "F2: the item records the brief delivery"
check '[["bui", "brief", "start-worker"]]' "$(field '[[d["id"], d["reason"], d["via"]] for d in items["linear:AI-793"]["behaviour_deliveries"]]')"
prog add-item linear:AI-795 --title "UI change that fails to start"
prog start-worker linear:AI-795 -- --name uifail --handoff "$BRIEF"
it "a start where no agent appears records no behaviour delivery on the item"
check "1 null" "$CODE $(field 'items["linear:AI-795"].get("behaviour_deliveries")')"
it "the worker_started row and the recovery request carry the behaviour ids"
has '"behaviour_ids": ["bui"]' "$(journal_last worker_started)"
check "with" "$(run_py "$RUN" "$BRIEF" <<'EOF'
rec = load_lib_module("programme_recovery")
rows = [r["payload"] for r in pj.read(args[0]) if r["kind"] == "operation_admitted" and r["payload"].get("item") == "linear:AI-793"]
op = rows[-1]
base = {"spinoff": ["--name", "ui", "--handoff", args[1]], "decision_ids": [], "restrictions": []}
with_ids = rec.request_digest("launch", op["item"], op["target"], dict(base, behaviour_ids=["bui"]))
print("with" if op["digest"] == with_ids else ("without" if op["digest"] == rec.request_digest("launch", op["item"], op["target"], base) else "neither"))
EOF
)"

write_snapshot base
prog add-item linear:AI-794 --title "Editor change"
: > "$CALLS"
prog start-worker linear:AI-794 --behaviour bpmself -- --name ed --handoff "$BRIEF"
it "start-worker refuses --behaviour naming a PM-only behaviour, and never calls spinoff"
check 1 "$CODE"
lacks "spinoff" "$(calls)"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-794 --behaviour bpm -- --name ed --handoff "$BRIEF"
it "start-worker --behaviour adds a PM-checked behaviour the PM saw hold"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "- bpm: when the item changes the editor" "$COPY"
check '["bpm", "bui"]' "$(field 'sorted(d["id"] for d in items["linear:AI-794"]["behaviour_deliveries"])')"

write_snapshot base
run_py "$RUN" <<'EOF' >/dev/null
import datetime
pj.append_row(args[0], pj.entry("claim", "sess-w", {"item": "herdr:w2/p31", "deliverable": "merged", "ref": "pr:9"},
                                now=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc)), channel="claims")
pb = load_lib_module("programme_behaviours")
def body(rec):
    pb.record_delivery(rec["programme"]["items"]["herdr:w2/p31"], "bpm", "brief", "start-worker")
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
seed_behaviours '[{"id": "bearly", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-03-01T00:00:00Z",
  "when": {"text": "the work changes UI", "checks": [{"text": "the diff touches UI files", "by": "agent"}]},
  "do": ["attach a browser recording"], "evidence": "a browser recording attached"},
 {"id": "blate", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "history": [{"event": "recorded", "at": "2026-09-01T00:00:00Z"}],
  "when": {"text": "a claim is made", "checks": []}, "do": ["name the test command in the claim"]}]'
SENT_BEFORE="$(journal_count prompt_sent)"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bpm --reason relevant
it "a behaviour delivered in the brief is still due for a relevant reminder when its PM check holds"
check 0 "$CODE"
has "herdr agent prompt w2:p31 Behaviour bpm" "$(calls)"
check '["bpm", "relevant", "remind-behaviour"]' "$(field '[items["herdr:w2/p31"]["behaviour_deliveries"][-1][k] for k in ("id", "reason", "via")]')"
it "the reminder journals one behaviour_reminded row and no prompt_sent row"
check "1 ${SENT_BEFORE}" "$(journal_count behaviour_reminded) $(journal_count prompt_sent)"
has '"behaviour": "bpm"' "$(journal_last behaviour_reminded)"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back
it "a behaviour created after the worker started but before its claim sends the claim back"
check 0 "$CODE"
has '"timing": "send_back"' "$OUT"
has "sent back" "$(calls)"
has "a browser recording attached" "$(calls)"
it "AE2: the first send-back reports a count of 1"
has '"sent_back_count": 1' "$OUT"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back
it "AE2: a second send-back of the same behaviour on the same item reports a count of 2"
check 0 "$CODE"
has '"sent_back_count": 2' "$OUT"
check 2 "$(field 'len([d for d in items["herdr:w2/p31"]["behaviour_deliveries"] if d["id"] == "bearly" and d["reason"] == "sent_back"])')"

: > "$CALLS"
DELIVERIES_BEFORE="$(field 'len(items["herdr:w2/p31"]["behaviour_deliveries"])')"
prog remind-behaviour herdr:w2/p31 blate --reason sent_back
it "AE3: a send-back of a behaviour recorded after the item's claim is refused as remind-only"
check 1 "$CODE"
has "remind" "$OUT"
lacks "agent prompt" "$(calls)"
check "$DELIVERIES_BEFORE" "$(field 'len(items["herdr:w2/p31"]["behaviour_deliveries"])')"
prog remind-behaviour herdr:w2/p31 blate --reason relevant
it "AE3: the reminder goes out, reports remind-only and tells the worker it applies from now on"
check 0 "$CODE"
has '"timing": "remind_only"' "$OUT"
has "from now on" "$(calls)"
it "AE3: the item records the relevant delivery with the claim it came after"
check '["blate", "relevant", "claim", "2026-06-01T00:00:00Z", "remind_only"]' "$(field '[items["herdr:w2/p31"]["behaviour_deliveries"][-1][k] for k in ("id", "reason", "trigger", "trigger_at", "timing")]')"

: > "$CALLS"
prog remind-behaviour herdr:w2/p31 bearly --reason sent_back --trigger merge
it "a send-back against a trigger the item has not passed is refused"
check 1 "$CODE"
lacks "agent prompt" "$(calls)"

seed_behaviours "[{\"id\": \"blong\", \"layer\": \"programme\", \"applies_to\": \"workers\", \"state\": \"active\", \"at\": \"2026-01-01T00:00:00Z\",
  \"when\": {\"text\": \"always\", \"checks\": []}, \"do\": [\"$("$PY" -c 'print("y" * 5000)')\"]}]"
: > "$CALLS"
prog remind-behaviour herdr:w2/p31 blong --reason relevant
it "a reminder over the 4000-character cap is cut to fit and still names the behaviour id"
check 0 "$CODE"
has "herdr agent prompt w2:p31 Behaviour blong" "$(calls)"
check "True" "$("$PY" -c 'import sys; t=open(sys.argv[1]).read().split("herdr agent prompt w2:p31 ", 1)[1].rstrip("\n"); print(len(t) <= 4000 and t.endswith("..."))' "$CALLS")"

REFUSED_BEFORE="$(journal_count prompt_refused)"
: > "$CALLS"
prog remind-behaviour linear:AI-773 bearly --reason relevant
it "remind-behaviour to an item with no owner pane is refused like prompt-item"
check 1 "$CODE"
has "no recorded pane" "$OUT"
lacks "agent prompt" "$(calls)"
check "$((REFUSED_BEFORE + 1)) null" "$(journal_count prompt_refused) $(field 'items["linear:AI-773"].get("behaviour_deliveries")')"

prog remind-behaviour herdr:w2/p31 bpmself --reason relevant
it "remind-behaviour refuses a PM-only behaviour"
check 1 "$CODE"
prog remind-behaviour herdr:w2/p31 bnosuch --reason relevant
it "remind-behaviour refuses an unknown behaviour"
check 1 "$CODE"
prog remind-behaviour herdr:w2/p31 bui --reason later
it "remind-behaviour refuses an unknown reason"
check 2 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-other prog remind-behaviour herdr:w2/p31 bui --reason relevant
it "remind-behaviour refuses a session that does not drive the programme"
check 1 "$CODE"
write_snapshot base

it "a start with no focus limit leaves the item with no hold"
check 'null' "$(field 'items["linear:AI-753"]["held"]')"

focus_limit() {
  local pid
  pid="$("$PY" - "$AUTO_ROOT" "$RUN" "focus budget limited $*" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from programme_prompts import append_prompt
print(append_prompt(sys.argv[2], "sess-pm", sys.argv[3], "typed")["prompt_id"])
PYEOF
)"
  prog amend-term focus_budget limited "$@" --prompt "$pid"
}
focus_limit --points 5 --agents none
prog add-item linear:AI-760 --title "sized" --size large
: > "$CALLS"
FAKE_HERDR_DOWN=1 prog start-worker linear:AI-760 -- --name big --handoff /tmp/h.md
it "start-worker with a point limit and herdr unreadable holds the start"
check 1 "$CODE"
has "count unavailable" "$OUT"
it "the held start never calls spinoff"
lacks "spinoff" "$(calls)"
it "the hold is recorded on the item"
has "count unavailable" "$(field 'items["linear:AI-760"]["held"]')"

focus_limit --points none --agents 1
: > "$CALLS"
prog start-worker linear:AI-760 -- --name big --handoff /tmp/h.md
it "a worker pane no item owns, started by hand, counts against the agent limit"
check 1 "$CODE"
has "agents at limit" "$OUT"
it "the agent-limit hold never calls spinoff"
lacks "spinoff" "$(calls)"

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-sources-behaviours.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

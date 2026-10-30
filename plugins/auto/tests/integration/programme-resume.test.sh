#!/usr/bin/env bash
# Restored context through the real hooks (U8): ended and archived programmes stay read-only
# at session start, a missing view is rebuilt only over readable authority, a home whose lease
# file is gone is surfaced, a request the hook cannot journal is reported, and status shows
# end and archive state. No real herdr, spinoff or tracker runs: the fixture's fakes log calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-programme-resume.XXXXXX)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/closure-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/herdr-pane.sh"
NOREPO="${WORK}/norepo"
REPO="${WORK}/repo"
mkdir -p "$NOREPO" "${REPO}/.claude/auto"

echo "programme-resume.test.sh"
write_snapshot base

hook_in() {
  local dir="$1" hook="$2" payload="$3"
  ( cd "$dir" && CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "${HOOKS}/${hook}" <<< "$payload" 2>/dev/null )
}
context_of() {
  "$PY" -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("<empty>"); sys.exit(0)
try:
    d = json.loads(raw)
except ValueError:
    print(raw.strip()); sys.exit(0)
print((d.get("hookSpecificOutput") or {}).get("additionalContext") or "")
' <<< "$1"
}
calls() { wc -l < "$CALLS" | tr -d ' '; }

# ── Scenario 5: ended and archived programmes at session start ──
RUNE="$(new_programme w2)"
prog add-item linear:AI-1 --title "unfinished" --run "$RUNE" >/dev/null
end_typed "$RUNE" >/dev/null
RUNA="$(new_programme w3)"
prog add-item linear:AI-2 --title "stopped" --run "$RUNA" >/dev/null
end_typed "$RUNA" >/dev/null
prog dispose-item linear:AI-2 --as stopped_unfinished --why "stopped" --run "$RUNA"
prog archive --run "$RUNA" --op seal-a
it "S5 setup: one programme ended unarchived, one archived"
check "0 true" "$CODE $(pyget "$OUT" 'd["sealed"]')"

BASE_E="$(inventory "$RUNE")"
BASE_A="$(inventory "$RUNA")"
CALLS0="$(calls)"
CTXE=""
for src in startup compact resume; do
  OUTS="$(hook_in "$NOREPO" on-session-start.sh "{\"session_id\":\"sess-pm\",\"source\":\"${src}\"}")"
  [ "$src" = startup ] && CTXE="$(context_of "$OUTS")"
done
hook_in "$NOREPO" on-pre-compact.sh '{"session_id":"sess-pm","trigger":"auto","custom_instructions":null}' >/dev/null
hook_in "$NOREPO" on-stop.sh '{"session_id":"sess-pm"}' >/dev/null
it "S5: the closing session is told the ended programme is not archived"
has "programme ${RUNE} has ended and is not archived" "$CTXE"
it "S5: the line forbids starting workers and re-arming watchers"
has "Start no workers and re-arm no watchers" "$CTXE"
it "S5: the archived programme gets no line"
lacks "$RUNA" "$CTXE"
it "S5: session start restores no rules for an ended programme"
lacks "<auto-rules>" "$CTXE"
it "S5: the ended home is byte-identical after SessionStart, PreCompact and Stop"
check "$BASE_E" "$(inventory "$RUNE")"
it "S5: the archived home is byte-identical after SessionStart, PreCompact and Stop"
check "$BASE_A" "$(inventory "$RUNA")"
it "S5: no worker started and no herdr or spinoff call was made"
check "$CALLS0" "$(calls)"
it "S5: no compact flag was set on either home"
check "absent absent" "$([ -e "$(home_of "$RUNE")/.compact-flag" ] && echo present || echo absent) $([ -e "$(home_of "$RUNA")/.compact-flag" ] && echo present || echo absent)"
OUTP="$(hook_in "$NOREPO" on-session-start.sh '{"session_id":"sess-stranger","source":"startup"}')"
it "S5: a session no closing entry names gets nothing"
check "" "$OUTP"

# ── Lifecycle in status (end, closure, archive) ──
rm -f "$(home_of "$RUNE")/views/view.json"
BASE_E2="$(inventory "$RUNE")"
prog status --run "$RUNE"
it "S5/S6: status on an ended programme with no view writes nothing"
check "0" "$CODE"
check "$BASE_E2" "$(inventory "$RUNE")"
it "status shows an ended programme's end and archive section"
has "End and archive" "$OUT"
has "ended: ended_by_shawn" "$OUT"
it "status says the ended programme is not archived"
has "not archived: run check-archive, then archive" "$OUT"
prog archive --run "$RUNE"
it "archive refuses the ended programme with an undisposed item"
check 1 "$CODE"
prog status --run "$RUNE"
it "status names the archive check that last failed"
has "the last archive attempt failed dispositions" "$OUT"
prog status --run "$RUNA" --json
it "status --json carries the seal in the lifecycle block"
check "true" "$(pyget "$OUT" 'bool(d["model"]["lifecycle"]["sealed_at"]) and d["model"]["lifecycle"]["manifest"] is not None')"
prog status --run "$RUNA"
it "status text shows the archive as read-only with its manifest"
has "read-only" "$OUT"
has "manifest " "$OUT"
it "the released lease shows as released"
has "resources released: lease:default.w3" "$OUT"
it "status on the archived programme left its home unchanged"
check "$BASE_A" "$(inventory "$RUNA")"

# ── Scenario 6: a missing optional view is rebuilt, never over missing authority ──
RUNV="$(new_programme w4)"
prog add-item linear:AI-3 --title "active" --run "$RUNV" >/dev/null
VIEW="$(home_of "$RUNV")/views/view.json"
rm -f "$VIEW"
prog status --run "$RUNV"
it "S6: status on an active programme with no view rebuilds the view"
check "0 present" "$CODE $([ -e "$VIEW" ] && echo present || echo absent)"
it "S6: the rebuilt view holds the item"
has "linear:AI-3" "$(cat "$VIEW" 2>/dev/null)"
rm -f "$VIEW"
mv "$(home_of "$RUNV")/programme.db" "${WORK}/held.db"
prog status --run "$RUNV"
it "S6: with programme.db missing, status refuses instead of reading the export"
check 1 "$CODE"
has "programme.db is missing" "$OUT"
it "S6: no view is written over missing authority"
check absent "$([ -e "$VIEW" ] && echo present || echo absent)"
CTXV="$(context_of "$(hook_in "$NOREPO" on-session-start.sh '{"session_id":"sess-pm","source":"startup"}')")"
it "S6: session start reports the hold rather than an empty programme"
has "programme ${RUNV} cannot restore its rules: its authority is unavailable" "$CTXV"
lacks "programme: ${RUNV}" "$CTXV"
mv "${WORK}/held.db" "$(home_of "$RUNV")/programme.db"

# ── Residual: a home whose lease file is gone ──
LEASE4="${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w4.json"
rm -f "$LEASE4"
BASE_V="$(inventory "$RUNV")"
CTXL="$(context_of "$(hook_in "$REPO" on-session-start.sh '{"session_id":"sess-pm","source":"startup"}')")"
it "a programme naming this session with no lease file is surfaced at session start"
has "programme ${RUNV} names this session as its driver, but no lease file names the run" "$CTXL"
it "the line names reconcile-leases"
has "reconcile-leases --run ${RUNV}" "$CTXL"
it "surfacing it writes nothing"
check "$BASE_V" "$(inventory "$RUNV")"
CTXO="$(context_of "$(hook_in "$REPO" on-session-start.sh '{"session_id":"sess-other","source":"startup"}')")"
it "another session is not told about it"
lacks "$RUNV" "$CTXO"
prog reconcile-leases --run "$RUNV"
CTXL2="$(context_of "$(hook_in "$REPO" on-session-start.sh '{"session_id":"sess-pm","source":"startup"}')")"
it "after reconcile-leases the line is gone and the rules come back"
lacks "no lease file names the run" "$CTXL2"
has "programme: ${RUNV}" "$CTXL2"

# ── Residual: a takeover request the hook cannot journal is reported, not dropped ──
DB="$(home_of "$RUNV")/programme.db"
cp "$DB" "${WORK}/good.db"
printf 'not a database' > "$DB"
DBSUM="$(shasum -a 256 "$DB")"
PAYLOAD="$("$PY" -c 'import json; print(json.dumps({"session_id": "sess-new", "prompt": "/auto:programme-takeover"}))')"
register_session sess-new w4 >/dev/null
OUTR="$( cd "$NOREPO" && HERDR_PANE_ID="w4:p77" HERDR_WORKSPACE_ID="w4" CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" \
  bash "${HOOKS}/on-user-prompt.sh" <<< "$PAYLOAD" 2>/dev/null )"
CTXR="$(context_of "$OUTR")"
it "a takeover request against a held programme is reported to the session"
has "auto did not journal this /auto:programme-takeover request" "$CTXR"
it "the report names the hold"
has "corrupt" "$CTXR"
it "the report says the takeover verb will refuse without it"
has "The takeover verb will" "$CTXR"
it "the held database is untouched"
check "$DBSUM" "$(shasum -a 256 "$DB")"
cp "${WORK}/good.db" "$DB"
OUTOK="$( cd "$NOREPO" && HERDR_PANE_ID="w4:p77" HERDR_WORKSPACE_ID="w4" CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" \
  bash "${HOOKS}/on-user-prompt.sh" <<< "$PAYLOAD" 2>/dev/null )"
it "with readable authority the same request is journaled and nothing is reported"
check "" "$OUTOK"
check "takeover_request" "$(run_py "$RUNV" <<'EOF'
print([r["kind"] for r in pj.read(args[0])][-1])
EOF
)"

# ── The inbox verb reads claims from the store ──
prog add-item linear:AI-4 --title "claims" --kind fix_only --run "$RUNV" >/dev/null
CLAUDE_CODE_SESSION_ID=sess-w1 prog claim --run "$RUNV" --item linear:AI-4 --deliverable merged \
  --ref "https://github.com/o/r/pull/9"
rm -f "$(home_of "$RUNV")/claims.jsonl"
prog inbox --run "$RUNV"
it "inbox lists the unread claim from the store with the claims export removed"
check "0 1 0 https://github.com/o/r/pull/9" "$CODE $(pyget "$OUT" 'len(d["claims"])') $(pyget "$OUT" 'd["claims"][0]["index"]') $(pyget "$OUT" 'd["claims"][0]["payload"]["ref"]')"
it "inbox names the mark-read offset"
check "mark-read --offset 1" "$(pyget "$OUT" 'd["next"]')"
prog mark-read --offset 1 --run "$RUNV"
prog inbox --run "$RUNV"
it "after mark-read inbox has no unread claim"
check "0 0 1" "$CODE $(pyget "$OUT" 'len(d["claims"])') $(pyget "$OUT" 'd["total"]')"
prog inbox --run "$RUNV" --all
it "inbox --all still lists every claim"
check "1" "$(pyget "$OUT" 'len(d["claims"])')"

it "no command crashed with a traceback"
check "" "$CRASHES"

echo
echo "programme-resume.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

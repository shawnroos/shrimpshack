#!/usr/bin/env bash
# auto U4 integration test: the advisor-gate PreToolUse hooks.
#
# Exercises the REAL run_record.py + the U4 hook scripts (.sh wrappers exec'ing into
# the sibling .py) wired exactly as the plugin manifest wires them. The ONLY
# injection points are the repo path (a sandbox tmp repo) and the PreToolUse event
# JSON (fed on stdin, as the harness would). Nothing is mocked.
#
# `driving_session_id` is recorded on the run-record by U5 (the arm-time setter),
# which is not part of THIS step. So — exactly as hooks.test.sh hand-ages
# last_beat_at — we inject driving_session_id by a direct read-edit-write of the
# run-record JSON. Without it the defensive read finds the key absent and ALLOWS, so
# every deny scenario depends on this injection.
#
# Scenarios (U4 plan):
#   askuser hook:
#     - live self-driven run + MATCHING session_id   -> deny + advisor redirect
#     - live run + MISMATCHED session_id (standalone) -> allow (KTD-5)
#     - no run-record / phase==done / driver==manual / stale (>3900s) -> allow
#     - malformed run-record -> allow + exit 0 (rel-001)
#   action hook, no limit set:
#     - destructive on a live owned run -> no deny, driver stays self, no audit row
#     - a run the backstop paused before the upgrade stays paused until continue
#   The limit that refuses these commands is in check-settings.test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"
ASKUSER_SH="${AUTO_ROOT}/.claude/hooks/on-pretooluse-askuser.sh"
ASKUSER_PY="${AUTO_ROOT}/lib/on-pretooluse-askuser.py"
ACTION_PY="${AUTO_ROOT}/lib/on-pretooluse-action.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
mkrepo() {
  local repo="${SANDBOX}/repo-${1}"
  mkdir -p "${repo}/.claude/auto"
  printf '%s' "$repo"
}

py_run_record() {
  local repo="$1"; shift
  "$PY" - "$repo" "$RUN_RECORD_PY"
}

# Inject driving_session_id onto a run's run-record by direct JSON edit (U5 owns the
# real setter — mirrors hooks.test.sh hand-aging last_beat_at).
set_driving_session() {
  local repo="$1" run="$2" sid="$3"
  "$PY" - "$repo" "$run" "$sid" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, sid, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
p = L.run_record_path(repo, run)
with open(p) as f: led = json.load(f)
led["driving_session_id"] = sid
with open(p,"w") as f: json.dump(led,f)
PYEOF
}

jget() { "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], ''))
except Exception:
    print('')" "$1" "$2"; }

# Read loop.driver / loop.blocked_on for run-record assertions.
rd_loop() {
  local repo="$1" run="$2" field="$3"
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$RUN_RECORD_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_run_record('$repo','$run');print(l['loop'].get('$field'))"
}

# Read the top-level advisor_audit list (NOT under loop) — count + a field of
# the most-recent record. usage: rd_audit <repo> <run> <count|kind|classification>
rd_audit() {
  local repo="$1" run="$2" what="$3"
  "$PY" -c "import importlib.util as u,sys
s=u.spec_from_file_location('l','$RUN_RECORD_PY');m=u.module_from_spec(s);s.loader.exec_module(m)
l=m.read_run_record('$repo','$run');aud=l.get('advisor_audit') or []
what='$what'
if what=='count': print(len(aud))
elif aud: print(aud[-1].get(what,''))
else: print('')"
}

# Pull permissionDecision out of a hookSpecificOutput payload.
perm_decision() {
  "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get('hookSpecificOutput',{}).get('permissionDecision',''))
except Exception:
    print('')" "$1"
}

# The test harness sentinel + a self-driven LIVE run is the common setup. The
# staleness gate stays ON (a fresh init_run_record stamps last_beat_at=now), so we
# do NOT set NO_STALENESS_CHECK except for the explicit stale scenario.
EVENT() {  # EVENT <session_id> <tool_name> <command>
  "$PY" -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'command':sys.argv[3]}}))" "$1" "$2" "$3"
}

# ════════════════════════════════════════════════════════════════════════════
echo "advisor-gate.test.sh"

# ─── askuser: live self-driven run + MATCHING session_id -> deny ──────────────
it "askuser: live self-driven run + matching session_id -> deny + advisor redirect"
REPO="$(mkrepo askuser-match)"
py_run_record "$REPO" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,"liverun",backend="ce",loop_phase="work",
              steps=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
set_driving_session "$REPO" liverun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "askuser: deny reason redirects to the advisor and names both classification branches"
assert_contains "$out" "advisor"
it "askuser: deny reason names the pause-handoff escalation for design forks"
assert_contains "$out" "auto-resume.py pause"

# ─── askuser FAIL-OPEN: deny-unsupported hatch -> systemMessage, NO deny ──────
# The question gate's asymmetry vs the action backstop (KTD-4 / plan VERIFY (a)):
# with no deny contract it ALLOWS the question through (operator asked directly)
# and surfaces a loud systemMessage — never a pause, never a deny.
it "askuser FAIL-OPEN: matching session + deny-unsupported -> systemMessage (allow, not deny)"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DENY_UNSUPPORTED=1 "$PY" "$ASKUSER_PY" "$REPO")"
assert_contains "$out" "systemMessage"
it "askuser FAIL-OPEN: deny-unsupported emits NO permissionDecision (allow, normal flow)"
assert_empty "$(perm_decision "$out")"

# ─── askuser: live run + MISMATCHED session_id -> allow (KTD-5) ───────────────
it "askuser: live run but MISMATCHED session_id (concurrent standalone) -> allow"
ev="$(EVENT sess-OTHER AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: no driving_session_id recorded -> allow (defensive read) ────────
it "askuser: live run but driving_session_id ABSENT (pre-U5 run_record) -> allow"
REPO="$(mkrepo askuser-nosid)"
py_run_record "$REPO" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,"nosid",backend="ce",loop_phase="work",
              steps=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: no run-record at all -> allow ───────────────────────────────────────
it "askuser: empty dispatch dir (no run) -> allow"
REPO="$(mkrepo askuser-empty)"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: phase==done -> allow ────────────────────────────────────────────
it "askuser: a done run (matching session_id) -> allow (run finished)"
REPO="$(mkrepo askuser-done)"
py_run_record "$REPO" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,"donerun",backend="ce",loop_phase="work",steps=[{"id":"U1","state":"terminal-skip"}])
L.set_loop(repo,"donerun",loop_phase="done")
PYEOF
set_driving_session "$REPO" donerun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: driver==manual (handoff/blocked pause) -> allow ────────────────────
it "askuser: a manual-driver (paused) run -> allow (not a live pulse chain)"
REPO="$(mkrepo askuser-manual)"
py_run_record "$REPO" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,"manualrun",backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"manualrun",driver="manual")
PYEOF
set_driving_session "$REPO" manualrun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: stale driver==self chain (>3900s) -> allow ──────────────────────
it "askuser: a STALE self chain (last_beat_at > DRIVER_SELF_STALE_SECONDS) -> allow (dead chain)"
REPO="$(mkrepo askuser-stale)"
py_run_record "$REPO" <<'PYEOF'
import sys, importlib.util, json, datetime
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,"staleself",backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
old = (datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(seconds=L.DRIVER_SELF_STALE_SECONDS + 120)).strftime("%Y-%m-%dT%H:%M:%SZ")
p = L.run_record_path(repo,"staleself")
with open(p) as f: led = json.load(f)
led["loop"]["last_beat_at"] = old
led["loop"]["driver"] = "self"
led["driving_session_id"] = "sess-AAA"
with open(p,"w") as f: json.dump(led,f)
PYEOF
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: malformed run-record -> allow + exit 0 (rel-001) ────────────────────
it "askuser: malformed run_record -> allow (no crash)"
REPO="$(mkrepo askuser-malformed)"
printf '{ not valid json' > "${REPO}/.claude/auto/broken.json"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"
it "askuser.py: malformed run_record -> exit 0 (rel-001)"
printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO" >/dev/null 2>&1
assert_eq "0" "$?"
it "askuser.sh shim: malformed run_record -> exit 0 (rel-001)"
( cd "$REPO" && printf '%s' "$ev" | bash "$ASKUSER_SH" >/dev/null 2>&1 )
assert_eq "0" "$?"

# ═══════════════════════════════════════════════════════════════════════════
# action hook (destructive backstop)
# ═══════════════════════════════════════════════════════════════════════════

# Build a fresh live owned run for the action scenarios.
mk_live_owned() {  # mk_live_owned <name> <run> <sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,run,backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

# ─── action: the destructive check is off by default ──────────────────────────
for cmd in 'git push --force origin main' 'rm -rf build/' 'gh repo delete owner/repo --yes'; do
  it "action off: '$cmd' on a live owned run -> no deny"
  REPO="$(mk_live_owned "off-$(echo "$cmd" | tr -dc 'a-z')" actrun sess-AAA)"
  out="$(EVENT sess-AAA Bash "$cmd" | "$PY" "$ACTION_PY" "$REPO")"
  assert_empty "$out"
  it "action off: '$cmd' leaves driver==self"
  assert_eq "self" "$(rd_loop "$REPO" actrun driver)"
  it "action off: '$cmd' records no audit row"
  assert_eq "0" "$(rd_audit "$REPO" actrun count)"
done

it "action off: a run the backstop paused before the upgrade allows the command"
REPO="$(mk_live_owned off-prepaused actrun sess-AAA)"
"$PY" - "$REPO" actrun "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.apply_pause(repo, run, "auto destructive-action backstop: blocked `rm -rf`", backstop_latched=True)
PYEOF
out="$(EVENT sess-AAA Bash 'rm -rf build/' | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "action off: that run stays paused"
assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"
it "action off: /auto-resume continue resumes that run"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-AAA" CLAUDE_CODE_CHILD_SESSION="" \
  "$PY" "${AUTO_ROOT}/lib/auto-resume.py" continue actrun >/dev/null 2>&1
assert_eq "self" "$(rd_loop "$REPO" actrun driver)"
it "action off: /auto-resume continue clears that run's latch"
assert_eq "None" "$(rd_loop "$REPO" actrun backstop_latched)"

RESUME_PY="${AUTO_ROOT}/lib/auto-resume.py"

# ════════════════════════════════════════════════════════════════════════════
# resume re-arm re-records the driving session (fix-round-6 P1)
# ════════════════════════════════════════════════════════════════════════════
# THE BUG: a run armed under session A, paused, then resumed from a DIFFERENT
# interactive session B (the common case: after a handoff pause / crash / next-day
# fresh window) USED TO keep the stale arm-time driving_session_id=A. The
# re-armed run is self-driven again, but BOTH advisor gates match on
# driving_session_id == stdin.session_id — so under session B a destructive
# command never matched (A != B) and the action backstop fell through to ALLOW.
# The fix: auto-resume.py::_cmd_continue RE-records the driving session before
# re-arming. These tests drive the REAL auto-resume.py + the REAL action hook.
RESUME_PY="${AUTO_ROOT}/lib/auto-resume.py"

# Read the top-level driving_session_id off a run-record (the field the gates match).
rd_driving() {
  local repo="$1" run="$2"
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$RUN_RECORD_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_run_record('$repo','$run');print(l.get('driving_session_id') or '')"
}

# A blocked-paused run owned by session A (driver=manual + driving_session_id=A),
# mirroring auto-resume.py `pause` then a cross-session `continue`.
mk_paused_owned() {  # mk_paused_owned <name> <run> <sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,run,backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
L.set_loop(repo,run,driver="manual",blocked_on="waiting on a human")
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

# ─── resume under session B re-records the driving session, gate follows ──────
it "resume: continue under a NEW session re-records driving_session_id (A -> B)"
REPO="$(mk_paused_owned resume-rearm rrun sess-AAA)"
# Sanity: armed under A.
assert_eq "sess-AAA" "$(rd_driving "$REPO" rrun)"
it "resume: re-arm flips driving_session_id to the resuming session B"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "sess-BBB" "$(rd_driving "$REPO" rrun)"
it "resume: a question from the RESUMING session B -> deny (the gate now owns it)"
out="$(EVENT sess-BBB AskUserQuestion noop | "$PY" "$ASKUSER_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

# ─── handoff->work branch ALSO re-records (different write path) ─────────────────
# _cmd_continue records the session BEFORE branching, but handoff->work routes
# through pulse.advance_to_phase -> run_record.transition_and_emit (a DIFFERENT write
# path than the blocked-pause set_loop). transition_and_emit does an in-place
# locked RMW (it never reconstructs the dict), so the top-level
# driving_session_id survives the phase advance. This asserts that explicitly so
# a future refactor of the emit path can't silently reintroduce the P1 bug.
it "resume: handoff-paused legacy run resumed under session B re-records the session through the handoff->work path"
REPO="$(mkrepo resume-handoff)"
"$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# Legacy run-record (workflow=None) so advance_to_phase falls through to the raw
# set_loop branch; a handoff pause is the precondition for the handoff->work flip.
L.init_run_record(repo,"handoffrun",backend="ce",loop_phase="handoff",steps=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"handoffrun",driver="manual",handoff_paused=True)
PYEOF
set_driving_session "$REPO" handoffrun "sess-AAA"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue handoffrun >/dev/null 2>&1
assert_eq "sess-BBB" "$(rd_driving "$REPO" handoffrun)"
it "resume: the handoff->work flip still advanced the phase (session re-record did not break the advance)"
assert_eq "work" "$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$RUN_RECORD_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_run_record('$REPO','handoffrun')['loop_phase'])")"

# ─── regression guard: WITHOUT the fix, the stale id would let B through ──────
# The same question from the STALE arm-time session A must NOT match the re-armed
# run (the gate now owns B, not A), so it ALLOWS.
it "resume: a question from the STALE arm-time session A -> allow (no longer owns the run)"
REPO="$(mk_paused_owned resume-staleA rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
out="$(EVENT sess-AAA AskUserQuestion noop | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── refuse to re-arm when the driving session cannot be determined ───────────
# None must NEVER reach set_driving_session_id (None CLEARS the field => both
# gates fail OPEN). With no CLAUDE_CODE_SESSION_ID, _cmd_continue refuses: leaves
# the run paused (driver=manual, driving_session_id UNCHANGED), exits non-zero.
it "resume: refuse to re-arm when CLAUDE_CODE_SESSION_ID is unset -> exit non-zero"
REPO="$(mk_paused_owned resume-norearm rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "1" "$?"
it "resume: refusal leaves the run PAUSED (driver=manual, not flipped to self)"
assert_eq "manual" "$(rd_loop "$REPO" rrun driver)"
it "resume: refusal does NOT clear driving_session_id (no fail-open)"
assert_eq "sess-AAA" "$(rd_driving "$REPO" rrun)"
# v0.6.4: CHILD_SESSION truthy is the NORMAL case (the harness sets it in every
# Bash-tool subprocess, where auto-resume.sh runs). With a real session id present,
# resume must PROCEED and re-record THIS session as the owner — not refuse.
it "resume: CHILD_SESSION set WITH a real id re-arms (exit 0), re-records the new owner"
REPO="$(mk_paused_owned resume-childproceed rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" CLAUDE_CODE_CHILD_SESSION="1" \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "0" "$?"
it "resume: re-arm re-records driving_session_id to the resuming session"
assert_eq "sess-BBB" "$(rd_driving "$REPO" rrun)"

# ─── ownership-steal guard (review #5) ───────────────────────────────────────
# A run that is LIVE (driver=self, fresh beat, not handoff-paused) and owned by
# session AAA must NOT be silently stolen by a `continue`/`advance` from session
# BBB — that would dark the ORIGINAL driver's destructive backstop mid-run.
REPO="$(mkrepo resume-steal)"
"$PY" - "$REPO" stealrun "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,run,backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
L.set_loop(repo,run,driver="self",beat=True)   # LIVE: self-driven + fresh heartbeat
PYEOF
set_driving_session "$REPO" stealrun sess-AAA
it "resume: refuses to steal a LIVE run owned by another session -> exit non-zero"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" CLAUDE_CODE_CHILD_SESSION="1" \
  "$PY" "$RESUME_PY" continue stealrun >/dev/null 2>&1
assert_eq "1" "$?"
it "resume: steal-refusal leaves the original owner (sess-AAA) intact"
assert_eq "sess-AAA" "$(rd_driving "$REPO" stealrun)"
# Same-session re-continue of its OWN live run is idempotent, not a steal -> allowed.
it "resume: the OWNING session continuing its own live run is allowed (not a steal)"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-AAA" CLAUDE_CODE_CHILD_SESSION="1" \
  "$PY" "$RESUME_PY" continue stealrun >/dev/null 2>&1
assert_eq "0" "$?"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "advisor-gate.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
#
# retro_queue_test.sh — tests for hooks/retro-queue.sh, the PreCompact/SessionEnd
# capture hook.
#
# Every assertion is on QUEUE FILE CONTENTS. The hook exits 0 on every path by
# design (R11), so an `rc == 0` assertion passes with the whole body deleted —
# that exact false-green shipped in this plugin before.
#
# Isolation: REFLECT_RETRO_QUEUE overrides the queue path. The operator's live
# $HOME/.claude/.retro-queue is never touched.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/hooks/retro-queue.sh"
BASH_BIN="$(command -v bash)"
JQ_BIN="$(command -v jq 2>/dev/null || echo NONE)"
PASS=0; FAIL=0
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/retro-queue-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Verification contract 6: pin which binary the shell-outs got.
echo "== retro queue hook (bash=$BASH_BIN jq=$JQ_BIN) =="

Q="$ROOT/queue"

# fire <json> — one hook invocation against $Q. stdout/stderr discarded: this
# file never reads them, and never reads the exit code either.
fire() { printf '%s' "$1" | REFLECT_RETRO_QUEUE="$Q" "$BASH_BIN" "$HOOK" >/dev/null 2>&1; }

fields() { awk -F'\t' -v n="$1" 'NR==n{print NF}' "$Q"; }
field()  { awk -F'\t' -v n="$1" -v f="$2" 'NR==n{print $f}' "$Q"; }
lines()  { [ -f "$Q" ] && wc -l < "$Q" | tr -d ' ' || echo 0; }

PRECOMPACT='{"session_id":"sess-abc","transcript_path":"/tmp/t/one.jsonl","hook_event_name":"PreCompact","trigger":"auto","cwd":"/tmp/t"}'
SESSIONEND='{"session_id":"sess-xyz","transcript_path":"/tmp/t/two.jsonl","hook_event_name":"SessionEnd","reason":"clear","cwd":"/tmp/t"}'

# ------------------------------------------------------- a single PreCompact
echo "== one payload, one record =="
rm -f "$Q"; fire "$PRECOMPACT"
check "a PreCompact payload appends exactly one line" '[ "$(lines)" = "1" ]'
check "the line carries the transcript path from the payload" \
  'grep -qF "/tmp/t/one.jsonl" "$Q"'
check "the line has exactly five tab-separated fields" '[ "$(fields 1)" = "5" ]'
check "field 1 is the session id" '[ "$(field 1 1)" = "sess-abc" ]'
check "field 2 is the transcript path" '[ "$(field 1 2)" = "/tmp/t/one.jsonl" ]'
# KTD7: the hook stashes and exits; it never reads a transcript. U3 stamps this
# field at drain time. Empty means "from the first record".
check "field 3 (cursor) is empty — the hook never reads a transcript" \
  '[ "$(fields 1)" = "5" ] && [ -z "$(field 1 3)" ]'
check "field 4 names the PreCompact event and its trigger" \
  '[ "$(field 1 4)" = "PreCompact:auto" ]'
check "field 5 is a UTC timestamp" \
  'printf "%s" "$(field 1 5)" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"'
check "the queue file is created mode 0600" '[ "$(stat -f %Lp "$Q")" = "600" ]'

# ------------------------------------------------------------- the two events
echo "== the two events are distinguishable =="
rm -f "$Q"; fire "$PRECOMPACT"; fire "$SESSIONEND"
check "a second payload appends rather than overwriting" '[ "$(lines)" = "2" ]'
check "the SessionEnd record names its event and reason" \
  '[ "$(field 2 4)" = "SessionEnd:clear" ]'
check "the two records carry different event fields" \
  '[ "$(field 1 4)" != "$(field 2 4)" ]'

# ----------------------------------------------------------- awkward payloads
echo "== awkward payloads =="
rm -f "$Q"
fire '{"session_id":"s1","transcript_path":"/tmp/a dir/with spaces.jsonl","hook_event_name":"PreCompact","trigger":"manual"}'
check "a transcript path containing spaces round-trips intact" \
  '[ "$(field 1 2)" = "/tmp/a dir/with spaces.jsonl" ]'
check "the spaced path still leaves exactly five fields" '[ "$(fields 1)" = "5" ]'

rm -f "$Q"
# A literal tab or newline inside a field would split one record into two, or
# weld two fields into one. Both are read back as corruption by U3, so the hook
# flattens them before the append.
fire '{"session_id":"s2","transcript_path":"/tmp/tab\there/nl\nthere.jsonl","hook_event_name":"SessionEnd","reason":"other"}'
check "an embedded tab or newline cannot split the record" '[ "$(lines)" = "1" ]'
check "the flattened record still has exactly five fields" '[ "$(fields 1)" = "5" ]'

rm -f "$Q"
fire '{"session_id":"s3","transcript_path":"/tmp/back\\slash.jsonl","hook_event_name":"PreCompact","trigger":"auto"}'
check "a backslash in the path is stored literally, not escaped" \
  '[ "$(field 1 2)" = "/tmp/back\\slash.jsonl" ]'

# ------------------------------------------------------------ nothing to stash
echo "== fail-open: the queue is left untouched =="
NOJQ="$ROOT/nojq"; mkdir -p "$NOJQ"
rm -f "$Q"
printf '%s' "$PRECOMPACT" | env -i PATH="$NOJQ" HOME="$ROOT" REFLECT_RETRO_QUEUE="$Q" \
  "$BASH_BIN" "$HOOK" >/dev/null 2>&1
check "with jq absent, no queue file is created" '[ ! -e "$Q" ]'

rm -f "$Q"; fire 'this is not json at all {{{'
check "malformed JSON creates no queue file" '[ ! -e "$Q" ]'

# The same, against an EXISTING queue: "unchanged" must mean byte-identical,
# not merely "still one line".
rm -f "$Q"; fire "$PRECOMPACT"
BEFORE="$(cat "$Q")"
fire 'not json {{{'
printf '%s' "$PRECOMPACT" | env -i PATH="$NOJQ" HOME="$ROOT" REFLECT_RETRO_QUEUE="$Q" \
  "$BASH_BIN" "$HOOK" >/dev/null 2>&1
check "an existing queue is byte-identical after both bad inputs" \
  '[ -s "$Q" ] && [ "$(cat "$Q")" = "$BEFORE" ]'

# Beyond the plan's listed scenarios: a record with no transcript path is
# unusable to the drain, so it is not worth a line. Fail-open means exit 0, not
# always append.
rm -f "$Q"; fire '{"session_id":"s4","hook_event_name":"PreCompact","trigger":"auto"}'
check "a payload with no transcript path is not queued" '[ ! -e "$Q" ]'

rm -f "$Q"; fire ''
check "empty stdin creates no queue file" '[ ! -e "$Q" ]'

# ---------------------------------------------------------------- concurrency
echo "== concurrent appends =="
rm -f "$Q"
fire "$PRECOMPACT" & fire "$SESSIONEND" & wait
check "two concurrent invocations leave exactly two lines" '[ "$(lines)" = "2" ]'
check "neither concurrent line is a fragment" \
  '[ "$(fields 1)" = "5" ] && [ "$(fields 2)" = "5" ]'

# Two racers rarely interleave. A wider burst is what actually exercises the
# single-printf-under-PIPE_BUF guarantee (KTD8) that a prior torn-tail defect in
# this repo broke.
rm -f "$Q"
for i in $(seq 1 16); do
  fire "{\"session_id\":\"s$i\",\"transcript_path\":\"/tmp/t/$i.jsonl\",\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\"}" &
done
wait
check "16 concurrent invocations leave 16 lines" '[ "$(lines)" = "16" ]'
check "every line of the burst has exactly five fields" \
  '[ -s "$Q" ] && [ "$(awk -F"\t" "NF!=5" "$Q" | wc -l | tr -d " ")" = "0" ]'
check "every session id appears exactly once" \
  '[ "$(cut -f1 "$Q" | sort -u | wc -l | tr -d " ")" = "16" ]'

# ------------------------------------------------------------------ hooks.json
echo "== hooks.json wiring =="
HJ="$REPO/.claude/hooks/hooks.json"
check "hooks.json is valid JSON" 'python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$HJ"'
check "hooks.json registers PreCompact and SessionEnd" \
  'python3 -c "import json,sys;h=json.load(open(sys.argv[1]))[\"hooks\"];sys.exit(0 if \"PreCompact\" in h and \"SessionEnd\" in h else 1)" "$HJ"'
# A `type: prompt` hook on a frequent event consumes a turn per firing and, in a
# background subagent, ends the agent permanently.
check "both new events are type: command with a timeout" \
  'python3 -c "
import json,sys
h=json.load(open(sys.argv[1]))[\"hooks\"]
for ev in (\"PreCompact\",\"SessionEnd\"):
    for m in h[ev]:
        assert \"matcher\" not in m or m[\"matcher\"]==\"*\", ev
        for e in m[\"hooks\"]:
            assert e[\"type\"]==\"command\", ev
            assert isinstance(e.get(\"timeout\"), int), ev
            assert \"retro-queue.sh\" in e[\"command\"], ev
" "$HJ"'

echo
echo "retro_queue_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

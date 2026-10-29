#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SWEEP="${AUTO_ROOT}/skills/programme-sweep/SKILL.md"
BEHAVIOURS="${AUTO_ROOT}/skills/programme-sweep/references/behaviours.md"
PACKER="${AUTO_ROOT}/agents/programme-sweep-packager.md"
# SKILL.md is loaded into the PM's context on every activation, so its size is part of the cost. The cap is main's copy.
SIZE_ON_MAIN=39630

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1]" ;; *) pass ;; esac; }

echo "programme-sweep-packager-skill.test.sh"
S="$(cat "$SWEEP")"
W="$(tr -s ' \n' ' ' < "$SWEEP")"
B="$(cat "$BEHAVIOURS")"
A="$(cat "$PACKER")"

it "step 1 runs sweep-inputs last in the chained call and takes its verdict"
has "P sweep-inputs --save; } 2>&1" "$W"
has "The last JSON in that output is the verdict of \`sweep-inputs\`: \`unchanged\` or \`changed\`" "$W"
has "\`home\`, \`unread_claims\` and \`next_offset\`" "$W"
it "a missing start marker or verdict JSON is unknown, never quiet"
has "{ echo SWEEP-START;" "$W"
has "No \`SWEEP-START\` line (the cap cut the head) or no verdict JSON (a verb crashed) means unknown" "$W"
it "the prune step finds the run from the lease"
has "which finds the run from this session's lease" "$W"
it "the re-read acknowledgement is keyed on the verdict, so the fallback path keeps it"
has "If \`why\` has \`rules_reread_requested\`, run \`P rules --ack\`" "$W"
it "the PM reads nothing over 6,000 characters itself, in the skill and in the agent"
has "Read nothing over 6,000 characters yourself" "$W"
has "6,000 characters" "$A"
it "a changed sweep dispatches the packager with home only, and it has no shell"
has "Dispatch \`auto:programme-sweep-packager\` with \`home\`" "$W"
has "It has no shell" "$W"
it "a digest is trusted only when ok, ended, generated like the verdict and listing every unread claim"
has "the file ends \`DIGEST-DONE\`, its \`generated\` matches the verdict's and it lists \`unread_claims\` claims" "$W"
it "an unusable digest falls back to the status and inbox readers and an uncut rules read"
has "dispatch \`auto:programme-status-reader\` and \`auto:programme-inbox-reader\`" "$W"
has "(never cut the rules)" "$W"
it "mark-read takes its offset from the verdict"
has "then \`P mark-read --offset <n>\` with \`next_offset\` from the verdict" "$W"
it "a quiet sweep ends in two PM turns and states every check it covers"
has "**Quiet sweep.**" "$W"
has "That is two PM turns." "$W"
has "the wake carried no watcher line" "$W"
has "a due tracker write, step 15" "$W"
has "a worker whose pane is not working (step 11)" "$W"
has "both wake-ups armed (step 16)" "$W"
has "no refusal, no \`fix:\` line" "$W"
has "no \`pending\` line from \`settle-permissions\`" "$W"
has '"refuted": []' "$W"
it "step 17 re-reads fresh actionable reasons"
has "Run \`P sweep-inputs --reasons\`, a fresh read taken after your actions" "$W"
it "the chained call carries the every-sweep verbs and caps its output"
has "\`P validate\`" "$W"
has "\`P sweep --record-sources\`" "$W"
has "\`P settle-permissions\`" "$W"
has "} 2>&1 | tail -c 6000" "$W"
it "a sub-agent may read the rules but never acknowledge them"
has "\`rules\` without \`--ack\`" "$W"
it "the behaviours rules moved out of the always-loaded skill and still exist"
lacks "Draft the checks from his words" "$S"
has "references/behaviours.md" "$S"
has "Draft the checks from his words" "$B"
has "Once per programme, offer to move tool preferences" "$B"
it "the always-loaded skill is no larger than main's copy"
SIZE="$(wc -c < "$SWEEP" | tr -d ' ')"
if [ "$SIZE" -le "$SIZE_ON_MAIN" ]; then pass; else fail "SKILL.md is ${SIZE} bytes, above ${SIZE_ON_MAIN}"; fi

echo "programme-sweep-packager-skill.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SWEEP="${AUTO_ROOT}/skills/programme-sweep/SKILL.md"
BEHAVIOURS="${AUTO_ROOT}/skills/programme-sweep/references/behaviours.md"
PACKER="${AUTO_ROOT}/agents/programme-sweep-packager.md"
# SKILL.md is loaded into the PM's context on every activation, so its size is part of the cost.
SIZE_BEFORE_PACKAGER=37023

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
B="$(cat "$BEHAVIOURS")"
A="$(cat "$PACKER")"

it "step 1 dispatches the sweep packager with the run and the home folder"
has "auto:programme-sweep-packager" "$S"
has "this programme's \`run\` and \`home\`" "$S"
it "the PM reads nothing over 6,000 characters itself, in the skill and in the agent"
has "Read nothing over 6,000 characters yourself" "$S"
has "6,000 characters" "$A"
it "a digest is trusted only when ok, ended with DIGEST-DONE and generated after the sweep started"
has "the file ends \`DIGEST-DONE\`" "$S"
has "\`generated\` is after this sweep started" "$S"
it "an unknown digest sends the PM to read for itself, still capped"
has "Otherwise it is unknown" "$S"
has "| head -c 6000" "$S"
it "a quiet sweep ends in two PM turns after the chained verbs print nothing new"
has "**Quiet sweep.**" "$S"
has "That is two PM turns." "$S"
has "no refusal, no \`fix:\` line" "$S"
it "the quiet gate also needs validate to report nothing refuted, and the rules are never cut"
has '"refuted": []' "$S"
has "(never cut the rules)" "$S"
it "the chained call carries the every-sweep verbs and caps its output"
has "\`P validate\`" "$S"
has "\`P sweep --record-sources\`" "$S"
has "\`P settle-permissions\`" "$S"
has "2>&1 | tail -c 6000" "$S"
it "a sub-agent may read the rules but never acknowledge them"
has "\`rules\` without \`--ack\`" "$S"
it "the behaviours rules moved out of the always-loaded skill and still exist"
lacks "Draft the checks from his words" "$S"
has "references/behaviours.md" "$S"
has "Draft the checks from his words" "$B"
has "Once per programme, offer to move tool preferences" "$B"
it "the always-loaded skill is no larger than it was before the packager"
SIZE="$(wc -c < "$SWEEP" | tr -d ' ')"
if [ "$SIZE" -le "$SIZE_BEFORE_PACKAGER" ]; then pass; else fail "SKILL.md is ${SIZE} bytes, above ${SIZE_BEFORE_PACKAGER}"; fi

echo "programme-sweep-packager-skill.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SWEEP="${AUTO_ROOT}/skills/programme-sweep/SKILL.md"
JUDGE="${AUTO_ROOT}/skills/programme-sweep/references/judgment.md"
TRACK="${AUTO_ROOT}/skills/programme-tracker/SKILL.md"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1]" ;; *) pass ;; esac; }

echo "programme-sweep-skill.test.sh"
S="$(cat "$SWEEP")"
J="$(cat "$JUDGE")"
T="$(cat "$TRACK")"

it "the sweep has a When to speak rule that ends a quiet sweep with no chat text"
has "## When to speak" "$S"
has "end the sweep with no chat text at all" "$S"
it "an ask is posted once per facts fingerprint and marked shown"
has "P ask-shown <item> --fingerprint <fp>" "$S"
it "the sweep never tells the PM to end with a Next: line"
has 'never end a message with a "Next:" line' "$S"
it "plain words that point to one ask approve nothing and get the exact reply"
has "record nothing and relay nothing" "$S"
it "the PM records before it relays and marks the relay"
has "Record, then relay." "$S"
has "P ask-relayed <item>" "$S"
it "step 16 no longer re-arms the remit watcher every sweep"
lacks "so re-arming is safe" "$S"
has "Do not arm it on" "$S"
it "step 17 runs the stop self-check on actionable reasons"
has "programme.actionable_reasons" "$S"
it "the sub-agent ground rule no longer claims a sub-agent has its own session id"
lacks "a sub-agent has its own session id" "$S"
it "the reporting rules name everything, restate state and carry the contract checklist"
has "**Name everything.**" "$J"
has "**Restate the state.**" "$J"
has "**Show the contract checklist**" "$J"
has "P check-mergeable <pr> --pin <item>" "$J"
it "the tracker voice allows PR and issue numbers with titles and bans herdr codes"
has "Name a PR or issue with its title beside its" "$T"
has "herdr item codes" "$T"

echo "programme-sweep-skill.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

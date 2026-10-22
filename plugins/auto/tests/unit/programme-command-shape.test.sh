#!/usr/bin/env bash
# auto unit test: /auto:programme walks setup one question per step instead of
# printing a setup screen, and keeps the accept a typed reply.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CMD="${AUTO_ROOT}/commands/programme.md"

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

has()    { grep -qF -- "$1" "$CMD"; }
hasnt()  { ! grep -qiF -- "$1" "$CMD"; }

it "no longer prints the setup screen"
if hasnt "Show one screen" && hasnt "output of \`programme.sh rules\`"; then pass; else fail "the setup screen instruction is still there"; fi

it "names the setup verbs the walkthrough runs"
missing=""
for verb in "pick-term" "take-recommendations" "setup-step" "setup-seen" "setup-keep"; do
  has "programme.sh ${verb}" || missing="${missing} ${verb}"
done
if [ -z "$missing" ]; then pass; else fail "missing:${missing}"; fi

it "keeps the accept a typed reply"
if has "Type this: accept the agreement" && has "The accept is never a pick" \
   && has "accept-agreement --prompt <id>"; then pass; else fail "the typed accept is not stated"; fi

it "never tells the PM to pre-fill picker answers"
if has "Never put answers into the AskUserQuestion call yourself"; then pass; else fail "the pre-fill ban is missing"; fi

it "lets the command use the picker"
if grep -qE '^allowed-tools:.*AskUserQuestion' "$CMD"; then pass; else fail "AskUserQuestion is not in allowed-tools"; fi

it "names the pane fallback in the first line"
if has "If the Programme pane is not beside this chat"; then pass; else fail "the /programme-view fallback line is missing"; fi

TAKEOVER="${AUTO_ROOT}/commands/programme-takeover.md"
HANDOVER="${AUTO_ROOT}/commands/programme-handover.md"

it "a takeover before acceptance resumes the setup walkthrough before the sweep"
resume="$(grep -n 'resume \`/auto:programme\` step 5 at the first step not done' "$TAKEOVER" | cut -d: -f1)"
sweep="$(grep -n 'Load the \`auto:programme-sweep\` skill' "$TAKEOVER" | cut -d: -f1)"
if [ -n "$resume" ] && [ -n "$sweep" ] && [ "$resume" -lt "$sweep" ] && grep -qF 'has a `setup` part' "$TAKEOVER"; then
  pass; else fail "no setup resume step before the sweep in programme-takeover.md"; fi

it "a takeover resumes setup before it re-arms the cron fallback"
cron="$(grep -n 'CronCreate the cadence fallback' "$TAKEOVER" | cut -d: -f1)"
if [ -n "$resume" ] && [ -n "$cron" ] && [ "$resume" -lt "$cron" ]; then
  pass; else fail "the setup resume step comes after the cron step in programme-takeover.md"; fi

it "lets the takeover use the picker"
if grep -qE '^allowed-tools:.*AskUserQuestion' "$TAKEOVER"; then pass; else fail "AskUserQuestion is not in takeover allowed-tools"; fi

it "a handover before acceptance tells the new session to resume setup"
if grep -qF 'resume `/auto:programme` step 5 at the first step not done' "$HANDOVER"; then
  pass; else fail "no setup resume line in programme-handover.md"; fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

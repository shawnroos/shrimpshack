#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
holds() { if grep -Fq -- "$2" "$1"; then pass; else fail "expected [$2] in $1"; fi; }
absent() { if grep -Fq -- "$2" "$1"; then fail "did not expect [$2] in $1"; else pass; fi; }

echo "programme-ritual-skill.test.sh"

SWEEP="${AUTO_ROOT}/skills/programme-sweep/SKILL.md"
REF="${AUTO_ROOT}/skills/programme-sweep/references/rituals.md"
SKILL="${AUTO_ROOT}/skills/programme-ritual/SKILL.md"
PACKAGER="${AUTO_ROOT}/agents/programme-sweep-packager.md"
COMMAND="${AUTO_ROOT}/commands/programme-ritual.md"

it "the files under test exist (anti-vacuity)"
missing=""
for f in "$SWEEP" "$REF" "$SKILL" "$PACKAGER" "$COMMAND"; do [ -f "$f" ] || missing="${missing} ${f}"; done
if [ -z "$missing" ]; then pass; else fail "missing:${missing}"; fi

it "the sweep has a step 5c that points at the rituals reference"
holds "$SWEEP" "5c. **Rituals.**"
it "step 5c sends the PM to the rituals reference"
holds "$SWEEP" "[references/rituals.md](references/rituals.md)"
it "the quiet-sweep rule counts rituals due"
holds "$SWEEP" "behaviours due, rituals due,"
it "the packager digests a Rituals section from the rituals key"
holds "$PACKAGER" "## Rituals"
holds "$PACKAGER" "source: rituals"

it "the reference offers all missed rituals in one picker and records the offer first"
holds "$REF" "P offer-rituals <id>..."
holds "$REF" "in one AskUserQuestion picker"
it "the reference makes run now, skip and retire each a typed per-ritual call"
holds "$REF" "P skip-ritual <id> --prompt <id>"
holds "$REF" "P retire-ritual <id> --as retired --prompt <id>"
it "the reference says never to run a missed ritual silently late"
holds "$REF" "Never run it silently late."
it "the reference names --without-rituals for a PM that is about to lose its session"
holds "$REF" "--without-rituals"

it "the authoring skill stores a ritual only on Shawn's typed answer naming the id"
holds "$SKILL" "His answer must name the ritual id."
holds "$SKILL" "record-ritual --from-proposal"
it "the authoring skill refuses protected escalations and keeps item changes as behaviours"
holds "$SKILL" "is refused, so tell him that and leave the step out"
holds "$SKILL" "is a Behaviour, not a ritual"
it "the authoring skill does not store a proposal Shawn has not answered"
holds "$SKILL" "Never store a proposal he has not answered."
it "the command loads the skill"
holds "$COMMAND" "auto:programme-ritual"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

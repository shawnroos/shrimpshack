#!/usr/bin/env bash
# auto unit test: /auto:programme-resume restarts a programme without routing around
# auto's own checks or carrying one repo's rules into every programme.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
CMD="${AUTO_ROOT}/commands/programme-resume.md"

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

has()   { grep -qF -- "$1" "$CMD"; }
hasnt() { ! grep -qiF -- "$1" "$CMD"; }

echo "programme-resume-command.test.sh"

it "a lease held by another session routes through become-pm"
if has 'run `P become-pm` and follow its one' && hasnt '--replace <that session id>'; then
  pass; else fail "the resume step does not route a held lease through become-pm"; fi

it "a refused prompt-item is reported, never sent another way"
if hasnt 'herdr agent prompt' && has 'send it another way'; then
  pass; else fail "the brief still has a fallback around prompt-item"; fi

it "a missing worktree is recreated only as a checkout"
if hasnt 'mkdir' && has 'git worktree add <path>'; then pass; else fail "the worktree step can create a bare folder"; fi

it "the command carries no one repo's rules or launch flags"
bad=""
for word in "--model" "HUSKY" "develop into" "AI Editor" "agent-browser"; do
  hasnt "$word" || bad="${bad} [${word}]"
done
if [ -z "$bad" ]; then pass; else fail "found:${bad}"; fi

it "the inventory skips every finished item state"
MISSING="$("$PY" - "$AUTO_ROOT" "$CMD" <<'PYEOF'
import os, re, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
states = load_lib_module("programme_home").FINISHED_ITEM_STATES
line = next((l for l in open(sys.argv[2]) if "effective_state" in l and "not in" in l), "")
print(" ".join(s for s in states if f'"{s}"' not in line) or ("no filter line" if not line else ""))
PYEOF
)"
if [ -z "$MISSING" ]; then pass; else fail "not skipped: ${MISSING}"; fi

it "every programme.sh verb the command names is a real verb"
VERBS="$(grep -oE '`P [a-z][a-z-]*' "$CMD" | sed 's/`P //' | sort -u)"
BAD=""
for v in $VERBS; do
  ERR="$(bash "${AUTO_ROOT}/lib/programme.sh" "$v" 2>&1)"
  case "$ERR" in *"unknown subcommand"*) BAD="$BAD $v" ;; esac
done
if [ -n "$VERBS" ] && [ -z "$BAD" ]; then pass; else fail "verbs: [$(echo $VERBS)] unknown: [$BAD]"; fi

echo ""
echo "programme-resume-command.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

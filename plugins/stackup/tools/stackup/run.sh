#!/usr/bin/env bash
# stackup — asks whether work should ship as a stack of dependent PRs.
#
# The mode is passed as argv, never read from the payload, so a renamed field
# upstream cannot silently route a hook to the wrong branch.
#   run.sh plan   PostToolUse(Write|Edit|MultiEdit) — a plan file just landed
#   run.sh pr     PreToolUse(Bash)                  — a PR is about to open
#
# Input is JSON on STDIN. `$TOOL_INPUT` does NOT exist for "type": "command"
# hooks (only for "type": "prompt"), and a matcher written against it greps an
# empty string and never fires.
#
# Every path exits 0: this never blocks a tool call. That also means an exit
# code proves nothing about whether the ask fired — assert on stdout instead.
set -uo pipefail

MODE="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${STACKUP_AUDIT:-}"

TMPIN="$(mktemp)" || exit 0
trap 'rm -f "$TMPIN"' EXIT
cat > "$TMPIN"
[ -s "$TMPIN" ] || exit 0

# Piping the payload through a variable mangles backslashes; read from the file.
_field() { jq -r "$1 // empty" < "$TMPIN" 2>/dev/null; }

_emit() {
  local event="$1" text="$2"
  jq -nc --arg e "$event" --arg c "$text" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}' 2>/dev/null || exit 0
  exit 0
}

# Suppression is the only outcome that can fail silently, so it is the only one
# the audit switch overrides.
_suppress() {
  if [ -n "$AUDIT" ]; then
    _emit "$1" "stackup audit: would have stayed silent here — $2"
  fi
  exit 0
}

ASK_PLAN='This plan has more than one implementation unit, and records no pull-request strategy yet. Decide now, while the dependency graph is fresh: do these units land as a stack of dependent pull requests, or as one pull request? Both answers are fine — "one pull request, because this is one logical change" is correct whenever the work does not decompose into independently reviewable steps. Record the decision in the plan, naming the layers in dependency order or the reason it is one. `gh stack` is available for the stacked case; ce-commit-push-pr already knows how to submit one.'

ASK_PR='This branch is about to become a single pull request. Before it does: does this change decompose into dependent, independently reviewable steps that would be easier to review as a stack? If it does, `gh stack` can build one and ce-commit-push-pr can submit it. If it does not, say so and carry on — one pull request for one logical change is the right answer and this is only a question.'

case "$MODE" in
  plan)
    EVENT="PostToolUse"
    path="$(_field '.tool_input.file_path')"
    [ -n "$path" ] || exit 0
    case "$path" in
      */plans/*.md) ;;
      *) exit 0 ;;
    esac
    # Unreadable or uncountable is uncertain, and uncertain fires.
    if [ ! -r "$path" ]; then _emit "$EVENT" "$ASK_PLAN"; fi
    # grep -c prints a count AND exits 1 on zero matches, so `|| echo 0` would
    # append a second line and make every integer test below fail.
    units="$(grep -c '^### U' "$path" 2>/dev/null || true)"; units="${units:-0}"
    if [ "$units" -eq 1 ]; then _suppress "$EVENT" "single-unit plan"; fi
    if [ "$units" -ge 2 ] || [ "$units" -eq 0 ]; then
      if grep -qiE 'landing strategy|pull-request strategy|pr strategy|pr & landing|stack of' "$path" 2>/dev/null; then
        _suppress "$EVENT" "plan already records a pull-request strategy"
      fi
      _emit "$EVENT" "$ASK_PLAN"
    fi
    exit 0
    ;;
  pr)
    EVENT="PreToolUse"
    cmd="$(_field '.tool_input.command')"
    [ -n "$cmd" ] || exit 0
    # Cheap string match first. No git or gh subprocess may run until this
    # passes: this hook runs before every shell command.
    printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+pr[[:space:]]+create' || exit 0
    printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+stack' && exit 0
    if git rev-parse --git-dir >/dev/null 2>&1; then
      base="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo origin/main)"
      changed="$(git diff --name-only "$base"...HEAD 2>/dev/null | wc -l | tr -d '[:space:]')"; changed="${changed:-0}"
      # Only a confident "too small" suppresses; a failed diff reads as 0 and falls through.
      if [ "$changed" -eq 1 ]; then _suppress "$EVENT" "single-file change"; fi
    fi
    if [ "$("$HERE/capability.sh" status 2>/dev/null)" = "unavailable" ]; then
      _suppress "$EVENT" "stacked pull requests unavailable for this repository"
    fi
    _emit "$EVENT" "$ASK_PR"
    ;;
  *) exit 0 ;;
esac
exit 0

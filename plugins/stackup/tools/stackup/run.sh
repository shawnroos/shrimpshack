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
case "$MODE" in plan) EVENT="PostToolUse" ;; pr) EVENT="PreToolUse" ;; *) exit 0 ;; esac

# Without jq nothing can be parsed and both hooks go quiet for good. That is the
# whole-plugin death mode, so it must be visible to the one switch built to see
# silence — hence this sits above every other bail.
if ! command -v jq >/dev/null 2>&1; then
  [ -n "$AUDIT" ] && printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"stackup audit: jq is not on PATH, so stackup cannot read hook payloads and will never ask."}}\n' "$EVENT"
  exit 0
fi

# Reads stdin directly: this runs before every shell command, so a temp file
# would cost a fork and a disk write on each one. Stdin is consumed by the first
# read, so each branch below reads exactly one field, once.
_field() { jq -r "$1 // empty" 2>/dev/null; }

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

# origin/HEAD is unset on plenty of clones, so a hardcoded origin/main names a
# ref that does not exist on a master-default repo: the diff fails, the count
# reads 0, and the single-file suppression silently never fires. Verify each
# candidate. Ported from plugins/lint-router/tools/lint-router/run.sh.
_base() {
  local b c
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return; }
  for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return; }
  done
  printf 'HEAD'
}

ASK_PLAN='This plan looks like it has several implementation units and records no pull-request strategy yet. Decide now, while the dependency graph is fresh: do these units land as a stack of dependent pull requests, or as one pull request? Both answers are fine — "one pull request, because this is one logical change" is correct whenever the work does not decompose into independently reviewable steps. Record the decision in the plan under a heading containing the words "PR & landing strategy", naming the layers in dependency order or the reason it is one — that heading is what stops this question being asked again. `gh stack` is available for the stacked case; ce-commit-push-pr already knows how to submit one.'

ASK_PR='This branch is becoming a single pull request. Does the change decompose into dependent, independently reviewable steps that would be easier to review as a stack? This hook does not stop the command, so if the pull request has already opened, `gh stack` can still restack the work. If it does not decompose, say so and carry on — one pull request for one logical change is the right answer and this is only a question.'

case "$MODE" in
  plan)
    path="$(_field '.tool_input.file_path')"
    [ -n "$path" ] || exit 0
    case "$path" in
      */plans/*.md|*/plans/*.html) ;;
      *) exit 0 ;;
    esac
    # Unreadable or uncountable is uncertain, and uncertain fires.
    if [ ! -r "$path" ]; then _emit "$EVENT" "$ASK_PLAN"; fi
    # grep -c prints a count AND exits 1 on zero matches, so `|| echo 0` would
    # append a second line and make every integer test below fail.
    # HTML plans carry the same unit IDs inside heading markup.
    units="$(grep -ciE '(^### U|<h3[^>]*>[[:space:]]*U)[0-9]+[.:) ]' "$path" 2>/dev/null || true)"; units="${units:-0}"
    if [ "$units" -eq 1 ]; then _suppress "$EVENT" "single-unit plan"; fi
    if [ "$units" -ge 2 ] || [ "$units" -eq 0 ]; then
      if grep -qiE 'landing strategy|pull-request strategy|pr strategy|pr & landing' "$path" 2>/dev/null; then
        _suppress "$EVENT" "plan already records a pull-request strategy"
      fi
      _emit "$EVENT" "$ASK_PLAN"
    fi
    exit 0
    ;;
  pr)
    cmd="$(_field '.tool_input.command')"
    [ -n "$cmd" ] || exit 0
    # Cheap string match first. No git or gh subprocess may run until this
    # passes: this hook runs before every shell command.
    # Builtin match, no fork: this is the hottest line in the file. [[:space:]]
    # covers newlines, so a multi-line command still matches.
    [[ "$cmd" =~ gh[[:space:]]+pr[[:space:]]+create ]] || exit 0
    [[ "$cmd" =~ gh[[:space:]]+stack ]] && exit 0
    if git rev-parse --git-dir >/dev/null 2>&1; then
      changed="$(git diff --name-only "$(_base)"...HEAD 2>/dev/null | wc -l | tr -d '[:space:]')"; changed="${changed:-0}"
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

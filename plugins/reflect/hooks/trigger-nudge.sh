#!/usr/bin/env bash
# trigger-nudge.sh — PostToolUse(Bash) hook. If the command an agent just ran
# matches a trigger a memory DECLARED, emit a one-or-two-line pointer nudge.
#
# Fires on every Bash call (~453 in the motivating session), so the cheap bails
# come first and in this order:
#   1. no compiled manifest      -> exit 0 before anything is spawned
#   2. no jq                     -> exit 0 (extraction is jq's only job here)
#   3. empty command             -> exit 0
#   4. prefilter says no match  -> exit 0 WITHOUT starting python
# python3 is spawned only once all four pass.
#
# Step 4 is the expensive one avoided. Measured here: the hook costs ~89ms per Bash
# call, of which ~45ms is `import triggers`; a `grep -Ef` over the compiled patterns
# is ~9ms. Most commands match nothing — replaying 480 real Bash calls from one
# session, ~80% matched no trigger — so the common case pays grep, not an
# interpreter.
#
# The prefilter is a SUPERSET of the real matcher (word boundaries stripped), so it
# can only say "maybe" too often, never "no" wrongly. A MISSING prefilter also
# means "maybe": the hook falls through to python and behaves exactly as before.
# That keeps this a pure optimization and never a source of silent misses.
#
# Input is JSON on STDIN — `$TOOL_INPUT` does NOT exist for `"type": "command"`
# hooks (it is real only for `"type": "prompt"` hooks), and a matcher written
# against it greps an empty string and never fires. Stdin is saved to a temp file
# and read twice rather than held in a shell variable: `echo "$json" | jq` mangles
# backslashes, and a Bash command is exactly the payload full of them.
#
# Output is the JSON `hookSpecificOutput` shape, NOT seeded-recall.sh's raw-stdout
# idiom: raw stdout is an injection channel for `UserPromptSubmit` only, while
# PostToolUse stdout goes to the transcript rather than to the model.
# `additionalContext` is confirmed real for PostToolUse on the running build.
# The JSON is assembled in python and passed through untouched — building it in
# shell would mean escaping arbitrary memory text into a JSON string by hand.
#
# Fail-open ALWAYS: every path exits 0. A nudge that cannot be produced is a
# non-event; a hook that returns non-zero is a broken session.
#
#   env: MEMORY_DIR                 override the store (tests)
#        MEMORY_TRIGGER_FLAG_DIR    override the per-session dedupe flag dir
#        MEMORY_TRIGGER_PREFILTER_AUDIT=1
#                                   do not trust the grep prefilter's "no" — fall
#                                   through to python anyway and report any command
#                                   it rejected that the matcher actually matches.
#                                   Costs the full ~89ms on every call, so it is for
#                                   checking the mechanism is honest, not for daily
#                                   use. A disagreement prints to stderr and lands in
#                                   RECALL.log as `prefilter-disagreement`.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ -n "${MEMORY_DIR:-}" ]; then
  STORE="$MEMORY_DIR"
else
  SLUG="-${HOME#/}"
  SLUG="${SLUG//\//-}"
  STORE="$HOME/.claude/projects/$SLUG/memory"
fi

# 1. No manifest -> nothing can match. This is also the fail-open answer for a
#    store that has never compiled one.
[ -f "$STORE/TRIGGERS.json" ] || exit 0

# 2. jq is the extractor. Absent -> exit 0 (same posture as the sibling matcher).
command -v jq >/dev/null 2>&1 || exit 0

TMPIN="$(mktemp -t trigger-nudge 2>/dev/null)" || exit 0
trap 'rm -f "$TMPIN"' EXIT
cat > "$TMPIN" 2>/dev/null || exit 0

CMD="$(jq -r '.tool_input.command // empty' < "$TMPIN" 2>/dev/null)" || exit 0

# 3. Nothing to match against.
[ -n "$CMD" ] || exit 0

# 4. Cheap reject. Only skip when the prefilter EXISTS and definitively says no —
# a missing file falls through, because "could not ask" must never become "no".
PREFILTER="$STORE/TRIGGERS.prefilter"
if [ -s "$PREFILTER" ]; then
  # Multi-line commands go through the prefilter too, and safely: `write_prefilter`
  # refuses to emit a file containing any pattern that could match ACROSS a newline
  # (`\s`, a bare `\n`, Python-only classes). With those excluded, matching each
  # line is equivalent to `re.search` over the whole command, so line-oriented grep
  # is not a narrowing. This matters more than it looks — 457 of 480 recorded Bash
  # calls were multi-line, so skipping them would have left the optimization
  # covering 5% of real traffic.
  #
  # -i is REQUIRED: the matcher compiles with re.I, and a case-sensitive prefilter
  # lost exactly 2 nudges across those 480 commands.
  # A NON-ASCII command is never judged by grep. Case folding is symmetric, and the
  # compile-side gate only checks the PATTERN's bytes — which leaves the command side
  # open. Python's matcher folds Unicode (`re.I`, no `re.ASCII`), so the plain ASCII
  # pattern `pip install` matches the command `pıp install` (U+0131 dotless i, the
  # classic Turkish-keyboard typo); K U+212A and ſ U+017F fold onto k and s the same
  # way. No grep folds any of them, under any locale, so grep says no, the matcher
  # says yes, and the nudge is lost silently. Non-ASCII commands are rare, so falling
  # through costs almost nothing.
  #
  # LC_ALL=C pins the fold on everything else. Without it, `grep -i` folds per the
  # ambient locale, and a Turkish/az locale folds I to ı — narrowing the prefilter on
  # glibc in the other direction. macOS libc happens not to implement that fold, so
  # this is the class of bug that passes here and breaks on a Linux user's box.
  #
  # KNOWINGLY UNTESTED: removing this pin does not fail the suite, because no locale
  # on this machine reproduces the divergence. Proving it needs a glibc box with
  # tr_TR.UTF-8 installed. Everything else in this block IS pinned by a test; this one
  # line rests on the argument above, so do not "simplify" it away.
  case "$CMD" in
    *[![:ascii:]]*)
      RC=0 ;;
    *)
      printf '%s' "$CMD" | LC_ALL=C grep -qiEf "$PREFILTER" 2>/dev/null
      RC=$? ;;
  esac
  # Captured on the very next line on purpose: the reasoning below is long, and
  # although comments do not clobber `$?`, any command someone later inserts between
  # the pipeline and the test would silently retarget it.
  #
  # ONLY exit 1 means "no match". Exit 2 is an unparseable pattern file and 127 is
  # no grep at all; reading either as "nothing matched" would let ONE bad pattern
  # silently suppress every nudge in the store. Verified: /usr/bin/grep exits 2 on a
  # Python-valid lookahead that ugrep accepts, so which grep resolves would decide
  # whether the mechanism went quiet. Anything but a clean "no" falls through.
  if [ "$RC" -eq 1 ]; then
    # A wrong reject here is the one failure this mechanism cannot show you: no
    # error, no log line, no nudge, and RECALL.log is written by python — which a
    # reject means we never start. Three such bugs have shipped. So there is a way
    # to ASK: with the audit flag set, a reject falls through to python anyway,
    # marked, and python records any disagreement. Off by default and deterministic
    # (a flag, not a sampling probability), so the fast path is unchanged unless you
    # deliberately turn it on to check the mechanism is honest.
    if [ "${MEMORY_TRIGGER_PREFILTER_AUDIT:-}" = "1" ]; then
      AUDIT="--prefilter-rejected"
    else
      exit 0
    fi
  fi
fi

# Extracted AFTER the reject, not with the command above: this is a second `jq`
# process (~6ms of a ~40ms fast path) charged to every Bash call, and only the python
# invocation below reads it. The temp file is still alive — the trap fires at EXIT.
SESSION="$(jq -r '.session_id // empty' < "$TMPIN" 2>/dev/null)" || true

# `printf '%s'` does not interpret escapes in its ARGUMENT, so a command full of
# backslashes reaches python byte-for-byte.
printf '%s' "$CMD" | python3 "$PLUGIN_ROOT/scripts/scoped-memory/triggers.py" \
  match --store "$STORE" --session "${SESSION:-}" --cwd "$PWD" ${AUDIT:-} 2>/dev/null || true

exit 0

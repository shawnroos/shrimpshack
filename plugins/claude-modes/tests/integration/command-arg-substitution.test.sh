#!/usr/bin/env bash
# $ARGUMENTS-uniqueness lint (Batch-4 Finding 9 — mechanical enforcement of the
# slash-command arg-substitution invariant).
#
# WHY: the Claude Code harness substitutes EVERY occurrence of `$ARGUMENTS` in a
# slash-command .md body before the bash runs (see memory
# feedback_slash_command_arg_substitution + feedback_slash_command_nl_routing_pattern).
# So a SECOND `$ARGUMENTS` — even a documentary mention in prose — gets the user's
# raw argument string spliced in too, corrupting the rendered command or, worse,
# injecting the argument into an unintended position. The invariant: a command
# .md has AT MOST ONE line containing `$ARGUMENTS`, and that line IS the dispatch
# line. This test makes a second occurrence a red build instead of a round-N find.
#
# (Batch-4 Finding 7 removed a prose `$ARGUMENTS` from mode-add.md; this test
# guards the whole commands/ dir so the next one is caught automatically.)
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# Count the number of LINES in a file that contain the literal `$ARGUMENTS`.
# (Line-count, not occurrence-count: the invariant is "<=1 line", and the
# dispatch line is exactly one line — see the convention in the memory.)
__count_arguments_lines() {
  # grep -c prints the count AND exits non-zero on zero matches; capture the
  # number and normalize so a no-match yields exactly "0" (not "0\n0" from a
  # `|| echo 0` fallback firing alongside grep's own "0").
  local n
  n="$(grep -c '\$ARGUMENTS' "$1" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# Scan every commands/*.md; collect any with >1 line containing $ARGUMENTS.
violations=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  n="$(__count_arguments_lines "$f")"
  if [ "$n" -gt 1 ]; then
    rel="${f#"${PLUGIN_ROOT}/"}"
    violations="${violations}${rel}: ${n} lines contain \$ARGUMENTS (must be <=1, and it must be the dispatch line)"$'\n'
  fi
done < <(find "${PLUGIN_ROOT}/commands" -maxdepth 1 -name '*.md' 2>/dev/null | sort)

claude_modes_test::it "every commands/*.md has at most ONE line containing \$ARGUMENTS (the dispatch line)"
if [ -z "$violations" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "command(s) with multiple \$ARGUMENTS occurrences (the harness substitutes EVERY one):"$'\n'"${violations}"
fi

# ─── Deliberate-fail self-test (NON-NEGOTIABLE) ───────────────────────────────
# Prove the detector actually flags a 2-occurrence file (a vacuous-green guard:
# if __count_arguments_lines / the >1 check broke, the green path above would
# pass while testing nothing).
__df_dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-argsub.XXXXXX")"
__df_bad="${__df_dir}/bad.md"
printf 'prose mentions $ARGUMENTS here\n`bash lib/x.sh "$ARGUMENTS"`\n' > "$__df_bad"
__df_bad_n="$(__count_arguments_lines "$__df_bad")"
claude_modes_test::it "deliberate-fail: detector flags a 2-occurrence command (.md)"
if [ "$__df_bad_n" -gt 1 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "detector did NOT count >1 \$ARGUMENTS line in a planted 2-occurrence file (vacuous-green risk)"
fi
__df_ok="${__df_dir}/ok.md"
printf 'no mention in prose\n`bash lib/x.sh "$ARGUMENTS"`\n' > "$__df_ok"
__df_ok_n="$(__count_arguments_lines "$__df_ok")"
claude_modes_test::it "deliberate-fail control: detector does NOT flag a single-occurrence command"
if [ "$__df_ok_n" -le 1 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "detector false-positived on a single-\$ARGUMENTS file (count=${__df_ok_n})"
fi
rm -rf "$__df_dir"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]

#!/usr/bin/env bash
# Integration test: R13 no-destructive-rm lint.
#
# R13: the plugin NEVER unconditionally deletes or truncates files in
# the user's catalog (~/.claude/commands/ or ~/.claude/agents/). Those
# files belong to the user (or to other plugins via the symlink
# mechanism in U8/U11), and a single bad rm would silently delete user
# work. Uninstall and the symlink-rebuild path use safer mechanisms
# (mv-with-staging, content-aware reconciliation, append-only adoption).
#
# This test converts R13 from "architectural discipline" to "the
# codebase cannot violate the invariant without this test failing."
#
# Heuristic: grep lib/*.sh, scripts/*.sh, AND lib/*.py for destructive
# operations targeting ~/.claude/(commands|agents)/ — both bash and
# Python shapes. NEW for V2: Python destructive verbs (os.remove,
# os.unlink, shutil.rmtree, pathlib unlink).
#
# Comment-line exclusion: lines whose first non-whitespace is `#` are
# stripped before scanning, so error-message strings and documentation
# comments that quote the literal path don't trip the lint.
# Triple-quoted Python docstrings/strings are also stripped (a
# pragmatic single-quote-style tracker — not a real Python parser).
#
# Why the scope is (commands|agents) only: the plugin DOES own
# ~/.claude/modes/ entirely, so `rm` against that subtree is the
# legitimate uninstall path. The lint must let those through.
#
# Acceptable false-positive rate: very low — this is a correctness
# invariant. If a lib script genuinely needs to reference the path
# pattern in a non-destructive context (a string literal, an error
# message), prefer building the path via variables so it doesn't match
# these patterns.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/helpers/test-helpers.sh"

CLAUDE_MODES_TEST_PASS_COUNT=0
CLAUDE_MODES_TEST_FAIL_COUNT=0

# ──────────────────────────────────────────────────────────────────────────
# Pattern definitions.

bash_patterns=(
  '\brm[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md'
  '\bunlink[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/'
  '\bfind[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents).*-delete'
  '>[[:space:]]*["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md'
  ':[[:space:]]*>[[:space:]]*["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/'
  '\btruncate[[:space:]]+-s[[:space:]]+0[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/'
  '\bcp[[:space:]]+/dev/null[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/'
  '\btee[[:space:]]+["'"'"']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md["'"'"']?[[:space:]]+<[[:space:]]*/dev/null'
  '\bsed[[:space:]]+-i[[:space:]]+.*\$\{?HOME\}?/\.claude/(commands|agents)/'
)

py_patterns=(
  'os\.remove[[:space:]]*\([[:space:]]*.*\.claude/(commands|agents)/'
  'os\.unlink[[:space:]]*\([[:space:]]*.*\.claude/(commands|agents)/'
  'shutil\.rmtree[[:space:]]*\([[:space:]]*.*\.claude/(commands|agents)'
  'pathlib\.Path[[:space:]]*\([[:space:]]*.*\.claude/(commands|agents)/.*\)\.unlink\(\)'
)

# ──────────────────────────────────────────────────────────────────────────
# Comment / docstring stripper.
#
# For .sh files: drop lines whose first non-whitespace is `#`.
# For .py files: drop lines whose first non-whitespace is `#`, AND drop
# lines inside triple-quoted blocks (""" or '''). This is a single-
# tracker stripper — it handles the common module-docstring + comment
# shapes used in our codebase. It's not a real Python parser, but the
# alternative (importing ast) would couple the lint to Python being
# installed at lint time, which we want to avoid.

__strip_for_scan() {
  local src="$1"
  local ext="${src##*.}"
  if [ "$ext" = "sh" ]; then
    grep -vE '^[[:space:]]*#' "$src" 2>/dev/null
  else
    # .py — strip comments + triple-quoted blocks via Python. Python is
    # used here (not awk) because the strippers need to track triple-
    # quote state across lines, and quoting an awk script that contains
    # both """ and ''' inside a bash single-quoted heredoc is a hazard.
    "$CLAUDE_MODES_PYTHON3" - "$src" <<'PYEOF' 2>/dev/null
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# Strip triple-quoted blocks (both """...""" and '''...''') across lines.
# Non-greedy match; DOTALL so newlines inside the block are consumed.
src = re.sub(r'"""(.*?)"""', '', src, flags=re.DOTALL)
src = re.sub(r"'''(.*?)'''", '', src, flags=re.DOTALL)
# Strip lines whose first non-whitespace character is '#'.
out_lines = []
for line in src.splitlines():
    if re.match(r'^\s*#', line):
        continue
    out_lines.append(line)
print('\n'.join(out_lines))
PYEOF
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Scanner — returns 0 on clean, prints violations to stdout.

__scan_file() {
  local f="$1"
  local rel="${f#$ROOT/}"
  local ext="${f##*.}"
  local patterns_var
  local -a patterns_use

  case "$ext" in
    sh) patterns_use=("${bash_patterns[@]}") ;;
    py) patterns_use=("${py_patterns[@]}") ;;
    *)  return 0 ;;
  esac

  local stripped
  stripped=$(__strip_for_scan "$f")
  if [ -z "$stripped" ]; then
    return 0
  fi

  local found=0
  for pat in "${patterns_use[@]}"; do
    local hits
    hits=$(printf '%s\n' "$stripped" | grep -En "$pat" 2>/dev/null || true)
    if [ -n "$hits" ]; then
      printf 'FILE: %s\nPATTERN: %s\nMATCHES:\n%s\n\n' "$rel" "$pat" "$hits"
      found=$((found + 1))
    fi
  done
  return $found
}

# ──────────────────────────────────────────────────────────────────────────
# Test 1: live source — scripts/*.sh, lib/*.sh, lib/*.py — MUST be clean.

claude_modes_test::it "R13 lint: live source (scripts/*.sh, lib/*.sh, lib/*.py) is clean"

live_violations=""
live_files=()
while IFS= read -r -d '' f; do
  live_files+=("$f")
done < <(find "$ROOT/lib" "$ROOT/scripts" \
  \( -name "*.sh" -o -name "*.py" \) -type f -print0 2>/dev/null)

live_violations_count=0
for f in "${live_files[@]}"; do
  out=$(__scan_file "$f")
  if [ -n "$out" ]; then
    live_violations="${live_violations}${out}"
    live_violations_count=$((live_violations_count + 1))
  fi
done

if [ "$live_violations_count" -eq 0 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "R13 violations found in live source:
${live_violations}"
fi

# Informational: file count scanned.
claude_modes_test::it "R13 lint: scanned ${#live_files[@]} live source file(s)"
claude_modes_test::pass

# ──────────────────────────────────────────────────────────────────────────
# Test 2: positive fixtures — every file MUST trip the lint.

claude_modes_test::it "R13 lint: every positive fixture matches at least one pattern"

pos_files=()
while IFS= read -r -d '' f; do
  pos_files+=("$f")
done < <(find "$ROOT/tests/fixtures/r13-positive" \
  \( -name "*.sh" -o -name "*.py" \) -type f -print0 2>/dev/null)

if [ "${#pos_files[@]}" -eq 0 ]; then
  claude_modes_test::fail "no r13-positive fixtures found — the lint is untested"
else
  pos_misses=""
  pos_miss_count=0
  for f in "${pos_files[@]}"; do
    rel="${f#$ROOT/}"
    out=$(__scan_file "$f")
    if [ -z "$out" ]; then
      pos_misses="${pos_misses}  ${rel}\n"
      pos_miss_count=$((pos_miss_count + 1))
    fi
  done
  if [ "$pos_miss_count" -eq 0 ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "${pos_miss_count} positive fixture(s) NOT caught by the lint (false negative):
$(printf '%b' "$pos_misses")"
  fi
fi

claude_modes_test::it "R13 lint: scanned ${#pos_files[@]} positive fixture(s)"
claude_modes_test::pass

# ──────────────────────────────────────────────────────────────────────────
# Test 3: negative fixtures — NO file may trip the lint.

claude_modes_test::it "R13 lint: no negative fixture trips the lint (false-positive guard)"

neg_files=()
while IFS= read -r -d '' f; do
  neg_files+=("$f")
done < <(find "$ROOT/tests/fixtures/r13-negative" \
  \( -name "*.sh" -o -name "*.py" \) -type f -print0 2>/dev/null)

if [ "${#neg_files[@]}" -eq 0 ]; then
  claude_modes_test::fail "no r13-negative fixtures found — false-positive risk uncovered"
else
  neg_hits=""
  neg_hit_count=0
  for f in "${neg_files[@]}"; do
    rel="${f#$ROOT/}"
    out=$(__scan_file "$f")
    if [ -n "$out" ]; then
      neg_hits="${neg_hits}
${out}"
      neg_hit_count=$((neg_hit_count + 1))
    fi
  done
  if [ "$neg_hit_count" -eq 0 ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "${neg_hit_count} negative fixture(s) WERE flagged by the lint (false positive):
${neg_hits}"
  fi
fi

claude_modes_test::it "R13 lint: scanned ${#neg_files[@]} negative fixture(s)"
claude_modes_test::pass

# ──────────────────────────────────────────────────────────────────────────
# Final summary line.

echo ""
echo "no-destructive-rm.test.sh: $CLAUDE_MODES_TEST_PASS_COUNT passed, $CLAUDE_MODES_TEST_FAIL_COUNT failed"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ] && exit 0 || exit 1

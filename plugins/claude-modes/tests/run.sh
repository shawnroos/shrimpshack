#!/usr/bin/env bash
# claude-modes test runner.
#
# Usage:
#   bash tests/run.sh [unit|integration|smoke|perf|all] [--verbose]
#
# Subcommands:
#   unit        — run all tests/unit/*.test.sh
#   integration — run all tests/integration/*.test.sh (excludes perf.test.sh)
#   perf        — run tests/integration/perf.test.sh (slow; records baseline)
#   smoke       — print location of smoke checklist and exit 0
#   all         — run unit + integration (default; does NOT include perf)
#
# Options:
#   --verbose   — also print individual test output (not just summary lines)
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more test failures, or $HOME isolation violated
#
# $HOME isolation verification:
#   The runner hashes a set of real-$HOME paths before and after the suite.
#   A mismatch means a test escaped isolation. The suite fails loudly on
#   mismatch regardless of individual test outcomes.
#
#   Scope (V2 — extended from V1's single-path check):
#     ~/.claude/modes/                  (V1; plugin's own state tree)
#     ~/.claude/commands/               (V2; user catalog R19)
#     ~/.claude/agents/                 (V2; user catalog R19)
#     ~/.claude/settings.json           (V2; R19 — plugin must never write)
#     ~/.claude/settings.json.pristine  (V2; forensic anchor — R24)
#
#   Each path is hashed independently. Absent paths hash to "ABSENT" (not
#   an error — most users won't have a settings.json.pristine on a clean
#   checkout). On mismatch, the runner names WHICH path changed so the
#   leak is diagnosable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ──────────────────────────────────────────────────────────────────────────
# Arg parsing.

SUBCOMMAND="all"
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    unit|integration|perf|smoke|all) SUBCOMMAND="$arg" ;;
    --verbose) VERBOSE=1 ;;
    *)
      echo "run.sh: unknown argument '${arg}'" >&2
      echo "Usage: bash tests/run.sh [unit|integration|smoke|perf|all] [--verbose]" >&2
      exit 1
      ;;
  esac
done

# ──────────────────────────────────────────────────────────────────────────
# $HOME isolation verification helpers.

# Hash the contents of a path (file OR directory).
# Returns a stable hash, or "ABSENT" if the path doesn't exist.
# Compatible with macOS (shasum, not sha256sum).
#
# Files: hash the file contents directly.
# Directories: list every regular file, sort deterministically, hash
# each, then hash the combined output.
# Errors during hashing on individual files are tolerated (a 2>/dev/null
# on the xargs) — the goal is to detect changes, not to perfect a
# checksum. If a test creates and then deletes a file mid-suite, the
# hash before/after still match (because nothing new persists).
_hash_path() {
  local path="$1"
  if [ ! -e "$path" ]; then
    printf 'ABSENT'
    return
  fi
  if [ -f "$path" ]; then
    shasum "$path" 2>/dev/null | awk '{print $1}'
    return
  fi
  if [ -d "$path" ]; then
    find "$path" -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 shasum 2>/dev/null \
      | shasum \
      | awk '{print $1}'
    return
  fi
  # Symlinks or special files — hash the readlink target path itself.
  # Rare enough that the simple shape is fine.
  ls -la "$path" 2>/dev/null | shasum | awk '{print $1}'
}

# Back-compat alias — V1 callers used this name; keep working in case
# anyone outside this file calls it.
_hash_modes_dir() {
  _hash_path "$1"
}

# Paths we hash before+after the suite to detect isolation leaks.
# Order matters only for stable diagnostic output.
ISOLATION_PATHS=(
  "${HOME}/.claude/modes"
  "${HOME}/.claude/commands"
  "${HOME}/.claude/agents"
  "${HOME}/.claude/settings.json"
  "${HOME}/.claude/settings.json.pristine"
)

# ──────────────────────────────────────────────────────────────────────────
# Summary tracking.

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_FILES=0
FAILED_FILES=""

# ──────────────────────────────────────────────────────────────────────────
# Run a single test file, capturing results.
# Updates TOTAL_PASS, TOTAL_FAIL, TOTAL_FILES.

_run_test_file() {
  local test_file="$1"
  local rel="${test_file#$ROOT/}"
  TOTAL_FILES=$((TOTAL_FILES + 1))

  local tmpout
  tmpout=$(mktemp -t claude-modes-run.XXXXXX)
  trap 'rm -f "$tmpout"' RETURN

  # Run the test, capturing combined stdout+stderr.
  bash "$test_file" >"$tmpout" 2>&1
  local rc=$?

  # Extract summary line (last non-empty line matching "<name>: N passed, M failed"
  # or "<name> results: N passed, M failed" — different test files use different formats).
  local summary_line=""
  summary_line=$(grep -E '^[^[:space:]]+\.test\.sh(:| results:) [0-9]+ passed, [0-9]+ failed' "$tmpout" | tail -1 || true)

  # Parse pass/fail counts from summary line.
  local file_pass=0 file_fail=0
  if [ -n "$summary_line" ]; then
    file_pass=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
    file_fail=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)
  fi

  # If rc is non-zero but we didn't get a summary line, count as 1 failure.
  if [ "$rc" -ne 0 ] && [ -z "$summary_line" ]; then
    file_fail=1
  fi

  TOTAL_PASS=$((TOTAL_PASS + file_pass))
  TOTAL_FAIL=$((TOTAL_FAIL + file_fail))

  # Print per-file summary.
  local status_icon
  if [ "$file_fail" -eq 0 ] && [ "$rc" -eq 0 ]; then
    status_icon="✓"
  else
    status_icon="✗"
    FAILED_FILES="${FAILED_FILES}  ${rel}"$'\n'
  fi

  printf "  %s  %-60s  (pass=%d fail=%d)\n" \
    "$status_icon" "$rel" "$file_pass" "$file_fail"

  # --verbose: print full test output.
  if [ "$VERBOSE" -eq 1 ]; then
    sed 's/^/    /' "$tmpout"
    echo ""
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Smoke subcommand: just print where the checklist lives.

if [ "$SUBCOMMAND" = "smoke" ]; then
  echo ""
  echo "Smoke checklist: $SCRIPT_DIR/SMOKE_CHECKLIST.md"
  echo ""
  echo "Open the checklist and work through it before merging."
  echo "Automated tests cannot cover live harness integration."
  echo ""
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# Perf subcommand: just run perf.test.sh.

if [ "$SUBCOMMAND" = "perf" ]; then
  echo ""
  echo "=== PERF (tests/integration/perf.test.sh) ==="
  echo ""
  bash "$ROOT/tests/integration/perf.test.sh"
  exit $?
fi

# ──────────────────────────────────────────────────────────────────────────
# Collect test files based on subcommand.

unit_files=()
integration_files=()

while IFS= read -r -d '' f; do
  unit_files+=("$f")
done < <(find "$ROOT/tests/unit" -name "*.test.sh" -type f -print0 2>/dev/null | sort -z)

while IFS= read -r -d '' f; do
  # Exclude perf.test.sh from default integration run (it's slow and records
  # a baseline; invoke explicitly with 'bash tests/run.sh perf').
  case "$f" in
    */perf.test.sh) continue ;;
  esac
  integration_files+=("$f")
done < <(find "$ROOT/tests/integration" -name "*.test.sh" -type f -print0 2>/dev/null | sort -z)

# ──────────────────────────────────────────────────────────────────────────
# $HOME isolation: record hashes before tests.

# V2: hash a SET of paths, not just ~/.claude/modes/. Each path gets
# its own hash so a mismatch can name WHICH path leaked.
declare -a HASHES_BEFORE
for p in "${ISOLATION_PATHS[@]}"; do
  HASHES_BEFORE+=("$(_hash_path "$p")")
done

# Back-compat alias for the single-path V1 variable name (still
# referenced by the legacy message text below before we rewrite it).
REAL_MODES_DIR="${HOME}/.claude/modes"

# ──────────────────────────────────────────────────────────────────────────
# Run selected tests.

echo ""
echo "claude-modes test suite"
echo "========================"

if [ "$SUBCOMMAND" = "unit" ] || [ "$SUBCOMMAND" = "all" ]; then
  echo ""
  echo "=== UNIT (${#unit_files[@]} files) ==="
  for f in "${unit_files[@]}"; do
    _run_test_file "$f"
  done
fi

if [ "$SUBCOMMAND" = "integration" ] || [ "$SUBCOMMAND" = "all" ]; then
  echo ""
  echo "=== INTEGRATION (${#integration_files[@]} files) ==="
  for f in "${integration_files[@]}"; do
    _run_test_file "$f"
  done
fi

# ──────────────────────────────────────────────────────────────────────────
# $HOME isolation: verify hashes after tests.

declare -a HASHES_AFTER
for p in "${ISOLATION_PATHS[@]}"; do
  HASHES_AFTER+=("$(_hash_path "$p")")
done

HOME_ISOLATION_OK=1
LEAKED_PATHS=""
for i in "${!ISOLATION_PATHS[@]}"; do
  if [ "${HASHES_BEFORE[$i]}" != "${HASHES_AFTER[$i]}" ]; then
    HOME_ISOLATION_OK=0
    LEAKED_PATHS+="  ${ISOLATION_PATHS[$i]}"$'\n'
    LEAKED_PATHS+="    before: ${HASHES_BEFORE[$i]}"$'\n'
    LEAKED_PATHS+="    after:  ${HASHES_AFTER[$i]}"$'\n'
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# Total summary.

echo ""
echo "========================"
echo "TOTAL: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed  (${TOTAL_FILES} files)"

if [ "$HOME_ISOLATION_OK" -eq 0 ]; then
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "HOME ISOLATION VIOLATION DETECTED"
  echo "One or more of the user's real \$HOME paths changed during"
  echo "the test suite. A test escaped \$HOME isolation. This is a"
  echo "P0 failure — fix the leak before merging."
  echo ""
  echo "Leaked path(s):"
  printf '%s' "$LEAKED_PATHS"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

if [ -n "$FAILED_FILES" ]; then
  echo ""
  echo "Failed test files:"
  printf '%s' "$FAILED_FILES"
fi

if [ "$TOTAL_FAIL" -gt 0 ] || [ "$HOME_ISOLATION_OK" -eq 0 ]; then
  exit 1
fi

exit 0

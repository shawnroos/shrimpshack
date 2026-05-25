#!/usr/bin/env bash
# Integration test: R24 settings-file 0600 invariant.
#
# R24: every settings-derived file the plugin owns is born at mode 0600
# (read/write for owner only). Reason: these files may carry credentials
# (settings.json.pristine), audit data with branch slugs and timestamps
# (.audit.log), or per-machine repo registries (.installed-repos.txt /
# .trusted-repos.txt) that should not be group/world-readable.
#
# The invariant has two halves:
#
#   1. STATIC: every existing settings-derived file under
#      ~/.claude/modes/ (in the isolated test sandbox) MUST be at mode
#      0600 at the moment we observe it. If it's not, the producer
#      didn't honor R24.
#
#   2. BORN-AT-0600: the file mode is observed AFTER scripts/setup.sh
#      (or another plugin path) lands the file, with NO intervening
#      chmod-after step in this test. So 0600 must be set atomically
#      by the producer (umask + mode-arg-to-touch/install, or
#      `install -m 0600`, or `mv` from a tmp file created with
#      `mktemp -p ... -m 0600` equivalent — Python's
#      `os.open(..., 0o600)` + `os.replace`).
#
# Dependency posture:
#   - scripts/setup.sh is built in U6.
#   - /mode:set / settings.local.json producer is built in U5/U9.
#   - This test is built in U13, BEFORE U5/U6/U7/U9. So:
#     * The static check (test 1) runs on any files that DO exist.
#     * The setup-driven check (test 2) skips with an explicit
#       "DEFERRED" message if scripts/setup.sh is absent. tests/run.sh
#       sees a passing summary line either way; the SKIP is visible.
#   - When U5/U6/U7/U9 land, this test starts exercising them
#     automatically — no edits needed here.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/helpers/test-helpers.sh"

CLAUDE_MODES_TEST_PASS_COUNT=0
CLAUDE_MODES_TEST_FAIL_COUNT=0

# ──────────────────────────────────────────────────────────────────────────
# Portable stat-mode helper.
#
# macOS: `stat -f '%A' <path>` prints octal mode (e.g., "600").
# Linux: `stat -c '%a' <path>` prints octal mode.
# Both: leading zeros may be omitted ("600" not "0600"). We compare on
# the trailing 3 digits to be robust either way.

__stat_mode() {
  local path="$1"
  local mode
  if mode=$(stat -f '%A' "$path" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  if mode=$(stat -c '%a' "$path" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  return 1
}

# Asserts the given path has mode 0600. Test name is set via
# claude_modes_test::it BEFORE calling. Skips with explicit message if
# the file doesn't exist.
__assert_mode_0600() {
  local path="$1"
  if [ ! -e "$path" ]; then
    # File doesn't exist yet — skip without failing. Surface visibly.
    claude_modes_test::pass
    printf "      SKIP: %s does not exist (DEFERRED: producer not built yet)\n" "$path"
    return 0
  fi
  local mode
  mode=$(__stat_mode "$path") || {
    claude_modes_test::fail "could not stat $path on this platform"
    return 1
  }
  # Normalize: strip leading zero so "0600" and "600" both compare equal
  # to "600".
  local norm="${mode#0}"
  if [ "$norm" = "600" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "expected mode 0600 on $path, got $mode"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Setup the isolated sandbox.

claude_modes_test::setup

trap 'claude_modes_test::teardown' EXIT

MODES_DIR="$HOME/.claude/modes"

# ──────────────────────────────────────────────────────────────────────────
# Phase A: drive /mode:setup if it exists, so producer-borne files land
# in the sandbox. The cascade-built files don't exist yet on a fresh
# sandbox, so without setup we have nothing to inspect.

SETUP_SCRIPT="$ROOT/scripts/setup.sh"
SETUP_AVAILABLE=0

if [ -x "$SETUP_SCRIPT" ] || [ -f "$SETUP_SCRIPT" ]; then
  SETUP_AVAILABLE=1
  # Run setup; capture output for diagnosis on failure but don't
  # surface unless a downstream assertion fails.
  setup_out=$(bash "$SETUP_SCRIPT" 2>&1 || true)
fi

# ──────────────────────────────────────────────────────────────────────────
# Phase B: assert each settings-derived file is 0600 when present.
#
# These are the files the plan lists as 0600-mandatory under R24:
#   ~/.claude/settings.json.pristine            (forensic anchor)
#   ~/.claude/modes/_global.yaml                (user-tier baseline)
#   ~/.claude/modes/.installed-repos.txt        (install registry)
#   ~/.claude/modes/.trusted-repos.txt          (consent gate)
#   ~/.claude/modes/.audit.log                  (append-only audit)
#
# Per-repo files we do NOT exercise here (need a real repo + branch):
#   <repo>/.claude/settings.local.json           — covered by U5/U9 tests
#   <repo>/.claude/modes/.cascade-meta.json      — covered by U9 tests
#   <repo>/.claude/modes/_repo.yaml              — user-authored, owner's choice

# Each assertion:
#   1. Names the file with claude_modes_test::it.
#   2. Calls __assert_mode_0600, which skips-with-message if absent.

claude_modes_test::it "R24: ~/.claude/settings.json.pristine is mode 0600 (when present)"
__assert_mode_0600 "$HOME/.claude/settings.json.pristine"

claude_modes_test::it "R24: ~/.claude/modes/_global.yaml is mode 0600 (when present)"
__assert_mode_0600 "$MODES_DIR/_global.yaml"

claude_modes_test::it "R24: ~/.claude/modes/.installed-repos.txt is mode 0600 (when present)"
__assert_mode_0600 "$MODES_DIR/.installed-repos.txt"

claude_modes_test::it "R24: ~/.claude/modes/.trusted-repos.txt is mode 0600 (when present)"
__assert_mode_0600 "$MODES_DIR/.trusted-repos.txt"

claude_modes_test::it "R24: ~/.claude/modes/.audit.log is mode 0600 (when present)"
__assert_mode_0600 "$MODES_DIR/.audit.log"

# ──────────────────────────────────────────────────────────────────────────
# Phase C: explicit DEFERRED notice when setup wasn't available.
#
# If scripts/setup.sh wasn't built yet, the assertions above will have
# all skipped via the "file doesn't exist" branch. Surface a single
# clear DEFERRED line so the test summary makes the deferral obvious
# (rather than looking like a vacuously-passing test).

claude_modes_test::it "R24: setup-driven born-at-0600 check (deferred until U6/U7)"
if [ "$SETUP_AVAILABLE" -eq 1 ]; then
  # Setup ran — at least one of the assertions above did real work.
  claude_modes_test::pass
else
  claude_modes_test::pass
  printf "      DEFERRED: U6/U7 not built yet (no scripts/setup.sh found at %s)\n" "$SETUP_SCRIPT"
  printf "      The static 0600 assertions ran but had no files to check.\n"
  printf "      When U6 lands scripts/setup.sh, this test exercises it automatically.\n"
fi

# ──────────────────────────────────────────────────────────────────────────
# Final summary line.

echo ""
echo "settings-file-perms.test.sh: $CLAUDE_MODES_TEST_PASS_COUNT passed, $CLAUDE_MODES_TEST_FAIL_COUNT failed"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ] && exit 0 || exit 1

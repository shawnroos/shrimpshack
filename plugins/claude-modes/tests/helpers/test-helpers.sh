#!/usr/bin/env bash
# claude-modes: shared test helpers and the $HOME isolation contract.
#
# # $HOME ISOLATION CONTRACT (P0 — read before writing tests)
#
# Every test that touches claude-modes state MUST isolate $HOME before
# running any plugin code. Without isolation, tests would read/write the
# real ~/.claude/modes/, clobbering authored modes or leaking test state.
#
# Pattern:
#   . tests/helpers/test-helpers.sh
#   claude_modes_test::setup     # exports HOME to a fresh tempdir
#   # ... run plugin code ...
#   claude_modes_test::teardown  # restores HOME and cleans tempdir
#
# Verification: tests/run.sh records a hash of $HOME_ORIGINAL/.claude/modes/
# before and after the suite. A mismatch means a test escaped isolation —
# the suite fails loudly.

# ──────────────────────────────────────────────────────────────────────────
# Canonical Python executable.
#
# WHY: on macOS the user's PATH often resolves `python3` to a Homebrew
# install (e.g., /opt/homebrew/bin/python3) that does NOT ship with the
# `yaml` module. /usr/bin/python3 (Apple-provided) ships with PyYAML by
# default. Pinning to /usr/bin/python3 makes the plugin robust on macOS
# regardless of which Python the user has prepended to PATH.
#
# Plugin code that needs Python with yaml MUST use this var, not bare
# `python3`. Tests assert this convention too (see tests/unit/mode-yaml).
CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
export CLAUDE_MODES_PYTHON3

# ──────────────────────────────────────────────────────────────────────────
# Setup / teardown — isolate $HOME and $TMPDIR.

claude_modes_test::setup() {
  # Remember the real HOME so the runner can verify nothing leaked.
  : "${CLAUDE_MODES_TEST_HOME_ORIGINAL:=$HOME}"
  export CLAUDE_MODES_TEST_HOME_ORIGINAL

  # ──────────────────────────────────────────────────────────────────────
  # WHY we leak PYTHONPATH to the original user's site-packages:
  #
  # On macOS, /usr/bin/python3 (Apple-shipped) finds the `yaml` module
  # via the user's site-packages directory, which is rooted in $HOME:
  #
  #   /Users/<user>/Library/Python/<X.Y>/lib/python/site-packages/yaml
  #
  # When we override $HOME for test isolation, that path no longer
  # resolves — Apple python3 then cannot import yaml, and EVERY mode-yaml
  # call fails inside tests.
  #
  # Two options:
  #   (a) ship our own yaml parser (heavy)
  #   (b) leak PYTHONPATH for yaml only, preserving $HOME isolation
  #       for everything else
  #
  # We chose (b). The leak is one env var; $HOME isolation for actual
  # plugin state (~/.claude/modes/*.yaml, registry.json, .audit.log)
  # remains intact. Tests verify HOME isolation via the
  # CLAUDE_MODES_TEST_HOME_ORIGINAL hash-check at runner level.
  if [ -z "${CLAUDE_MODES_TEST_PYTHONPATH_SAVED:-}" ]; then
    CLAUDE_MODES_TEST_PYTHONPATH_SAVED="${PYTHONPATH:-}"
    export CLAUDE_MODES_TEST_PYTHONPATH_SAVED
    # Resolve the original-HOME site-packages dir for the pinned python.
    # We do this once (cached for the suite) to avoid spawning python on
    # every setup() call.
    if [ -z "${CLAUDE_MODES_TEST_USER_SITE:-}" ]; then
      CLAUDE_MODES_TEST_USER_SITE=$(
        HOME="$CLAUDE_MODES_TEST_HOME_ORIGINAL" \
          "$CLAUDE_MODES_PYTHON3" -c "import site; print(site.getusersitepackages())" 2>/dev/null
      )
      export CLAUDE_MODES_TEST_USER_SITE
    fi
  fi
  if [ -n "${CLAUDE_MODES_TEST_USER_SITE:-}" ]; then
    export PYTHONPATH="${CLAUDE_MODES_TEST_USER_SITE}${CLAUDE_MODES_TEST_PYTHONPATH_SAVED:+:${CLAUDE_MODES_TEST_PYTHONPATH_SAVED}}"
  fi

  # Fresh per-test sandbox.
  CLAUDE_MODES_TEST_SANDBOX=$(mktemp -d -t claude-modes-test.XXXXXX)
  export CLAUDE_MODES_TEST_SANDBOX

  export HOME="$CLAUDE_MODES_TEST_SANDBOX"

  # Seed empty ~/.claude/modes/ inside the sandbox so plugin scripts that
  # short-circuit on its absence don't accidentally pass for the wrong
  # reason in tests that DO want plugin behavior to run.
  mkdir -m 0700 -p "$HOME/.claude/modes"
}

claude_modes_test::teardown() {
  if [ -n "${CLAUDE_MODES_TEST_SANDBOX:-}" ] && [ -d "${CLAUDE_MODES_TEST_SANDBOX}" ]; then
    # Defensive: only delete things under our sandbox.
    case "$CLAUDE_MODES_TEST_SANDBOX" in
      */claude-modes-test.*) rm -rf "$CLAUDE_MODES_TEST_SANDBOX" ;;
      *) echo "test-helpers: refusing to rm '$CLAUDE_MODES_TEST_SANDBOX' (unexpected path)" >&2 ;;
    esac
  fi
  unset CLAUDE_MODES_TEST_SANDBOX
  export HOME="$CLAUDE_MODES_TEST_HOME_ORIGINAL"
}

# ──────────────────────────────────────────────────────────────────────────
# Assertion helpers — minimal, no framework dependency.
#
# All assertions print PASS/FAIL with the test name, and on FAIL emit a
# diagnostic and increment CLAUDE_MODES_TEST_FAIL_COUNT.

: "${CLAUDE_MODES_TEST_PASS_COUNT:=0}"
: "${CLAUDE_MODES_TEST_FAIL_COUNT:=0}"
: "${CLAUDE_MODES_TEST_CURRENT:=anonymous}"
export CLAUDE_MODES_TEST_PASS_COUNT CLAUDE_MODES_TEST_FAIL_COUNT CLAUDE_MODES_TEST_CURRENT

claude_modes_test::it() {
  CLAUDE_MODES_TEST_CURRENT="${1:-anonymous}"
}

claude_modes_test::pass() {
  CLAUDE_MODES_TEST_PASS_COUNT=$((CLAUDE_MODES_TEST_PASS_COUNT + 1))
  printf "  \033[32m✓\033[0m %s\n" "${CLAUDE_MODES_TEST_CURRENT}"
}

claude_modes_test::fail() {
  CLAUDE_MODES_TEST_FAIL_COUNT=$((CLAUDE_MODES_TEST_FAIL_COUNT + 1))
  printf "  \033[31m✗\033[0m %s\n" "${CLAUDE_MODES_TEST_CURRENT}"
  if [ -n "${1:-}" ]; then
    printf "      %s\n" "$1"
  fi
}

claude_modes_test::assert_eq() {
  local expected="$1"
  local actual="$2"
  if [ "$expected" = "$actual" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "expected: '${expected}'  actual: '${actual}'"
  fi
}

claude_modes_test::assert_ne() {
  local notexpected="$1"
  local actual="$2"
  if [ "$notexpected" != "$actual" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "should NOT equal: '${notexpected}'"
  fi
}

claude_modes_test::assert_true() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "command should have succeeded: $cmd"
  fi
}

claude_modes_test::assert_false() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    claude_modes_test::fail "command should have failed: $cmd"
  else
    claude_modes_test::pass
  fi
}

claude_modes_test::assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) claude_modes_test::pass ;;
    *) claude_modes_test::fail "expected substring '${needle}' in: '${haystack}'" ;;
  esac
}

claude_modes_test::assert_file_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "expected file to exist: $path"
  fi
}

claude_modes_test::assert_file_absent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "expected file/dir NOT to exist: $path"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Path resolution helpers.

# Returns the absolute path to the plugin root (parent of tests/).
claude_modes_test::plugin_root() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

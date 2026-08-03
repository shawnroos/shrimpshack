#!/usr/bin/env bash
#
# cli-drift.test.sh — fail when spinoff.sh invokes a backend CLI subcommand or flag
# that the INSTALLED CLI does not expose.
#
# Why this exists: spinoff 0.8.3 called `herdr agent send` (removed) and
# `herdr agent wait --status` (renamed to --until). Both were wrapped in
# `>/dev/null 2>&1`, so both failed silently while every run reported success. The
# existing suites could never catch it — their stubs accept any verb, so the tests
# were green *because* they were validating the script against a fake CLI rather
# than the real one.
#
# So this check deliberately does NOT use a stub. It reads the script statically,
# extracts the calls it makes, and compares them against the installed CLI's own
# --help output.
#
# A backend that isn't installed is reported SKIPPED, never passed. A skip that
# reads as a pass is how a drift check silently stops protecting anything.
#
# Usage: bash cli-drift.test.sh   [SPINOFF_UNDER_TEST=/path/to/spinoff.sh]

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SPINOFF="${SPINOFF_UNDER_TEST:-$HERE/spinoff.sh}"
[ -f "$SPINOFF" ] || { echo "✗ script not found: $SPINOFF" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  — SKIPPED (not a pass): $*"; SKIP=$((SKIP+1)); }

echo "backend CLI drift check ($(basename "$SPINOFF")):"

# ---- extract the calls the script makes --------------------------------------
# Lines invoking the backend through its resolved binary variable, e.g.
#   "$HERDR" pane run "$pane" ...
#   "$CMUX" new-surface --type terminal ...
# Captures the subcommand words (up to two) plus any long flags on that line.
extract_calls() {                     # $1 = binary var name (HERDR|CMUX)
  grep -oE "\"\\\$$1\" [a-z][a-z-]*( [a-z][a-z-]*)?" "$SPINOFF" \
    | sed -E "s/\"\\\$$1\" //" | sort -u
}
# Flags belonging to the BACKEND call only. Quoted segments are stripped first,
# because a call like `pane run "$view" "bat --paging=always ..."` carries the inner
# command's flags too — counting those produced false failures, which is worse than
# missing a bug: a noisy drift check gets ignored.
extract_flags() {                     # $1 = binary var, $2 = subcommand (space-separated)
  grep -E "\"\\\$$1\" $2( |\$)" "$SPINOFF" \
    | sed -E 's/"[^"]*"/ /g' \
    | grep -oE '(^| )--[a-z][a-z-]*' | tr -d ' ' | sort -u
}

# ---- check one backend -------------------------------------------------------
# Verifies each subcommand appears in the CLI's help, then each long flag appears
# in that subcommand's own help.
check_backend() {                     # $1 = label, $2 = binary var, $3 = binary path
  local label="$1" var="$2" bin="$3"
  if [ -z "$bin" ] || ! command -v "$bin" >/dev/null 2>&1; then
    skip "$label is not installed — its calls in $(basename "$SPINOFF") are UNVERIFIED"
    return
  fi

  local calls sub top_help
  calls="$(extract_calls "$var")"
  if [ -z "$calls" ]; then
    bad "$label: found no calls to check — the extractor is broken, not the script"
    return
  fi

  # Group-level help lists the top-level subcommands.
  top_help="$("$bin" --help 2>&1)"

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    local group verb sub_help
    group="${sub%% *}"; verb="${sub#* }"

    # Is the group itself real?
    if ! printf '%s\n' "$top_help" | grep -qE "(^|[[:space:]])${group}([[:space:]]|$)"; then
      bad "$label: '$group' is not a subcommand of $label"
      continue
    fi

    # Single-word call (no verb) — group presence is all we can check.
    if [ "$group" = "$verb" ]; then
      ok "$label: '$group' exists"
      continue
    fi

    sub_help="$("$bin" "$group" --help 2>&1)"
    if ! printf '%s\n' "$sub_help" | grep -qE "(^|[[:space:]])${verb}([[:space:]]|$)"; then
      bad "$label: '$group $verb' — '$verb' is not a subcommand of '$group'"
      continue
    fi
    ok "$label: '$group $verb' exists"

    # Every long flag the script passes to this subcommand must exist too.
    local verb_help flag
    verb_help="$("$bin" "$group" "$verb" --help 2>&1)"
    for flag in $(extract_flags "$var" "$group $verb"); do
      if printf '%s\n' "$verb_help" | grep -qE -- "(^|[[:space:]])${flag}([[:space:]=,]|$)"; then
        ok "$label: '$group $verb $flag' exists"
      else
        bad "$label: '$group $verb' does not accept '$flag'"
      fi
    done
  done <<< "$calls"
}

HERDR_BIN="$(command -v herdr 2>/dev/null)"
CMUX_BIN="$(command -v cmux 2>/dev/null)"
[ -n "$CMUX_BIN" ] || { [ -x /Applications/cmux.app/Contents/Resources/bin/cmux ] && CMUX_BIN=/Applications/cmux.app/Contents/Resources/bin/cmux; }

check_backend herdr HERDR "${HERDR_BIN:-}"
check_backend cmux  CMUX  "${CMUX_BIN:-}"

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
[ "$SKIP" -gt 0 ] && echo "  NOTE: a skipped backend is UNVERIFIED, not passing."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

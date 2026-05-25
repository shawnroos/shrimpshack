#!/usr/bin/env bash
# claude-modes (0.3.0 / U5): /mode:drop orchestrator.
#
# Removes a plugin or skill from the ACTIVE mode's tier-3 YAML, in-flow. The
# drop semantics differ from add (a plugin drop is a cascade-SUBTRACTION into
# disable.enabledPlugins; a skill drop removes the basename from
# user_catalog.agents) but the ORCHESTRATION — resolve active mode, resolve
# candidate(s), drift-check, apply, reload, the exit-code language, and the
# locking discipline — is IDENTICAL to /mode:add. To keep the critical-section
# logic in exactly one place (DRY; one place to audit for the drift + R22 +
# lock invariants), this file is a thin entry point that delegates to the shared
# orchestrator in lib/mode-add.sh via the DROP verb.
#
# ─── PUBLIC CLI CONTRACT (identical exit-code language to /mode:add) ──────────
#
#   bash lib/mode-drop.sh <query-or-fqn> [<expected-snapshot>]
#
#   0   — dropped (one candidate / FQN). Includes the idempotent already-dropped
#         case: apply_delta signals a no-op with exit 11, the orchestrator maps
#         it to exit 0 (a no-op is success) but SKIPS the reload prompt and
#         emits a no_change audit instead of "Mode updated". The YAML is
#         unchanged in that case.
#   1   — orchestrator failure: no active mode, zero candidates, drift, R22
#         refusal (e.g. dropping claude-modes itself), or writer failure.
#   2   — usage error (missing arg).
#   10  — AMBIGUOUS: N>1 candidates. Same stdout shape as /mode:add (__SNAPSHOT__
#         line + TSV rows). The caller disambiguates and re-invokes with the
#         chosen FQN + snapshot.
#
# R22 NOTE: dropping claude-modes (the plugin itself) is REFUSED by apply_delta's
# R22 pre-check (and the cascade-engine backstop). The user sees the R22 message
# on stderr; no write, no reload. This is the headline drop-specific guard.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the shared orchestrator (defines claude_modes::mode_drop + the locked
# critical section). mode-add.sh is the single home for the edit machinery.
. "${SCRIPT_DIR}/mode-add.sh"

# ──────────────────────────────────────────────────────────────────────
# CLI entry point.
#   bash lib/mode-drop.sh <query-or-fqn> [<expected-snapshot>]
#
# NOTE: sourcing mode-add.sh above does NOT run its CLI block — that block is
# guarded by `[ "${BASH_SOURCE[0]}" = "${0}" ]`, which is false while sourced.
# So this file owns the runnable entry for /mode:drop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    "")
      echo "mode-drop: usage: $0 <query-or-fqn> [<expected-snapshot>]" >&2
      exit 2
      ;;
    --*)
      echo "mode-drop: unknown flag '${1}'" >&2
      exit 2
      ;;
    *)
      claude_modes::mode_drop "$@"
      ;;
  esac
fi

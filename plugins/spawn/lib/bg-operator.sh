#!/usr/bin/env bash
# bg-operator.sh — the OPERATOR entry point for a background job (plan U8, R8).
#
#   printf 'fix the failing suite' | bg-operator.sh --alias gpt-sol
#
# This is one of two doors. A person typed the slash command that reached this
# one: they are present and accountable, so the child runs under the operator's
# own permission configuration. The other door, `bg-repo.sh`, is the one a
# calling AGENT reaches, and it hands its child the repo-bounded ceiling.
#
# WHY TWO FILES AND NOT ONE FLAG (R8)
# -----------------------------------
# The ceiling is decided by WHICH FILE RAN, so the harness's allowlist decides
# which ceiling a caller may reach. Allowlist this path for yourself and the
# agent path for your agents:
#
#   "Bash(bash */plugins/spawn/lib/bg-operator.sh:*)"   <- the person
#   "Bash(bash */plugins/spawn/lib/bg-repo.sh:*)"       <- the agent
#
# A single script taking `--ceiling operator` would be self-declared: any agent
# able to run it could claim to be the operator, and the harness would have no
# way to tell. That is why CEILING below is a constant with no argument path to
# it, and why the argument parser in ceilings.sh has no flag that sets it.
#
# Everything this door DOES lives in ceilings.sh, shared byte-for-byte with the
# other door — the security property is "these two paths differ only in the
# ceiling", and a copy-pasted body is how that quietly stops being true.
#
# set -e is deliberately OFF (only -u -o pipefail): every failure path is an
# exit code the contract names.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KTD5 — sourced, not re-implemented.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./ceilings.sh
. "$SCRIPT_DIR/ceilings.sh"

# The single stdout write lives in common.sh (emit); EMITTED is this script's
# own state, so it stays declared here.
EMITTED=0

# ---------------------------------------------------------------------------
# The one constant that distinguishes this door. There is no argument, no
# environment variable and no config key that changes it.
# ---------------------------------------------------------------------------
CEILING="$SPAWN_CEILING_OPERATOR"
ENTRY_POINT="bg-operator.sh"
CEILING_CALLER="operator — a person who typed a command, present and accountable"
CEILING_SUMMARY="The operator door. A background job started by a person runs under that person's own permission configuration; the ceiling is fixed by this file being the one that ran, not by anything the caller says about itself."

spawn::ceiling_main "$@"

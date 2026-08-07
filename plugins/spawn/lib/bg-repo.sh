#!/usr/bin/env bash
# bg-repo.sh — the AGENT entry point for a background job (plan U8, R8).
#
#   printf 'fix the failing suite' | bg-repo.sh --alias gpt-sol
#
# This is one of two doors. Whatever reached this one did so without a human in
# the loop, so the child runs under the REPO-BOUNDED ceiling: its writes are
# scoped to the worktree, version-control internals and hooks and agent
# configuration are denied, and — the part that actually bites — `user` is
# dropped from the child's setting sources, so the operator's own permissions
# are not inherited. Measured: a child launched from a session that broadly
# allows shell access could not run a shell command, while the control arm with
# the same prompt could.
#
# WHY TWO FILES AND NOT ONE FLAG (R8)
# -----------------------------------
# The ceiling is decided by WHICH FILE RAN, so the harness's allowlist decides
# which ceiling a caller may reach. Allowlist this path for your agents and the
# operator path for yourself:
#
#   "Bash(bash */plugins/spawn/lib/bg-repo.sh:*)"       <- the agent
#   "Bash(bash */plugins/spawn/lib/bg-operator.sh:*)"   <- the person
#
# A single script taking `--ceiling repo-bounded` would be self-declared: any
# agent able to run it could claim to be the operator instead, and the harness
# would have no way to tell. That is why CEILING below is a constant with no
# argument path to it, and why the argument parser in ceilings.sh has no flag
# that sets it.
#
# WHAT THIS DOOR DOES NOT DO
# --------------------------
# It does not police the bound (KD10). The ceiling is a permission
# configuration the child session runs under, and the HARNESS enforces it. This
# script chooses which configuration to hand down and hands it down. Within
# that bound the model still reads whatever the worktree contains, secrets
# included — the repo-bounded default denies execution-bearing paths, not
# readable ones.
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
CEILING="$SPAWN_CEILING_REPO"
ENTRY_POINT="bg-repo.sh"
CEILING_CALLER="calling agent — no human is present to answer for this job"
CEILING_SUMMARY="The agent door. A background job started autonomously runs repo-bounded: writes scoped to the worktree, version-control hooks and agent configuration denied, and the operator's own settings dropped from the child's sources so they cannot be inherited."

say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }

spawn::ceiling_main "$@"

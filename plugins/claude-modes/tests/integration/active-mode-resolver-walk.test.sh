#!/usr/bin/env bash
# Integration test: active-mode resolver walk-up semantics (the fix for the
# "non-repo subdir of a modes-project inherits the parent's pin" leak that
# blocked 0.3.0 shipping).
#
# Tests the new claude_modes::current_repo_root behavior: walk up from cwd
# looking for `.claude/modes/` (a directory). First ancestor that has the
# directory wins; stop at $HOME (exclusive). Empty result means no per-branch
# project root found; the read_active_mode_name caller then falls through to
# the user-global pointer.
#
# 7 scenarios mirroring the locked design:
#   1. cwd is exact project root with marker dir       → project root resolves
#   2. cwd is descendant of marker'd project           → project root resolves
#   3. cwd is non-repo subdir of UNMARKED tree         → no leak (THE FIX)
#   4. cwd is worktree of marker'd project on a       → falls through (no
#      branch the parent did NOT pin                      matching branch-pin)
#   5. nested marker'd project inside marker'd parent  → nested wins (stop-at-first)
#   6. cwd is exactly $HOME                            → no project root (defers)
#   7. marker dir present but matching branch-pin file → no per-branch pin
#      missing                                            (falls through to global)
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/active-mode.sh"

# Convenience: run claude_modes::current_repo_root from a given dir + capture
# its stdout. The function reads $PWD directly, so we cd into the dir first
# (in a subshell so we don't leak cwd to the next scenario).
__resolve_repo_root_from() {
  ( cd "$1" 2>/dev/null && claude_modes::current_repo_root )
}

# Same idea but for the full read_active_mode_name (the full chain).
__resolve_mode_from() {
  ( cd "$1" 2>/dev/null && claude_modes::read_active_mode_name )
}

# Helper: build a marker'd "project" (creates .claude/modes/ AND optionally a
# branch-pin file inside it). Does NOT git-init by default — we want to test
# resolver behavior independently of git context too.
__mark_project() {
  local dir="$1"
  mkdir -p "${dir}/.claude/modes"
}

__pin_branch() {
  local dir="$1" branch="$2" mode_name="$3"
  mkdir -p "${dir}/.claude/modes"
  printf '%s' "$mode_name" > "${dir}/.claude/modes/${branch}.mode"
  chmod 0600 "${dir}/.claude/modes/${branch}.mode"
}

# Build a git repo at the given dir on the given branch (so the resolver's
# current_branch_slug returns a real value when called from inside). The
# initial commit adds a .keep file at the toplevel so the toplevel itself
# is git-tracked (the marker-walk's second gate requires this).
__git_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  ( cd "$dir" \
    && git init -q \
    && git checkout -q -b "$branch" 2>/dev/null \
    && touch .keep && git add .keep && git commit -q -m "init"
  ) >/dev/null 2>&1
}

# Add + commit a tracked file at the given path inside a repo, so descendants
# of that path are considered git-tracked under the marker-walk's second gate.
__track_path() {
  local repo_dir="$1" relpath="$2"
  mkdir -p "$(dirname "${repo_dir}/${relpath}")"
  touch "${repo_dir}/${relpath}"
  ( cd "$repo_dir" && git add "$relpath" && git commit -q -m "add $relpath" ) >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────
# Scenario 1: cwd IS the project root, has .claude/modes/
# ──────────────────────────────────────────────────────────────────────────
PROJECT="${HOME}/scenario1-project"
__git_repo "$PROJECT" "main"
__pin_branch "$PROJECT" "main" "delivery"
claude_modes_test::it "scenario 1: cwd == project root with marker → returns root"
got=$(__resolve_repo_root_from "$PROJECT")
expected=$(cd "$PROJECT" && pwd -P)
claude_modes_test::assert_eq "$expected" "$got"
claude_modes_test::it "scenario 1: full resolution returns the pinned mode"
got=$(__resolve_mode_from "$PROJECT")
claude_modes_test::assert_eq "delivery" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 2: cwd is a TRACKED descendant of the marker'd root (e.g. src/).
# Tracked because the marker-walk's second gate requires it — untracked
# descendants are tested separately in scenario 3.
# ──────────────────────────────────────────────────────────────────────────
__track_path "$PROJECT" "src/deep/nested/file.go"
claude_modes_test::it "scenario 2: cwd in TRACKED subdir of project → root resolves"
got=$(__resolve_repo_root_from "${PROJECT}/src/deep/nested")
expected=$(cd "$PROJECT" && pwd -P)
claude_modes_test::assert_eq "$expected" "$got"
claude_modes_test::it "scenario 2: full resolution still returns the pinned mode"
got=$(__resolve_mode_from "${PROJECT}/src/deep/nested")
claude_modes_test::assert_eq "delivery" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 3 — THE FIX (real this time): cwd is an UNTRACKED non-repo subdir
# of a MARKED project. The first-pass dir-as-marker fix would have leaked
# the parent's pin here (since `.claude/modes/` walks up successfully); the
# second-gate "cwd must be git-tracked" rejects it because the dir is not
# in the project's index.
#
# This is the original blocker — `~/projects/<project>/<random-scratch-dir>/`
# inheriting the project's mode against the user's intent.
# ──────────────────────────────────────────────────────────────────────────
mkdir -p "${PROJECT}/scratch/random"
# scratch/ is NOT git-tracked (no `git add`). It physically lives under a
# marker'd project, but the resolver MUST refuse to honor the parent's pin.
claude_modes_test::it "scenario 3: cwd in UNTRACKED subdir of marked project → no leak"
got=$(__resolve_repo_root_from "${PROJECT}/scratch/random")
claude_modes_test::assert_eq "" "$got"
claude_modes_test::it "scenario 3: full resolution returns empty (no mode)"
got=$(__resolve_mode_from "${PROJECT}/scratch/random")
claude_modes_test::assert_eq "" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 3b — also: cwd in an entirely unmarked tree → no project root.
# Unmarked means no .claude/modes/ anywhere on the walk-up.
# ──────────────────────────────────────────────────────────────────────────
UNMARKED="${HOME}/scenario3b-unmarked-tree"
__git_repo "$UNMARKED" "main"
mkdir -p "${UNMARKED}/anywhere"
claude_modes_test::it "scenario 3b: cwd in unmarked tree (no .claude/modes/ above) → no mode"
got=$(__resolve_mode_from "${UNMARKED}/anywhere")
claude_modes_test::assert_eq "" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 4: cwd is a worktree of a marker'd parent, on a branch the
# parent did NOT pin. The walk-up will find the parent's marker, but the
# branch-slug won't match a pin file there → falls through to global
# (which is empty in this test → returns empty).
# ──────────────────────────────────────────────────────────────────────────
WTPARENT="${HOME}/scenario4-parent"
__git_repo "$WTPARENT" "main"
__pin_branch "$WTPARENT" "main" "delivery"
# Add a worktree on a branch NOT pinned in the parent.
( cd "$WTPARENT" && git worktree add -q -b feature-x worktrees/wt1 ) >/dev/null 2>&1
claude_modes_test::it "scenario 4: worktree of marked parent → no mode (global empty)"
got=$(__resolve_mode_from "${WTPARENT}/worktrees/wt1")
claude_modes_test::assert_eq "" "$got"
# Under the marker + git-tracked gate, the worktree path is NOT tracked in
# the parent's working tree (`git worktree add` registers the worktree but
# doesn't add its dir to the parent's index). So the second gate rejects
# walking up to the parent's marker. This is the desired behavior:
# worktrees stand on their own, they don't inherit their parent's pin.
claude_modes_test::it "scenario 4: walk does NOT cross worktree boundary into parent"
got=$(__resolve_repo_root_from "${WTPARENT}/worktrees/wt1")
claude_modes_test::assert_eq "" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 5: nested marker'd project inside a marker'd parent → nested wins
# (stop-at-first; "more specific wins")
# ──────────────────────────────────────────────────────────────────────────
OUTER="${HOME}/scenario5-outer"
__git_repo "$OUTER" "main"
__pin_branch "$OUTER" "main" "outer-mode"
INNER="${OUTER}/sub/inner"
__git_repo "$INNER" "main"
__pin_branch "$INNER" "main" "inner-mode"
claude_modes_test::it "scenario 5: cwd inside nested marker'd project → returns INNER root"
got=$(__resolve_repo_root_from "$INNER")
expected=$(cd "$INNER" && pwd -P)
claude_modes_test::assert_eq "$expected" "$got"
claude_modes_test::it "scenario 5: full resolution returns the INNER mode, not OUTER"
got=$(__resolve_mode_from "$INNER")
claude_modes_test::assert_eq "inner-mode" "$got"
claude_modes_test::it "scenario 5: cwd in OUTER (not under INNER) → still returns OUTER"
got=$(__resolve_mode_from "$OUTER")
claude_modes_test::assert_eq "outer-mode" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 6: cwd is exactly $HOME. The walk should NOT consider
# $HOME/.claude/modes/ as a project root (that's the user-global modes dir,
# the fallback tier, not a per-branch project pin).
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "scenario 6: cwd at HOME → no project root (defers to global)"
got=$(__resolve_repo_root_from "$HOME")
claude_modes_test::assert_eq "" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 7: marker dir present but the branch's pin file is absent.
# The resolver finds the project but read_active_mode_name finds no
# matching `.mode` file → no per-branch mode (falls through to global).
# ──────────────────────────────────────────────────────────────────────────
HOLLOW="${HOME}/scenario7-hollow-marker"
__git_repo "$HOLLOW" "main"
__mark_project "$HOLLOW"  # creates .claude/modes/ but no .mode file inside
claude_modes_test::it "scenario 7: marker dir but no branch-pin → no per-branch mode"
got=$(__resolve_mode_from "$HOLLOW")
claude_modes_test::assert_eq "" "$got"
claude_modes_test::it "scenario 7: but the project root IS reported (marker found)"
got=$(__resolve_repo_root_from "$HOLLOW")
expected=$(cd "$HOLLOW" && pwd -P)
claude_modes_test::assert_eq "$expected" "$got"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]

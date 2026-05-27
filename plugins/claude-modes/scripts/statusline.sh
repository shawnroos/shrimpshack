#!/usr/bin/env bash
# claude-modes: statusline emitter.
#
# Claude Code's statusline mechanism: the harness invokes this script
# on every status refresh, passes session metadata as JSON on stdin,
# and renders whatever this script writes to stdout as the right-hand
# statusline.
#
# Visibility rules (V1.1, per design decision A.2):
#   - When a mode IS active on the current branch: emit `🔧 <mode> · <branch>`
#   - When NO mode is active (or not in a git repo, or modes dir absent):
#     emit nothing. Silence is the default state; the positive signal
#     should be unmistakable when present, and the negative signal
#     should not steal statusline real estate from the user's other
#     tooling (cmux, crex, git status, etc.).
#
# Cost-of-being-installed guarantee: the FIRST check is the modes-dir
# presence gate, before any subprocess work (git, etc.). Same pattern
# as scripts/on-*.sh hook shims.
#
# Statusline scripts are perf-sensitive (called frequently). This script
# must complete in well under 100ms in the no-mode case.

# ── Helper: emit an OSC 2 terminal title escape ────────────────────────────
# Most modern terminals (iTerm2, Ghostty, kitty, alacritty) interpret
# `\033]2;<title>\007` as a window-title set. cmux picks the same
# escape up for tab titles. The escape is non-printing in terminals
# that don't support it, so it's a safe always-emit signal.
#
# Per A.2-with-reset decision: we ALWAYS emit a title (even when no
# mode is active) so the title reflects current state. Otherwise a
# stale `[mode] foo` title would persist in the tab after /mode:clear.

set -uo pipefail

# Source the shared display sanitizer early (pure function def, no side effects
# — doesn't violate the cost-of-being-installed presence gate below, which is
# about WORK not function definitions). __cm_title is the single chokepoint for
# every terminal title this script emits, so sanitizing $1 here covers ALL
# title content (the cwd basename — attacker-influenceable via clone dir name —
# and the validated mode name). The OSC-2 framing is this script's own (safe).
__cm_sl_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${__cm_sl_dir}/../lib/sanitize.sh" 2>/dev/null || true

__cm_title() {
  # terminal-escape: strip Cc+Cf from title content so a crafted cwd basename
  # can't inject OSC/CSI/bidi into the terminal title. Falls back to raw only
  # if the sanitizer somehow didn't load (then the title is best-effort).
  local __t="$1"
  if command -v claude_modes::sanitize_for_display >/dev/null 2>&1; then
    __t="$(claude_modes::sanitize_for_display "$1")"
  fi
  printf '\033]2;%s\007' "$__t"
}

# ── Modes-dir guard (MUST be first — cost-of-being-installed) ────────────
# When the modes dir is absent, we can't even know whether a mode is
# active — so we emit nothing (no statusline segment, no title). The
# user's existing host title-setting (if any) takes over.
[ -d "${HOME}/.claude/modes" ] || exit 0

# ── Read stdin event JSON (Claude Code passes session metadata) ───────────
# We need the cwd to decide which repo we're in. Claude Code passes it
# as `workspace.current_dir` or similar; pull both via Python for
# robustness. Bail silently if we can't parse — the statusline must
# never block the prompt with an error.
CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

input=$(cat 2>/dev/null)
if [ -z "$input" ]; then
  exit 0
fi

cwd=$(
  "$CLAUDE_MODES_PYTHON3" - "$input" <<'PYEOF' 2>/dev/null
import json, sys, os
try:
    d = json.loads(sys.argv[1])
    # Claude Code statusline event shape: workspace.current_dir.
    # Defensive: also try cwd / current_dir at the top level.
    cwd = (
        d.get("workspace", {}).get("current_dir")
        or d.get("cwd")
        or d.get("current_dir")
        or os.getcwd()
    )
    print(cwd)
except Exception:
    pass
PYEOF
)

# If we couldn't determine cwd, fall back to bash's PWD. Statusline
# scripts inherit cwd from the caller in most harnesses, so this is
# usually correct.
[ -z "$cwd" ] && cwd="${PWD}"
[ -d "$cwd" ] || exit 0

# Compute the cwd basename once — used in both the "active mode" title
# (`[mode] basename`) and the "no mode" title (`basename` alone).
cwd_basename=$(basename "$cwd")

# ── No-mode reset helper ───────────────────────────────────────────────────
# Per A.2-with-reset: when there's no active mode (for any reason —
# not in a git repo, detached HEAD, no .mode file, empty mode name),
# emit a bare-cwd-basename title to clear any stale `[mode] ...`
# prefix from a previous active state. Emit NO statusline segment
# (A.2 silence on the statusline side — only the title resets).
__cm_reset_and_exit() {
  __cm_title "$cwd_basename"
  exit 0
}

# ── Resolve the active mode via the canonical per-branch chain ──────────
# Source active-mode.sh (transitively sources validate-mode-name + repo-root)
# and call read_per_branch_mode_name from a subshell cd'd into $cwd, so the
# resolver sees the harness-provided cwd (not the script's process PWD).
#
# CRITICAL: read_per_branch_mode_name — NOT read_active_mode_name. The
# statusline is a per-repo display surface; it must NOT consult the
# user-global ~/.claude/modes/.last-active-mode pointer. That pointer is a
# shared mutable variable across every concurrent claude-modes session
# (see feedback_mode_set_leaks_via_global_pointer_to_other_sessions); a
# statusline that read it would flicker to reflect another tab's
# /mode:set in a repo/branch that has no pin of its own. The per-branch
# function returns empty when there's no pin in this repo+branch —
# correct behavior for "this repo's mode."
#
# Routing through claude_modes::current_repo_root (the GATED read-side
# resolver: walks up for a .claude/modes marker AND requires cwd to be
# git-tracked under it) ALSO refuses to display a parent project's mode
# from an untracked subdir. The .mode body goes through read_validated_
# mode_body (charset [A-Za-z0-9_-]+, reserved-token-rejected, length-
# capped, "claude" sentinel accepted) so the OSC-2 title and statusline
# segment cannot carry ESC/OSC/CSI/bidi bytes from a hostile committed
# .mode file.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/active-mode.sh"
mode_name=$(cd "$cwd" 2>/dev/null && claude_modes::read_per_branch_mode_name) || __cm_reset_and_exit
[ -n "$mode_name" ] || __cm_reset_and_exit
# "claude" is the no-mode-active sentinel; reset to bare-cwd title.
[ "$mode_name" = "claude" ] && __cm_reset_and_exit

# ── Emit the statusline segment ────────────────────────────────────────────
# Format: `🔧 <mode>` wrapped in ANSI yellow.
# Designed for COMPOSITION with an existing statusline (like the
# claude-code-templates beads-statusline pattern). The host statusline
# is expected to chain this snippet via:
#
#   modes_segment=""
#   if [ -x "$HOME/.claude/plugins/claude-modes/scripts/statusline.sh" ]; then
#     modes_segment=$(echo "$input" | bash "$HOME/.claude/plugins/claude-modes/scripts/statusline.sh" 2>/dev/null)
#     [ -n "$modes_segment" ] && modes_segment=" $modes_segment"
#   fi
#   printf "📁 %s%s%s%s" "$display_path" "$git_status" "$beads_status" "$modes_segment"
#
# We omit the branch slug from the segment because the host statusline
# almost certainly already shows the git branch. Showing it twice would
# be visual noise. The mode name alone is the load-bearing signal —
# the user can cross-reference it with the existing git-branch segment
# if they want to verify slug consistency.
#
# We do NOT prepend a separator (space / bullet) — the host composes
# the separator. This mirrors the convention beads-statusline.sh uses.
#
# ── Title escape (B.1 prefix style: `[mode] cwd-basename`) ────────────────
# OSC 2 escape — most terminals and cmux pick this up as the window/tab
# title. Emit it BEFORE the visible statusline segment so the title
# escape doesn't appear as a visible artifact in renderers that DON'T
# interpret OSC 2 (it'd be a no-op in those terminals; the visible
# segment still renders correctly). Per A.2-with-reset, this fires on
# every refresh when a mode is active, which keeps the title in sync
# with mode state.
__cm_title "[${mode_name}] ${cwd_basename}"

# ── Statusline segment ─────────────────────────────────────────────────────
# ANSI color: yellow (\033[33m) to visually distinguish the mode segment
# from the host's path/git/beads context (which all render in default
# fg). Reset (\033[0m) at the end so the color doesn't bleed into any
# future host content that might render AFTER the mode segment.
# Per-mode color (declarative `color:` field in the mode YAML) is a
# V1.2 candidate — once there are more than 2 authored modes, having
# discovery=yellow / delivery=green / oncall=red becomes useful, but
# V1 ships single-color so the mechanism is verifiable first.
printf '\033[33m🔧 %s\033[0m' "$mode_name"

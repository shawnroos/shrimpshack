#!/usr/bin/env bash
# claude-modes: idempotent installer for the statusline snippet.
#
# Mechanism: Claude Code has a single user-level statusline slot
# (~/.claude/settings.json::statusLine.command). Multiple plugins
# can't all own it; the established pattern (beads-statusline,
# git-statusline, etc.) is to ship a composable snippet that the
# user's existing statusline script chains into via `[ -x ... ]`
# guards.
#
# This script implements the chain insertion on behalf of the user:
#   - Reads ~/.claude/settings.json to discover the configured
#     statusLine.command path
#   - Locates the user's statusline script
#   - Inserts a marked block right before the final printf
#   - Augments the final printf to include the mode segment
#   - Idempotent: re-running is a no-op if the marker is already
#     present (no double-insertion)
#   - Backs up the original before mutation
#   - VERIFIES the patched file contains the marker AND parses cleanly
#     BEFORE committing — refuses to commit a broken patch
#
# Uninstall: scripts/uninstall-statusline.sh
# Slash command:  /mode:statusline install | uninstall | status
#
# Implementation note: an earlier draft used `awk -v snippet="$snippet"`
# to inject the multi-line snippet. awk variables cannot carry literal
# newlines, so the patch silently produced an empty (or broken) tmp
# file while the script still printed success. The current version
# does all file manipulation in Python (which handles multi-line
# naturally) and asserts the marker is present in the output before
# mv-ing to the target.

set -uo pipefail

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
SETTINGS_FILE="${HOME}/.claude/settings.json"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MARKER_BEGIN="# >>> claude-modes statusline snippet (managed — do not edit between markers)"
MARKER_END="# <<< claude-modes statusline snippet"

# Parse args: optional --target <path> for fixture testing.
TARGET_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-statusline.sh [--target <path>]

Inserts the claude-modes statusline snippet into the user's configured
statusline script. With --target, operates on the given file instead
of the script discovered from ~/.claude/settings.json (useful for
fixture testing).
USAGE
      exit 0
      ;;
    *) echo "install-statusline: unknown arg: $1" >&2; exit 2 ;;
  esac
done

__die() {
  echo "install-statusline: $1" >&2
  exit 1
}

# maint-3: shared parser (lib/statusline-target.sh). This caller's policy:
# __die on any miss + require the resolved script be writable (it edits it).
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/statusline-target.sh"

__resolve_statusline_target() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    __die "no ~/.claude/settings.json found — Claude Code has no statusline configured. Create a statusline script and register it in settings.json first, then re-run install."
  fi

  local raw
  if ! raw=$(claude_modes::statusline_extract_command_path "$SETTINGS_FILE"); then
    __die "could not find a script path in settings.json::statusLine.command. Make sure your statusLine.command points at a shell script (e.g., 'bash ~/.claude/statusline.sh')."
  fi

  local resolved
  resolved="${raw/#\~/$HOME}"
  [ ! -f "$resolved" ] && __die "statusline script not found at: $resolved"
  [ ! -w "$resolved" ] && __die "statusline script not writable: $resolved"
  printf '%s' "$resolved"
}

# ──────────────────────────────────────────────────────────────────────────
# Main.

if [ -n "$TARGET_OVERRIDE" ]; then
  [ ! -f "$TARGET_OVERRIDE" ] && __die "--target file not found: $TARGET_OVERRIDE"
  [ ! -w "$TARGET_OVERRIDE" ] && __die "--target file not writable: $TARGET_OVERRIDE"
  target="$TARGET_OVERRIDE"
  echo "install-statusline: using explicit --target ${target}"
else
  target=$(__resolve_statusline_target) || exit 1
fi

# Idempotency: marker already present → no-op.
if grep -qF "$MARKER_BEGIN" "$target" 2>/dev/null; then
  echo "install-statusline: already installed in ${target}"
  echo "  (marker present — no changes made)"
  echo "  Run 'bash ${PLUGIN_ROOT}/scripts/uninstall-statusline.sh' to remove."
  exit 0
fi

# Backup before any mutation. Backup is preserved even on success so
# the user has a known-good restore point.
backup="${target}.backup.$(date +%Y%m%d-%H%M%S)"
cp -p "$target" "$backup" || __die "could not create backup at $backup"
echo "install-statusline: backed up to ${backup}"

# Patch the file via Python so multi-line strings and quoting just work.
# We assert the result is valid AND contains the marker before committing.
tmp=$(mktemp -t claude-modes-install-statusline.XXXXXX) || __die "could not mktemp"
trap 'rm -f "$tmp"' EXIT

# Export everything Python needs as env vars (avoids quoting hell).
export CM_TARGET="$target"
export CM_TMP="$tmp"
export CM_PLUGIN_ROOT="$PLUGIN_ROOT"
export CM_MARKER_BEGIN="$MARKER_BEGIN"
export CM_MARKER_END="$MARKER_END"

"$CLAUDE_MODES_PYTHON3" - <<'PYEOF' || __die "Python patcher failed — original preserved at ${target}; backup at ${backup}"
import os, re, sys

target = os.environ["CM_TARGET"]
tmp = os.environ["CM_TMP"]
plugin_root = os.environ["CM_PLUGIN_ROOT"]
begin = os.environ["CM_MARKER_BEGIN"]
end = os.environ["CM_MARKER_END"]

with open(target) as f:
    content = f.read()

lines = content.splitlines(keepends=False)

# Find the last line starting with `printf` (this is the convention
# every reasonable statusline script follows — the final assembly
# happens in one printf at the bottom).
target_idx = None
for i in range(len(lines) - 1, -1, -1):
    s = lines[i].lstrip()
    if s.startswith("printf"):
        target_idx = i
        break

if target_idx is None:
    sys.stderr.write(
        "install-statusline: could not locate the final printf in "
        f"{target}. The statusline script doesn't match the expected "
        "shape (a script ending with a single 'printf' line). Open the "
        "file and add the snippet manually — see README.\n"
    )
    sys.exit(1)

original_printf = lines[target_idx]

# Augment the printf:
#   printf "<fmt>" arg1 arg2 ...
# becomes
#   printf "<fmt>%s" arg1 arg2 ... "$modes_segment"
m = re.match(r'^(\s*printf\s+)"([^"]*)"(.*)$', original_printf)
if not m:
    sys.stderr.write(
        "install-statusline: the final printf line doesn't match the "
        "expected shape (printf \"<format>\" <args>). Add the snippet "
        "manually — see README. Line was:\n"
        f"  {original_printf}\n"
    )
    sys.exit(1)

head, fmt, rest = m.group(1), m.group(2), m.group(3)
if "modes_segment" in original_printf:
    sys.stderr.write(
        "install-statusline: 'modes_segment' is already referenced in "
        "the printf line but the marker block is missing — the file "
        "is in a partially-installed state. Run uninstall first, then "
        "re-install.\n"
    )
    sys.exit(1)

new_fmt = fmt + "%s"
new_rest = (rest.rstrip() + ' "$modes_segment"').strip()
new_printf = f'{head}"{new_fmt}" {new_rest}'

# Build the snippet block. f-string with explicit \n so the layout
# survives across editor settings.
snippet = (
    f"{begin}\n"
    f"modes_segment=\"\"\n"
    f"if [ -x \"{plugin_root}/scripts/statusline.sh\" ]; then\n"
    f"  modes_segment=$(printf '%s' \"$input\" | bash \"{plugin_root}/scripts/statusline.sh\" 2>/dev/null)\n"
    f"  [ -n \"$modes_segment\" ] && modes_segment=\" $modes_segment\"\n"
    f"fi\n"
    f"{end}"
)

# Replace the printf line with: snippet + augmented printf.
# No interstitial blank line — keeping it tight makes uninstall a clean
# byte-identical round-trip (verified by tests/integration/
# statusline-install.test.sh).
new_lines = lines[:target_idx] + [snippet] + [new_printf] + lines[target_idx + 1:]
new_content = "\n".join(new_lines) + "\n"

# Verification BEFORE writing: assert the marker is present in the
# generated content. This catches the failure mode where the patch
# silently produces an empty or marker-less file (the awk regression
# from the previous draft).
if begin not in new_content:
    sys.stderr.write(
        "install-statusline: ASSERTION FAILED — patched content does "
        "NOT contain the begin marker. Refusing to commit.\n"
    )
    sys.exit(2)
if "modes_segment" not in new_content:
    sys.stderr.write(
        "install-statusline: ASSERTION FAILED — patched content does "
        "NOT reference $modes_segment. Refusing to commit.\n"
    )
    sys.exit(2)

with open(tmp, "w") as f:
    f.write(new_content)

print(f"  patched: inserted snippet before line {target_idx + 1}")
print(f"  patched: augmented printf with %s + \"$modes_segment\"")
PYEOF

# Syntax-check the patched file. If bash -n rejects it, refuse to
# commit — the user's working statusline must never be replaced with
# a broken one.
if ! bash -n "$tmp" 2>/dev/null; then
  __die "patched file failed bash -n syntax check. Original preserved at ${target}; broken patch at ${tmp}. Inspect manually."
fi

# Final assertion: the patched file is non-empty and larger than the
# original (because we added the snippet). Catches the silent-truncate
# failure mode.
orig_size=$(wc -c < "$target")
new_size=$(wc -c < "$tmp")
if [ "$new_size" -le "$orig_size" ]; then
  __die "patched file is not larger than the original (orig=${orig_size}B, new=${new_size}B). Something went wrong — original preserved at ${target}; broken patch at ${tmp}."
fi

# Commit the patch.
cat "$tmp" > "$target"
rm -f "$tmp"
trap - EXIT

echo ""
echo "install-statusline: snippet installed in ${target}"
echo "  Backup preserved at: ${backup}"
echo "  Removal: bash ${PLUGIN_ROOT}/scripts/uninstall-statusline.sh"
echo ""
echo "Restart Claude Code (or wait for the next statusline refresh) to see"
echo "  🔧 <mode>  on the right of your statusline when a mode is active."

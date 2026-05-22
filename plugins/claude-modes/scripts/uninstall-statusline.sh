#!/usr/bin/env bash
# claude-modes: idempotent uninstaller for the statusline snippet.
#
# Reverses scripts/install-statusline.sh:
#   1. Locates the user's statusline script (via settings.json).
#   2. Strips the marker-wrapped block.
#   3. Reverses the printf augmentation (removes trailing `%s` from
#      the format string and the `"$modes_segment"` arg).
#   4. Idempotent: a clean (already-uninstalled) target is a no-op.
#   5. Backs up the original before mutation.
#
# Slash command: /mode:statusline uninstall

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
Usage: uninstall-statusline.sh [--target <path>]

Removes the claude-modes statusline snippet from the user's configured
statusline script (or the file given via --target).
USAGE
      exit 0
      ;;
    *) echo "uninstall-statusline: unknown arg: $1" >&2; exit 2 ;;
  esac
done

__die() {
  echo "uninstall-statusline: $1" >&2
  exit 1
}

# maint-3: shared parser (lib/statusline-target.sh) — both install and
# uninstall source it from lib/ (no coupling between the two entry points).
# This caller's policy: __die on any miss + require writable (it edits it).
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/statusline-target.sh"

__resolve_statusline_target() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    __die "no ~/.claude/settings.json found — nothing to uninstall from."
  fi

  local raw
  if ! raw=$(claude_modes::statusline_extract_command_path "$SETTINGS_FILE"); then
    __die "could not find a script path in settings.json::statusLine.command"
  fi

  local resolved
  resolved="${raw/#\~/$HOME}"

  [ ! -f "$resolved" ] && __die "statusline script not found at: $resolved"
  [ ! -w "$resolved" ] && __die "statusline script not writable: $resolved"

  printf '%s' "$resolved"
}

if [ -n "$TARGET_OVERRIDE" ]; then
  [ ! -f "$TARGET_OVERRIDE" ] && __die "--target file not found: $TARGET_OVERRIDE"
  [ ! -w "$TARGET_OVERRIDE" ] && __die "--target file not writable: $TARGET_OVERRIDE"
  target="$TARGET_OVERRIDE"
  echo "uninstall-statusline: using explicit --target ${target}"
else
  target=$(__resolve_statusline_target) || exit 1
fi

if ! grep -qF "$MARKER_BEGIN" "$target" 2>/dev/null; then
  echo "uninstall-statusline: not installed in ${target} — nothing to do."
  exit 0
fi

# Backup before mutation.
backup="${target}.backup.$(date +%Y%m%d-%H%M%S)"
cp -p "$target" "$backup" || __die "could not create backup at $backup"
echo "uninstall-statusline: backed up to ${backup}"

# Strategy:
#   1. Delete every line from MARKER_BEGIN through MARKER_END, inclusive.
#   2. Find the line that has both `printf` and `"$modes_segment"`, and
#      reverse the augmentation: strip trailing `%s` from the format
#      string and strip the trailing `"$modes_segment"` arg.

tmp=$(mktemp -t claude-modes-uninstall-statusline.XXXXXX) || __die "could not mktemp"
trap 'rm -f "$tmp"' EXIT

# Step 1: strip the marked block.
awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
{
  if ($0 == begin) { skip = 1 }
  if (!skip) print
  if ($0 == end) { skip = 0; next }
}
' "$target" > "$tmp"

# Step 2: reverse the printf augmentation.
"$CLAUDE_MODES_PYTHON3" - "$tmp" <<'PYEOF' > "${tmp}.printf"
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Find the last line containing `printf` AND `$modes_segment`.
lines = content.splitlines(keepends=True)
target_idx = None
for i in range(len(lines) - 1, -1, -1):
    if "printf" in lines[i] and "$modes_segment" in lines[i]:
        target_idx = i
        break

if target_idx is None:
    sys.stdout.write(content)
    sys.exit(0)

line = lines[target_idx].rstrip("\n")
# Reverse augmentation: format string ends with %s, args end with
# "$modes_segment". Strip both. Conservative single-regex pass.
# Match:  printf <ws> "<fmt>%s" ... "$modes_segment"
m = re.match(r'^(printf\s+)"([^"]*)%s"(.*?)\s+"\$modes_segment"(.*)$', line)
if m:
    head, fmt_minus_s, mid, tail = m.group(1), m.group(2), m.group(3), m.group(4)
    new_line = f'{head}"{fmt_minus_s}"{mid}{tail}'
    lines[target_idx] = new_line + "\n"

sys.stdout.write("".join(lines))
PYEOF

mv "${tmp}.printf" "$tmp"

# Sanity: the new file must be syntactically valid bash.
if ! bash -n "$tmp" 2>/dev/null; then
  __die "the unpatched statusline failed bash -n syntax check. Original is preserved at ${target}; failed unpatch at ${tmp}. Inspect manually."
fi

cat "$tmp" > "$target"
rm -f "$tmp"
trap - EXIT

echo "uninstall-statusline: snippet removed from ${target}"
echo "  Backup preserved at: ${backup}"
echo "  To re-install: bash ${PLUGIN_ROOT}/scripts/install-statusline.sh"

#!/usr/bin/env bash
# Slate-root containment. Sourced, never executed.
#
# Every entry point calls this before doing anything else, so it is the one
# thing standing between the plugin and a repository it has no business
# touching. Two failure shapes it exists to prevent, both of which a string
# prefix admits: a sibling directory whose name begins with the root path
# ("SlateOther" against "Slate"), and a symlink that resolves somewhere else
# entirely. Both operands are therefore resolved before they are compared, and
# the comparison carries a trailing separator.
#
# Fail-closed: an unresolvable root, an unresolvable path, or an empty argument
# all answer "outside". The plugin declining to act is the safe direction; the
# hooks that call this still exit 0 so a session is never blocked.

# Only a real directory can be contained. The plugin acts on repositories and
# worktrees, so a non-directory target is refused outright rather than resolved.
# That one rule closes three ways the boundary was escapable: a symlink to a
# file outside the root (the parent resolved, the link's own name did not), a
# dangling symlink, and a hardlink -- which is not a link in the path at all,
# has no target to follow, and would survive any amount of readlink.
# A symlink TO a directory still resolves correctly through the cd/pwd -P below.
herdr_linear::_resolve() {
    local p="$1"
    [ -n "$p" ] || return 1
    [ -d "$p" ] || return 1
    (cd "$p" 2>/dev/null && pwd -P) || return 1
}

# The root a session must sit under. The environment variable is the test seam;
# nothing in the plugin writes it at runtime.
herdr_linear::slate_root() {
    printf '%s' "${HERDR_LINEAR_SLATE_ROOT:-$HOME/projects/Slate}"
}

# herdr_linear::contains <path> -> 0 when <path> is the root or beneath it.
herdr_linear::contains() {
    local target="${1:-}" root resolved_root resolved_target
    [ -n "$target" ] || return 1

    root="$(herdr_linear::slate_root)"
    resolved_root="$(herdr_linear::_resolve "$root")" || return 1
    resolved_target="$(herdr_linear::_resolve "$target")" || return 1

    [ "$resolved_target" = "$resolved_root" ] && return 0
    case "$resolved_target" in
        "$resolved_root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

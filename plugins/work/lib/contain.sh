#!/usr/bin/env bash
# Slate-root containment, and the scope readers built on it. Sourced, never
# executed.
#
# Containment is a SIGNAL now, not a gate: no lib verb refuses for being
# outside, and the hooks read the signal themselves to keep their silence. What
# the comparison below still has to get right is the answer, and two failure
# shapes would make it wrong, both of which a string prefix admits: a sibling
# directory whose name begins with the root path
# ("SlateOther" against "Slate"), and a symlink that resolves somewhere else
# entirely. Both operands are therefore resolved before they are compared, and
# the comparison carries a trailing separator.
#
# An unresolvable root, an unresolvable path, or an empty argument all answer
# "outside" -- the reader still answers, and the hooks that read it exit 0, so a
# session is never blocked.

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

# ------------------------------------------------------------- scope readers
#
# One root used to answer four different questions. These are three of them,
# named apart. Every one of them ANSWERS: a reader that refuses cannot be
# weighed against anything else, and containment is a signal now, not a gate.
#
# The environment variable takes precedence over derivation in all three. It is
# the deliberate seam -- a caller that sets it has said where the work is, and
# nothing should second-guess that from a path. Derivation is what runs when
# nobody has said.

# herdr_linear::path_signal [dir] -> prints `inside` or `outside`. Always 0.
herdr_linear::path_signal() {
    if herdr_linear::contains "${1:-$PWD}"; then
        printf 'inside'
    else
        printf 'outside'
    fi
}

# herdr_linear::worktree_project [dir]
#
# The project directory this worktree belongs to: the parent of the `worktrees`
# directory it sits in, matching the ~/projects/<project>/worktrees/<feature>
# layout. Its basename is the project name. A directory that sits under no
# worktrees directory falls back to the configured root, which is the answer
# for a plain repository checkout.
herdr_linear::worktree_project() {
    local dir="${1:-$PWD}" resolved
    if [ -n "${HERDR_LINEAR_SLATE_ROOT:-}" ]; then
        printf '%s' "$HERDR_LINEAR_SLATE_ROOT"
        return 0
    fi
    resolved="$(herdr_linear::_resolve "$dir")" || { herdr_linear::slate_root; return 0; }
    case "$resolved" in
        */worktrees) printf '%s' "${resolved%/worktrees}"; return 0 ;;
        */worktrees/*) printf '%s' "${resolved%%/worktrees/*}"; return 0 ;;
    esac
    herdr_linear::slate_root
}

# herdr_linear::worktree_repo [dir]
#
# A git repository to run commands in: the directory holding the common git
# dir, so a linked worktree answers with the checkout it was made from.
# --path-format=absolute is load-bearing -- the bare form prints `.git` at a
# main checkout, which is a relative path and not somewhere `git -C` can go.
herdr_linear::worktree_repo() {
    local dir="${1:-$PWD}" common
    if [ -n "${HERDR_LINEAR_SLATE_ROOT:-}" ]; then
        printf '%s' "$HERDR_LINEAR_SLATE_ROOT"
        return 0
    fi
    common="$("${HERDR_LINEAR_GIT_BIN:-git}" -C "$dir" rev-parse \
        --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    [ -n "$common" ] || { herdr_linear::worktree_project "$dir"; return 0; }
    printf '%s' "$(dirname "$common")"
}

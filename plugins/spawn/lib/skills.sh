#!/usr/bin/env bash
# skills.sh — resolve a named skill to its directory, and provision a copy a
# background child can read.
#
# WHY A CHILD NEEDS THIS
# ---------------------
# A bg-agent child runs with `--setting-sources project`, which is what makes it
# genuinely narrower than its launcher — it does NOT inherit the operator's own
# skills. So a job asked to "run ce-code-review" has no such skill and will
# improvise something shaped like one. Copying the requested skill into the
# worktree's project skills directory is what makes the instruction real.
#
# WHY THE COPY IS READ-ONLY TO THE CHILD, AND THAT IS DELIBERATE
# --------------------------------------------------------------
# The ceiling allows Read across the worktree and DENIES Write/Edit on
# `.claude/**`. So the supervisor provisions and the child consumes. A child
# cannot edit a skill it was given, and cannot add itself another — the same
# separation the job record relies on, where the thing being reported is not the
# thing doing the reporting.
#
# RESOLUTION IS AUTHORITATIVE, NOT A GUESS
# ----------------------------------------
# A plugin skill exists at several cached versions at once — measured on this
# box: ce-code-review at 3.9.0, 3.21.1 AND 3.21.4. Picking "a match" or "the
# highest number" hands the job a stale skill that still looks right, which is
# the silent-wrong-behaviour class this plugin keeps paying for. The installed
# version is recorded in ~/.claude/plugins/installed_plugins.json as an explicit
# installPath, so that is what is read. No globbing for a version.

set -uo pipefail

# The shared sanitizer, sourced rather than reimplemented. A skill NAME is
# caller-controlled — it reaches this file from a command line the model
# composed — so every one of these diagnostics interpolates untrusted text into
# a stream a human may read. The lint in escapes.bats caught exactly that here.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# common.sh for the sanitizing say()/die(). Sourced even though this file calls
# neither directly: the lint walks the source GRAPH, and a shipped lib that can
# reach a raw say() is exactly what it exists to stop. Guarded so the double
# source from bg-agent.sh (which sources both) is a no-op.
if ! declare -F say >/dev/null 2>&1; then
    # shellcheck source=./common.sh
    . "$SCRIPT_DIR/common.sh"
fi

SPAWN_SKILLS_HOME="${SPAWN_SKILLS_HOME:-$HOME/.claude}"

# spawn::skill_resolve <name> — print the skill's source directory, or nothing.
#
# Accepts a bare name (`ce-code-review`) or the namespaced form
# (`compound-engineering:ce-code-review`). A user skill wins over a plugin skill
# of the same name, because that is the order the harness itself resolves them.
# spawn::skill_name_ok <name> — the identifier grammar, enforced before use.
#
# HARDENING, NOT A BUG FIX — and the distinction was earned. An adversarial
# review called `..` a P0 that would rm -rf the user's whole .claude directory.
# Traced end to end, it was not exploitable: POSIX rm REFUSES a path ending in
# `..`, and the copy never ran either because the destination resolved to an
# EXISTING directory and the collision check rejected it. Two incidental guards,
# neither written for this.
#
# It gets a grammar anyway, because "safe because something else happens to
# refuse it" is not a property you can rely on through the next edit. Default-
# deny on the characters a name may contain, not a blocklist of what has bitten.
#
# DEFAULT-DENY, and it stays that way: an allowlist of the characters a skill
# name may contain, not a blocklist of the sequences that have bitten so far.
# Enumerating bad inputs is how this plugin keeps shipping the same defect.
spawn::skill_name_ok() {
    local n="${1:-}" bare="${1##*:}"
    [ -n "$n" ] || return 1
    case "$bare" in
        .|..) return 1 ;;
    esac
    printf '%s' "$bare" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || return 1
    # A dot run cannot appear anywhere, not merely at the start.
    case "$bare" in *..*) return 1 ;; esac
    return 0
}

spawn::skill_resolve() {
    # Declared separately: `local a="$1" b="$a"` evaluates $a before a exists,
    # which under `set -u` is an unbound-variable error, not an empty string.
    local want="$1"
    spawn::skill_name_ok "$want" || return 1
    local plugin="" name
    name="$want"
    case "$want" in
        *:*) plugin="${want%%:*}"; name="${want##*:}" ;;
    esac

    # 1. the user's own skills
    if [ -z "$plugin" ] && [ -f "$SPAWN_SKILLS_HOME/skills/$name/SKILL.md" ]; then
        printf '%s' "$SPAWN_SKILLS_HOME/skills/$name"
        return 0
    fi

    # 2. an INSTALLED plugin's skills, per the installed-plugins record
    local reg="$SPAWN_SKILLS_HOME/plugins/installed_plugins.json"
    [ -f "$reg" ] || return 1
    python3 - "$reg" "$name" "$plugin" <<'PY' 2>/dev/null
import json, os, sys
reg, name, plugin = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(reg))
except Exception:
    sys.exit(1)

def install_paths(node):
    """Yield (key, installPath) for every installed plugin record.

    The file nests plugins under a marketplace key and each value is a LIST of
    scope records; walking generically means a layout change surfaces as 'not
    found' rather than as a wrong path silently resolving.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, list):
                for entry in v:
                    if isinstance(entry, dict) and entry.get("installPath"):
                        yield k, entry["installPath"]
            else:
                yield from install_paths(v)

for key, path in install_paths(data):
    if plugin and not key.startswith(plugin):
        continue
    cand = os.path.join(path, "skills", name)
    if os.path.isfile(os.path.join(cand, "SKILL.md")):
        print(cand)
        sys.exit(0)
sys.exit(1)
PY
}

# spawn::skill_selfcontained <dir> — 0 when nothing points outside the skill.
#
# A skill that resolves paths against its own plugin root cannot be copied
# somewhere else and still work; it would load and then fail on a path that is
# not there. Provisioning refuses such a skill rather than handing the child one
# that loads and then misbehaves — measured on this box, 8 of 215 user skills
# are refused, and each of those genuinely reads from its own plugin root.
spawn::skill_selfcontained() {
    local dir="$1"
    grep -rqE 'CLAUDE_PLUGIN_ROOT|plugins/cache/' "$dir" 2>/dev/null && return 1
    return 0
}

# spawn::skill_prune_escaping_links <dir> <name> — drop links the child cannot follow.
#
# After the copy, a nested link that does not resolve inside <dest> is dead
# weight: the ceiling refuses it, so it can only produce a refusal the reader
# will read as a permissions problem. Removing the link is deliberately NOT the
# same as materialising it — copying the target in would place content from
# outside the source root inside the worktree, a wider hole than the one being
# closed. An absolute link into the original source root is pruned too: it
# points back outside the worktree and is refused just the same.
#
# Returns non-zero when a link it meant to drop is still there — that link is the
# thing the ceiling refuses, so a caller must be able to see it.
spawn::skill_prune_escaping_links() {
    local dir="$1" name="$2" report kind rel rc=0
    report="$(python3 - "$dir" <<'PY'
import os, sys

# The invariant, stated once: a link is kept only when the path it RESOLVES to
# is the root or lives under it. Resolving the target's parent instead would
# read a chain whose next hop leaves as safe.
root = os.path.realpath(sys.argv[1])
for base, dirs, files in os.walk(root, followlinks=False):
    for entry in list(dirs) + list(files):
        link = os.path.join(base, entry)
        if not os.path.islink(link):
            continue
        target = os.path.realpath(link)
        if target == root or target.startswith(root + os.sep):
            continue
        rel = os.path.relpath(link, root)
        try:
            os.unlink(link)
        except OSError:
            print("failed\t" + rel)
        else:
            print("pruned\t" + rel)
PY
    )" || {
        printf 'skill_prune_unreadable\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        return 1
    }
    while IFS="$(printf '\t')" read -r kind rel; do
        [ -n "$kind" ] || continue
        case "$kind" in
            pruned) printf 'skill_link_pruned\t%s\t%s\n' \
                "$(spawn::sanitize_for_display "$name")" \
                "$(spawn::sanitize_for_display "$rel")" >&2 ;;
            # The link SURVIVES, so the ceiling refuses it and the reader blames
            # permissions — the misdiagnosis this function exists to remove.
            failed) printf 'skill_link_prune_failed\t%s\t%s\n' \
                "$(spawn::sanitize_for_display "$name")" \
                "$(spawn::sanitize_for_display "$rel")" >&2
                rc=1 ;;
        esac
    done <<EOF
$report
EOF
    return "$rc"
}

# spawn::skill_install_one <dest_root> <manifest> <name> — one skill, or nothing.
#
# Everything happens in a staging directory beside the destination, and the
# destination appears in one `mv` once the skill is known to be complete. That
# is what makes the manifest honest: a path the child can see and a line in the
# manifest exist only together, so teardown never has to reason about a half
# skill and the child never loads one.
spawn::skill_install_one() {
    local dest_root="$1" manifest="$2" name="$3"
    local src dest stage rc=0

    # Validated FIRST. spawn::skill_resolve gates on the same grammar, so a name
    # checked after it can only ever report `not found` for a name that is
    # actually invalid — the diagnostic would name the wrong problem.
    spawn::skill_name_ok "$name" || {
        printf 'skill_name_invalid\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        return 1
    }
    src="$(spawn::skill_resolve "$name")" || src=""
    if [ -z "$src" ]; then
        printf 'skill_not_found\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        return 1
    fi
    # A skill that resolves paths against its own plugin root cannot be copied
    # somewhere else and still work. Refused rather than provisioned, because
    # the child would load it and then fail on a path that is not there.
    spawn::skill_selfcontained "$src" || {
        printf 'skill_not_selfcontained\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        return 1
    }

    dest="$dest_root/${name##*:}"
    if [ -e "$dest" ]; then
        # Not an overwrite and not a silent skip — the caller asked for a skill
        # and something else already owns that name.
        printf 'skill_name_taken\t%s\t%s\n' \
            "$(spawn::sanitize_for_display "$name")" "$(spawn::sanitize_for_display "$dest")" >&2
        return 1
    fi

    # Beside the destination, so the `mv` that publishes it is a rename within
    # one filesystem rather than a second copy that can half-finish.
    stage="$(mktemp -d "$dest_root/.stage.XXXXXX")" || {
        printf 'skill_copy_failed\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        return 1
    }

    # Resolved before the copy, because `cp -R` preserves a symlink and most
    # entries in ~/.claude/skills are symlinks into ~/.agents/skills. The
    # permission system resolves a path BEFORE matching it, so the copy landed
    # inside the worktree pointing out of it and every child read was refused —
    # a provisioning bug that reads as a permissions one. `cp -RL` is not the
    # fix: it also materialises nested links that escape the source root, making
    # outside content real and readable in here.
    src="$(cd "$src" 2>/dev/null && pwd -P)" || src=""
    if [ -n "$src" ] && cp -R "$src" "$stage/payload" 2>/dev/null; then
        # cp -R carries the source's directory modes, and a read-only directory
        # makes the prune fail. Only directories need to be writable for that,
        # and the copy is a disposable child artifact, so nothing is lost.
        find "$stage/payload" -type d -exec chmod u+w {} + 2>/dev/null || rc=1
        spawn::skill_prune_escaping_links "$stage/payload" "$name" || rc=1
        if [ ! -r "$stage/payload/SKILL.md" ]; then
            # Pruning empties a skill whose own SKILL.md was a link out of the
            # source root. Nothing is published, so the child never sees it.
            printf 'skill_incomplete\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
            rc=1
        fi
    else
        printf 'skill_copy_failed\t%s\n' "$(spawn::sanitize_for_display "$name")" >&2
        rc=1
    fi

    if [ "$rc" -ne 0 ] || ! mv "$stage/payload" "$dest" 2>/dev/null; then
        rm -rf "$stage" 2>/dev/null
        return 1
    fi
    rmdir "$stage" 2>/dev/null
    printf '%s\n' "$dest" >> "$manifest"
    return 0
}

# spawn::skill_provision <worktree> <manifest> <name>...
#
# Copies each named skill into <worktree>/.claude/skills/, appending one line per
# provisioned skill to <manifest> so teardown removes exactly what was added and
# nothing a user put there. Refuses to overwrite: a job must never silently
# replace a skill the repo already ships. A non-zero return means at least one
# named skill did not land; the ones that did are still usable.
spawn::skill_provision() {
    local worktree="$1" manifest="$2"; shift 2
    local dest_root="$worktree/.claude/skills"
    local name rc=0

    mkdir -p "$dest_root" || {
        printf 'skill_dest_unwritable\t%s\n' "$(spawn::sanitize_for_display "$dest_root")" >&2
        return 1
    }
    for name in "$@"; do
        [ -n "$name" ] || continue
        spawn::skill_install_one "$dest_root" "$manifest" "$name" || rc=1
    done
    return "$rc"
}

# spawn::skill_unprovision <manifest> — remove exactly what was provisioned.
#
# Reads the manifest rather than globbing the destination: a glob would also
# delete a skill the user added to their own repo while the job ran.
spawn::skill_unprovision() {
    local manifest="$1" dest
    [ -f "$manifest" ] || return 0
    while IFS= read -r dest; do
        [ -n "$dest" ] || continue
        # Belt and braces on the delete. The glob alone matched
        # `<w>/.claude/skills/..`, which resolves OUT of the skills dir — so the
        # resolved path is compared, not the literal one. A manifest line that
        # does not resolve to a child of a `.claude/skills` directory is skipped,
        # never deleted.
        local real parent
        real="$(cd "$(dirname "$dest")" 2>/dev/null && pwd -P)/$(basename "$dest")" || continue
        parent="$(dirname "$real")"
        case "$parent" in
            */.claude/skills) : ;;
            *) continue ;;
        esac
        case "$(basename "$real")" in .|..) continue ;; esac
        rm -rf "$real" 2>/dev/null
    done < "$manifest"
    rm -f "$manifest" 2>/dev/null
    return 0
}

# spawn::skill_git_exclude <worktree> — keep provisioned skills out of git.
#
# `.claude/` is NOT gitignored in a typical repo here (measured on two), so a
# 500KB vendored skill would land in `git status` and is one `git add -A` from
# being committed. `.git/info/exclude` is local-only and never travels, so this
# does not edit a file the user tracks.
spawn::skill_git_exclude() {
    local worktree="$1"
    local gitdir; gitdir="$(git -C "$worktree" rev-parse --git-dir 2>/dev/null)" || return 0
    case "$gitdir" in /*) : ;; *) gitdir="$worktree/$gitdir" ;; esac
    local ex="$gitdir/info/exclude"
    mkdir -p "$(dirname "$ex")" 2>/dev/null || return 0
    grep -qF '.claude/skills/' "$ex" 2>/dev/null && return 0
    printf '\n# added by spawn: skills provisioned for a background job\n.claude/skills/\n' >> "$ex" 2>/dev/null
    return 0
}

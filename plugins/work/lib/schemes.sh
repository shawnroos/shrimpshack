#!/usr/bin/env bash
# schemes.sh — how the plugin names things. Sourced, never executed.
#
# A name is ASKED FOR by kind, not composed by the caller: a name composed at
# each call site drifts, one site slugging what the site beside it does not.
#
# This is an ENUMERATION rather than a template. A scheme is a name in a fixed
# set that this file renders. A placeholder language would let a setting grow
# shapes nobody tested; an enum cannot, and every member of it is reachable from
# one loop in the suite. An unrecognised scheme is REFUSED with the valid set
# named — never quietly replaced by the default, which would turn a typo into a
# silently different worktree location.
#
# Only three kinds have a rendering site in this plugin: a worktree, a branch,
# and a tab. The plugin never labels a space, and a pane is never labelled at
# all — herdr's `pane split` takes no label. Inventing schemes for two levels
# nothing renders would be an enum whose members no call site can reach.
#
# The DEFAULT of every scheme renders byte-identical names to today's. A
# default that changes an existing name silently re-homes every future worktree
# and breaks the identifier-in-both-places property that makes a worktree
# findable from its branch.

# No lib sources another, and the source order is not guaranteed: without this
# the calls below are 127, which a `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"

# Any Linear-derived name bound for a path, a branch or an argument is
# reduced to [A-Za-z0-9._-] and then REJECTED outright when the result would be
# dangerous rather than being repaired into something plausible: empty, `.`,
# `..`, or a leading hyphen (which every CLI reads as a flag) or dot (which
# hides the file). Repairing would silently produce a name nobody chose.
herdr_linear::slug() {
    local text="${1:-}" max="${2:-60}" raw out
    raw="$(printf '%s' "$text" | tr -c 'A-Za-z0-9._-' '-')"
    # Checked BEFORE trimming. Stripping the leading hyphens first and then
    # testing for them is a check that can never fire: `--rf` would quietly
    # become `rf`, which is exactly the repair this function must not perform.
    case "$raw" in
        -*|.*) return 1 ;;
    esac
    out="$(printf '%s' "$raw" | sed -E 's/-+/-/g; s/-+$//' | cut -c1-"$max")"
    case "$out" in
        ''|'.'|'..') return 1 ;;
    esac
    printf '%s' "$out"
}

HERDR_LINEAR_SCHEME_OK=0
HERDR_LINEAR_SCHEME_REFUSED=1
# Distinct from REFUSED. A refusal says this ticket cannot be named; UNKNOWN
# says the setting names a scheme that does not exist, which is a different
# thing to fix and a different thing for a caller to report.
HERDR_LINEAR_SCHEME_UNKNOWN=2

HERDR_LINEAR_SCHEME_KINDS="worktree branch tab"

HERDR_LINEAR_WORKTREE_SCHEMES="identifier-title identifier"
HERDR_LINEAR_BRANCH_SCHEMES="prefix-worktree worktree"
HERDR_LINEAR_TAB_SCHEMES="identifier identifier-title"

HERDR_LINEAR_WORKTREE_SCHEME_DEFAULT="identifier-title"
HERDR_LINEAR_BRANCH_SCHEME_DEFAULT="prefix-worktree"
HERDR_LINEAR_TAB_SCHEME_DEFAULT="identifier"

# The offending value reaches stderr only when it is closed under the slug charset.
# A scheme comes from an environment variable, so it is text a person typed and
# printing it raw would put an ESC or an OSC-2 title rewrite on the terminal.
herdr_linear::_scheme_printable() {
    if herdr_linear::is_safe_identifier "$1"; then printf '%s' "$1"; else printf '(unprintable)'; fi
}

herdr_linear::_scheme_unknown() {
    local what="$1" value="$2" valid="$3"
    printf '%s %s is not one this plugin renders; valid: %s\n' \
        "$what" "$(herdr_linear::_scheme_printable "$value")" "$valid" >&2
    printf 'A scheme is an enumeration, so adding one is a code change -- a branch in lib/schemes.sh, its test, and a suite-floor bump -- rather than a setting. Nothing was rendered.\n' >&2
    return "$HERDR_LINEAR_SCHEME_UNKNOWN"
}

herdr_linear::_scheme_in() {
    local want="$1" item
    for item in $2; do
        [ "$item" = "$want" ] && return 0
    done
    return 1
}

# `:-` and not `-`, unlike HERDR_LINEAR_BRANCH_PREFIX. An empty prefix means
# something -- no prefix -- so the two states must stay apart there. An empty
# scheme names nothing, so it can only mean the scheme was not chosen.
herdr_linear::_scheme_for() {
    local kind="$1" scheme valid
    case "$kind" in
        worktree) scheme="${HERDR_LINEAR_WORKTREE_SCHEME:-$HERDR_LINEAR_WORKTREE_SCHEME_DEFAULT}"
                  valid="$HERDR_LINEAR_WORKTREE_SCHEMES" ;;
        branch)   scheme="${HERDR_LINEAR_BRANCH_SCHEME:-$HERDR_LINEAR_BRANCH_SCHEME_DEFAULT}"
                  valid="$HERDR_LINEAR_BRANCH_SCHEMES" ;;
        tab)      scheme="${HERDR_LINEAR_TAB_SCHEME:-$HERDR_LINEAR_TAB_SCHEME_DEFAULT}"
                  valid="$HERDR_LINEAR_TAB_SCHEMES" ;;
        *)        return "$HERDR_LINEAR_SCHEME_UNKNOWN" ;;
    esac
    herdr_linear::_scheme_in "$scheme" "$valid" \
        || herdr_linear::_scheme_unknown "the $kind scheme" "$scheme" "$valid" || return
    printf '%s' "$scheme"
}

# The only title-slug pipeline in the plugin: two copies of a name's shape is a
# divergence waiting for the day somebody improves one.
#
# The 40-character cut can sever a word in half, so the severed remnant is
# dropped -- but only when the cut actually happened. Trimming unconditionally
# would cost every short title its last word.
herdr_linear::_scheme_title_slug() {
    local title="$1" slug
    slug="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' \
        | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
    if [ "${#slug}" -gt 40 ]; then
        slug="$(printf '%s' "$slug" | cut -c1-40 | sed -E 's/-[^-]*$//; s/-+$//')"
    fi
    [ -n "$slug" ] || return 1
    printf '%s' "$slug"
}

herdr_linear::_scheme_render_worktree() {
    local scheme="$1" ident="$2" title="$3" slug
    case "$scheme" in
        identifier-title)
            slug="$(herdr_linear::_scheme_title_slug "$title")" || return 1
            herdr_linear::slug "$ident-$slug" 60 ;;
        identifier)
            herdr_linear::slug "$ident" 60 ;;
        *)  return 1 ;;
    esac
}

# herdr_linear::scheme_name <kind> <identifier> <title> [branch-prefix]
#
# Prints the rendered name and returns OK, or prints nothing and returns
# REFUSED (this ticket cannot be named) or UNKNOWN (the scheme does not exist).
herdr_linear::scheme_name() {
    local kind="${1-}" ident="${2-}" title="${3-}"
    # `-` and not `:-`, twice over. Setting the prefix empty gets the branch
    # and the directory back as one identical string; `:-` would collapse that
    # explicit empty into "feature".
    local prefix="${4-${HERDR_LINEAR_BRANCH_PREFIX-feature}}"
    local scheme wt_scheme name wt rc

    case "$kind" in
        worktree|branch|tab) ;;
        *) herdr_linear::_scheme_unknown "the name kind" "$kind" "$HERDR_LINEAR_SCHEME_KINDS"
           return "$HERDR_LINEAR_SCHEME_UNKNOWN" ;;
    esac

    scheme="$(herdr_linear::_scheme_for "$kind")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    herdr_linear::is_safe_identifier "$ident" || {
        printf 'the ticket identifier %s cannot be part of a name; nothing was rendered\n' \
            "$(herdr_linear::_scheme_printable "$ident")" >&2
        return "$HERDR_LINEAR_SCHEME_REFUSED"
    }

    case "$kind" in
        worktree)
            name="$(herdr_linear::_scheme_render_worktree "$scheme" "$ident" "$title")" || name="" ;;
        branch)
            # A branch is the worktree name behind a prefix convention, so it
            # follows the WORKTREE scheme. That is what keeps the identifier in
            # both places: changing one changes the other with it.
            wt_scheme="$(herdr_linear::_scheme_for worktree)"; rc=$?
            [ "$rc" -eq 0 ] || return "$rc"
            wt="$(herdr_linear::_scheme_render_worktree "$wt_scheme" "$ident" "$title")" || wt=""
            if [ -z "$wt" ]; then
                name=""
            elif [ "$scheme" = "prefix-worktree" ] && [ -n "$prefix" ]; then
                name="$prefix/$wt"
            else
                name="$wt"
            fi ;;
        tab)
            case "$scheme" in
                # Verbatim, not through herdr_linear::slug, which squeezes
                # separator runs. Tabs already open carry the bare identifier
                # as their label, and this has to reproduce that byte for byte.
                identifier)       name="$ident" ;;
                identifier-title) name="$(herdr_linear::_scheme_render_worktree identifier-title "$ident" "$title")" || name="" ;;
            esac ;;
    esac

    [ -n "$name" ] || {
        printf 'the title of %s renders no name under the %s scheme %s; nothing was rendered\n' \
            "$ident" "$kind" "$scheme" >&2
        return "$HERDR_LINEAR_SCHEME_REFUSED"
    }

    # Enforced rather than trusted. A scheme is free to compose the name any
    # way it likes, but a worktree that does not carry its identifier cannot be
    # found from its branch -- and the 60-character cut is a live way to lose it
    # without anyone writing a scheme that omits it.
    case "$kind" in
        worktree|branch)
            case "$name" in
                *"$ident"*) ;;
                *) printf 'the %s scheme %s dropped the identifier %s from the name it rendered; nothing was rendered\n' \
                       "$kind" "$scheme" "$ident" >&2
                   return "$HERDR_LINEAR_SCHEME_REFUSED" ;;
            esac ;;
    esac

    printf '%s' "$name"
    return "$HERDR_LINEAR_SCHEME_OK"
}

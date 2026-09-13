#!/usr/bin/env bash
# schemes.sh — how the plugin names things. Sourced, never executed.
#
# R4/R5. A name is ASKED FOR by kind, not composed by the caller. Before this,
# a name was either what one shell function returned or a literal at the line
# that used it, and the two drifted: the layout verb in lib/herdr-write.sh slugs
# the tab label it sets, the session verb beside it sets its label unslugged,
# and nothing reconciled them. Both ask here now.
#
# R6, and the reason this is an ENUMERATION rather than a template. A scheme is
# a name in a fixed set that this file renders. A placeholder language would let
# a setting grow shapes nobody tested; an enum cannot, and every member of it is
# reachable from one loop in the suite. An unrecognised scheme is REFUSED with
# the valid set named — never quietly replaced by the default, which would turn
# a typo into a silently different worktree location.
#
# R4 names five kinds. Only three of them have a rendering site in this plugin:
# a worktree, a branch, and a tab. A space label is set once, at
# `lib/create.sh:241`, and a pane is never labelled at all — herdr's `pane split`
# takes no label. Inventing schemes for two levels nothing renders would be an
# enum whose members no call site can reach.
#
# KTD5. The DEFAULT of every scheme renders byte-identical names to today's. A
# default that changes an existing name silently re-homes every future worktree
# and breaks the identifier-in-both-places property that makes a worktree
# findable from its branch.

# No lib sources another, and the source order is not guaranteed: without these
# the calls below are 127, which a `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::slug >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/linear.sh"

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

# ------------------------------------------------------------------ refusing

# The offending value reaches stderr only when it is closed under R28's charset.
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

# ----------------------------------------------------------------- rendering

# The only title-slug pipeline in the plugin. `start_worktree_name` held a
# byte-for-byte copy of it until it was routed through here; two copies of a
# name's shape is a divergence waiting for the day somebody improves one.
#
# The 40-character cut can sever a word in half, so the severed remnant is
# dropped -- but only when the cut actually happened. Trimming unconditionally
# cost every short title its last word.
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

# herdr_linear::scheme_wants_title <kind>
#
# True when the kind's chosen scheme renders the title as well as the
# identifier. A site holding only an identifier -- both tab labels do -- uses
# this to decide whether to go and read the title. The DEFAULT tab scheme does
# not want one, so the common path still asks Linear nothing it did not already
# ask; without this the alternative was to make `identifier-title` a tab scheme
# no site could render.
herdr_linear::scheme_wants_title() {
    local kind="${1-}" scheme
    # A branch is rendered from the WORKTREE scheme, so that is the one to ask.
    if [ "$kind" = branch ]; then kind=worktree; fi
    # Silenced: an unrecognised scheme is reported by the render that refuses,
    # and a caller that asks this first would otherwise print the same complaint
    # twice for one typo.
    scheme="$(herdr_linear::_scheme_for "$kind" 2>/dev/null)" || return 1
    case "$scheme" in
        identifier-title) return 0 ;;
    esac
    return 1
}

# ----------------------------------------------------------------- the resolver

# herdr_linear::scheme_name <kind> <identifier> <title> [branch-prefix]
#
# Prints the rendered name and returns OK, or prints nothing and returns
# REFUSED (this ticket cannot be named) or UNKNOWN (the scheme does not exist).
herdr_linear::scheme_name() {
    local kind="${1-}" ident="${2-}" title="${3-}"
    # `-` and not `:-`, twice over. KTD1 says setting the prefix empty gets the
    # branch and the directory back as one identical string; `:-` would collapse
    # that explicit empty into "feature" and make the claim false.
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
                # separator runs. `herdr-write.sh:229` labels a tab from the bare
                # identifier today and this has to reproduce that byte for byte.
                identifier)       name="$ident" ;;
                identifier-title) name="$(herdr_linear::_scheme_render_worktree identifier-title "$ident" "$title")" || name="" ;;
            esac ;;
    esac

    [ -n "$name" ] || {
        printf 'the title of %s renders no name under the %s scheme %s; nothing was rendered\n' \
            "$ident" "$kind" "$scheme" >&2
        return "$HERDR_LINEAR_SCHEME_REFUSED"
    }

    # R7, enforced rather than trusted. A scheme is free to compose the name any
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

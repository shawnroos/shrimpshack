#!/usr/bin/env bash
# The bind skill's arguments: parse them, and check each id against the bind rule.
# Sourced, never executed.

# The same codes record.sh defines, so this file can be sourced without it and
# the skill's parse=1 and parse=2 still mean what its table says.
HERDR_LINEAR_BINDING_ABSENT=1
HERDR_LINEAR_BINDING_REFUSED=2

# The bind arguments can arrive from any board-socket client, so they get a
# stricter rule than sanitize.sh's general identifier rule, which admits `.` and
# has no length cap and which every other caller depends on as it is.

# The charsets are enumerated for the reason sanitize.sh gives: bash 3.2 matches
# a range by locale collation. The first-character rule is what keeps
# `-rf` and `--exec` from reaching argv as options; the charset admits both.
herdr_linear::is_bind_identifier() {
    local s="${1:-}"
    [ -n "$s" ] || return 1
    [ "${#s}" -le 64 ] || return 1
    case "$s" in
        [!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
    esac
    case "$s" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
    esac
    return 0
}

# herdr_linear::bind_args_parse [--space S --project P [--view V | --issue I]]
#   0  four `field<TAB>value` lines, space, project, view, issue, in that order
#   1  no arguments: the interactive form
#   2  refused; a reason naming the flag, never the value, on stderr
# The value after a flag is taken whatever it looks like and handed to the rule:
# a parser that skipped option-shaped values would be a second, unmutated guard.
# A view and an issue together are refused because no entry point sends both.
herdr_linear::bind_args_parse() {
    local space="" project="" view="" issue="" flag seen=" "
    [ "$#" -gt 0 ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    while [ "$#" -gt 0 ]; do
        flag="$1"
        case "$flag" in
            --space|--project|--view|--issue) ;;
            *) printf 'bind: unexpected argument; the form is --space --project [--view | --issue]\n' >&2
               return "$HERDR_LINEAR_BINDING_REFUSED" ;;
        esac
        case "$seen" in
            *" $flag "*) printf 'bind: %s given twice\n' "$flag" >&2
                         return "$HERDR_LINEAR_BINDING_REFUSED" ;;
        esac
        seen="$seen$flag "
        if [ "$#" -lt 2 ]; then
            printf 'bind: %s has no value\n' "$flag" >&2
            return "$HERDR_LINEAR_BINDING_REFUSED"
        fi
        if ! herdr_linear::is_bind_identifier "$2"; then
            printf 'bind: %s is not a valid identifier\n' "$flag" >&2
            return "$HERDR_LINEAR_BINDING_REFUSED"
        fi
        case "$flag" in
            --space) space="$2" ;;
            --project) project="$2" ;;
            --view) view="$2" ;;
            --issue) issue="$2" ;;
        esac
        shift 2
    done
    if [ -z "$space" ] || [ -z "$project" ]; then
        printf 'bind: --space and --project are both required\n' >&2
        return "$HERDR_LINEAR_BINDING_REFUSED"
    fi
    if [ -n "$view" ] && [ -n "$issue" ]; then
        printf 'bind: --view and --issue are not given together\n' >&2
        return "$HERDR_LINEAR_BINDING_REFUSED"
    fi
    printf 'space\t%s\nproject\t%s\nview\t%s\nissue\t%s' "$space" "$project" "$view" "$issue"
}

# herdr_linear::bind_space_is_own <space> <pane space>
# The caller passes the pane's space as the position resolver reports it, not
# HERDR_WORKSPACE_ID: that variable keeps the launch space after a pane move.
# An empty pane space refuses, so a session outside herdr binds no space.
herdr_linear::bind_space_is_own() {
    local space="${1:-}" own="${2:-}"
    if [ -z "$own" ] || ! herdr_linear::is_bind_identifier "$space" || [ "$space" != "$own" ]; then
        printf 'bind: --space is not the space this session runs in\n' >&2
        return "$HERDR_LINEAR_BINDING_REFUSED"
    fi
    return 0
}

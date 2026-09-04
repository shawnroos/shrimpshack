#!/usr/bin/env bash
# sanitize.sh — this plugin's untrusted-text accessors (R28, KD10).
#
# WHY THIS EXISTS
# Anyone with tracker access can write the text this plugin reads: issue titles,
# descriptions, comments, project and state names, plus branch names from the
# repository. That text becomes paths, arguments, session context and terminal
# output. ESC / CSI / OSC sequences (an OSC-2 title rewrite, a CSI line-erase)
# and Unicode bidi overrides (U+202E) in it can rewrite the statusline or spoof
# a consent prompt.
#
# It is VENDORED, not sourced from plugins/spawn (KTD8).
#
# R28 splits the defence in two, and both halves live here:
#   * identifiers (issue keys, branch fragments, state names) are closed BY
#     CONSTRUCTION — herdr_linear::is_safe_identifier validates against
#     [A-Za-z0-9._-]+, so an escape byte or a path separator in an identifier is
#     impossible rather than filtered. A denylist has to enumerate every hostile
#     shape and is wrong the moment a new one appears; the closed charset needs
#     no new rule. Prefer this at every input site.
#   * free-form text (issue prose, API error bodies, log tails) is sanitised
#     HERE, at the sink.
#
# The precedent is plugins/claude-modes/docs/solutions/terminal-escape-audit.md.
# Its lesson is about METHOD: that bug class recurred across three review rounds
# because each round's narrow grep found one new sibling sink, and the audit doc
# itself once falsely claimed a sink was sanitised. So sanitising belongs at
# CHOKEPOINTS — inside whatever say()/die() a surface owns — rather than at call
# sites.
#
# SCOPE (deliberate)
# Strips: C0 controls except tab (9) and newline (10) — which means ESC (27),
# CR (13), BEL (7) and NUL all go; DEL (127); C1 controls (128-159); and the
# Unicode format characters that reorder or hide text: soft hyphen (173),
# U+061C, U+200B-U+200F, U+2028-U+202E, U+2060-U+206F, U+FEFF.
# Keeps: tab and newline (a stripped newline would run a multi-line issue
# description together into one unreadable line), and every printable character
# including non-ASCII prose.
# Does NOT do NFKC / homoglyph / confusable defence — that is a separate
# concern, and saying so beats implying coverage.

# The filter, as a jq program. jq is this plugin's JSON reader for every Linear
# API response, so it is present wherever the plugin does real work; it is
# UTF-8-aware, and it replaces invalid bytes with U+FFFD instead of erroring —
# so no input can make it fail open.
#
# Codepoints are numeric on purpose: a range written with backslash-u escapes
# is one editor accident away from embedding the literal control byte it is
# supposed to describe, in the very file whose job is removing it.
HERDR_LINEAR_SANITIZE_JQ_DEF='
def strip_display_controls:
  explode
  | map(select(
      (. == 9 or . == 10)
      or ( . > 31 and . != 127
           and (. < 128 or . > 159)
           and . != 173
           and . != 1564
           and (. < 8203 or . > 8207)
           and (. < 8232 or . > 8238)
           and (. < 8288 or . > 8303)
           and . != 65279 )))
  | implode;
def strip_display_deep:
  walk(if type == "string" then strip_display_controls else . end);
'

# herdr_linear::sanitize_for_display <string>
# Prints the string with display-control characters removed.
#
# The jq-less fallback is `tr`, which is byte-oriented: it removes every C0
# control except tab and newline, plus DEL — so ESC, and therefore every CSI
# and OSC sequence, is still impossible. The multi-byte Unicode format
# characters, U+202E among them, SURVIVE it. That residue is stated rather than
# papered over: a machine with no jq cannot read a Linear response at all, so
# the surfaces that carry tracker prose have already failed by then, and the
# only text reaching this path is the plugin's own.
herdr_linear::sanitize_for_display() {
    local out rc
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "$1" | jq -Rrs "$HERDR_LINEAR_SANITIZE_JQ_DEF strip_display_controls" 2>/dev/null)"
        rc=$?
        if [ $rc -eq 0 ]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    printf '%s' "$1" | LC_ALL=C tr -d '\001-\010\013-\037\177'
}

# herdr_linear::sanitize_stream
# Filter form, for piping a file or a command's output to a terminal — an API
# error body or a log tail. Line-oriented (jq -R reads a line at a time), so it
# streams rather than buffering a whole log into memory.
herdr_linear::sanitize_stream() {
    if command -v jq >/dev/null 2>&1; then
        jq -Rr "$HERDR_LINEAR_SANITIZE_JQ_DEF strip_display_controls" 2>/dev/null
    else
        LC_ALL=C tr -d '\001-\010\013-\037\177'
    fi
}

# herdr_linear::is_safe_identifier <string>
# The construction half of R28. True only for a non-empty string made entirely
# of [A-Za-z0-9._-], and never for "." or ".." — a bare dot pair passes the
# charset and is a directory traversal the moment it becomes a path segment.
#
# Every string that becomes a path segment, a branch name, a git argument or a
# command argument goes through this BEFORE it is used, not after. The test for
# it lists the hostile shapes it refuses, and the point of the closed charset is
# that the list is illustrative rather than exhaustive.
herdr_linear::is_safe_identifier() {
    local s="${1:-}"
    [ -n "$s" ] || return 1
    case "$s" in
        .|..) return 1 ;;
    esac
    case "$s" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

#!/usr/bin/env bash
# sanitize.sh — the gateway plugin's shared terminal-display sanitizer (KTD5).
#
# WHY THIS EXISTS
# ---------------
# The plugin's whole job is printing text produced by a non-Anthropic model,
# plus alias names and notes read from a user-editable gateway.yaml, straight
# to a terminal. ESC / CSI / OSC sequences (an OSC-2 title rewrite, a CSI
# line-erase) and Unicode bidi overrides (U+202E) in that output can rewrite
# the statusline or spoof a consent prompt.
#
# KTD5 splits the defence in two, and this file is only HALF of it:
#   * identifiers (alias names, session ids) are closed BY CONSTRUCTION — they
#     are validated against [A-Za-z0-9._-]+ at every input site, so an escape
#     byte in an identifier is impossible rather than filtered. Prefer that.
#   * free-form text (model prose, gateway error bodies, config-derived notes,
#     process argv, log tails) is sanitized HERE, at the sink.
#
# The precedent is plugins/claude-modes/docs/solutions/terminal-escape-audit.md.
# Its lesson is about METHOD: that bug class recurred across three review rounds
# because each round's narrow grep found one new sibling sink, and the audit doc
# itself once falsely claimed a sink was sanitized. So this plugin sanitizes at
# CHOKEPOINTS — inside say() / die() / emit_error() — rather than at call sites,
# and the source x sink matrix in README.md is verified against source.
#
# SCOPE (deliberate)
# ------------------
# Strips: C0 controls except tab (9) and newline (10) — which means ESC (27),
# CR (13), BEL (7) and NUL all go; DEL (127); C1 controls (128-159); and the
# Unicode format characters that reorder or hide text: soft hyphen (173),
# U+061C, U+200B-U+200F, U+2028-U+202E, U+2060-U+206F, U+FEFF.
# Keeps: tab and newline (a stripped newline would run a multi-line diagnostic
# together into one unreadable line), and every printable character including
# non-ASCII prose and the plugin's own U+25B8 marker.
# Does NOT do NFKC / homoglyph / confusable defence — that is a separate
# concern, deferred, and README.md says so rather than implying coverage.
#
# NOT SANITIZED, BY DESIGN: the lens's JSON `text` field and its spill file.
# They are data, KTD5 assigns that sink to the consumer, and stripping there
# would corrupt legitimate code blocks in a review answer.

# The filter, as a jq program. jq is already a hard dependency of every script
# in this plugin (each one calls need_jq and exits 2 without it), it is
# UTF-8-aware, and it replaces invalid bytes with U+FFFD instead of erroring —
# so no input can make it fail open.
#
# Codepoints are numeric on purpose: a range written with backslash-u escapes
# is one editor accident away from embedding the literal control byte it is
# supposed to describe, in the very file whose job is removing it.
SPAWN_SANITIZE_JQ_DEF='
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

# spawn::sanitize_for_display <string>
# Prints the string with display-control characters removed.
#
# The jq-less fallback is `tr`, which is byte-oriented: it removes every C0
# control except tab and newline, plus DEL — so ESC, and therefore every CSI
# and OSC sequence, is still impossible. Only the multi-byte Unicode format
# characters survive it. That residue is accepted rather than papered over:
# without jq every script in this plugin exits 2 within a few lines anyway,
# because the contract it cannot satisfy is "one JSON object on stdout".
spawn::sanitize_for_display() {
    local out rc
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "$1" | jq -Rrs "$SPAWN_SANITIZE_JQ_DEF strip_display_controls" 2>/dev/null)"
        rc=$?
        if [ $rc -eq 0 ]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    printf '%s' "$1" | LC_ALL=C tr -d '\001-\010\013-\037\177'
}

# spawn::sanitize_stream
# Filter form, for piping a file or a command's output to a terminal — the log
# tail in spawnctl.sh and the seed-run stderr tail in launch.sh. Line-oriented
# (jq -R reads a line at a time), so it streams rather than buffering a whole
# log into memory.
spawn::sanitize_stream() {
    if command -v jq >/dev/null 2>&1; then
        jq -Rr "$SPAWN_SANITIZE_JQ_DEF strip_display_controls" 2>/dev/null
    else
        LC_ALL=C tr -d '\001-\010\013-\037\177'
    fi
}

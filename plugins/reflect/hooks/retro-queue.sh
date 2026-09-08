#!/usr/bin/env bash
# retro-queue.sh — PreCompact + SessionEnd hook. Stashes a reference to the
# session's transcript so vent material survives compaction and session end
# (R7). One script serves both events; the event name and its trigger/reason
# distinguish the records.
#
# It stashes and exits. It never reads a transcript, so the cursor field is
# always written EMPTY — U3's drain owns that field (KTD7) and stamps the
# last-processed uuid back onto the record. Empty means "from the first record".
#
# Queue line, tab-separated, exactly five fields:
#   session_id <TAB> transcript_path <TAB> cursor_uuid <TAB> event <TAB> ts
#
# Input is JSON on STDIN. `$TOOL_INPUT` and friends do NOT exist for
# `"type": "command"` hooks — two matchers written against them sat dead in this
# plugin for months producing zero triggers.
#
# Fail-open ALWAYS: every path exits 0 (R11). A record that cannot be stashed is
# a non-event; a hook that returns non-zero is a broken session.
#
#   env: REFLECT_RETRO_QUEUE   override the queue path (tests)

set -u

command -v jq >/dev/null 2>&1 || exit 0

QUEUE="${REFLECT_RETRO_QUEUE:-$HOME/.claude/.retro-queue}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || exit 0

# jq assembles the whole line in one pass, reading stdin directly: `echo "$json"
# | jq` mangles backslashes, and a transcript path is exactly the payload that
# would carry them.
#
# `clean` strips tabs, newlines and carriage returns from every field. A raw tab
# would weld two fields into one and a raw newline would split one record into
# two — both read back at drain time as corruption rather than as an error.
# Deliberately NOT @tsv: that escapes tabs and backslashes, which would invent
# an encoding U3 has to know to decode, and silently mangle a path containing a
# backslash.
#
# No transcript path means nothing the drain can use, so no line is written.
# Fail-open means exit 0, not always append.
LINE="$(jq -r '
  def clean: (. // "") | tostring | gsub("[\t\n\r]"; " ");
  if ((.transcript_path // "") | tostring) == "" then
    empty
  else
    (((.trigger // .reason) // "") | clean) as $detail
    | [ (.session_id | clean),
        (.transcript_path | clean),
        "",
        ((.hook_event_name // "unknown" | clean)
          + (if $detail == "" then "" else ":" + $detail end)),
        $ts
      ] | join("\t")
  end' --arg ts "$TS" 2>/dev/null)" || exit 0

[ -n "$LINE" ] || exit 0

mkdir -p "$(dirname "$QUEUE")" 2>/dev/null || exit 0

# The queue is a running index of every project path the operator works in.
umask 077
# One printf of one line. Several sessions compact independently and append to
# this one file; a prior torn-tail defect in this repo welded a record onto a
# fragment (KTD8).
printf '%s\n' "$LINE" >> "$QUEUE" 2>/dev/null || true

exit 0

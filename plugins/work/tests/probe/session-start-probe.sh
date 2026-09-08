#!/usr/bin/env bash
# U1 — prove whether a hook can put text in front of the model on this build.
#
# Two tokens, one JSON object. One sits under hookSpecificOutput.additionalContext,
# the channel the documentation describes. The other sits under a sibling key the
# harness has no reason to read. The discrimination is the whole point:
#
#   only the additionalContext token comes back -> the channel is real
#   BOTH come back                              -> the harness is dumping our
#                                                  stdout, and additionalContext
#                                                  is NOT proven; a later hook
#                                                  that prints a diagnostic would
#                                                  break grounding
#   neither, but the PostToolUse control works  -> SessionStart cannot inject
#   neither, and the control fails too          -> inconclusive; blocks Phase B
#
# It also records what the payload actually carried, because no script in this
# repo reads a SessionStart stdin field today.
set -u
OUT="${HERDR_LINEAR_PROBE_DIR:?probe dir required}"
mkdir -p "$OUT"

payload="$(cat)"
printf '%s' "$payload" > "$OUT/${1:-sessionstart}.payload.json"

live="$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c 12)"
decoy="$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c 12)"
printf 'live=%s\ndecoy=%s\n' "$live" "$decoy" > "$OUT/${1:-sessionstart}.tokens"

# The decoy key is deliberately not part of any documented hook contract.
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"PROBE-LIVE-%s"},"herdrLinearDecoy":"PROBE-DECOY-%s"}\n' \
  "${2:-SessionStart}" "$live" "$decoy"
exit 0

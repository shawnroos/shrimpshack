#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf '%s' "${0##*/}"; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
printf 'trace-env %s\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')" >> "${FAKE_CALLS:-/dev/null}"
[ -n "${FAKE_TRACE_EXIT:-}" ] && { echo 'trace store unreachable' >&2; exit "$FAKE_TRACE_EXIT"; }
case "$1" in
  show) printf '{"id":"%s","service":"web","status":"ok"}\n' "$2" ;;
  sha) printf '%s\n' "$FAKE_DEPLOYED_SHA" ;;
  *) echo "fake trace: unhandled $*" >&2; exit 2 ;;
esac

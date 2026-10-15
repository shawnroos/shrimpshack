#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf 'ldcli'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
printf 'ldcli-env %s\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')" >> "${FAKE_CALLS:-/dev/null}"
[ "${LD_ACCESS_TOKEN:-}" = "${FAKE_LD_TOKEN:-}" ] && printf 'ldcli-token ok\n' >> "${FAKE_CALLS:-/dev/null}"
[ -n "${FAKE_LD_MISSING:-}" ] && { cat "${FAKE_FIXTURES}/ld-flag-not-found-real.err" >&2; exit 1; }
[ -n "${FAKE_LD_EXIT:-}" ] && { echo 'Required flag(s) "access-token" not set' >&2; exit "$FAKE_LD_EXIT"; }
case "$1 $2" in
  "flags get") cat "$FAKE_LD_FLAG" ;;
  *) echo "fake ldcli: unhandled $*" >&2; exit 2 ;;
esac
